import admin from "firebase-admin"
import { db } from "../test/emulator-setup"
import { MAXIMUM_DURATION_SECONDS } from "./ensure-vm"
import { Db } from "./run-package"
import { makeWork, VmRouteDeps } from "./vm-routes"
import { Runner } from "./vm-auth"

// The mint gate compares a stored launched_at, which the Admin SDK reads back as a Timestamp, so
// this runs against the emulator rather than the fake, whose reads hand back what was written.
const PORTAL = "learn_portal_staging_concord_org"
const ROOT = `researcher_dashboard/${PORTAL}`
const CLASS_A = "a".repeat(48)
const runner: Runner = {
  uid: 42, platformUserId: "42", platformId: "https://learn.portal.staging.concord.org/", portal: PORTAL, firebaseUid: "firebase-uid-42",
  signedInAt: Date.now()
}

function mockRes() {
  const res: any = { locals: { runner } }
  res.error = jest.fn((status: number, message: string) => { res._status = status; res._body = { error: message }; return res })
  res.status = jest.fn((status: number) => { res._status = status; return res })
  res.json = jest.fn((body: object) => { res._body = body; return res })
  return res
}

const deps = (): VmRouteDeps => ({
  db: db as unknown as Db,
  verifyIdToken: async () => { throw new Error("not used") },
  microvms: { suspend: async () => undefined },
  broker: { assume: async () => { throw new Error("not used") } },
  mint: async (uid, claims) => `minted:${uid}:${claims.class_hash ?? "session"}`,
  ownProject: "report-service-dev",
  now: Date.now,
  log: { error: jest.fn() },
  config: { bucket: "b", brokerRoleArn: "r", audience: "a", unconfigured: [] }
})

async function seed(launchedAt: admin.firestore.Timestamp | admin.firestore.FieldValue) {
  await db.doc(`${ROOT}/vms/42`).set({ microvm_id: "vm-1", launched_at: launchedAt })
  await db.doc(`${ROOT}/work/42`).set({
    packages: [{ identity: "users/1/a", version: "1.0.0", checksum: `sha256:${"0".repeat(64)}`, catalog_id: 7, class_hash: CLASS_A }],
    scopes: { [CLASS_A]: { scope: {}, class_tokens: { "report-service-dev": "rigse-class" } } },
    session_token: "rigse-session",
    firebase_project: "report-service-dev"
  })
  await db.doc(`${ROOT}/classes/${CLASS_A}/researchers/42/results/users__1__a`).set({ status: "queued" })
}

beforeEach(async () => {
  await db.recursiveDelete(db.collection("researcher_dashboard"))
})

describe("POST /work against stored Timestamps", () => {
  it("mints fresh tokens for a VM launched within its life", async () => {
    await seed(admin.firestore.FieldValue.serverTimestamp())
    const res = mockRes()

    await makeWork(deps())({ body: { microvm_id: "vm-1" } } as any, res)

    expect(res._status).toBe(200)
    expect(res._body.session_token).toBe("minted:firebase-uid-42:session")
    expect(res._body.scopes[CLASS_A].class_tokens["report-service-dev"]).toBe(`minted:firebase-uid-42:${CLASS_A}`)
  })

  it("passes rigse's tokens through for a VM past its life", async () => {
    await seed(admin.firestore.Timestamp.fromMillis(Date.now() - (MAXIMUM_DURATION_SECONDS + 60) * 1000))
    const res = mockRes()

    await makeWork(deps())({ body: { microvm_id: "vm-1" } } as any, res)

    expect(res._status).toBe(200)
    expect(res._body.session_token).toBe("rigse-session")
    expect(res._body.scopes[CLASS_A].class_tokens["report-service-dev"]).toBe("rigse-class")
  })
})
