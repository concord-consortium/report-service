import * as admin from "firebase-admin"
import { CloudTasksClient } from "@google-cloud/tasks"
import { classPath } from "./firestore-paths"
import { deriveProfile, Derived, ProfileDeps } from "./derive-profile"
import { DeriveTask } from "./derive-profile-route"
import { Db } from "./run-package"

export interface DerivationDeps extends ProfileDeps {
  db: Db
  timestamp(): unknown
  fromMillis(ms: number): { toMillis(): number }
}

const isTimestamp = (v: unknown): v is { toMillis(): number } =>
  typeof v === "object" && v !== null && typeof (v as { toMillis?: unknown }).toMillis === "function"

/**
 * Writes the class's profile whole, unless a later request's derivation is already stored, so
 * a slow derivation of older inputs never overwrites a newer one.
 */
export async function writeProfile(deps: DerivationDeps, task: DeriveTask, derived: Derived) {
  const ref = deps.db.doc(classPath(task.portal, task.class_hash))
  await deps.db.runTransaction(async tx => {
    const current = (await tx.get(ref)).data() as { requested_at?: unknown } | undefined
    if (isTimestamp(current?.requested_at) && current!.requested_at.toMillis() > task.requested_at) return
    tx.set(ref, {
      platform_id: task.platform_id,
      assignment_urls: task.assignment_urls,
      interactive_urls: derived.interactive_urls,
      content_urls: derived.content_urls,
      unread: derived.unread,
      truncated: derived.truncated,
      assignment_fingerprint: task.assignment_fingerprint,
      requested_at: deps.fromMillis(task.requested_at),
      derived_at: deps.timestamp()
    })
  })
}

export async function runDerivation(deps: DerivationDeps, task: DeriveTask) {
  await writeProfile(deps, task, await deriveProfile(deps, task.assignment_urls))
}

export function defaultDerivationDeps(allowedHosts: Set<string>): DerivationDeps {
  return {
    db: admin.firestore() as unknown as Db,
    timestamp: () => admin.firestore.FieldValue.serverTimestamp(),
    fromMillis: ms => admin.firestore.Timestamp.fromMillis(ms),
    fetchImpl: (url, init) => fetch(url, init),
    allowedHosts
  }
}

const WORKER = "deriveProfileWorker"
const LOCATION = "us-central1"
let tasksClient: CloudTasksClient | null = null

/**
 * Queues a derivation for `deriveProfileWorker`, whose task queue Firebase creates on its first
 * deploy. The emulator cannot reach Cloud Tasks, so there the derivation runs directly.
 */
export async function enqueueDerivation(task: DeriveTask, deps: () => DerivationDeps, log: { error(message: string, data: object): void }) {
  if (process.env.FUNCTIONS_EMULATOR === "true") {
    runDerivation(deps(), task).catch(e => log.error("derive-profile: emulator derivation failed", { error: String(e) }))
    return
  }
  const project = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT
  if (!project) throw new Error("the GCP project is unknown")
  const url = `https://${LOCATION}-${project}.cloudfunctions.net/${WORKER}`
  tasksClient ??= new CloudTasksClient()
  await tasksClient.createTask({
    parent: `projects/${project}/locations/${LOCATION}/queues/${WORKER}`,
    task: {
      httpRequest: {
        httpMethod: "POST",
        url,
        headers: { "Content-Type": "application/json" },
        body: Buffer.from(JSON.stringify({ data: task })).toString("base64"),
        oidcToken: { serviceAccountEmail: `${project}@appspot.gserviceaccount.com`, audience: url }
      }
    }
  })
}
