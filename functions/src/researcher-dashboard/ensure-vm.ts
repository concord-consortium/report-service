import { MicrovmApi } from "./microvm"
import { runnerPath, vmPath } from "./firestore-paths"
import { Db, Researcher, RunPackageBody } from "./run-package"

// PENDING or RUNNING: the VM asks for work at the end of /run and again before it idles.
// SUSPENDING: the watchdog resumes a SUSPENDED VM that has work outstanding.
export type VmOutcome = "launched" | "launching" | "resumed" | "running" | "suspending"

const LAUNCH_STATES = [undefined, "TERMINATING", "TERMINATED"]
// Longer than RunMicrovm plus the mint round trip, short enough that a launcher that crashed
// holding it does not block the researcher for long.
const LAUNCH_CLAIM_MS = 60 * 1000
const RUN_HOOK_PAYLOAD_MAX_BYTES = 16384
// Per upstream call, each made once; the four a launch makes fit the function's 60-second timeout.
export const UPSTREAM_TIMEOUT_MS = 10 * 1000

export interface VmDoc {
  microvm_id?: string
  image_version?: string
  launching_until?: number | null
}

export interface EnsureVmDeps {
  db: Db
  microvms: MicrovmApi
  fetchImpl: typeof fetch
  now(): number
  timestamp(): unknown
  config: {
    imageIdentifier: string
    executionRoleArn: string
    bucket: string
    reportServerUrl: string
    functionUrl: string
  }
}

/**
 * A failure after the work was queued, answered with its status and reason. `vmMayExist` marks
 * a launch that may have created a VM, whose claim must lapse rather than be cleared.
 */
export class VmStepError extends Error {
  constructor(public status: number, message: string, public vmMayExist = false) {
    super(message)
  }
}

const reason = (e: unknown) => e instanceof Error ? e.message : String(e)

const within = <T>(promise: Promise<T>, ms: number): Promise<T> => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`no answer within ${ms / 1000} seconds`)), ms)
  promise.then(
    value => { clearTimeout(timer); resolve(value) },
    error => { clearTimeout(timer); reject(error) }
  )
})

/**
 * Makes sure the researcher has one VM that will take the queued work: launches one if there is
 * none, resumes a suspended one, and otherwise leaves it. Never waits for a VM to change state.
 */
export async function ensureVm(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody): Promise<VmOutcome> {
  const vmRef = deps.db.doc(vmPath(who.portal, who.platformUserId))
  // Asked outside any transaction: a transaction can retry, and must not span a network call.
  const seen = (await vmRef.get()).data() as VmDoc | undefined
  let state: string | undefined
  try {
    state = seen?.microvm_id ? (await deps.microvms.get(seen.microvm_id))?.state : undefined
  } catch (e) {
    throw new VmStepError(502, `GetMicrovm failed: ${reason(e)}`)
  }

  if (state === "SUSPENDED") return resume(deps, seen!.microvm_id!)
  if (state === "SUSPENDING") return "suspending"
  if (!LAUNCH_STATES.includes(state)) return "running"

  // The transaction re-reads the document and claims only if nobody launched or claimed since
  // it was read above, so two concurrent requests launch at most one VM.
  const claimed = await deps.db.runTransaction(async tx => {
    const vm = (await tx.get(vmRef)).data() as VmDoc | undefined
    if (vm?.launching_until && vm.launching_until > deps.now()) return false
    if ((vm?.microvm_id ?? null) !== (seen?.microvm_id ?? null)) return false
    tx.set(vmRef, { launching_until: deps.now() + LAUNCH_CLAIM_MS }, { merge: true })
    return true
  })
  if (!claimed) return "launching"

  // Once a VM may exist, a failure leaves the claim to lapse rather than clearing it: clearing
  // would let the next request launch a second VM.
  let launched: Launched
  try {
    launched = await launch(deps, who, body)
  } catch (e) {
    if (!(e instanceof VmStepError && e.vmMayExist)) {
      // if this fails too the claim lapses on its own, and the original reason is what to answer
      await deps.db.runTransaction(async tx => { tx.set(vmRef, { launching_until: null }, { merge: true }) }).catch(() => undefined)
    }
    throw e
  }
  try {
    await recordLaunch(deps, who, launched)
  } catch (e) {
    throw new VmStepError(502, `VM ${launched.microvmId} was launched but could not be recorded: ${reason(e)}`, true)
  }
  return "launched"
}

async function resume(deps: EnsureVmDeps, microvmId: string): Promise<VmOutcome> {
  try {
    await deps.microvms.resume(microvmId)
  } catch (e) {
    throw new VmStepError(502, `ResumeMicrovm failed: ${reason(e)}`)
  }
  return "resumed"
}

// Only on the launch branch: minting revokes the researcher's previous token, which a live VM
// would still be holding.
async function mintReportServerToken(deps: EnsureVmDeps, assertion: string): Promise<string> {
  let response: Response
  let answer: { token?: string; message?: string }
  try {
    const request = deps.fetchImpl(`${deps.config.reportServerUrl.replace(/\/$/, "")}/api/v1/dashboard-tokens`, {
      method: "POST",
      headers: { Authorization: `Bearer ${assertion}`, "Content-Type": "application/json" },
      body: "{}"
    }).then(async r => ({ response: r, answer: await r.json().catch(() => ({})) }))
    ;({ response, answer } = await within(request, UPSTREAM_TIMEOUT_MS))
  } catch (e) {
    throw new VmStepError(502, `report-server could not be reached for a dashboard token: ${reason(e)}`)
  }
  if (!response.ok) {
    throw new VmStepError(502, `report-server refused the dashboard token (${response.status}): ${answer.message ?? "no reason given"}`)
  }
  if (!answer.token) throw new VmStepError(502, "report-server returned no dashboard token")
  return answer.token
}

interface Launched { microvmId: string; imageVersion?: string }

async function launch(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody): Promise<Launched> {
  let imageVersion: string | undefined
  try {
    imageVersion = await deps.microvms.currentImageVersion(deps.config.imageIdentifier)
  } catch (e) {
    throw new VmStepError(502, `GetMicrovmImage failed: ${reason(e)}`)
  }

  const reportServerToken = await mintReportServerToken(deps, body.report_server_assertion)
  const runHookPayload = JSON.stringify({
    session_token: body.session_token,
    platform_user_id: who.platformUserId,
    platform_id: who.platformId,
    portal: who.portal,
    firebase_project: body.firebase_project,
    bucket: deps.config.bucket,
    report_server_token: reportServerToken,
    report_server_url: deps.config.reportServerUrl,
    function_url: deps.config.functionUrl
  })
  const bytes = Buffer.byteLength(runHookPayload)
  if (bytes > RUN_HOOK_PAYLOAD_MAX_BYTES) {
    throw new VmStepError(500, `runHookPayload is ${bytes} bytes, over the ${RUN_HOOK_PAYLOAD_MAX_BYTES}-byte cap`)
  }

  try {
    const vm = await deps.microvms.run({
      imageIdentifier: deps.config.imageIdentifier,
      imageVersion,
      executionRoleArn: deps.config.executionRoleArn,
      runHookPayload
    })
    return { microvmId: vm.microvmId, imageVersion: vm.imageVersion ?? imageVersion }
  } catch (e) {
    // Only a 4xx is a definite refusal; a timeout, a dropped connection or a 5xx may have launched one.
    const status = (e as { $metadata?: { httpStatusCode?: number } })?.$metadata?.httpStatusCode
    const refused = status !== undefined && status >= 400 && status < 500
    throw new VmStepError(502, `RunMicrovm failed: ${reason(e)}`, !refused)
  }
}

async function recordLaunch(deps: EnsureVmDeps, who: Researcher, vm: Launched) {
  const now = deps.timestamp()
  await deps.db.runTransaction(async tx => {
    tx.set(deps.db.doc(vmPath(who.portal, who.platformUserId)),
      { microvm_id: vm.microvmId, image_version: vm.imageVersion ?? null, launching_until: null }, { merge: true })
    // the queue is already on the runner document, written when the work was queued
    tx.set(deps.db.doc(runnerPath(who.portal, who.platformUserId)),
      { state: "starting", microvm_id: vm.microvmId, platform_id: who.platformId, started_at: now, updated_at: now }, { merge: true })
  })
}
