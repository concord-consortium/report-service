import * as fs from "fs"
import * as path from "path"
import { FakeDb } from "../test/researcher-dashboard-fake-db"
import { Derived } from "./derive-profile"
import { DeriveTask } from "./derive-profile-route"
import { DerivationDeps, enqueueDerivation, runDerivation, writeProfile } from "./derive-profile-worker"

const createTask = jest.fn()
jest.mock("@google-cloud/tasks", () => ({ CloudTasksClient: jest.fn().mockImplementation(() => ({ createTask })) }))

const PATH = `researcher_dashboard/learn_concord_org/classes/${"c".repeat(48)}`

class FakeTimestamp {
  constructor(private ms: number) {}
  toMillis() { return this.ms }
}

const task = (requestedAt: number, overrides: Partial<DeriveTask> = {}): DeriveTask => ({
  portal: "learn_concord_org",
  platform_id: "https://learn.concord.org/",
  class_hash: "c".repeat(48),
  assignment_fingerprint: `v1:${requestedAt}`,
  assignment_urls: [`https://clue.example/?unit=${requestedAt}`],
  requested_at: requestedAt,
  ...overrides
})

const derived = (urls: string[]): Derived => ({ interactive_urls: urls, content_urls: [], unread: [], truncated: false })

let db: FakeDb
let deps: DerivationDeps

beforeEach(() => {
  db = new FakeDb()
  deps = {
    db,
    timestamp: () => "<server timestamp>",
    fromMillis: ms => new FakeTimestamp(ms),
    fetchImpl: jest.fn(),
    allowedHosts: new Set(["authoring.concord.org"])
  }
})

describe("writeProfile", () => {
  it("sets exactly the profile's fields, replacing whatever was there", async () => {
    db.docs.set(PATH, { stale: true, requested_at: new FakeTimestamp(1) })
    await writeProfile(deps, task(1000), { interactive_urls: ["https://x.org/"], content_urls: ["https://a/"], unread: [{ url: "https://b/", reason: "HTTP 404" }], truncated: true })

    const doc = db.read(PATH)
    expect(Object.keys(doc).sort()).toEqual([
      "assignment_fingerprint", "assignment_urls", "content_urls", "derived_at", "interactive_urls", "platform_id",
      "requested_at", "truncated", "unread"
    ])
    expect(doc).toMatchObject({
      platform_id: "https://learn.concord.org/",
      assignment_urls: ["https://clue.example/?unit=1000"],
      interactive_urls: ["https://x.org/"],
      content_urls: ["https://a/"],
      unread: [{ url: "https://b/", reason: "HTTP 404" }],
      truncated: true,
      assignment_fingerprint: "v1:1000",
      derived_at: "<server timestamp>"
    })
    expect((doc.requested_at as FakeTimestamp).toMillis()).toBe(1000)
  })

  it("writes nothing for a task older than the stored request", async () => {
    await writeProfile(deps, task(2000), derived(["https://new/"]))
    await writeProfile(deps, task(1000), derived(["https://old/"]))
    expect(db.read(PATH).interactive_urls).toEqual(["https://new/"])
  })

  it("leaves the later request's document whichever of two tasks lands first", async () => {
    for (const order of [[1000, 2000], [2000, 1000]]) {
      db = new FakeDb()
      deps.db = db
      await Promise.all(order.map(t => writeProfile(deps, task(t), derived([`https://${t}/`]))))
      expect(db.read(PATH).assignment_fingerprint).toBe("v1:2000")
    }
  })

  it("rewrites the same request's derivation, since a retried task carries the same time", async () => {
    await writeProfile(deps, task(1000), derived(["https://first/"]))
    await writeProfile(deps, task(1000), derived(["https://retry/"]))
    expect(db.read(PATH).interactive_urls).toEqual(["https://retry/"])
  })
})

describe("runDerivation", () => {
  it("derives from the task's URLs and writes the class document", async () => {
    await runDerivation(deps, task(1000, { assignment_urls: ["https://models-resources.concord.org/collaborative-learning/index.html?unit=moth"] }))
    expect(deps.fetchImpl).not.toHaveBeenCalled()
    expect(db.read(PATH)).toMatchObject({ interactive_urls: [], content_urls: [], unread: [], truncated: false })
  })
})

describe("enqueueDerivation", () => {
  const saved = { ...process.env }
  const log = { error: jest.fn() }
  const settle = () => new Promise(resolve => setTimeout(resolve, 20))

  beforeEach(() => {
    createTask.mockReset()
    createTask.mockResolvedValue([{}])
    log.error.mockReset()
    delete process.env.FUNCTIONS_EMULATOR
    delete process.env.GCLOUD_PROJECT
    delete process.env.GCP_PROJECT
  })

  afterEach(() => { process.env = { ...saved } })

  it("queues the task for deriveProfileWorker with an OIDC token, as onTaskDispatched expects", async () => {
    process.env.GCLOUD_PROJECT = "proj"
    await enqueueDerivation(task(1000), () => deps, log)

    const url = "https://us-central1-proj.cloudfunctions.net/deriveProfileWorker"
    expect(createTask).toHaveBeenCalledTimes(1)
    const { parent, task: queued } = createTask.mock.calls[0][0]
    expect(parent).toBe("projects/proj/locations/us-central1/queues/deriveProfileWorker")
    expect(queued.httpRequest).toMatchObject({
      httpMethod: "POST",
      url,
      headers: { "Content-Type": "application/json" },
      oidcToken: { serviceAccountEmail: "proj@appspot.gserviceaccount.com", audience: url }
    })
    expect(JSON.parse(Buffer.from(queued.httpRequest.body, "base64").toString())).toEqual({ data: task(1000) })
  })

  it("refuses when the project is unknown", async () => {
    await expect(enqueueDerivation(task(1000), () => deps, log)).rejects.toThrow("the GCP project is unknown")
    expect(createTask).not.toHaveBeenCalled()
  })

  it("derives directly under the emulator", async () => {
    process.env.FUNCTIONS_EMULATOR = "true"
    await enqueueDerivation(task(1000), () => deps, log)
    await settle()
    expect(createTask).not.toHaveBeenCalled()
    expect(db.read(PATH)).toMatchObject({ assignment_fingerprint: "v1:1000" })
  })

  it("logs a failed emulator derivation rather than rejecting", async () => {
    process.env.FUNCTIONS_EMULATOR = "true"
    db.runTransaction = () => Promise.reject(new Error("firestore down"))
    await expect(enqueueDerivation(task(1000), () => deps, log)).resolves.toBeUndefined()
    await settle()
    expect(log.error).toHaveBeenCalledWith("derive-profile: emulator derivation failed", { error: "Error: firestore down" })
  })
})

describe("what the profile modules read", () => {
  it("never touch authored state, an interactive's display name, or CLUE's curriculum", () => {
    for (const file of ["derive-profile-route.ts", "derive-profile-worker.ts", "derive-profile-task.ts"]) {
      const source = fs.readFileSync(path.join(__dirname, file), "utf8")
      expect(source).not.toMatch(/authored_state|curriculum|library_interactive/i)
    }
  })
})
