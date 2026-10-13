import { packageKey, resultPath, workPath } from "./firestore-paths"
import { Db, DocRef, QueueEntry, Researcher, Transaction, WorkDoc, WorkEntry } from "./run-package"

// What a package's result says about its queue entry. A missing result counts as queued: the
// function writes one `queued` for every entry it appends.
export type Standing = "queued" | "running" | "finished"

export interface ResultDoc { status?: unknown; microvm_id?: unknown; previous?: unknown; [field: string]: unknown }
export interface StoodEntry { entry: WorkEntry; standing: Standing; result?: ResultDoc }

export interface QueueRead {
  ref: DocRef
  work?: WorkDoc
  entries: StoodEntry[]
}

const standing = (status: unknown): Standing =>
  status === "running" ? "running" : status === "done" || status === "failed" ? "finished" : "queued"

/** Reads the researcher's queue and each entry's result, inside the caller's transaction. */
export async function readQueue(db: Db, tx: Transaction, who: Researcher): Promise<QueueRead> {
  const ref = db.doc(workPath(who.portal, who.platformUserId))
  const work = (await tx.get(ref)).data() as WorkDoc | undefined
  const entries: StoodEntry[] = []
  for (const entry of work?.packages ?? []) {
    const path = resultPath(who.portal, entry.class_hash, who.platformUserId, packageKey(entry.identity))
    const result = (await tx.get(db.doc(path))).data() as ResultDoc | undefined
    entries.push({ entry, standing: standing(result?.status), result })
  }
  return { ref, work, entries }
}

export const withStanding = (q: QueueRead, ...wanted: Standing[]) =>
  q.entries.filter(e => wanted.includes(e.standing)).map(e => e.entry)

/** Queued or running: still the VM's to do. A finished entry leaves the queue. */
export const outstanding = (q: QueueRead) => withStanding(q, "queued", "running")

export const mirror = (entries: WorkEntry[]): QueueEntry[] =>
  entries.map(e => ({ class_hash: e.class_hash, package_key: packageKey(e.identity) }))

/** The scopes of the classes `packages` still names; a class's scope leaves with its last package. */
export function keptScopes(work: WorkDoc | undefined, packages: WorkEntry[]) {
  const classes = new Set(packages.map(p => p.class_hash))
  return Object.fromEntries(Object.entries(work?.scopes ?? {}).filter(([hash]) => classes.has(hash)))
}

/** Drops finished entries, and the scopes nothing outstanding names, when there are any. */
export function prune(tx: Transaction, q: QueueRead) {
  if (!q.entries.some(e => e.standing === "finished")) {
    return
  }
  const packages = outstanding(q)
  tx.set(q.ref, { packages, scopes: keptScopes(q.work, packages) }, { mergeFields: ["packages", "scopes"] })
}

// The fields of a finished run that a re-queued result keeps as `previous`
const PREVIOUS_FIELDS = ["package", "image_version", "summary", "display", "started_at", "finished_at"]

/**
 * The last finished run a re-queued result keeps, so a reader can show it, and compare against
 * its `started_at`, while the re-run waits: a `done` result's own fields, each only when present,
 * or else whatever `previous` the result already carries. Undefined when there is none.
 */
export function previousOf(current: ResultDoc | undefined): Record<string, unknown> | undefined {
  if (current?.status !== "done") {
    return current?.previous as Record<string, unknown> | undefined
  }
  return Object.fromEntries(PREVIOUS_FIELDS.filter(field => current[field] !== undefined).map(field => [field, current[field]]))
}

/** A Firestore Timestamp, or epoch milliseconds, as milliseconds; NaN for anything else. */
export const toMillis = (value: unknown): number => {
  if (typeof value === "number") {
    return value
  }
  const ts = value as { toMillis?: () => number } | null | undefined
  return typeof ts?.toMillis === "function" ? ts.toMillis() : NaN
}
