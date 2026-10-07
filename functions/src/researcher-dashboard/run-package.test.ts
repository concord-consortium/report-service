/**
 * @jest-environment node
 */
import http from "http"
import express from "express"
import { AddressInfo } from "net"
import jwt from "jsonwebtoken"
import { generateKeyPairSync } from "crypto"
import { researcherDashboardApp } from "./app"
import { parsePortalKeys } from "./portal-token"
import { RunPackageDeps } from "./run-package"
import { FakeDb } from "../test/researcher-dashboard-fake-db"
import { VmStepError } from "./ensure-vm"

const STAGING_ISS = "https://learn.portal.staging.concord.org/"
const PORTAL = "learn_portal_staging_concord_org"
const CLASS_A = "a".repeat(48)
const CLASS_B = "b".repeat(48)
const CHECKSUM = `sha256:${"0".repeat(64)}`

const PRODUCTION_ISS = "https://learn.concord.org/"

const makeKey = (kid: string, iss: string) => ({ kid, iss, ...generateKeyPairSync("rsa", { modulusLength: 2048 }) })
const staging = makeKey("staging-test", STAGING_ISS)
const production = makeKey("production-test", PRODUCTION_ISS)
const keysJson = JSON.stringify([staging, production].map(k =>
  ({ kid: k.kid, iss: k.iss, pem: k.publicKey.export({ type: "spki", format: "pem" }).toString() })))

const now = () => Math.floor(Date.now() / 1000)
const assertion = (aud: string, overrides: Record<string, unknown> = {}, key = staging) =>
  jwt.sign({ iss: key.iss, aud, uid: 42, iat: now(), exp: now() + 120, ...overrides }, key.privateKey, { algorithm: "RS256", keyid: key.kid })

const TIMESTAMP = "<server timestamp>"

let db: FakeDb
let deps: RunPackageDeps
let server: http.Server
let port: number

beforeEach(async () => {
  db = new FakeDb()
  deps = {
    db,
    keys: () => parsePortalKeys(keysJson),
    timestamp: () => TIMESTAMP,
    ensureVm: jest.fn().mockResolvedValue("running"),
    log: { error: jest.fn() },
    config: { queueCap: 20 },
    unconfigured: []
  }
  // Firebase parses the body before the app sees the request
  server = express().use(express.json() as express.RequestHandler).use(researcherDashboardApp(() => deps)).listen(0)
  await new Promise(resolve => server.once("listening", resolve))
  port = (server.address() as AddressInfo).port
})

afterEach(() => new Promise(resolve => server.close(resolve)))

const post = (body: object, bearer: string | null = assertion("report-service-functions"), path = "/run-package") =>
  new Promise<{ status: number; body: any }>((resolve, reject) => {
    const payload = JSON.stringify(body)
    const req = http.request({
      port, path, method: "POST",
      headers: { "Content-Type": "application/json", ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) }
    }, res => {
      let data = ""
      res.on("data", chunk => { data += chunk })
      res.on("end", () => resolve({ status: res.statusCode as number, body: JSON.parse(data) }))
    })
    req.on("error", reject)
    req.end(payload)
  })

const pkg = (name: string, overrides: Record<string, unknown> = {}) =>
  ({ identity: `projects/20/${name}`, version: "1.0.0", checksum: CHECKSUM, catalog_id: 7, ...overrides })

const requestBody = (overrides: Record<string, unknown> = {}, classHash = CLASS_A) => ({
  packages: [pkg("class-counts"), pkg("answers-summary", { catalog_id: 8 })],
  scope: {
    kind: "class",
    collection: "classes",
    id: classHash,
    classes: [{ class_hash: classHash, class_id: 111 }],
    assignments: [{ offering_id: 5, runnable_id: 9, name: "Activity 1", url: "https://activity-player.concord.org/?activity=1" }]
  },
  class_tokens: { "report-service": `class-token-${classHash.slice(0, 1)}` },
  session_token: "session-token",
  firebase_project: "report-service-dev",
  report_server_assertion: assertion("report-server"),
  ...overrides
})

const workDoc = () => db.docs.get(`researcher_dashboard/${PORTAL}/work/42`) as any
const runnerDoc = () => db.docs.get(`researcher_dashboard/${PORTAL}/runners/42`) as any
const resultDoc = (classHash: string, key: string) =>
  db.docs.get(`researcher_dashboard/${PORTAL}/classes/${classHash}/researchers/42/results/${key}`) as any

describe("POST /run-package queueing", () => {
  it("queues the batch, writes a queued result per package and mirrors the queue, in one transaction", async () => {
    const res = await post(requestBody())

    expect(res.status).toBe(202)
    expect(res.body).toMatchObject({
      queue: [
        { class_hash: CLASS_A, package_key: "projects__20__class-counts" },
        { class_hash: CLASS_A, package_key: "projects__20__answers-summary" }
      ],
      appended: ["projects__20__class-counts", "projects__20__answers-summary"],
      vm: "running"
    })
    expect(db.commits).toBe(1)

    expect(workDoc().packages).toEqual([
      { ...pkg("class-counts"), class_hash: CLASS_A },
      { ...pkg("answers-summary", { catalog_id: 8 }), class_hash: CLASS_A }
    ])
    expect(workDoc().scopes[CLASS_A]).toEqual({ scope: requestBody().scope, class_tokens: { "report-service": "class-token-a" } })
    expect(workDoc()).toMatchObject({ session_token: "session-token", firebase_project: "report-service-dev", updated_at: TIMESTAMP })

    expect(resultDoc(CLASS_A, "projects__20__class-counts")).toEqual({
      status: "queued",
      queued_at: TIMESTAMP,
      updated_at: TIMESTAMP,
      platform_id: STAGING_ISS,
      package: { identity: "projects/20/class-counts", version: "1.0.0", checksum: CHECKSUM }
    })
    expect(runnerDoc()).toEqual({ queue: res.body.queue, platform_id: STAGING_ISS, updated_at: TIMESTAMP })
  })

  it("appends only the packages not already queued for the class", async () => {
    await post(requestBody({ packages: [pkg("class-counts")] }))

    const res = await post(requestBody())

    expect(res.status).toBe(202)
    expect(res.body.appended).toEqual(["projects__20__answers-summary"])
    expect(workDoc().packages.map((p: any) => p.identity)).toEqual(["projects/20/class-counts", "projects/20/answers-summary"])
  })

  it("queues the same package for a second class as its own entry, leaving the first class's scope and tokens alone", async () => {
    await post(requestBody({ packages: [pkg("class-counts")] }))

    const res = await post(requestBody({ packages: [pkg("class-counts")] }, CLASS_B), undefined)

    expect(res.status).toBe(202)
    expect(res.body.queue).toEqual([
      { class_hash: CLASS_A, package_key: "projects__20__class-counts" },
      { class_hash: CLASS_B, package_key: "projects__20__class-counts" }
    ])
    expect(workDoc().scopes[CLASS_A].class_tokens).toEqual({ "report-service": "class-token-a" })
    expect(workDoc().scopes[CLASS_A].scope.id).toBe(CLASS_A)
    expect(workDoc().scopes[CLASS_B].class_tokens).toEqual({ "report-service": "class-token-b" })
    expect(resultDoc(CLASS_B, "projects__20__class-counts").status).toBe("queued")
  })

  it("replaces a class's scope and tokens on a later request rather than merging stale tokens into them", async () => {
    await post(requestBody({ packages: [pkg("class-counts")], class_tokens: { "report-service": "t1", "other-app": "t2" } }))

    await post(requestBody({ packages: [pkg("answers-summary")], class_tokens: { "report-service": "t3" } }))

    expect(workDoc().scopes[CLASS_A].class_tokens).toEqual({ "report-service": "t3" })
    expect(workDoc().packages).toHaveLength(2)
  })

  it("accepts an assignment with an empty url and a null name", async () => {
    const body = requestBody()
    body.scope.assignments = [{ offering_id: 5, runnable_id: 9, name: null as any, url: "" }]

    expect((await post(body)).status).toBe(202)
  })

  it("refuses a request over the queue cap with 409 and writes nothing", async () => {
    deps.config.queueCap = 1

    const res = await post(requestBody())

    expect(res.status).toBe(409)
    expect(res.body.error).toBe("queue at its cap (1 outstanding)")
    expect(db.docs.size).toBe(0)
  })

  it("files the work under the assertion's researcher, ignoring researcher fields in the body", async () => {
    const res = await post(requestBody({ platform_user_id: 999, platform_id: "https://learn.concord.org/", portal: "learn_concord_org" }))

    expect(res.status).toBe(202)
    expect(workDoc()).toBeDefined()
    expect(Array.from(db.docs.keys()).every(path => path.startsWith(`researcher_dashboard/${PORTAL}/`))).toBe(true)
    expect(Array.from(db.docs.keys()).some(path => path.includes("/999"))).toBe(false)
  })

  it("hands the researcher and the body to the VM step and answers with its outcome", async () => {
    const ensureVm = jest.fn().mockResolvedValue("launched")
    deps.ensureVm = ensureVm

    const res = await post(requestBody())

    expect(res.body.vm).toBe("launched")
    expect(ensureVm).toHaveBeenCalledWith(
      { uid: 42, platformUserId: "42", platformId: STAGING_ISS, portal: PORTAL },
      expect.objectContaining({ session_token: "session-token" })
    )
  })

  it("answers a VM step failure with its status and reason, keeping the queued work", async () => {
    deps.ensureVm = jest.fn().mockRejectedValue(new VmStepError(502, "RunMicrovm failed: throttled"))

    const res = await post(requestBody())

    expect(res.status).toBe(502)
    expect(res.body.error).toBe("RunMicrovm failed: throttled")
    expect(workDoc().packages).toHaveLength(2)
    expect(resultDoc(CLASS_A, "projects__20__class-counts").status).toBe("queued")
  })

  it("answers 500 without leaking the error when the write fails", async () => {
    db.runTransaction = () => Promise.reject(new Error("firestore unavailable"))

    const res = await post(requestBody())

    expect(res.status).toBe(500)
    expect(res.body.error).toBe("run-package failed")
    expect(deps.log.error).toHaveBeenCalled()
  })
})

describe("POST /run-package validation", () => {
  const withScope = (scope: Record<string, unknown>) => {
    const body = requestBody()
    return { ...body, scope: { ...body.scope, ...scope } }
  }

  const malformed: [string, object, RegExp][] = [
    ["no packages", requestBody({ packages: [] }), /packages must be a non-empty array/],
    ["a bad identity", requestBody({ packages: [pkg("x", { identity: "projects/20/Bad_Name" })] }), /identity/],
    ["a bare-hex checksum", requestBody({ packages: [pkg("x", { checksum: "0".repeat(64) })] }), /checksum/],
    ["an uppercase checksum", requestBody({ packages: [pkg("x", { checksum: `sha256:${"A".repeat(64)}` })] }), /checksum/],
    ["a missing version", requestBody({ packages: [pkg("x", { version: "" })] }), /version/],
    ["a string catalog_id", requestBody({ packages: [pkg("x", { catalog_id: "7" })] }), /catalog_id/],
    ["a package listed twice", requestBody({ packages: [pkg("x"), pkg("x")] }), /listed twice/],
    ["no scope", requestBody({ scope: undefined }), /scope is required/],
    ["another scope kind", withScope({ kind: "cohort" }), /scope must be/],
    ["two classes", withScope({ classes: [{ class_hash: CLASS_A, class_id: 1 }, { class_hash: CLASS_B, class_id: 2 }] }), /exactly one class/],
    ["a class_hash with a slash", withScope({ id: "a/b", classes: [{ class_hash: "a/b", class_id: 1 }] }), /class_hash/],
    ["a scope id that is not the class hash", withScope({ id: CLASS_B }), /scope.id/],
    ["an assignment without ids", withScope({ assignments: [{ name: "x", url: "" }] }), /offering_id/],
    ["an assignment with a numeric url", withScope({ assignments: [{ offering_id: 1, runnable_id: 1, name: "x", url: 5 }] }), /url/],
    ["no class tokens", requestBody({ class_tokens: {} }), /class_tokens/],
    ["no session token", requestBody({ session_token: "" }), /session_token/],
    ["no firebase project", requestBody({ firebase_project: undefined }), /firebase_project/],
    ["no report-server assertion", requestBody({ report_server_assertion: undefined }), /report_server_assertion/]
  ]

  it.each(malformed)("refuses %s with 400 naming the field and writes nothing", async (_label, body, message) => {
    const res = await post(body)

    expect(res.status).toBe(400)
    expect(res.body.error).toMatch(message)
    expect(db.docs.size).toBe(0)
  })

  it("refuses a report-server assertion for another researcher", async () => {
    const res = await post(requestBody({ report_server_assertion: assertion("report-server", { uid: 43 }) }))

    expect(res.status).toBe(400)
    expect(res.body.error).toMatch(/another researcher/)
    expect(db.docs.size).toBe(0)
  })

  it("refuses a report-server assertion from another portal", async () => {
    const res = await post(requestBody({ report_server_assertion: assertion("report-server", {}, production) }))

    expect(res.status).toBe(400)
    expect(res.body.error).toMatch(/another researcher/)
    expect(db.docs.size).toBe(0)
  })

  it("refuses a report-server assertion of another audience", async () => {
    const res = await post(requestBody({ report_server_assertion: assertion("report-service-functions") }))

    expect(res.status).toBe(400)
    expect(db.docs.size).toBe(0)
  })
})

describe("POST /run-package authentication", () => {
  it("refuses an assertion of another audience", async () => {
    expect((await post(requestBody(), assertion("report-server"))).status).toBe(401)
    expect(db.docs.size).toBe(0)
  })

  it("refuses the shared AUTH_BEARER_TOKEN", async () => {
    expect((await post(requestBody(), "the-shared-bearer-token")).status).toBe(401)
  })

  it("refuses a request with no bearer", async () => {
    expect((await post(requestBody(), null)).status).toBe(401)
  })

  it("refuses a bearer in the body even beside a valid header", async () => {
    expect((await post({ ...requestBody(), bearer: "the-shared-bearer-token" })).status).toBe(401)
    expect(db.docs.size).toBe(0)
  })

  it("answers 503 naming the unset launch settings and writes nothing", async () => {
    deps.unconfigured = ["RD_MICROVM_IMAGE_ARN", "RD_DATA_BUCKET"]

    const res = await post(requestBody())

    expect(res.status).toBe(503)
    expect(res.body.error).toBe("researcherDashboard is not configured: RD_MICROVM_IMAGE_ARN, RD_DATA_BUCKET unset")
    expect(db.docs.size).toBe(0)
    expect(deps.ensureVm).not.toHaveBeenCalled()
  })

  it("answers 500 naming the setting when PORTAL_PUBLIC_KEYS is misconfigured", async () => {
    deps.keys = () => parsePortalKeys("{not json")

    const res = await post(requestBody())

    expect(res.status).toBe(500)
    expect(res.body.error).toMatch(/PORTAL_PUBLIC_KEYS/)
  })
})
