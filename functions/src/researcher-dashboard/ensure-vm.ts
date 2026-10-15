import { MicrovmApi } from "./microvm"
import { runnerPath, vmPath } from "./firestore-paths"
import { readQueue, runningOn, toMillis } from "./queue"
import { Db, Researcher, RunPackageBody } from "./run-package"

// PENDING or RUNNING: the VM asks for work at the end of /run and again before it idles.
// SUSPENDING: the watchdog resumes a SUSPENDED VM that has work queued.
export type VmOutcome = "launched" | "launching" | "resumed" | "running" | "suspending"

const LAUNCH_STATES = [undefined, "TERMINATING", "TERMINATED"]
// Longer than RunMicrovm plus the mint round trip, short enough that a launcher that crashed
// holding it does not block the researcher for long.
export const LAUNCH_CLAIM_MS = 60 * 1000
// A VM resumed this recently is held rather than replaced: the caller's SUSPENDED may predate that
// resume, after which the VM can finish its run and claim more work. Longer than the function's
// 60-second timeout, which bounds how old a caller's state can be.
const RESUME_SETTLE_MS = 2 * 60 * 1000
const RUN_HOOK_PAYLOAD_MAX_BYTES = 16384
// A VM's maximum life: the platform terminates it this long after launch, suspended or not. It
// also bounds how long an old image keeps serving.
export const MAXIMUM_DURATION_SECONDS = 8 * 60 * 60
// Per upstream call, each made once; the four a launch makes before it is recorded, and fetching
// the AWS credentials they use, fit the function's 60-second timeout. A replace's TerminateMicrovm
// comes after the record, so a timeout can cut only that.
export const UPSTREAM_TIMEOUT_MS = 10 * 1000

export interface VmDoc {
  microvm_id?: string
  image_version?: string
  launching_until?: number | null
  // a server timestamp; the watchdog sweeps the VMs launched within their maximum life
  launched_at?: unknown
  // a server timestamp written before each resume, from which the watchdog restarts a run's lease
  resumed_at?: unknown
}

export interface EnsureVmDeps {
  db: Db
  microvms: MicrovmApi
  fetchImpl: typeof fetch
  now(): number
  timestamp(): unknown
  log: { warn(message: string, data: object): void }
  config: {
    imageIdentifier: string
    executionRoleArn: string
    bucket: string
    reportServerUrl: string
    functionUrl: string
  }
}

/**
 * A failure after the work was queued, answered with its status and reason. `keepClaim` marks a
 * launch whose claim must lapse rather than be cleared, because a VM may exist or a mint may still
 * land and revoke the token a next launch hands its VM.
 */
export class VmStepError extends Error {
  constructor(public status: number, message: string, public keepClaim = false) {
    super(message)
  }
}

export const reason = (e: unknown) => e instanceof Error ? e.message : String(e)

export const within = <T>(promise: Promise<T>, ms: number, onTimeout?: () => void): Promise<T> => new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    onTimeout?.()
    reject(new Error(`no answer within ${ms / 1000} seconds`))
  }, ms)
  promise.then(
    value => { clearTimeout(timer); resolve(value) },
    error => { clearTimeout(timer); reject(error) }
  )
})

/**
 * Makes sure the researcher has one VM that will take the queued work: launches one if there is
 * none, resumes a suspended one, replaces a suspended one on an older image version, and otherwise
 * leaves it. Never waits for a VM to change state.
 */
export async function ensureVm(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody): Promise<VmOutcome> {
  const vmRef = deps.db.doc(vmPath(who.portal, who.platformUserId))
  // Asked outside any transaction: a transaction can retry, and must not span a network call.
  const seen = (await vmRef.get()).data() as VmDoc | undefined
  let state: string | undefined
  try {
    const vm = seen?.microvm_id ? await deps.microvms.get(seen.microvm_id) : null
    // a VM with no state may be live, so it must not read as one to replace
    if (vm && !vm.state) {
      throw new Error("the answer has no state")
    }
    state = vm?.state
  } catch (e) {
    throw new VmStepError(502, `GetMicrovm failed: ${reason(e)}`)
  }

  if (state === "SUSPENDED") {
    const imageVersion = await activeImageVersion(deps)
    const wake = await wakeSuspended(deps, who, { microvm_id: seen!.microvm_id!, image_version: seen!.image_version }, imageVersion)
    if (wake !== "replace") {
      // a VM recorded or resumed since the read above, or a launch under way, is the one to take the work
      return wake === "resumed" ? "resumed" : "launching"
    }
    return await claimAndLaunch(deps, who, body, seen, imageVersion, seen!.microvm_id)
  }
  if (state === "SUSPENDING") return "suspending"
  if (!LAUNCH_STATES.includes(state)) return "running"
  return await claimAndLaunch(deps, who, body, seen, await activeImageVersion(deps))
}

async function claimAndLaunch(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody, seen: VmDoc | undefined,
  imageVersion: string | undefined, replacing?: string): Promise<VmOutcome> {
  const vmRef = deps.db.doc(vmPath(who.portal, who.platformUserId))

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

  // Once a VM may exist, or a mint may still land, a failure leaves the claim to lapse rather than
  // clearing it: clearing would let the next request launch a second VM or lose its token.
  let launched: Launched
  try {
    launched = await launch(deps, who, body, imageVersion)
  } catch (e) {
    if (!(e instanceof VmStepError && e.keepClaim)) {
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
  if (replacing) {
    // Best effort: the old VM is no longer recorded, so nothing wakes it, and it ends at its
    // maximum life
    try {
      await deps.microvms.terminate(replacing)
    } catch (e) {
      deps.log.warn("run-package could not terminate the VM it replaced",
        { platformUserId: who.platformUserId, portal: who.portal, replaced: replacing, microvmId: launched.microvmId, error: reason(e) })
    }
  }
  return "launched"
}

/** The image's active version: the one a launch pins, and the one a suspended VM is compared against. */
async function activeImageVersion(deps: EnsureVmDeps): Promise<string | undefined> {
  try {
    return await deps.microvms.currentImageVersion(deps.config.imageIdentifier)
  } catch (e) {
    throw new VmStepError(502, `GetMicrovmImage failed: ${reason(e)}`)
  }
}

export type Wake = "resumed" | "replace" | "held"

export type WakeDeps = Pick<EnsureVmDeps, "db" | "now" | "timestamp"> & {
  microvms: Pick<MicrovmApi, "resume">
  /** Asked just before ResumeMicrovm; the watchdog passes its budget. */
  mayCall?(): boolean
}

/**
 * Wakes a suspended VM, or says it is to be replaced. Both ensureVm and the watchdog decide here,
 * given the VM as `vms/` records it and the image's active version, so a rule about which suspended
 * VMs to wake has one place to live. A VM on another version, or none, is replaced unless a
 * `running` result names it, since it was paused partway through a run that a resume finishes; with
 * no active version there is nothing to compare. `resumed_at` is written before the resume, so no
 * watchdog pass sees the VM running with only the run's pre-suspend heartbeat, and never for a VM to
 * be replaced. Holds, writing and resuming nothing, once `vms/` records another VM, which is the one to
 * take the work, while a launch claim is live, or instead of replacing a VM resumed in the last two
 * minutes; and holds after the write when `mayCall` says no.
 */
export async function wakeSuspended(deps: WakeDeps, who: Researcher, vm: { microvm_id: string; image_version?: string | null },
  activeVersion: string | undefined): Promise<Wake> {
  const vmRef = deps.db.doc(vmPath(who.portal, who.platformUserId))
  const stale = !!activeVersion && vm.image_version !== activeVersion
  const decided = await deps.db.runTransaction(async (tx): Promise<Wake> => {
    const current = (await tx.get(vmRef)).data() as VmDoc | undefined
    if (current?.microvm_id !== vm.microvm_id || (current.launching_until ?? 0) > deps.now()) {
      return "held"
    }
    if (stale && !runningOn(await readQueue(deps.db, tx, who), vm.microvm_id)) {
      return (toMillis(current.resumed_at) || 0) > deps.now() - RESUME_SETTLE_MS ? "held" : "replace"
    }
    tx.set(vmRef, { resumed_at: deps.timestamp() }, { merge: true })
    return "resumed"
  })
  if (decided !== "resumed") {
    return decided
  }
  if (deps.mayCall && !deps.mayCall()) {
    return "held"
  }
  try {
    await deps.microvms.resume(vm.microvm_id)
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
  // Aborting on timeout also ends the body read. Where AbortController is missing the request
  // is left to finish, which the kept claim covers.
  const controller = typeof AbortController === "undefined" ? undefined : new AbortController()
  try {
    const request = deps.fetchImpl(`${deps.config.reportServerUrl.replace(/\/$/, "")}/api/v1/dashboard-tokens`, {
      method: "POST",
      headers: { Authorization: `Bearer ${assertion}`, "Content-Type": "application/json" },
      body: "{}",
      signal: controller?.signal
    }).then(async r => ({ response: r, answer: await r.json().catch(() => ({})) }))
    ;({ response, answer } = await within(request, UPSTREAM_TIMEOUT_MS, () => controller?.abort()))
  } catch (e) {
    // report-server may have minted anyway, so the claim is kept for this one too
    throw new VmStepError(502, `report-server could not be reached for a dashboard token: ${reason(e)}`, true)
  }
  if (!response.ok) {
    throw new VmStepError(502, `report-server refused the dashboard token (${response.status}): ${answer.message ?? "no reason given"}`)
  }
  if (!answer.token) throw new VmStepError(502, "report-server returned no dashboard token")
  return answer.token
}

interface Launched { microvmId: string; imageVersion?: string }

async function launch(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody, imageVersion: string | undefined): Promise<Launched> {
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
      { microvm_id: vm.microvmId, image_version: vm.imageVersion ?? null, launching_until: null, launched_at: now, resumed_at: null }, { merge: true })
    // the queue is already on the runner document, written when the work was queued
    tx.set(deps.db.doc(runnerPath(who.portal, who.platformUserId)),
      { state: "starting", microvm_id: vm.microvmId, platform_id: who.platformId, started_at: now, updated_at: now }, { merge: true })
  })
}
