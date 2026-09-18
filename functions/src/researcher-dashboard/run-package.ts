import express from "express"
// Type-only, so this module carries no runtime dependency on the AWS SDK: the branch
// below is the part worth testing and it needs a fake, not a client.
import type { MicrovmApi } from "./microvm"

// A VM is reused only in these two states. Anything else, including one the API has never
// heard of, means launching a fresh one: the researcher status document cannot answer
// this, because a VM that died without writing leaves it claiming `ready`.
const REUSABLE_STATES = ["RUNNING", "SUSPENDED"]

// The port the runner's HTTP server listens on inside the VM, matching Hooks.Port in
// researcher-dashboard-runner.yml.
const RUNNER_PORT = 8080

export interface VmRecord {
  microvm_id: string
  image_version: string
}

export interface RunPackageDeps {
  microvms: MicrovmApi
  // Where the researcher's current VM is remembered. Not the researcher status document,
  // which the VM writes and which therefore still reads `ready` for a VM that died
  // without writing; get-microvm is the authority and this only says which to ask about.
  loadVm(portal: string, platformUserId: string): Promise<VmRecord | null>
  saveVm(portal: string, platformUserId: string, record: VmRecord): Promise<void>
  fetchImpl: typeof fetch
  config: {
    imageIdentifier: string
    executionRoleArn: string
    bucket: string
    reportServerUrl: string
  }
}

interface Body {
  scope?: { kind?: string; class_hash?: string; class_id?: number | string }
  package?: { name?: string; version?: string; checksum?: string }
  class_tokens?: Record<string, string>
  session_token?: string
  report_server_assertion?: string
  firebase_project?: string
  platform_id?: string
  platform_user_id?: string | number
  portal?: string
}

function invalid(body: Body): string | null {
  // Passed through to the runner untouched, including class_id, which report-server
  // filters a run by and which nothing inside the VM can derive from the hash.
  if (body.scope?.kind !== "class" || !body.scope?.class_hash) {
    return "scope must be {kind: 'class', class_hash, class_id}"
  }
  if (body.scope?.class_id === undefined || body.scope?.class_id === null || body.scope?.class_id === "") {
    return "scope must carry class_id"
  }
  if (!body.package?.name || !body.package?.version || !body.package?.checksum) {
    return "package must carry name, version and checksum"
  }
  const tokens = body.class_tokens
  if (!tokens || typeof tokens !== "object" || Object.keys(tokens).length === 0) {
    return "class_tokens must map a firebase app name to a token"
  }
  for (const field of ["session_token", "report_server_assertion", "firebase_project", "platform_id", "portal"]) {
    if (!(body as any)[field]) return `${field} is required`
  }
  if (body.platform_user_id === undefined || body.platform_user_id === null || body.platform_user_id === "") {
    return "platform_user_id is required"
  }
  return null
}

// Exchanged only on the branch that creates a VM. Minting revokes the researcher's
// previous token, so asking on a request that reuses a live VM would pull the credential
// out from under it.
async function mintReportServerToken(deps: RunPackageDeps, assertion: string): Promise<string> {
  const response = await deps.fetchImpl(`${deps.config.reportServerUrl.replace(/\/$/, "")}/api/v1/dashboard-tokens`, {
    method: "POST",
    headers: { Authorization: `Bearer ${assertion}`, "Content-Type": "application/json" },
    body: "{}"
  })
  if (!response.ok) {
    throw new Error(`report-server refused the dashboard token request: ${response.status}`)
  }
  const minted = await response.json() as { token?: string }
  if (!minted.token) throw new Error("report-server returned no token")
  return minted.token
}

export function makeRunPackage(deps: RunPackageDeps) {
  return async function runPackage(req: express.Request, res: express.Response) {
    const body = (req.body ?? {}) as Body
    const problem = invalid(body)
    if (problem) return res.error(400, problem)

    const portal = body.portal as string
    const platformUserId = String(body.platform_user_id)

    try {
      const currentVersion = await deps.microvms.currentImageVersion(deps.config.imageIdentifier)
      const remembered = await deps.loadVm(portal, platformUserId)

      let endpoint: string | undefined
      let microvmId: string | undefined

      if (remembered?.microvm_id) {
        const vm = await deps.microvms.get(remembered.microvm_id)
        if (vm && REUSABLE_STATES.includes(vm.state ?? "") && vm.imageVersion === currentVersion) {
          endpoint = vm.endpoint
          microvmId = remembered.microvm_id
        }
      }

      if (!microvmId) {
        const reportServerToken = await mintReportServerToken(deps, body.report_server_assertion as string)
        const launched = await deps.microvms.run({
          imageIdentifier: deps.config.imageIdentifier,
          executionRoleArn: deps.config.executionRoleArn,
          runHookPayload: JSON.stringify({
            session_token: body.session_token,
            platform_user_id: platformUserId,
            platform_id: body.platform_id,
            portal,
            firebase_project: body.firebase_project,
            bucket: deps.config.bucket,
            report_server_token: reportServerToken,
            report_server_url: deps.config.reportServerUrl
          })
        })
        endpoint = launched.endpoint
        microvmId = launched.microvmId
        await deps.saveVm(portal, platformUserId, {
          microvm_id: launched.microvmId,
          image_version: launched.imageVersion
        })
      }

      const headers = await deps.microvms.authHeaders(microvmId, RUNNER_PORT)
      const dispatched = await deps.fetchImpl(`${endpoint?.replace(/\/$/, "")}/run-package`, {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({
          scope: body.scope,
          package: body.package,
          class_tokens: body.class_tokens
        })
      })

      const answered = await dispatched.json().catch(() => ({})) as Record<string, unknown>
      if (!dispatched.ok) {
        // The runner's refusals are the app's to show: 409 for a package already running
        // or a VM expiring too soon, 4xx for a body it will not accept. Every one of them
        // leaves Firestore untouched, so passing the status through says so honestly.
        return res.error(dispatched.status, (answered as { error?: string }).error ?? "the runner refused the package run")
      }
      return res.success({ ...answered, microvm_id: microvmId })
    } catch (err: any) {
      return res.error(502, err.message)
    }
  }
}
