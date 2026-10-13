import admin from "firebase-admin"
import { db } from "../test/emulator-setup"
import { Db } from "./run-package"
import { failResult, MACHINE_STOPPED, NOT_CLAIMED, runWatchdog } from "./watchdog"
import { makeWatchdogQueries } from "./watchdog-queries"

const PORTAL = "learn_portal_staging_concord_org"
const ROOT = `researcher_dashboard/${PORTAL}`
const CLASS = "a".repeat(48)
const NOW = Date.parse("2026-09-25T12:00:00Z")
const at = (ms: number) => admin.firestore.Timestamp.fromMillis(ms)
const result = (key: string) => `${ROOT}/classes/${CLASS}/researchers/42/results/${key}`
const deps = { db: db as unknown as Db, timestamp: () => admin.firestore.FieldValue.serverTimestamp() }

beforeEach(async () => {
  await db.recursiveDelete(db.collection("researcher_dashboard"))
  await db.recursiveDelete(db.collection("elsewhere"))
})

it.each(["running", "queued"])("finds %s results updated before a time, and only in the dashboard's tree", async status => {
  const query = status === "running" ? "runningUpdatedBefore" : "queuedUpdatedBefore"
  await db.doc(result("old")).set({ status, updated_at: at(NOW - 3600e3), expected_duration_seconds: 600, heartbeat_seconds: 60, microvm_id: "vm-1" })
  await db.doc(result("fresh")).set({ status, updated_at: at(NOW - 60e3) })
  await db.doc(result("iso")).set({ status, updated_at: new Date(NOW - 3600e3).toISOString() })
  await db.doc(result("done")).set({ status: "done", updated_at: at(NOW - 3600e3) })
  await db.doc("elsewhere/x/results/y").set({ status, updated_at: at(NOW - 3600e3) })

  const stale = await makeWatchdogQueries(db)[query](NOW - 600e3)

  expect(stale).toEqual([{
    portal: PORTAL, classHash: CLASS, platformUserId: "42", packageKey: "old",
    updatedAt: NOW - 3600e3, expectedSeconds: 600, heartbeatSeconds: 60, microvmId: "vm-1"
  }])
})

it("finds the VMs launched after a time, with their image version", async () => {
  await db.doc(`${ROOT}/vms/42`).set({ microvm_id: "vm-42", image_version: "7", launched_at: at(NOW - 3600e3) })
  await db.doc(`${ROOT}/vms/7`).set({ microvm_id: "vm-7", launched_at: at(NOW - 10 * 3600e3) })
  await db.doc(`${ROOT}/vms/8`).set({ microvm_id: "vm-8" })

  const vms = await makeWatchdogQueries(db).vmsLaunchedAfter(NOW - 8.2 * 3600e3)

  expect(vms).toEqual([{ portal: PORTAL, platformUserId: "42", microvmId: "vm-42", imageVersion: "7", launchedAt: NOW - 3600e3 }])
})

it("fails a stalled result as the query returned it, so its updated_at check holds on a Timestamp", async () => {
  await db.doc(result("old")).set({ status: "running", updated_at: at(NOW - 3600e3), microvm_id: "vm-1" })
  const [stale] = await makeWatchdogQueries(db).runningUpdatedBefore(NOW - 600e3)

  expect(await failResult(deps, stale, "running", MACHINE_STOPPED, "vm-1")).toEqual({ failed: true, runnerEnded: false })
  expect((await db.doc(result("old")).get()).data()).toMatchObject({ status: "failed", error: MACHINE_STOPPED })
})

it("restarts a run's lease from a stored resumed_at Timestamp", async () => {
  await db.doc(result("old")).set({ status: "running", updated_at: at(NOW - 3600e3), heartbeat_seconds: 60, microvm_id: "vm-1" })
  await db.doc(`${ROOT}/vms/42`).set({ microvm_id: "vm-1", resumed_at: at(NOW - 60e3) })
  const microvms = {
    get: jest.fn(async () => ({ state: "RUNNING" })),
    suspend: jest.fn(),
    terminate: jest.fn(),
    resume: jest.fn()
  }
  const run = () => runWatchdog({ ...deps, queries: makeWatchdogQueries(db), microvms, now: () => NOW, log: { info: jest.fn() } })

  expect(await run()).toEqual([])
  expect(microvms.terminate).not.toHaveBeenCalled()

  await db.doc(`${ROOT}/vms/42`).set({ microvm_id: "vm-1", resumed_at: at(NOW - 600e3) })
  expect(await run()).toEqual(["watchdog.vm_terminated"])
})

it("fails work no VM took only while the researcher's VM was launched before the cutoff", async () => {
  await db.doc(result("old")).set({ status: "queued", updated_at: at(NOW - 9 * 3600e3) })
  await db.doc(`${ROOT}/vms/42`).set({ microvm_id: "vm-42", launched_at: at(NOW - 3600e3) })
  const [stale] = await makeWatchdogQueries(db).queuedUpdatedBefore(NOW - 8.2 * 3600e3)

  expect(await failResult(deps, stale, "queued", NOT_CLAIMED, undefined, NOW - 8.2 * 3600e3)).toEqual({ failed: false, runnerEnded: false })
  await db.doc(`${ROOT}/vms/42`).set({ microvm_id: "vm-42", launched_at: at(NOW - 9 * 3600e3) })
  expect(await failResult(deps, stale, "queued", NOT_CLAIMED, undefined, NOW - 8.2 * 3600e3)).toEqual({ failed: true, runnerEnded: false })
  expect((await db.doc(result("old")).get()).data()).toMatchObject({ status: "failed", error: NOT_CLAIMED })
})
