import * as admin from "firebase-admin"
import { parseResultPath, parseVmPath } from "./firestore-paths"
import { toMillis } from "./queue"
import { RecentVm, StaleResult, WatchdogQueries } from "./watchdog"

/**
 * The watchdog's collection-group queries. Each needs its index in firestore.indexes.json, and
 * anything outside researcher_dashboard/ that shares a collection name is dropped.
 */
export function makeWatchdogQueries(db: admin.firestore.Firestore): WatchdogQueries {
  const at = (ms: number) => admin.firestore.Timestamp.fromMillis(ms)
  const resultsUpdatedBefore = async (status: string, ms: number) => {
    const snap = await db.collectionGroup("results").where("status", "==", status).where("updated_at", "<", at(ms)).get()
    return snap.docs.flatMap(doc => {
      const where = parseResultPath(doc.ref.path)
      if (!where) {
        return []
      }
      const data = doc.data()
      const stale: StaleResult = {
        ...where,
        updatedAt: toMillis(data.updated_at),
        expectedSeconds: data.expected_duration_seconds,
        heartbeatSeconds: data.heartbeat_seconds,
        microvmId: data.microvm_id
      }
      return [stale]
    })
  }
  return {
    runningUpdatedBefore: ms => resultsUpdatedBefore("running", ms),
    queuedUpdatedBefore: ms => resultsUpdatedBefore("queued", ms),
    async vmsLaunchedAfter(ms) {
      const snap = await db.collectionGroup("vms").where("launched_at", ">", at(ms)).get()
      return snap.docs.flatMap(doc => {
        const where = parseVmPath(doc.ref.path)
        const data = doc.data()
        if (!where || typeof data.microvm_id !== "string") {
          return []
        }
        const vm: RecentVm = {
          ...where,
          microvmId: data.microvm_id,
          imageVersion: typeof data.image_version === "string" ? data.image_version : undefined,
          launchedAt: toMillis(data.launched_at)
        }
        return [vm]
      })
    }
  }
}
