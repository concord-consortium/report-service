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
import { DeriveProfileRouteDeps, DeriveTask, parseAllowedHosts } from "./derive-profile-route"
import { FakeDb } from "../test/researcher-dashboard-fake-db"

const ISS = "https://learn.portal.staging.concord.org/"
const CLASS = "c".repeat(48)
const NOW = 1_790_000_000_000

const key = { kid: "staging-test", iss: ISS, ...generateKeyPairSync("rsa", { modulusLength: 2048 }) }
const keysJson = JSON.stringify([{ kid: key.kid, iss: ISS, pem: key.publicKey.export({ type: "spki", format: "pem" }).toString() }])
const seconds = () => Math.floor(Date.now() / 1000)
const assertion = (aud = "report-service-functions") =>
  jwt.sign({ iss: ISS, aud, uid: 42, iat: seconds(), exp: seconds() + 120 }, key.privateKey, { algorithm: "RS256", keyid: key.kid })

let queued: DeriveTask[]
let deriveDeps: DeriveProfileRouteDeps
let server: http.Server
let port: number

beforeEach(async () => {
  queued = []
  deriveDeps = {
    enqueue: jest.fn(async (task: DeriveTask) => { queued.push(task) }),
    allowedHosts: () => parseAllowedHosts("authoring.concord.org"),
    now: () => NOW
  }
  const runDeps: RunPackageDeps = {
    db: new FakeDb(),
    keys: () => parsePortalKeys(keysJson),
    timestamp: () => "<ts>",
    ensureVm: jest.fn(),
    log: { error: jest.fn() },
    config: { queueCap: 20 },
    unconfigured: []
  }
  // Firebase parses the body, with a larger limit than express's 100 KB default, before the app sees it
  server = express()
    .use(express.json({ limit: "10mb" }) as express.RequestHandler)
    .use(researcherDashboardApp(() => runDeps, () => deriveDeps))
    .listen(0)
  await new Promise(resolve => server.once("listening", resolve))
  port = (server.address() as AddressInfo).port
})

afterEach(() => new Promise(resolve => server.close(resolve)))

const post = (payload: unknown, bearer: string | null = assertion()) =>
  new Promise<{ status: number; body: any }>((resolve, reject) => {
    const req = http.request({
      port, path: "/derive-profile", method: "POST",
      headers: { "Content-Type": "application/json", ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) }
    }, res => {
      let data = ""
      res.on("data", chunk => { data += chunk })
      res.on("end", () => resolve({ status: res.statusCode as number, body: JSON.parse(data) }))
    })
    req.on("error", reject)
    req.end(JSON.stringify(payload))
  })

const body = (overrides: Record<string, unknown> = {}) => ({
  class_hash: CLASS,
  assignment_fingerprint: "v1:abc",
  assignment_urls: ["https://activity-player.concord.org/index.html?activity=https://authoring.concord.org/api/v1/activities/1.json"],
  ...overrides
})

describe("POST /derive-profile", () => {
  it("queues exactly the task, with the portal and platform_id from the assertion", async () => {
    const res = await post(body({ portal: "someone_else", platform_id: "https://evil.example/" }))
    expect(res).toEqual({ status: 202, body: { success: true, queued: true } })
    expect(queued).toEqual([{
      portal: "learn_portal_staging_concord_org",
      platform_id: ISS,
      class_hash: CLASS,
      assignment_fingerprint: "v1:abc",
      assignment_urls: body().assignment_urls,
      requested_at: NOW
    }])
  })

  it("accepts an empty assignment list, which derives an empty profile", async () => {
    expect((await post(body({ assignment_urls: [] }))).status).toBe(202)
  })

  it.each<[string, Record<string, unknown>]>([
    ["class_hash", { class_hash: "C".repeat(48) }],
    ["class_hash", { class_hash: "c".repeat(47) }],
    ["class_hash", { class_hash: "../x" }],
    ["assignment_fingerprint", { assignment_fingerprint: "" }],
    ["assignment_fingerprint", { assignment_fingerprint: "f".repeat(257) }],
    ["assignment_urls", { assignment_urls: "https://x.org/" }],
    ["assignment_urls", { assignment_urls: Array(501).fill("https://x.org/") }],
    ["assignment URL", { assignment_urls: ["x".repeat(2049)] }],
    ["assignment URL", { assignment_urls: [5] }]
  ])("refuses a malformed %s with 400 and queues nothing", async (field, overrides) => {
    const res = await post(body(overrides))
    expect(res.status).toBe(400)
    expect(res.body.error).toContain(field)
    expect(queued).toEqual([])
  })

  it("refuses a body over 256 KiB with 400", async () => {
    const res = await post(body({ assignment_urls: Array(200).fill("u".repeat(2000)) }))
    expect(res).toEqual({ status: 400, body: expect.objectContaining({ error: "the body exceeds 256 KiB" }) })
    expect(queued).toEqual([])
  })

  it("refuses an assertion for another audience, or none", async () => {
    expect((await post(body(), assertion("report-server"))).status).toBe(401)
    expect((await post(body(), null)).status).toBe(401)
    expect(queued).toEqual([])
  })

  it("answers 502 when the task cannot be queued", async () => {
    deriveDeps.enqueue = jest.fn().mockRejectedValue(new Error("queue missing"))
    const res = await post(body())
    expect(res.status).toBe(502)
    expect(res.body.error).toContain("queue missing")
  })

  it("answers 503 naming RD_AUTHORING_HOSTS while it is empty, before validating", async () => {
    deriveDeps.allowedHosts = () => parseAllowedHosts(" , ")
    const res = await post({ nonsense: true })
    expect(res).toEqual({ status: 503, body: expect.objectContaining({ error: "researcherDashboard is not configured: RD_AUTHORING_HOSTS unset" }) })
    expect(queued).toEqual([])
  })
})

describe("parseAllowedHosts", () => {
  it("splits on commas, trims and lowercases", () => {
    expect(Array.from(parseAllowedHosts(" Authoring.Concord.org, authoring.lara.staging.concord.org ,"))).toEqual([
      "authoring.concord.org", "authoring.lara.staging.concord.org"
    ])
  })
})
