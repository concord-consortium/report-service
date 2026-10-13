/**
 * @jest-environment node
 */
import http from "http"
import express from "express"
import { AddressInfo } from "net"
import { researcherDashboardApp } from "./app"
import { RunPackageDeps } from "./run-package"
import { VmRouteDeps } from "./vm-routes"
import { RunnerClaims } from "./vm-auth"
import { FakeDb } from "../test/researcher-dashboard-fake-db"
import { BrokerRefusal } from "./storage-policy"

const PLATFORM = "https://learn.portal.staging.concord.org/"
const PORTAL = "learn_portal_staging_concord_org"
const ROOT = `researcher_dashboard/${PORTAL}`
const CLASS_A = "a".repeat(48)
const CLASS_B = "b".repeat(48)
const CHECKSUM = `sha256:${"0".repeat(64)}`
const NOW = Date.parse("2026-09-25T12:00:00Z")
const HOUR = 3600 * 1000

const runnerClaims: RunnerClaims = {
  uid: "firebase-uid-42", platform_id: PLATFORM, platform_user_id: 42, user_type: "researcher", researcher_dashboard_runner: true
}
// Bearer strings the fake verifier knows, standing for verified ID tokens
const tokens: Record<string, RunnerClaims> = {
  runner: runnerClaims,
  browser: { ...runnerClaims, researcher_dashboard_runner: undefined, class_hash: CLASS_A },
  truthyClaim: { ...runnerClaims, researcher_dashboard_runner: "true" },
  learner: { ...runnerClaims, user_type: "learner" },
  wildcardId: { ...runnerClaims, platform_user_id: "4*" },
  zeroId: { ...runnerClaims, platform_user_id: 0 },
  noPlatform: { ...runnerClaims, platform_id: "not a url" },
  stringId: { ...runnerClaims, platform_user_id: "42" }
}

let db: FakeDb
let deps: VmRouteDeps
let server: http.Server
let port: number

const entry = (identity: string, classHash = CLASS_A) => ({ identity, version: "1.0.0", checksum: CHECKSUM, catalog_id: 7, class_hash: classHash })
const key = (identity: string) => identity.replace(/\//g, "__")
const resultAt = (identity: string, classHash = CLASS_A) => `${ROOT}/classes/${classHash}/researchers/42/results/${key(identity)}`
const scopeOf = (classHash: string) => ({ kind: "class", collection: "classes", id: classHash, classes: [{ class_hash: classHash, class_id: 1 }], assignments: [] })

function seed(packages: ReturnType<typeof entry>[], statuses: Record<string, string> = {}) {
  db.docs.set(`${ROOT}/work/42`, {
    packages,
    scopes: Object.fromEntries([...new Set(packages.map(p => p.class_hash))].map(h =>
      [h, { scope: scopeOf(h), class_tokens: { "report-service-dev": `rigse-class-${h[0]}`, "collaborative-learning": `clue-${h[0]}` } }])),
    session_token: "rigse-session", firebase_project: "report-service-dev", updated_at: NOW - HOUR
  })
  for (const p of packages) {
    db.docs.set(resultAt(p.identity, p.class_hash), { status: statuses[p.identity] ?? "queued" })
  }
}

beforeEach(async () => {
  db = new FakeDb()
  db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", launched_at: NOW - HOUR })
  deps = {
    db,
    verifyIdToken: jest.fn(async (t: string) => {
      if (!tokens[t]) {
        throw new Error("bad token")
      }
      return tokens[t]
    }),
    microvms: { suspend: jest.fn().mockResolvedValue(undefined) },
    broker: { assume: jest.fn().mockResolvedValue({ accessKeyId: "ASIA", secretAccessKey: "s", sessionToken: "t", expiration: new Date(NOW + HOUR) }) },
    mint: jest.fn(async (uid: string, claims: Record<string, unknown>) => `minted:${uid}:${claims.class_hash ?? "session"}`),
    ownProject: "report-service-dev",
    now: () => NOW,
    log: { error: jest.fn() },
    config: {
      bucket: "researcher-dashboard-runner-staging", brokerRoleArn: "arn:aws:iam::1:role/broker", audience: "researcher-dashboard-runner-staging", unconfigured: []
    }
  }
  const noRigse = () => { throw new Error("no rigse routes here") }
  server = express().use(express.json() as express.RequestHandler)
    .use(researcherDashboardApp(noRigse as () => RunPackageDeps, noRigse as never, () => deps)).listen(0)
  await new Promise(resolve => server.once("listening", resolve))
  port = (server.address() as AddressInfo).port
})

afterEach(() => new Promise(resolve => server.close(resolve)))

const post = (path: string, body: object = { microvm_id: "vm-1" }, bearer: string | null = "runner") =>
  new Promise<{ status: number; body: any }>((resolve, reject) => {
    const data = JSON.stringify(body)
    const headers: http.OutgoingHttpHeaders = { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) }
    if (bearer) headers.Authorization = `Bearer ${bearer}`
    const req = http.request({ port, path, method: "POST", headers }, res => {
      let raw = ""
      res.on("data", c => { raw += c })
      res.on("end", () => resolve({ status: res.statusCode!, body: raw ? JSON.parse(raw) : null }))
    })
    req.on("error", reject)
    req.end(data)
  })

describe("the VM's authentication", () => {
  it.each(["/work", "/idle", "/storage-credentials"])("%s refuses a missing or unverifiable token with 401", async path => {
    expect((await post(path, undefined, null)).status).toBe(401)
    expect((await post(path, undefined, "forged")).status).toBe(401)
  })

  it.each(["/work", "/idle", "/storage-credentials"])("%s refuses a browser's token for the same researcher with 403", async path => {
    seed([entry("users/1/a")])
    const res = await post(path, undefined, "browser")
    expect(res.status).toBe(403)
    expect(JSON.stringify(res.body)).not.toMatch(/rigse-|minted|ASIA/)
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
    expect(deps.broker.assume).not.toHaveBeenCalled()
  })

  const refusedTokens = ["truthyClaim", "learner", "wildcardId", "zeroId", "noPlatform"]
  it.each(["/work", "/idle", "/storage-credentials"].flatMap(path => refusedTokens.map(name => [path, name])))(
    "%s refuses a token with %s", async (path, name) => {
      seed([entry("users/1/a")], { "users/1/a": "done" })
      const res = await post(path, undefined, name)
      expect(res.status).toBe(403)
      expect(JSON.stringify(res.body)).not.toMatch(/rigse-|minted|ASIA/)
      expect(deps.microvms.suspend).not.toHaveBeenCalled()
      expect(deps.broker.assume).not.toHaveBeenCalled()
    })

  const elsewhere = { microvm_id: "vm-1", platform_user_id: 7, platform_id: "https://evil.example/" }

  it("/work takes the researcher from the token, not the body", async () => {
    seed([entry("users/1/a")])
    const res = await post("/work", elsewhere)
    expect(res.body.packages.map((p: any) => p.identity)).toEqual(["users/1/a"])
  })

  it("/idle takes the researcher from the token, not the body", async () => {
    seed([entry("users/1/a")], { "users/1/a": "done" })
    const res = await post("/idle", elsewhere)
    expect(res.body).toMatchObject({ suspended: true })
    expect(deps.microvms.suspend).toHaveBeenCalledWith("vm-1")
  })

  it("accepts platform_user_id as its decimal string", async () => {
    seed([entry("users/1/a")])
    expect((await post("/work", undefined, "stringId")).body.packages).toHaveLength(1)
    await post("/storage-credentials", undefined, "stringId")
    expect(deps.broker.assume).toHaveBeenCalledWith(expect.objectContaining({ platformUserId: "42" }))
  })

  it("/storage-credentials takes the researcher from the token, not the body", async () => {
    await post("/storage-credentials", elsewhere)
    expect(deps.broker.assume).toHaveBeenCalledWith(expect.objectContaining({ platformUserId: "42" }))
  })
})

describe("POST /work", () => {
  it("hands out the queued packages, in order, with only their classes' scopes", async () => {
    seed([entry("users/1/a"), entry("users/1/b", CLASS_B), entry("users/1/c")], { "users/1/c": "running" })
    const res = await post("/work")
    expect(res.status).toBe(200)
    expect(res.body.packages).toEqual([
      { class_hash: CLASS_A, package_key: "users__1__a", identity: "users/1/a", version: "1.0.0", checksum: CHECKSUM, catalog_id: 7 },
      { class_hash: CLASS_B, package_key: "users__1__b", identity: "users/1/b", version: "1.0.0", checksum: CHECKSUM, catalog_id: 7 }
    ])
    expect(Object.keys(res.body.scopes).sort()).toEqual([CLASS_A, CLASS_B])
    expect(res.body.scopes[CLASS_A].scope).toEqual(scopeOf(CLASS_A))
    expect(res.body.firebase_project).toBe("report-service-dev")
  })

  it("is idempotent: handing work out removes nothing", async () => {
    seed([entry("users/1/a")])
    const first = await post("/work")
    const second = await post("/work")
    expect(second.body.packages).toEqual(first.body.packages)
  })

  it("drops finished entries and a class's scope with its last package", async () => {
    seed([entry("users/1/a"), entry("users/1/b", CLASS_B)], { "users/1/b": "done" })
    const res = await post("/work")
    expect(res.body.packages.map((p: any) => p.identity)).toEqual(["users/1/a"])
    expect(Object.keys(res.body.scopes)).toEqual([CLASS_A])
    expect(deps.mint).toHaveBeenCalledTimes(2)
    expect((deps.mint as jest.Mock).mock.calls.map(([, claims]) => claims.class_hash ?? "session").sort()).toEqual([CLASS_A, "session"].sort())
    const work: any = db.read(`${ROOT}/work/42`)
    expect(work.packages.map((p: any) => p.identity)).toEqual(["users/1/a"])
    expect(Object.keys(work.scopes)).toEqual([CLASS_A])
    expect(db.read(resultAt("users/1/b", CLASS_B))).toEqual({ status: "done" })
  })

  it("mints the session token and this project's class tokens, and passes CLUE's through", async () => {
    seed([entry("users/1/a")])
    const res = await post("/work")
    expect(res.body.session_token).toBe("minted:firebase-uid-42:session")
    expect(res.body.scopes[CLASS_A].class_tokens).toEqual({ "report-service-dev": `minted:firebase-uid-42:${CLASS_A}`, "collaborative-learning": "clue-a" })
    expect(deps.mint).toHaveBeenCalledWith("firebase-uid-42",
      { platform_id: PLATFORM, platform_user_id: 42, user_type: "researcher", researcher_dashboard_runner: true, class_hash: CLASS_A })
  })

  it("passes rigse's tokens through when the recorded VM is past its maximum life", async () => {
    seed([entry("users/1/a")])
    db.docs.set(`${ROOT}/vms/42`, { microvm_id: "vm-1", launched_at: NOW - 9 * HOUR })
    const res = await post("/work")
    expect(res.body.session_token).toBe("rigse-session")
    expect(res.body.scopes[CLASS_A].class_tokens["report-service-dev"]).toBe("rigse-class-a")
    expect(deps.mint).not.toHaveBeenCalled()
  })

  it("answers 502 when minting fails", async () => {
    seed([entry("users/1/a")])
    deps.mint = jest.fn().mockRejectedValue(new Error("iam.serviceAccounts.signBlob denied"))
    const res = await post("/work")
    expect(res.status).toBe(502)
    expect(res.body.error).toMatch(/signBlob/)
  })

  it("answers 502 when the mints take longer than one upstream call", async () => {
    seed([entry("users/1/a")])
    deps.mint = jest.fn(() => new Promise<string>(() => undefined))
    // The ten-second cut-off fires at once, so the test does not wait for it.
    const realSetTimeout = global.setTimeout
    const spy = jest.spyOn(global, "setTimeout").mockImplementation(((fn: () => void, ms?: number) =>
      realSetTimeout(fn, ms === 10 * 1000 ? 0 : ms)) as typeof setTimeout)
    try {
      const res = await post("/work")
      expect(res.status).toBe(502)
      expect(res.body.error).toMatch(/no answer within 10 seconds/)
    } finally {
      spy.mockRestore()
    }
  })

  it("answers only the recorded VM", async () => {
    seed([entry("users/1/a")])
    expect((await post("/work", { microvm_id: "vm-stray" })).status).toBe(409)
    expect((await post("/work", {})).status).toBe(400)
    expect((await post("/work", { microvm_id: 5 })).status).toBe(400)
  })

  it("passes rigse's tokens through for a queue recorded for another project", async () => {
    seed([entry("users/1/a")])
    db.docs.set(`${ROOT}/work/42`, { ...db.read(`${ROOT}/work/42`), firebase_project: "report-service-pro" })
    const res = await post("/work")
    expect(deps.mint).not.toHaveBeenCalled()
    expect(res.body.session_token).toBe("rigse-session")
    expect(res.body.scopes[CLASS_A].class_tokens["report-service-dev"]).toBe("rigse-class-a")
  })

  it("answers an empty queue with the session token", async () => {
    seed([entry("users/1/a")], { "users/1/a": "done" })
    const res = await post("/work")
    expect(res.body).toMatchObject({ packages: [], session_token: "minted:firebase-uid-42:session" })
    expect(res.body.scopes).toEqual({})
  })
})

describe("POST /idle", () => {
  it("refuses a missing or non-string microvm_id with 400 and suspends nothing", async () => {
    seed([entry("users/1/a")], { "users/1/a": "done" })
    expect((await post("/idle", {})).status).toBe(400)
    expect((await post("/idle", { microvm_id: 5 })).status).toBe(400)
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("suspends the recorded VM when nothing is queued", async () => {
    seed([entry("users/1/a")], { "users/1/a": "done" })
    const res = await post("/idle")
    expect(res).toMatchObject({ status: 200, body: { suspended: true } })
    expect(deps.microvms.suspend).toHaveBeenCalledWith("vm-1")
    expect(db.read(`${ROOT}/work/42`)).toMatchObject({ packages: [], scopes: {} })
  })

  it("does not suspend when work was queued meanwhile", async () => {
    seed([entry("users/1/a")])
    const res = await post("/idle")
    expect(res.body).toMatchObject({ suspended: false, work_queued: true })
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("does not suspend, answering run_in_progress, when a running result names this VM", async () => {
    seed([entry("users/1/a")], { "users/1/a": "running" })
    db.docs.set(resultAt("users/1/a"), { status: "running", microvm_id: "vm-1" })
    const res = await post("/idle")
    expect(res).toMatchObject({ status: 200, body: { success: true, suspended: false, run_in_progress: true } })
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("suspends when the only running result names another VM", async () => {
    seed([entry("users/1/a")], { "users/1/a": "running" })
    db.docs.set(resultAt("users/1/a"), { status: "running", microvm_id: "vm-0" })
    const res = await post("/idle")
    expect(res.body).toMatchObject({ suspended: true })
    expect(deps.microvms.suspend).toHaveBeenCalledWith("vm-1")
  })

  it("will not suspend a VM that is not the recorded one", async () => {
    expect((await post("/idle", { microvm_id: "vm-stray" })).status).toBe(409)
    expect(deps.microvms.suspend).not.toHaveBeenCalled()
  })

  it("answers 502 with the reason when SuspendMicrovm fails", async () => {
    (deps.microvms.suspend as jest.Mock).mockRejectedValue(new Error("ConflictException"))
    const res = await post("/idle")
    expect(res.status).toBe(502)
    expect(res.body.error).toMatch(/ConflictException/)
  })
})

describe("POST /storage-credentials", () => {
  it("answers the session for the token's researcher", async () => {
    const res = await post("/storage-credentials")
    expect(res.status).toBe(200)
    expect(res.body).toEqual({
      success: true, access_key_id: "ASIA", secret_access_key: "s", session_token: "t",
      expiration: new Date(NOW + HOUR).toISOString(), bucket: "researcher-dashboard-runner-staging",
      prefix: "researchers/42/", region: "us-east-1"
    })
    expect(deps.broker.assume).toHaveBeenCalledWith({ roleArn: "arn:aws:iam::1:role/broker", audience: "researcher-dashboard-runner-staging", bucket: "researcher-dashboard-runner-staging", platformUserId: "42" })
  })

  it("answers 503 naming the unset settings", async () => {
    deps.config = { ...deps.config, unconfigured: ["RD_BROKER_ROLE_ARN", "RD_AWS_AUDIENCE"] }
    const res = await post("/storage-credentials")
    expect(res.status).toBe(503)
    expect(res.body.error).toBe("researcherDashboard is not configured: RD_BROKER_ROLE_ARN, RD_AWS_AUDIENCE unset")
    expect(deps.broker.assume).not.toHaveBeenCalled()
  })

  it("answers 503 when the bucket setting is not a bucket name", async () => {
    (deps.broker.assume as jest.Mock).mockRejectedValue(new BrokerRefusal("bucket \"b*\" is not an S3 bucket name"))
    const res = await post("/storage-credentials")
    expect(res.status).toBe(503)
    expect(res.body.error).toMatch(/storage broker is misconfigured/)
  })

  it("answers 502 with the reason when STS refuses", async () => {
    (deps.broker.assume as jest.Mock).mockRejectedValue(new Error("AccessDenied"))
    const res = await post("/storage-credentials")
    expect(res.status).toBe(502)
    expect(res.body.error).toMatch(/AccessDenied/)
  })
})
