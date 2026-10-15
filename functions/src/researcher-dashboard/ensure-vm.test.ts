import { ensureVm, EnsureVmDeps, VmStepError, wakeSuspended } from "./ensure-vm"
import { MicrovmApi } from "./microvm"
import { Researcher, RunPackageBody } from "./run-package"
import { FakeDb } from "../test/researcher-dashboard-fake-db"

const PORTAL = "learn_portal_staging_concord_org"
const VM_PATH = `researcher_dashboard/${PORTAL}/vms/42`
const RUNNER_PATH = `researcher_dashboard/${PORTAL}/runners/42`
const NOW = 1_800_000_000_000
const TIMESTAMP = "<server timestamp>"

const who: Researcher = { uid: 42, platformUserId: "42", platformId: "https://learn.portal.staging.concord.org/", portal: PORTAL }

const body = (overrides: Partial<RunPackageBody> = {}) => ({
  packages: [],
  scope: { kind: "class", collection: "classes", id: "a", classes: [{ class_hash: "a", class_id: 1 }], assignments: [] },
  class_tokens: { "report-service": "class-token" },
  session_token: "session-token",
  firebase_project: "report-service-dev",
  report_server_assertion: "the-assertion",
  ...overrides
}) as RunPackageBody

const okResponse = (json: object, status = 201) =>
  ({ ok: status >= 200 && status < 300, status, json: async () => json }) as unknown as Response

let db: FakeDb
let microvms: { [K in keyof MicrovmApi]: jest.Mock }
let fetchImpl: jest.Mock
let deps: EnsureVmDeps

beforeEach(() => {
  db = new FakeDb()
  microvms = {
    currentImageVersion: jest.fn().mockResolvedValue("7"),
    get: jest.fn().mockResolvedValue(null),
    run: jest.fn().mockResolvedValue({ microvmId: "vm-new", imageVersion: "7" }),
    resume: jest.fn().mockResolvedValue(undefined),
    suspend: jest.fn().mockResolvedValue(undefined),
    terminate: jest.fn().mockResolvedValue(undefined)
  }
  fetchImpl = jest.fn().mockResolvedValue(okResponse({ token: "ccd_minted", expires_at: "later", user_id: 3 }))
  deps = {
    db,
    microvms,
    fetchImpl: fetchImpl as unknown as typeof fetch,
    now: () => NOW,
    timestamp: () => TIMESTAMP,
    log: { warn: jest.fn() },
    config: {
      imageIdentifier: "arn:image",
      executionRoleArn: "arn:role",
      bucket: "runner-bucket",
      reportServerUrl: "https://report-server.example/",
      functionUrl: "https://us-central1-report-service-dev.cloudfunctions.net/researcherDashboard"
    }
  }
})

const recordVm = (doc: object) => db.docs.set(VM_PATH, doc as Record<string, unknown>)

describe("ensureVm", () => {
  it("launches when no VM is recorded, minting once and passing exactly the payload the runner reads", async () => {
    expect(await ensureVm(deps, who, body())).toBe("launched")

    expect(fetchImpl).toHaveBeenCalledTimes(1)
    const [url, init] = fetchImpl.mock.calls[0]
    expect(url).toBe("https://report-server.example/api/v1/dashboard-tokens")
    expect(init.headers.Authorization).toBe("Bearer the-assertion")

    expect(microvms.run).toHaveBeenCalledTimes(1)
    const input = microvms.run.mock.calls[0][0]
    expect(input).toEqual({ imageIdentifier: "arn:image", imageVersion: "7", executionRoleArn: "arn:role", runHookPayload: expect.any(String) })
    expect(JSON.parse(input.runHookPayload)).toEqual({
      session_token: "session-token",
      platform_user_id: "42",
      platform_id: "https://learn.portal.staging.concord.org/",
      portal: PORTAL,
      firebase_project: "report-service-dev",
      bucket: "runner-bucket",
      report_server_token: "ccd_minted",
      report_server_url: "https://report-server.example/",
      function_url: "https://us-central1-report-service-dev.cloudfunctions.net/researcherDashboard"
    })
  })

  it("records the launched VM and writes the runner document as starting", async () => {
    db.docs.set(RUNNER_PATH, { queue: [{ class_hash: "a", package_key: "projects__20__x" }] })

    await ensureVm(deps, who, body())

    expect(db.docs.get(VM_PATH)).toEqual({ microvm_id: "vm-new", image_version: "7", launching_until: null, launched_at: TIMESTAMP, resumed_at: null })
    expect(db.docs.get(RUNNER_PATH)).toEqual({
      queue: [{ class_hash: "a", package_key: "projects__20__x" }],
      state: "starting",
      microvm_id: "vm-new",
      platform_id: "https://learn.portal.staging.concord.org/",
      started_at: TIMESTAMP,
      updated_at: TIMESTAMP
    })
  })

  it("clears the last VM's resumed_at when it records a launch", async () => {
    recordVm({ microvm_id: "vm-old", resumed_at: "an old resume" })
    microvms.get.mockResolvedValue({ state: "TERMINATED" })

    await ensureVm(deps, who, body())

    expect(db.docs.get(VM_PATH)).toMatchObject({ microvm_id: "vm-new", resumed_at: null })
  })

  it.each([["TERMINATED"], ["TERMINATING"]])("launches when the recorded VM is %s", async state => {
    recordVm({ microvm_id: "vm-old" })
    microvms.get.mockResolvedValue({ state })

    expect(await ensureVm(deps, who, body())).toBe("launched")
    expect(db.docs.get(VM_PATH)).toMatchObject({ microvm_id: "vm-new" })
  })

  it("answers a GetMicrovmImage failure with 502 naming it, before claiming", async () => {
    microvms.currentImageVersion.mockRejectedValue(new Error("throttled"))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "GetMicrovmImage failed: throttled" })
    expect(db.docs.get(VM_PATH)).toBeUndefined()
    expect(fetchImpl).not.toHaveBeenCalled()
    expect(microvms.run).not.toHaveBeenCalled()
  })

  it("launches when the API no longer knows the recorded VM", async () => {
    recordVm({ microvm_id: "vm-gone" })

    expect(await ensureVm(deps, who, body())).toBe("launched")
    expect(microvms.get).toHaveBeenCalledWith("vm-gone")
  })

  it("resumes a suspended VM without minting", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "7" })
    microvms.get.mockResolvedValue({ state: "SUSPENDED" })

    expect(await ensureVm(deps, who, body())).toBe("resumed")
    expect(microvms.resume).toHaveBeenCalledWith("vm-old")
    expect(db.docs.get(VM_PATH)).toMatchObject({ resumed_at: TIMESTAMP })
    expect(fetchImpl).not.toHaveBeenCalled()
    expect(microvms.run).not.toHaveBeenCalled()
    expect(microvms.terminate).not.toHaveBeenCalled()
  })

  it("resumes nothing when a newer VM was recorded after it read the suspended one", async () => {
    recordVm({ microvm_id: "vm-old" })
    microvms.get.mockImplementation(async () => {
      recordVm({ microvm_id: "vm-newer" })
      return { state: "SUSPENDED" }
    })

    expect(await ensureVm(deps, who, body())).toBe("launching")
    expect(microvms.resume).not.toHaveBeenCalled()
  })

  it.each([["RUNNING"], ["PENDING"]])("leaves a %s VM alone and does not mint", async state => {
    recordVm({ microvm_id: "vm-old" })
    microvms.get.mockResolvedValue({ state })

    expect(await ensureVm(deps, who, body())).toBe("running")
    expect(fetchImpl).not.toHaveBeenCalled()
    expect(microvms.run).not.toHaveBeenCalled()
    expect(microvms.resume).not.toHaveBeenCalled()
  })

  it("leaves a suspending VM for the watchdog to resume", async () => {
    recordVm({ microvm_id: "vm-old" })
    microvms.get.mockResolvedValue({ state: "SUSPENDING" })

    expect(await ensureVm(deps, who, body())).toBe("suspending")
    expect(microvms.resume).not.toHaveBeenCalled()
    expect(microvms.run).not.toHaveBeenCalled()
  })

  it("launches one VM for two concurrent requests", async () => {
    const outcomes = await Promise.all([ensureVm(deps, who, body()), ensureVm(deps, who, body())])

    expect(outcomes.sort()).toEqual(["launched", "launching"])
    expect(microvms.run).toHaveBeenCalledTimes(1)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it("does nothing while another request's launch claim is live", async () => {
    recordVm({ launching_until: NOW + 1000 })

    expect(await ensureVm(deps, who, body())).toBe("launching")
    expect(microvms.run).not.toHaveBeenCalled()
  })

  it("launches over a claim that has lapsed", async () => {
    recordVm({ launching_until: NOW - 1 })

    expect(await ensureVm(deps, who, body())).toBe("launched")
  })

  it("answers report-server's refusal with its status and reason, and clears the claim", async () => {
    fetchImpl.mockResolvedValue(okResponse({ error: "NOT_AUTHENTICATED", message: "You must supply a valid API token." }, 401))

    const failure = ensureVm(deps, who, body())

    await expect(failure).rejects.toThrow(VmStepError)
    await expect(failure).rejects.toMatchObject({ status: 502, message: expect.stringMatching(/refused the dashboard token \(401\): You must supply/) })
    expect(microvms.run).not.toHaveBeenCalled()
    expect(db.docs.get(VM_PATH)).toEqual({ launching_until: null })
  })

  it("times out a report-server that sends headers and then stalls the body", async () => {
    jest.useFakeTimers()
    try {
      fetchImpl.mockResolvedValue({ ok: true, status: 201, json: () => new Promise(() => undefined) })

      const failure = ensureVm(deps, who, body())
      await new Promise(resolve => setImmediate(resolve))
      jest.advanceTimersByTime(10 * 1000)

      await expect(failure).rejects.toMatchObject({ status: 502, message: expect.stringMatching(/no answer within 10 seconds/) })
      expect(microvms.run).not.toHaveBeenCalled()
      expect(db.docs.get(VM_PATH)).toEqual({ launching_until: NOW + 60 * 1000 })
    } finally {
      jest.useRealTimers()
    }
  })

  it("keeps the claim when report-server cannot be reached, since it may have minted", async () => {
    fetchImpl.mockRejectedValue(new Error("socket hang up"))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: expect.stringMatching(/could not be reached.*socket hang up/) })
    expect(db.docs.get(VM_PATH)).toEqual({ launching_until: NOW + 60 * 1000 })
  })

  it("answers a RunMicrovm refusal with 502 naming it, and clears the claim", async () => {
    microvms.run.mockRejectedValue(Object.assign(new Error("ThrottlingException"), { $metadata: { httpStatusCode: 429 } }))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "RunMicrovm failed: ThrottlingException" })
    expect(db.docs.get(VM_PATH)).toEqual({ launching_until: null })
  })

  const mayHaveLaunched: [string, object][] = [["a timeout", {}], ["a 5xx", { $metadata: { httpStatusCode: 503 } }]]
  it.each(mayHaveLaunched)(
    "keeps the claim when RunMicrovm fails with %s, since a VM may have been launched", async (_label, metadata) => {
      microvms.run.mockRejectedValue(Object.assign(new Error("no answer"), metadata))

      await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "RunMicrovm failed: no answer" })
      expect(db.docs.get(VM_PATH)).toEqual({ launching_until: NOW + 60 * 1000 })
      expect(await ensureVm(deps, who, body())).toBe("launching")
      expect(microvms.run).toHaveBeenCalledTimes(1)
    })

  it("answers the upstream reason even when clearing the claim fails", async () => {
    fetchImpl.mockResolvedValue(okResponse({ message: "nope" }, 401))
    const transact = db.runTransaction.bind(db)
    let transactions = 0
    // the claim is the first transaction and the clear the second
    db.runTransaction = (fn => ++transactions === 2 ? Promise.reject(new Error("unavailable")) : transact(fn)) as typeof db.runTransaction

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: expect.stringMatching(/refused the dashboard token \(401\): nope/) })
  })

  it("keeps the claim when the launched VM cannot be recorded, so no second VM is launched", async () => {
    const transact = db.runTransaction.bind(db)
    let transactions = 0
    // the claim is the first transaction and the record the second
    db.runTransaction = (fn => ++transactions === 2 ? Promise.reject(new Error("unavailable")) : transact(fn)) as typeof db.runTransaction

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: expect.stringMatching(/vm-new was launched but could not be recorded/) })
    expect(db.docs.get(VM_PATH)).toEqual({ launching_until: NOW + 60 * 1000 })

    db.runTransaction = transact
    expect(await ensureVm(deps, who, body())).toBe("launching")
    expect(microvms.run).toHaveBeenCalledTimes(1)
  })

  it("aborts a report-server that does not answer in time, answers 502 and keeps the claim", async () => {
    jest.useFakeTimers()
    try {
      fetchImpl.mockReturnValue(new Promise(() => undefined))

      const failure = ensureVm(deps, who, body())
      await new Promise(resolve => setImmediate(resolve))
      jest.advanceTimersByTime(10 * 1000)

      await expect(failure).rejects.toMatchObject({ status: 502, message: expect.stringMatching(/could not be reached.*no answer within 10 seconds/) })
      expect(fetchImpl.mock.calls[0][1].signal.aborted).toBe(true)
      // the mint may still land, so the next request must not launch and mint again yet
      expect(db.docs.get(VM_PATH)).toEqual({ launching_until: NOW + 60 * 1000 })
    } finally {
      jest.useRealTimers()
    }
  })

  it("answers a GetMicrovm failure with 502 naming it", async () => {
    recordVm({ microvm_id: "vm-old" })
    microvms.get.mockRejectedValue(new Error("AccessDenied"))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "GetMicrovm failed: AccessDenied" })
  })

  it("answers a VM found with no state with 502, and launches nothing beside it", async () => {
    recordVm({ microvm_id: "vm-old" })
    microvms.get.mockResolvedValue({})

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "GetMicrovm failed: the answer has no state" })
    expect(microvms.run).not.toHaveBeenCalled()
  })

  it("answers a ResumeMicrovm failure with 502 naming it", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "7" })
    microvms.get.mockResolvedValue({ state: "SUSPENDED" })
    microvms.resume.mockRejectedValue(new Error("ConflictException"))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "ResumeMicrovm failed: ConflictException" })
  })

  it("refuses a payload over the platform's cap before RunMicrovm, and clears the claim", async () => {
    await expect(ensureVm(deps, who, body({ session_token: "x".repeat(17000) }))).rejects.toMatchObject({ status: 500 })
    expect(microvms.run).not.toHaveBeenCalled()
    expect(db.docs.get(VM_PATH)).toEqual({ launching_until: null })
  })
})

describe("wakeSuspended", () => {
  it("writes resumed_at before it calls ResumeMicrovm", async () => {
    recordVm({ microvm_id: "vm-old" })
    let seenAtResume: unknown
    microvms.resume.mockImplementation(async () => { seenAtResume = db.docs.get(VM_PATH)?.resumed_at })

    expect(await wakeSuspended(deps, who, { microvm_id: "vm-old" }, undefined)).toBe("resumed")
    expect(seenAtResume).toBe(TIMESTAMP)
  })

  it("writes and resumes nothing when vms/ records another VM", async () => {
    recordVm({ microvm_id: "vm-newer" })

    expect(await wakeSuspended(deps, who, { microvm_id: "vm-old" }, undefined)).toBe("held")

    expect(db.docs.get(VM_PATH)).toEqual({ microvm_id: "vm-newer" })
    expect(microvms.resume).not.toHaveBeenCalled()
  })

  it("resumes nothing when mayCall says no, with resumed_at written", async () => {
    recordVm({ microvm_id: "vm-old" })

    expect(await wakeSuspended({ ...deps, mayCall: () => false }, who, { microvm_id: "vm-old" }, undefined)).toBe("held")

    expect(microvms.resume).not.toHaveBeenCalled()
    expect(db.docs.get(VM_PATH)).toMatchObject({ resumed_at: TIMESTAMP })
  })

  it("answers 502 when ResumeMicrovm fails, with resumed_at already written", async () => {
    recordVm({ microvm_id: "vm-old" })
    microvms.resume.mockRejectedValue(new Error("ConflictException"))

    await expect(wakeSuspended(deps, who, { microvm_id: "vm-old" }, undefined)).rejects.toMatchObject({ status: 502 })
    expect(db.docs.get(VM_PATH)).toMatchObject({ resumed_at: TIMESTAMP })
  })
})

describe("replacing a suspended VM on an old image", () => {
  const WORK_PATH = `researcher_dashboard/${PORTAL}/work/42`
  const RESULT_PATH = `researcher_dashboard/${PORTAL}/classes/a/researchers/42/results/users__1__a`
  const runningResult = (microvmId: string) => {
    db.docs.set(WORK_PATH, { packages: [{ identity: "users/1/a", version: "1", checksum: "c", catalog_id: 1, class_hash: "a" }] })
    db.docs.set(RESULT_PATH, { status: "running", microvm_id: microvmId })
  }
  const calls: string[] = []

  beforeEach(() => {
    calls.length = 0
    microvms.get.mockResolvedValue({ state: "SUSPENDED" })
    microvms.currentImageVersion.mockImplementation(async () => { calls.push("GetMicrovmImage"); return "7" })
    microvms.run.mockImplementation(async () => { calls.push("RunMicrovm"); return { microvmId: "vm-new", imageVersion: "7" } })
    microvms.terminate.mockImplementation(async (id: string) => {
      calls.push(`TerminateMicrovm ${id} with vms/ naming ${db.docs.get(VM_PATH)?.microvm_id}`)
    })
  })

  it("launches on the active version, records the new VM, and only then terminates the old one", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })

    expect(await ensureVm(deps, who, body())).toBe("launched")

    expect(calls).toEqual(["GetMicrovmImage", "RunMicrovm", "TerminateMicrovm vm-old with vms/ naming vm-new"])
    expect(microvms.run.mock.calls[0][0].imageVersion).toBe("7")
    expect(microvms.resume).not.toHaveBeenCalled()
    expect(db.docs.get(VM_PATH)).toEqual({ microvm_id: "vm-new", image_version: "7", launching_until: null, launched_at: TIMESTAMP, resumed_at: null })
  })

  it.each<[string, object]>([
    ["no recorded version", { microvm_id: "vm-old" }],
    ["a null version", { microvm_id: "vm-old", image_version: null }]
  ])("replaces a VM with %s", async (_, vm) => {
    recordVm(vm)

    expect(await ensureVm(deps, who, body())).toBe("launched")
    expect(microvms.terminate).toHaveBeenCalledWith("vm-old")
    expect(microvms.resume).not.toHaveBeenCalled()
  })

  it("resumes when the image has no active version", async () => {
    microvms.currentImageVersion.mockResolvedValue(undefined)
    recordVm({ microvm_id: "vm-old", image_version: "6" })

    expect(await ensureVm(deps, who, body())).toBe("resumed")
    expect(microvms.resume).toHaveBeenCalledWith("vm-old")
    expect(microvms.terminate).not.toHaveBeenCalled()
  })

  it("resumes a VM on an old version that a running result names", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })
    runningResult("vm-old")

    expect(await ensureVm(deps, who, body())).toBe("resumed")
    expect(microvms.resume).toHaveBeenCalledWith("vm-old")
    expect(microvms.run).not.toHaveBeenCalled()
    expect(microvms.terminate).not.toHaveBeenCalled()
  })

  it("replaces a VM on an old version when the running result names another VM", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })
    runningResult("vm-dead")

    expect(await ensureVm(deps, who, body())).toBe("launched")
    expect(microvms.terminate).toHaveBeenCalledWith("vm-old")
  })

  it.each([["an old", "6"], ["the active", "7"]])("does nothing to a VM on %s version while a launch claim is live", async (_, version) => {
    recordVm({ microvm_id: "vm-old", image_version: version, launching_until: NOW + 1000 })

    expect(await ensureVm(deps, who, body())).toBe("launching")
    expect(microvms.run).not.toHaveBeenCalled()
    expect(microvms.resume).not.toHaveBeenCalled()
    expect(microvms.terminate).not.toHaveBeenCalled()
  })

  it("answers a GetMicrovmImage failure with 502 naming it, deciding nothing", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })
    microvms.currentImageVersion.mockRejectedValue(new Error("throttled"))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502, message: "GetMicrovmImage failed: throttled" })
    expect(microvms.resume).not.toHaveBeenCalled()
    expect(microvms.terminate).not.toHaveBeenCalled()
    expect(db.docs.get(VM_PATH)).toEqual({ microvm_id: "vm-old", image_version: "6" })
  })

  it("answers launched and logs when the old VM cannot be terminated", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })
    microvms.terminate.mockRejectedValue(new Error("throttled"))

    expect(await ensureVm(deps, who, body())).toBe("launched")
    expect(deps.log.warn).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ replaced: "vm-old", microvmId: "vm-new", error: "throttled" }))
  })

  it("leaves the old VM recorded and clears the claim when the mint is refused", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })
    fetchImpl.mockResolvedValue(okResponse({ message: "no" }, 403))

    await expect(ensureVm(deps, who, body())).rejects.toMatchObject({ status: 502 })
    expect(microvms.terminate).not.toHaveBeenCalled()
    expect(db.docs.get(VM_PATH)).toEqual({ microvm_id: "vm-old", image_version: "6", launching_until: null })
  })

  it("leaves a running VM on an old version without asking the image", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })
    microvms.get.mockResolvedValue({ state: "RUNNING" })

    expect(await ensureVm(deps, who, body())).toBe("running")
    expect(microvms.currentImageVersion).not.toHaveBeenCalled()
    expect(microvms.terminate).not.toHaveBeenCalled()
  })

  it("launches and terminates once when two requests replace the same VM", async () => {
    recordVm({ microvm_id: "vm-old", image_version: "6" })

    const outcomes = await Promise.all([ensureVm(deps, who, body()), ensureVm(deps, who, body())])

    expect(outcomes.sort()).toEqual(["launched", "launching"])
    expect(microvms.run).toHaveBeenCalledTimes(1)
    expect(microvms.terminate).toHaveBeenCalledTimes(1)
  })
})
