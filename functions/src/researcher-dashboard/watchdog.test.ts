import { readdirSync, readFileSync } from "fs"
import { join } from "path"
import { FakeDb } from "../test/researcher-dashboard-fake-db"
import { IDLE_SWEEP_MS, MACHINE_STOPPED, NOT_CLAIMED, runWatchdog, StaleResult, WatchdogDeps } from "./watchdog"

const PORTAL = "learn_portal_staging_concord_org"
const ROOT = `researcher_dashboard/${PORTAL}`
const CLASS = "a".repeat(48)
const NOW = Date.parse("2026-09-25T12:00:00Z")
const SEC = 1000
const MIN = 60 * SEC
const RESULT = `${ROOT}/classes/${CLASS}/researchers/42/results/users__1__a`
const TS = "<server timestamp>"

let db: FakeDb
let deps: WatchdogDeps
let stale: StaleResult[]
let queuedStale: StaleResult[]
let states: Record<string, string | null>
let clock: number

const staleRun = (over: Partial<StaleResult> = {}): StaleResult =>
  ({
    portal: PORTAL, classHash: CLASS, platformUserId: "42", packageKey: "users__1__a",
    updatedAt: NOW - 30 * MIN, expectedSeconds: 600, heartbeatSeconds: 60, microvmId: "vm-1", ...over
  })

beforeEach(() => {
  db = new FakeDb()
  stale = []
  queuedStale = []
  states = {}
  clock = NOW
  deps = {
    db,
    queries: {
      runningUpdatedBefore: jest.fn(async () => stale),
      queuedUpdatedBefore: jest.fn(async () => queuedStale),
      vmsLaunchedAfter: jest.fn(async () => [])
    },
    microvms: {
      get: jest.fn(async (id: string) => (id in states ? (states[id] === null ? null : { state: states[id]! }) : null)),
      suspend: jest.fn().mockResolvedValue(undefined),
      terminate: jest.fn().mockResolvedValue(undefined),
      resume: jest.fn().mockResolvedValue(undefined),
      currentImageVersion: jest.fn().mockResolvedValue("7")
    },
    imageIdentifier: "arn:image",
    now: () => clock,
    timestamp: () => TS,
    log: { info: jest.fn() }
  }
  db.docs.set(RESULT, { status: "running", updated_at: NOW - 30 * MIN, platform_id: "p" })
  db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", state: "ready", current_package: { class_hash: CLASS, package_key: "users__1__a" } })
})

const logged = (event: string, data: object) => expect(deps.log.info).toHaveBeenCalledWith(event, expect.objectContaining(data))

describe("runs whose heartbeat has stopped", () => {
  const RUNNER = `${ROOT}/runners/42`
  const quiet = (ms: number, over: Partial<StaleResult> = {}) => {
    db.docs.set(RESULT, { status: "running", updated_at: NOW - ms, platform_id: "p" })
    stale = [staleRun({ updatedAt: NOW - ms, ...over })]
  }

  it.each([[60, 300], [30, 150], [120, 600]])("at heartbeat_seconds %i, acts only once a result is quiet past %i seconds", async (beat, lease) => {
    states["vm-1"] = "RUNNING"
    quiet(lease * SEC - SEC, { heartbeatSeconds: beat })
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.get).not.toHaveBeenCalled()

    quiet(lease * SEC + SEC, { heartbeatSeconds: beat })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
    expect(deps.queries.runningUpdatedBefore).toHaveBeenCalledWith(NOW - 150 * SEC)
  })

  it.each<[string, number | undefined]>([["missing", undefined], ["29", 29], ["121", 121], ["60.5", 60.5]])("skips a result whose heartbeat_seconds is %s", async (_, beat) => {
    states["vm-1"] = null
    stale = [staleRun({ heartbeatSeconds: beat })]
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.get).not.toHaveBeenCalled()
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
  })

  it.each<[string, string | null]>([["not known", null], ["TERMINATED", "TERMINATED"]])(
    "fails a run whose VM is %s, and marks that VM's runner document terminated", async (_, state) => {
      stale = [staleRun()]
      states["vm-1"] = state

      expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed", "watchdog.runner_terminated"])
      expect(db.read(RESULT)).toEqual({ status: "failed", error: MACHINE_STOPPED, finished_at: TS, updated_at: TS, platform_id: "p" })
      expect(db.read(RUNNER)).toEqual({ microvm_id: "vm-1", state: "terminated", current_package: null, updated_at: TS })
      logged("watchdog.result_failed", { cause: "vm_gone", microvmId: "vm-1", classHash: CLASS, packageKey: "users__1__a" })
      logged("watchdog.runner_terminated", { microvmId: "vm-1" })
    })

  it.each(["terminated", "failed"])("leaves a runner document already %s exactly as it was", async runnerState => {
    stale = [staleRun()]
    states["vm-1"] = null
    db.docs.set(RUNNER, { microvm_id: "vm-1", state: runnerState, error: "flush incomplete", updated_at: "<earlier>" })
    expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed"])
    expect(db.read(RUNNER)).toEqual({ microvm_id: "vm-1", state: runnerState, error: "flush incomplete", updated_at: "<earlier>" })
  })

  it.each(["TERMINATING", "SUSPENDING"])("leaves the result and terminates nothing while the VM is %s", async state => {
    stale = [staleRun()]
    states["vm-1"] = state
    expect(await runWatchdog(deps)).toEqual([])
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
    expect(deps.microvms.terminate).not.toHaveBeenCalled()
  })

  it.each(["PENDING", "RUNNING"])("terminates a %s VM, writes nothing, and fails the run once the VM is gone", async state => {
    stale = [staleRun()]
    states["vm-1"] = state
    const runner = db.read(RUNNER)

    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
    expect(deps.microvms.terminate).toHaveBeenCalledWith("vm-1")
    logged("watchdog.vm_terminated", { reason: "lease", microvmId: "vm-1" })
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
    expect(db.read(RUNNER)).toEqual(runner)

    states["vm-1"] = "TERMINATED"
    expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed", "watchdog.runner_terminated"])
    expect(db.read(RESULT)).toMatchObject({ status: "failed", error: MACHINE_STOPPED })
  })

  it("leaves a run, and its runner document, whose VM is found with no state", async () => {
    stale = [staleRun()]
    ;(deps.microvms.get as jest.Mock).mockResolvedValue({})
    ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue([{ portal: PORTAL, platformUserId: "42", microvmId: "vm-1", launchedAt: NOW - 60 * MIN }])
    const runner = db.read(RUNNER)

    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
    logged("watchdog.upstream_failed", { call: "GetMicrovm", error: "the answer has no state" })
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
    expect(db.read(RUNNER)).toEqual(runner)
    expect(deps.microvms.terminate).not.toHaveBeenCalled()
  })

  it("logs a terminate that throws and writes nothing", async () => {
    stale = [staleRun()]
    states["vm-1"] = "RUNNING"
    ;(deps.microvms.terminate as jest.Mock).mockRejectedValue(new Error("ResourceNotFound"))
    const runner = db.read(RUNNER)

    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
    logged("watchdog.upstream_failed", { call: "TerminateMicrovm" })
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
    expect(db.read(RUNNER)).toEqual(runner)
  })

  describe("a VM suspended mid-run", () => {
    beforeEach(() => {
      states["vm-1"] = "SUSPENDED"
    })

    it("is left inside the declared duration plus 10 minutes", async () => {
      quiet(30 * MIN, { expectedSeconds: 20 * 60 + 1 })
      expect(await runWatchdog(deps)).toEqual([])
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
    })

    it("is terminated past it, with nothing written", async () => {
      quiet(30 * MIN, { expectedSeconds: 20 * 60 - 1 })
      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
      logged("watchdog.vm_terminated", { reason: "suspended_mid_run" })
      expect(db.read(RESULT)).toMatchObject({ status: "running" })
    })

    it("caps a declared duration, and takes a missing one as the cap", async () => {
      quiet(8 * 60 * MIN + 11 * MIN, { expectedSeconds: 10 ** 9 })
      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])

      quiet(8 * 60 * MIN + 9 * MIN, { expectedSeconds: undefined })
      expect(await runWatchdog(deps)).toEqual([])

      quiet(8 * 60 * MIN + 11 * MIN, { expectedSeconds: undefined })
      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
    })

    it("is not resumed by the same run that terminates it, which asks its state once", async () => {
      quiet(30 * MIN, { expectedSeconds: 60 })
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1" })
      const other = `${ROOT}/classes/${CLASS}/researchers/42/results/users__1__q`
      db.docs.set(other, { status: "queued" })
      db.docs.set(`${ROOT}/work/42`, {
        packages: [{ identity: "users/1/q", version: "1", checksum: "c", catalog_id: 1, class_hash: CLASS }], updated_at: NOW - MIN
      })
      ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue([{ portal: PORTAL, platformUserId: "42", microvmId: "vm-1", launchedAt: NOW - 60 * MIN }])

      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
      expect(deps.microvms.resume).not.toHaveBeenCalled()
      expect(deps.microvms.get).toHaveBeenCalledTimes(1)
      expect(db.read(`${ROOT}/vms/42`)).toEqual({ microvm_id: "vm-1" })
    })

    it("is not postponed by a resumed_at that a failing resume keeps writing", async () => {
      quiet(30 * MIN)
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", resumed_at: NOW - MIN })
      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
      logged("watchdog.vm_terminated", { reason: "suspended_mid_run" })
    })

    it("is terminated, not failed as moved on, while a fresh resumed_at holds its lease", async () => {
      quiet(30 * MIN)
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", resumed_at: NOW - MIN })
      db.docs.set(`${ROOT}/runners/42`, {
        microvm_id: "vm-1", state: "ready", current_package: { class_hash: CLASS, package_key: "users__1__b" }, updated_at: NOW - MIN
      })
      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
      logged("watchdog.vm_terminated", { reason: "suspended_mid_run" })
      expect(db.read(RESULT)).toMatchObject({ status: "running" })
    })

    it.each<[string, string | null]>([["gone", null], ["RUNNING", "RUNNING"]])(
      "leaves a run past its suspended bound whose VM is now %s while a fresh resumed_at holds its lease", async (_, state) => {
        quiet(30 * MIN)
        db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", resumed_at: NOW - MIN })
        states["vm-1"] = state
        expect(await runWatchdog(deps)).toEqual([])
        expect(db.read(RESULT)).toMatchObject({ status: "running" })
        expect(deps.microvms.terminate).not.toHaveBeenCalled()
      })
  })

  describe("a runner that has moved on", () => {
    const movedOn = (over: object = {}) =>
      db.docs.set(RUNNER, {
        microvm_id: "vm-1", state: "ready", current_package: { class_hash: CLASS, package_key: "users__1__b" }, updated_at: NOW - MIN, ...over
      })

    it.each<[string, object]>([
      ["another package", {}],
      ["the same package key in another class", { current_package: { class_hash: "b".repeat(48), package_key: "users__1__a" } }],
      ["no package", { current_package: null }]
    ])("fails the result, holding %s, without asking about the VM", async (_, over) => {
      stale = [staleRun()]
      movedOn(over)
      const runner = db.read(RUNNER)

      expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed"])
      expect(db.read(RESULT)).toMatchObject({ status: "failed", error: MACHINE_STOPPED })
      logged("watchdog.result_failed", { cause: "moved_on" })
      expect(deps.microvms.get).not.toHaveBeenCalled()
      expect(db.read(RUNNER)).toEqual(runner)
    })

    it.each<[string, object]>([
      ["holds this result", { current_package: { class_hash: CLASS, package_key: "users__1__a" } }],
      ["last wrote before the result", { updated_at: NOW - 31 * MIN }],
      ["records another VM", { microvm_id: "vm-2" }],
      ["says terminated", { state: "terminated" }],
      ["says failed", { state: "failed" }]
    ])("asks about the VM when the runner document %s", async (_, over) => {
      stale = [staleRun()]
      movedOn(over)
      states["vm-1"] = null

      expect(await runWatchdog(deps)).toContain("watchdog.result_failed")
      expect(deps.microvms.get).toHaveBeenCalledWith("vm-1")
      logged("watchdog.result_failed", { cause: "vm_gone" })
    })
  })

  it("restarts the lease at a resume of the result's VM, and not of another", async () => {
    states["vm-1"] = "RUNNING"
    quiet(60 * MIN)
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", resumed_at: NOW - MIN })
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.terminate).not.toHaveBeenCalled()

    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-2", resumed_at: NOW - MIN })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
  })

  it("starts no TerminateMicrovm once GetMicrovm calls have spent the budget", async () => {
    const other = `${ROOT}/classes/${CLASS}/researchers/7/results/users__1__a`
    db.docs.set(other, { status: "running", updated_at: NOW - 30 * MIN })
    stale = [staleRun(), staleRun({ platformUserId: "7", microvmId: "vm-7" })]
    ;(deps.microvms.get as jest.Mock).mockImplementation(async () => {
      clock += 25 * SEC
      return { state: "RUNNING" }
    })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
    expect(deps.microvms.terminate).toHaveBeenCalledTimes(1)
    expect(deps.microvms.terminate).toHaveBeenCalledWith("vm-1")
  })

  it("does not overwrite a result the runner has written since it was read", async () => {
    stale = [staleRun()]
    states["vm-1"] = null
    db.docs.set(RESULT, { status: "running", updated_at: NOW - MIN })
    expect(await runWatchdog(deps)).toEqual([])
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
  })

  it("leaves a newer VM's runner document alone", async () => {
    stale = [staleRun()]
    states["vm-1"] = null
    db.docs.set(RUNNER, { microvm_id: "vm-2", state: "ready", current_package: null })
    await runWatchdog(deps)
    expect(db.read(RESULT)).toMatchObject({ status: "failed" })
    expect(db.read(RUNNER)).toEqual({ microvm_id: "vm-2", state: "ready", current_package: null })
  })

  it("goes on after one VM's API call fails, and writes nothing for it", async () => {
    const other = `${ROOT}/classes/${CLASS}/researchers/7/results/users__1__a`
    db.docs.set(other, { status: "running", updated_at: NOW - 30 * MIN })
    stale = [staleRun({ microvmId: "vm-bad" }), staleRun({ platformUserId: "7", microvmId: "vm-7" })]
    ;(deps.microvms.get as jest.Mock).mockImplementation(async (id: string) => {
      if (id === "vm-bad") {
        throw new Error("throttled")
      }
      return null
    })
    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed", "watchdog.result_failed"])
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
    expect(db.read(other)).toMatchObject({ status: "failed" })
  })

  it("keeps the result's previous run when it fails one", async () => {
    const previous = { summary: "3 classes", started_at: "<started>" }
    db.docs.set(RESULT, { status: "running", updated_at: NOW - 30 * MIN, previous })
    stale = [staleRun()]
    states["vm-1"] = null
    await runWatchdog(deps)
    expect(db.read(RESULT)).toMatchObject({ status: "failed", previous })
  })
})

describe("work no VM took", () => {
  const LIFE = 8 * 60 * MIN + 10 * MIN
  const queuedAt = NOW - LIFE - MIN
  beforeEach(() => {
    db.docs.set(RESULT, { status: "queued", updated_at: queuedAt, platform_id: "p" })
    queuedStale = [staleRun({ updatedAt: queuedAt, expectedSeconds: undefined, microvmId: undefined })]
  })

  it("asks for results queued before any VM that could take them is gone", async () => {
    await runWatchdog(deps)
    expect(deps.queries.queuedUpdatedBefore).toHaveBeenCalledWith(NOW - LIFE)
  })

  it("fails one queued past every VM's life, merging only its fields and leaving the runner document", async () => {
    const runner = db.read(`${ROOT}/runners/42`)
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", launched_at: NOW - LIFE - 2 * MIN })
    expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed"])
    expect(db.read(RESULT)).toEqual({ status: "failed", error: NOT_CLAIMED, finished_at: TS, updated_at: TS, platform_id: "p" })
    logged("watchdog.result_failed", { cause: "not_claimed" })
    expect(db.read(`${ROOT}/runners/42`)).toEqual(runner)
    expect(deps.microvms.get).not.toHaveBeenCalled()
  })

  it("leaves it while the researcher's VM was launched within a VM's life", async () => {
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", launched_at: NOW - 60 * MIN })
    expect(await runWatchdog(deps)).toEqual([])
    expect(db.read(RESULT)).toMatchObject({ status: "queued" })
  })

  it("leaves it while a launch is under way, and fails it once that claim has lapsed", async () => {
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", launched_at: NOW - LIFE - 2 * MIN, launching_until: NOW + 30 * SEC })
    expect(await runWatchdog(deps)).toEqual([])
    expect(db.read(RESULT)).toMatchObject({ status: "queued" })

    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", launched_at: NOW - LIFE - 2 * MIN, launching_until: NOW - SEC })
    expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed"])
  })

  it("does not overwrite one a VM has claimed since the query", async () => {
    db.docs.set(RESULT, { status: "running", updated_at: NOW - MIN })
    expect(await runWatchdog(deps)).toEqual([])
    expect(db.read(RESULT)).toMatchObject({ status: "running" })
  })

  it("keeps the result's previous run", async () => {
    const previous = { summary: "3 classes", started_at: "<started>" }
    db.docs.set(RESULT, { status: "queued", updated_at: queuedAt, previous })
    await runWatchdog(deps)
    expect(db.read(RESULT)).toMatchObject({ status: "failed", error: NOT_CLAIMED, previous })
  })

  it("is not stopped by the budget, since it makes no upstream call", async () => {
    stale = [staleRun()]
    states["vm-1"] = "RUNNING"
    ;(deps.microvms.get as jest.Mock).mockImplementation(async () => {
      clock += 35 * 1000
      return { state: "RUNNING" }
    })
    const other = `${ROOT}/classes/${CLASS}/researchers/42/results/users__1__b`
    db.docs.set(other, { status: "queued", updated_at: queuedAt })
    queuedStale = [staleRun({ packageKey: "users__1__b", updatedAt: queuedAt, microvmId: undefined })]
    expect(await runWatchdog(deps)).toEqual(["watchdog.result_failed"])
    expect(db.read(other)).toMatchObject({ status: "failed", error: NOT_CLAIMED })
  })
})

describe("deletes nothing", () => {
  it("no module of the dashboard deletes a document or a field", () => {
    const sources = readdirSync(__dirname).filter(f => f.endsWith(".ts") && !f.endsWith(".test.ts") && !f.endsWith(".live.ts"))
    expect(sources).toContain("watchdog.ts")
    for (const file of sources) {
      expect(readFileSync(join(__dirname, file), "utf8")).not.toMatch(/\.delete\(|recursiveDelete|FieldValue\.delete/)
    }
  })
})

describe("idle and suspended VMs", () => {
  const WORK = `${ROOT}/work/42`
  const queued = (identity: string, status = "queued") => {
    const key = identity.replace(/\//g, "__")
    db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/${key}`, { status })
    return { identity, version: "1", checksum: "c", catalog_id: 1, class_hash: CLASS }
  }
  const vm = (launchedAt = NOW - 3 * 60 * MIN) => [{ portal: PORTAL, platformUserId: "42", microvmId: "vm-1", imageVersion: "7", launchedAt }]

  beforeEach(() => {
    db.docs.delete(RESULT)
    db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", state: "ready", current_package: null, updated_at: NOW - 40 * MIN })
    db.docs.set(WORK, { packages: [], scopes: {}, updated_at: NOW - 40 * MIN })
    ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue(vm())
  })

  it("suspends an awake VM that has had nothing to do for the threshold", async () => {
    states["vm-1"] = "RUNNING"
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_suspended"])
    expect(deps.queries.vmsLaunchedAfter).toHaveBeenCalledWith(NOW - 8 * 60 * MIN - 10 * MIN)
    expect(deps.microvms.suspend).toHaveBeenCalledWith("vm-1")
  })

  it("leaves it awake inside the threshold", async () => {
    states["vm-1"] = "RUNNING"
    db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", current_package: null, updated_at: NOW - IDLE_SWEEP_MS + MIN })
    expect(await runWatchdog(deps)).toEqual([])
  })

  it("leaves it awake inside the threshold of its work document's update", async () => {
    states["vm-1"] = "RUNNING"
    db.docs.set(WORK, { packages: [], scopes: {}, updated_at: NOW - IDLE_SWEEP_MS + MIN })
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("leaves it awake inside the threshold of its launch", async () => {
    states["vm-1"] = "RUNNING"
    ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue(vm(NOW - IDLE_SWEEP_MS + MIN))
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("leaves it awake with work queued, a package current, or a run of its own outstanding", async () => {
    states["vm-1"] = "RUNNING"
    db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - 40 * MIN })
    expect(await runWatchdog(deps)).toEqual([])

    db.docs.set(WORK, { packages: [queued("users/1/r", "running")], updated_at: NOW - 40 * MIN })
    db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/users__1__r`, { status: "running", microvm_id: "vm-1" })
    expect(await runWatchdog(deps)).toEqual([])

    db.docs.set(WORK, { packages: [], updated_at: NOW - 40 * MIN })
    db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/users__1__x`, { status: "running", microvm_id: "vm-1" })
    db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", current_package: { class_hash: CLASS, package_key: "users__1__x" }, updated_at: NOW - 40 * MIN })
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("is not kept awake by a current package whose result is no longer running", async () => {
    states["vm-1"] = "RUNNING"
    db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/users__1__x`, { status: "failed", microvm_id: "vm-1" })
    db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", current_package: { class_hash: CLASS, package_key: "users__1__x" }, updated_at: NOW - 40 * MIN })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_suspended"])
  })

  it("is not kept awake by a current package whose run another VM holds", async () => {
    states["vm-1"] = "RUNNING"
    db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/users__1__x`, { status: "running", microvm_id: "vm-2" })
    db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", current_package: { class_hash: CLASS, package_key: "users__1__x" }, updated_at: NOW - 40 * MIN })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_suspended"])
  })

  it("leaves a VM found with no state, and its runner document, alone", async () => {
    ;(deps.microvms.get as jest.Mock).mockResolvedValue({})
    const runner = db.read(`${ROOT}/runners/42`)
    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
    expect(db.read(`${ROOT}/runners/42`)).toEqual(runner)
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("is not kept awake by a stale run another VM claimed", async () => {
    states["vm-1"] = "RUNNING"
    const entry = queued("users/1/old", "running")
    db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/users__1__old`, { status: "running", microvm_id: "vm-dead" })
    db.docs.set(WORK, { packages: [entry], updated_at: NOW - 40 * MIN })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_suspended"])
  })

  it("resumes a suspended VM with work queued behind its suspend", async () => {
    states["vm-1"] = "SUSPENDED"
    db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - MIN })
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1" })
    expect(await runWatchdog(deps)).toEqual(["watchdog.vm_resumed"])
    expect(deps.microvms.resume).toHaveBeenCalledWith("vm-1")
    expect(db.read(`${ROOT}/vms/42`)).toEqual({ microvm_id: "vm-1", resumed_at: TS })
  })

  it("logs a SuspendMicrovm that fails", async () => {
    states["vm-1"] = "RUNNING"
    ;(deps.microvms.suspend as jest.Mock).mockRejectedValue(new Error("throttled"))
    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
    logged("watchdog.upstream_failed", { call: "SuspendMicrovm" })
  })

  it("logs a ResumeMicrovm that fails", async () => {
    states["vm-1"] = "SUSPENDED"
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1" })
    db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - MIN })
    ;(deps.microvms.resume as jest.Mock).mockRejectedValue(new Error("throttled"))
    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
    logged("watchdog.upstream_failed", { call: "ResumeMicrovm" })
  })

  it("logs a failed resumed_at write as Firestore's, without calling ResumeMicrovm", async () => {
    states["vm-1"] = "SUSPENDED"
    db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - MIN })
    const transact = db.runTransaction.bind(db)
    let calls = 0
    jest.spyOn(db, "runTransaction").mockImplementation((async (fn: never) => {
      calls += 1
      if (calls === 2) {
        throw new Error("contention")
      }
      return transact(fn)
    }) as never)
    expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
    logged("watchdog.upstream_failed", { call: "Firestore" })
    expect(deps.microvms.resume).not.toHaveBeenCalled()
  })

  it("starts no ResumeMicrovm when the wake's own write runs past the budget", async () => {
    states["vm-1"] = "SUSPENDED"
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1" })
    db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - MIN })
    const transact = db.runTransaction.bind(db)
    let calls = 0
    jest.spyOn(db, "runTransaction").mockImplementation((async (fn: never) => {
      calls += 1
      if (calls === 2) {
        clock += 31 * 1000
      }
      return transact(fn)
    }) as never)
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.resume).not.toHaveBeenCalled()
  })

  describe("on an older image version", () => {
    const oldVm = () => [{ ...vm()[0], imageVersion: "6" }]
    const twoSuspended = () => {
      states["vm-1"] = "SUSPENDED"
      states["vm-2"] = "SUSPENDED"
      ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue([vm()[0], { ...vm()[0], platformUserId: "43", microvmId: "vm-2" }])
      db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - MIN })
      db.docs.set(`${ROOT}/work/43`, { packages: [{ identity: "users/1/q", version: "1", checksum: "c", catalog_id: 1, class_hash: CLASS }], updated_at: NOW - MIN })
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", image_version: "7" })
      db.docs.set(`${ROOT}/vms/43`, { microvm_id: "vm-2", image_version: "7" })
    }

    beforeEach(() => {
      states["vm-1"] = "SUSPENDED"
      ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue(oldVm())
      db.docs.set(WORK, { packages: [queued("users/1/q")], updated_at: NOW - MIN })
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", image_version: "6" })
    })

    it("leaves a suspended VM resumed in the last two minutes, which may since have finished its run", async () => {
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", image_version: "6", resumed_at: NOW - MIN })

      expect(await runWatchdog(deps)).toEqual([])
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
      expect(deps.microvms.resume).not.toHaveBeenCalled()
    })

    it("terminates a suspended VM with work queued, writing nothing, and leaves its runner document to the next pass", async () => {
      db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", state: "suspended", current_package: null, queue: [{ class_hash: CLASS, package_key: "users__1__q" }] })
      const before = JSON.stringify([...db.docs.entries()])

      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_terminated"])
      logged("watchdog.vm_terminated", { reason: "old_image" })
      expect(deps.microvms.terminate).toHaveBeenCalledWith("vm-1")
      expect(deps.microvms.resume).not.toHaveBeenCalled()
      expect(JSON.stringify([...db.docs.entries()])).toBe(before)

      states["vm-1"] = "TERMINATED"
      expect(await runWatchdog(deps)).toEqual(["watchdog.runner_terminated"])
      expect(db.read(`${ROOT}/runners/42`)).toMatchObject({ state: "terminated", queue: [{ class_hash: CLASS, package_key: "users__1__q" }] })
    })

    it("resumes a VM that a running result names", async () => {
      db.docs.set(WORK, { packages: [queued("users/1/q"), queued("users/1/r", "running")], updated_at: NOW - MIN })
      db.docs.set(`${ROOT}/classes/${CLASS}/researchers/42/results/users__1__r`, { status: "running", microvm_id: "vm-1" })

      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_resumed"])
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
    })

    it("logs a TerminateMicrovm that fails", async () => {
      ;(deps.microvms.terminate as jest.Mock).mockRejectedValue(new Error("throttled"))
      expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
      logged("watchdog.upstream_failed", { call: "TerminateMicrovm" })
    })

    it("asks for the image's version once per run", async () => {
      twoSuspended()
      expect(await runWatchdog(deps)).toEqual(["watchdog.vm_resumed", "watchdog.vm_resumed"])
      expect(deps.microvms.resume).toHaveBeenCalledTimes(2)
      expect(deps.microvms.currentImageVersion).toHaveBeenCalledTimes(1)
    })

    it("logs a GetMicrovmImage that fails once and wakes nothing", async () => {
      twoSuspended()
      ;(deps.microvms.currentImageVersion as jest.Mock).mockRejectedValue(new Error("throttled"))
      expect(await runWatchdog(deps)).toEqual(["watchdog.upstream_failed"])
      logged("watchdog.upstream_failed", { call: "GetMicrovmImage" })
      expect(deps.microvms.currentImageVersion).toHaveBeenCalledTimes(1)
      expect(deps.microvms.resume).not.toHaveBeenCalled()
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
    })

    it("asks nothing and terminates nothing once the queue read runs past the budget", async () => {
      const transact = db.runTransaction.bind(db)
      jest.spyOn(db, "runTransaction").mockImplementation((async (fn: never) => {
        const out = await transact(fn)
        clock += 31 * 1000
        return out
      }) as never)
      expect(await runWatchdog(deps)).toEqual([])
      expect(deps.microvms.currentImageVersion).not.toHaveBeenCalled()
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
    })

    it.each([["an older", "6"], ["the active", "7"]])("writes and wakes nothing on %s version when GetMicrovmImage runs past the budget", async (_, version) => {
      ;(deps.queries.vmsLaunchedAfter as jest.Mock).mockResolvedValue([{ ...vm()[0], imageVersion: version }])
      db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", image_version: version })
      ;(deps.microvms.currentImageVersion as jest.Mock).mockImplementation(async () => {
        clock += 31 * 1000
        return "7"
      })
      expect(await runWatchdog(deps)).toEqual([])
      expect(db.read(`${ROOT}/vms/42`)).toEqual({ microvm_id: "vm-1", image_version: version })
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
      expect(deps.microvms.resume).not.toHaveBeenCalled()
    })

    it("starts no TerminateMicrovm when the wake's decision runs past the budget", async () => {
      const transact = db.runTransaction.bind(db)
      let calls = 0
      jest.spyOn(db, "runTransaction").mockImplementation((async (fn: never) => {
        calls += 1
        if (calls === 2) {
          clock += 31 * 1000
        }
        return transact(fn)
      }) as never)
      expect(await runWatchdog(deps)).toEqual([])
      expect(deps.microvms.currentImageVersion).toHaveBeenCalledTimes(1)
      expect(deps.microvms.terminate).not.toHaveBeenCalled()
    })
  })

  it("leaves a suspended VM with nothing queued asleep", async () => {
    states["vm-1"] = "SUSPENDED"
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.resume).not.toHaveBeenCalled()
  })

  it("prunes finished entries as it reads the queue", async () => {
    states["vm-1"] = "SUSPENDED"
    db.docs.set(WORK, { packages: [queued("users/1/d", "done")], scopes: { [CLASS]: {} }, updated_at: NOW - MIN })
    await runWatchdog(deps)
    expect(db.read(WORK)).toMatchObject({ packages: [], scopes: {} })
  })

  it("starts nothing after its budget", async () => {
    states["vm-1"] = "RUNNING"
    ;(deps.microvms.get as jest.Mock).mockImplementation(async () => {
      clock += 35 * 1000
      return { state: "RUNNING" }
    })
    expect(await runWatchdog(deps)).toEqual([])
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  describe("a VM that is gone", () => {
    const RUNNER = `${ROOT}/runners/42`

    it.each<[string, string | null]>([["not known", null], ["TERMINATED", "TERMINATED"]])(
      "marks its runner document terminated when the API reports it %s", async (_, state) => {
        states["vm-1"] = state
        for (const runnerState of ["starting", "ready", "suspended"]) {
          db.docs.set(RUNNER, { microvm_id: "vm-1", state: runnerState, current_package: "users__1__x", queue: [{ class_hash: CLASS, package_key: "users__1__q" }] })
          expect(await runWatchdog(deps)).toEqual(["watchdog.runner_terminated"])
          logged("watchdog.runner_terminated", { microvmId: "vm-1" })
          expect(db.read(RUNNER)).toEqual({
            microvm_id: "vm-1", state: "terminated", current_package: null, updated_at: TS, queue: [{ class_hash: CLASS, package_key: "users__1__q" }]
          })
        }
      })

    it.each(["TERMINATING", "RUNNING", "PENDING", "SUSPENDING", "SUSPENDED"])("leaves the runner document while the VM is %s", async state => {
      states["vm-1"] = state
      db.docs.set(`${ROOT}/runners/42`, { microvm_id: "vm-1", state: "ready", current_package: null, updated_at: NOW - MIN })
      expect(await runWatchdog(deps)).not.toContain("watchdog.runner_terminated")
      expect(db.read(RUNNER)).toMatchObject({ state: "ready" })
    })

    it("leaves a runner document that names another VM", async () => {
      states["vm-1"] = "TERMINATED"
      db.docs.set(RUNNER, { microvm_id: "vm-2", state: "starting" })
      expect(await runWatchdog(deps)).toEqual([])
      expect(db.read(RUNNER)).toEqual({ microvm_id: "vm-2", state: "starting" })
    })

    it.each(["terminated", "failed"])("does not rewrite a runner document already %s, nor log", async runnerState => {
      states["vm-1"] = null
      db.docs.set(RUNNER, { microvm_id: "vm-1", state: runnerState, updated_at: "<earlier>" })
      expect(await runWatchdog(deps)).toEqual([])
      expect(db.read(RUNNER)).toEqual({ microvm_id: "vm-1", state: runnerState, updated_at: "<earlier>" })
      expect(deps.log.info).not.toHaveBeenCalled()
    })
  })
})
