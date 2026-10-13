import { MAXIMUM_DURATION_SECONDS, reason, VmDoc, VmStepError, wakeSuspended } from "./ensure-vm"
import { resultPath, runnerPath, vmPath } from "./firestore-paths"
import { MicrovmApi } from "./microvm"
import { heldBy, prune, readQueue, toMillis, withStanding } from "./queue"
import { Db, DocRef, Researcher, Transaction } from "./run-package"

// A runner rewrites a claimed result's updated_at every heartbeat_seconds, which the rules bound;
// a result quiet for LEASE_BEATS beats has lost its runner
export const HEARTBEAT_MIN_SECONDS = 30
export const HEARTBEAT_MAX_SECONDS = 120
export const LEASE_BEATS = 5
// The shortest lease, which the query uses; each result's own lease is applied in code
export const LEASE_FLOOR_MS = LEASE_BEATS * HEARTBEAT_MIN_SECONDS * 1000
// How long a VM suspended mid-run keeps its run past the run's declared duration, and how long past
// its maximum life a VM is still swept
export const MARGIN_MS = 10 * 60 * 1000
// An awake VM with nothing to do for this long is suspended; the runner's own idle period is shorter
export const IDLE_SWEEP_MS = 30 * 60 * 1000
// No upstream call starts after this. A call can take 20 seconds, 10 for the AWS credentials it may
// refresh and 10 for itself, so one in flight and its write finish inside the function's 60 seconds.
export const BUDGET_MS = 30 * 1000
// The cap the runner applies to a manifest's declared duration, and the watchdog's default
const MAX_DECLARED_SECONDS = MAXIMUM_DURATION_SECONDS
// Past this, every VM that could have claimed work queued before it is gone
const VM_LIFE_MS = MAXIMUM_DURATION_SECONDS * 1000 + MARGIN_MS

export const MACHINE_STOPPED = "The machine running it stopped before the run finished; run it again."
export const NOT_CLAIMED = "No VM took this package before its VM's life ended; run it again"

// A VM being terminated may still run its /terminate hook, which writes the run's result itself
const GONE = [null, "TERMINATED"]
// The runner document's states that already say the session is over
const TERMINAL_RUNNER_STATES = ["terminated", "failed"]

export interface StaleResult {
  portal: string
  classHash: string
  platformUserId: string
  packageKey: string
  updatedAt: number
  expectedSeconds?: unknown
  heartbeatSeconds?: unknown
  microvmId?: unknown
}

export interface RecentVm {
  portal: string
  platformUserId: string
  microvmId: string
  imageVersion?: string
  launchedAt: number
}

/** The collection-group queries, over the Admin SDK in production. */
export interface WatchdogQueries {
  runningUpdatedBefore(ms: number): Promise<StaleResult[]>
  queuedUpdatedBefore(ms: number): Promise<StaleResult[]>
  vmsLaunchedAfter(ms: number): Promise<RecentVm[]>
}

export interface WatchdogDeps {
  db: Db
  queries: WatchdogQueries
  microvms: Pick<MicrovmApi, "get" | "suspend" | "terminate" | "resume">
  now(): number
  timestamp(): unknown
  log: { info(message: string, data: object): void }
}

const researcher = (portal: string, platformUserId: string): Researcher =>
  ({ portal, platformUserId, uid: Number(platformUserId), platformId: "" })

interface RunnerDoc {
  microvm_id?: unknown
  state?: unknown
  current_package?: { class_hash?: unknown; package_key?: unknown } | null
  updated_at?: unknown
}

const isHeartbeat = (value: unknown): value is number =>
  Number.isInteger(value) && (value as number) >= HEARTBEAT_MIN_SECONDS && (value as number) <= HEARTBEAT_MAX_SECONDS

const isTerminal = (runner: RunnerDoc | undefined) => TERMINAL_RUNNER_STATES.includes(runner?.state as string)

/**
 * Marks the runner document terminated when its VM is gone, while it still names that VM and does
 * not already say the session ended. Returns whether it wrote.
 */
function endRunner(tx: Transaction, ref: DocRef, runner: RunnerDoc | undefined, goneVm: string, now: unknown) {
  if (runner?.microvm_id !== goneVm || isTerminal(runner)) {
    return false
  }
  tx.set(ref, { state: "terminated", current_package: null, updated_at: now }, { merge: true })
  return true
}

/**
 * The runner on the result's VM has written its document since the result's last beat without
 * holding this package, so it will never write this result again.
 */
const movedOn = (runner: RunnerDoc | undefined, stale: StaleResult, microvmId: string) =>
  runner?.microvm_id === microvmId && !isTerminal(runner)
  && !(runner.current_package?.class_hash === stale.classHash && runner.current_package?.package_key === stale.packageKey)
  && toMillis(runner.updated_at) > stale.updatedAt

const declaredSeconds = (value: unknown) =>
  Number.isInteger(value) && (value as number) > 0 ? Math.min(value as number, MAX_DECLARED_SECONDS) : MAX_DECLARED_SECONDS

/** One minute's reconciliation. Returns the actions taken, for logs and tests. */
export async function runWatchdog(deps: WatchdogDeps): Promise<string[]> {
  const started = deps.now()
  const inBudget = () => deps.now() - started < BUDGET_MS
  const actions: string[] = []
  const act = (event: string, data: object) => {
    actions.push(event)
    deps.log.info(event, data)
  }

  // A VM's state, null when the API does not know it, or undefined when asking failed and this
  // run should leave it alone
  const stateOf = async (microvmId: string, data: object): Promise<string | null | undefined> => {
    try {
      const vm = await deps.microvms.get(microvmId)
      return vm ? vm.state ?? null : null
    } catch (e) {
      act("watchdog.upstream_failed", { ...data, call: "GetMicrovm", error: reason(e) })
      return undefined
    }
  }

  // Runs whose heartbeat has stopped: the runner moved on, or its VM is ended and the run failed
  // once the VM is gone
  for (const stale of await deps.queries.runningUpdatedBefore(started - LEASE_FLOOR_MS)) {
    if (!isHeartbeat(stale.heartbeatSeconds) || typeof stale.microvmId !== "string") {
      continue
    }
    const microvmId = stale.microvmId
    const data = { portal: stale.portal, platformUserId: stale.platformUserId, classHash: stale.classHash, packageKey: stale.packageKey, microvmId }
    try {
      const vm = (await deps.db.doc(vmPath(stale.portal, stale.platformUserId)).get()).data() as VmDoc | undefined
      const resumedAt = vm?.microvm_id === microvmId ? toMillis(vm.resumed_at) || 0 : 0
      const leaseLapsed = started - Math.max(stale.updatedAt, resumedAt) > LEASE_BEATS * stale.heartbeatSeconds * 1000
      // A suspended VM sends no heartbeat, and a resume from the dashboard can still finish the run.
      // This bound ignores resumed_at, which a resume that keeps failing would keep moving.
      const suspensionLapsed = started - stale.updatedAt > declaredSeconds(stale.expectedSeconds) * 1000 + MARGIN_MS
      if (!leaseLapsed && !suspensionLapsed) {
        continue
      }
      const runner = (await deps.db.doc(runnerPath(stale.portal, stale.platformUserId)).get()).data() as RunnerDoc | undefined
      if (leaseLapsed && movedOn(runner, stale, microvmId)) {
        if (await failResult(deps, stale, "running", MACHINE_STOPPED)) {
          act("watchdog.result_failed", { ...data, cause: "moved_on" })
        }
        continue
      }

      if (!inBudget()) {
        continue
      }
      const state = await stateOf(microvmId, data)
      if (state === undefined) {
        continue
      }
      if (GONE.includes(state) && leaseLapsed) {
        if (await failResult(deps, stale, "running", MACHINE_STOPPED, microvmId)) {
          act("watchdog.result_failed", { ...data, cause: "vm_gone" })
        }
        continue
      }

      let why: string
      if ((state === "PENDING" || state === "RUNNING") && leaseLapsed) {
        why = "lease"
      } else if (state === "SUSPENDED" && suspensionLapsed) {
        why = "suspended_mid_run"
      } else {
        continue
      }
      if (!inBudget()) {
        continue
      }
      try {
        await deps.microvms.terminate(microvmId)
      } catch (e) {
        act("watchdog.upstream_failed", { ...data, call: "TerminateMicrovm", error: reason(e) })
        continue
      }
      act("watchdog.vm_terminated", { ...data, reason: why })
    } catch (e) {
      act("watchdog.upstream_failed", { ...data, call: "Firestore", error: reason(e) })
    }
  }

  // Work still queued after any VM that could have taken it is gone. No upstream call, so the
  // budget does not stop it.
  for (const stale of await deps.queries.queuedUpdatedBefore(started - VM_LIFE_MS)) {
    const data = { portal: stale.portal, platformUserId: stale.platformUserId, classHash: stale.classHash, packageKey: stale.packageKey }
    try {
      if (await failResult(deps, stale, "queued", NOT_CLAIMED, undefined, started - VM_LIFE_MS)) {
        act("watchdog.result_failed", { ...data, cause: "not_claimed" })
      }
    } catch (e) {
      act("watchdog.upstream_failed", { ...data, call: "Firestore", error: reason(e) })
    }
  }

  // The VMs that can still exist: idle ones, suspended ones with work queued behind the suspend,
  // and gone ones whose runner document still claims a session
  for (const vm of await deps.queries.vmsLaunchedAfter(started - VM_LIFE_MS)) {
    if (!inBudget()) {
      break
    }
    const data = { portal: vm.portal, platformUserId: vm.platformUserId, microvmId: vm.microvmId }
    try {
      const state = await stateOf(vm.microvmId, data)
      const gone = state !== undefined && GONE.includes(state)
      if (state !== "SUSPENDED" && state !== "RUNNING" && !gone) {
        continue
      }
      const who = researcher(vm.portal, vm.platformUserId)
      const now = deps.timestamp()
      // Every read before any write: Firestore refuses a read after prune() has written.
      const seen = await deps.db.runTransaction(async tx => {
        const runnerRef = deps.db.doc(runnerPath(vm.portal, vm.platformUserId))
        const runner = (await tx.get(runnerRef)).data() as RunnerDoc | undefined
        const current = runner?.current_package
        const currentRunning = typeof current?.class_hash === "string" && typeof current.package_key === "string"
          && ((await tx.get(deps.db.doc(resultPath(vm.portal, current.class_hash, vm.platformUserId, current.package_key)))).data() as
            { status?: unknown } | undefined)?.status === "running"
        const q = await readQueue(deps.db, tx, who)
        prune(tx, q)
        const ended = gone && endRunner(tx, runnerRef, runner, vm.microvmId, now)
        return { q, runner, currentRunning, ended }
      })
      if (gone) {
        if (seen.ended) {
          act("watchdog.runner_terminated", { ...data, state })
        }
        continue
      }
      const queued = withStanding(seen.q, "queued").length
      if (!inBudget()) {
        break
      }

      if (state === "SUSPENDED") {
        if (queued === 0) {
          continue
        }
        try {
          await wakeSuspended(deps, who, { microvm_id: vm.microvmId, image_version: vm.imageVersion })
          act("watchdog.vm_resumed", { ...data, queued })
        } catch (e) {
          act("watchdog.upstream_failed", { ...data, call: e instanceof VmStepError ? "ResumeMicrovm" : "Firestore", error: reason(e) })
        }
        continue
      }

      const ownRun = seen.q.entries.some(e => e.standing === "running" && heldBy(e.result?.microvm_id, vm.microvmId))
      if (queued > 0 || ownRun || seen.currentRunning) {
        continue
      }
      const lastActivity = Math.max(vm.launchedAt, toMillis(seen.runner?.updated_at) || 0, toMillis(seen.q.work?.updated_at) || 0)
      if (started - lastActivity < IDLE_SWEEP_MS) {
        continue
      }
      try {
        await deps.microvms.suspend(vm.microvmId)
        act("watchdog.vm_suspended", { ...data, idleSince: new Date(lastActivity).toISOString() })
      } catch (e) {
        act("watchdog.upstream_failed", { ...data, call: "SuspendMicrovm", error: reason(e) })
      }
    } catch (e) {
      act("watchdog.upstream_failed", { ...data, call: "Firestore", error: reason(e) })
    }
  }
  return actions
}

/**
 * Writes a result `failed`, merging only the failure's fields, and only if it still has the status
 * and `updated_at` that were read. Given the VM that is gone, the runner document is marked
 * terminated while it still names that VM and does not already say the session ended. Work no VM
 * took is failed only while the researcher's recorded VM, if any, was launched before
 * `launchedBefore`, so a VM that may still claim it keeps it.
 */
export async function failResult(
  deps: Pick<WatchdogDeps, "db" | "timestamp">, stale: StaleResult, status: "running" | "queued", error: string,
  goneVm?: string, launchedBefore?: number
) {
  const now = deps.timestamp()
  return deps.db.runTransaction(async tx => {
    const ref = deps.db.doc(resultPath(stale.portal, stale.classHash, stale.platformUserId, stale.packageKey))
    const result = (await tx.get(ref)).data() as { status?: unknown; updated_at?: unknown } | undefined
    const runnerRef = deps.db.doc(runnerPath(stale.portal, stale.platformUserId))
    const runner = (await tx.get(runnerRef)).data() as RunnerDoc | undefined
    const vm = (await tx.get(deps.db.doc(vmPath(stale.portal, stale.platformUserId)))).data() as VmDoc | undefined
    if (result?.status !== status || toMillis(result.updated_at) !== stale.updatedAt) {
      return false
    }
    if (launchedBefore !== undefined && toMillis(vm?.launched_at) >= launchedBefore) {
      return false
    }
    tx.set(ref, { status: "failed", error, finished_at: now, updated_at: now }, { merge: true })
    if (goneVm) {
      endRunner(tx, runnerRef, runner, goneVm, now)
    }
    return true
  })
}
