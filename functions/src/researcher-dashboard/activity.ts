import admin from "firebase-admin"
import { activityUserPath, CLASS_HASH, portalSegment } from "./firestore-paths"
import { PLATFORM_USER_ID } from "./storage-policy"

type AnswerFields = Record<string, unknown>

export type Skip =
  | "deleted" | "no_class" | "moved" | "unchanged"
  | "bad_platform_id" | "bad_class_hash" | "bad_user_id" | "bad_resource_link_id"

export interface ActivityTarget { path: string; resourceLinkId: string }

const present = (v: unknown) => (typeof v === "string" && v !== "") || typeof v === "number"
// The Activity Player sets these afresh on every save, so they differ even when nothing else does
const PER_SAVE = ["created", "interactive_state_history_id"]
const content = (answer: AnswerFields) =>
  JSON.stringify(Object.fromEntries(Object.entries(answer).filter(([k]) => !PER_SAVE.includes(k))))
const sameContent = (before: AnswerFields, after: AnswerFields) => content(before) === content(after)
// A portal offering id; it becomes a key of the `changed` map, which no rule pins
const OFFERING_ID = /^[1-9][0-9]*$/

// Which learner's activity document an answer write updates, or why it updates none.
export function activityTarget(before: AnswerFields | undefined, after: AnswerFields | undefined):
  ActivityTarget | { skip: Skip } {
  if (!after) {
    return { skip: "deleted" }
  }
  const { platform_id, platform_user_id, context_id, resource_link_id } = after
  if (![platform_id, platform_user_id, context_id, resource_link_id].every(present)) {
    return { skip: "no_class" }
  }
  if (before && (before.context_id !== context_id || String(before.platform_user_id) !== String(platform_user_id))) {
    return { skip: "moved" }
  }
  if (before && sameContent(before, after)) {
    return { skip: "unchanged" }
  }
  let portal = ""
  try {
    portal = portalSegment(String(platform_id))
  } catch {
    // an unparseable URL leaves portal empty, as a hostless one ("foo:bar") does
  }
  if (portal === "") {
    return { skip: "bad_platform_id" }
  }
  if (!CLASS_HASH.test(String(context_id))) {
    return { skip: "bad_class_hash" }
  }
  if (!PLATFORM_USER_ID.test(String(platform_user_id))) {
    return { skip: "bad_user_id" }
  }
  if (!OFFERING_ID.test(String(resource_link_id))) {
    return { skip: "bad_resource_link_id" }
  }
  return {
    path: activityUserPath(portal, String(context_id), String(platform_user_id)),
    resourceLinkId: String(resource_link_id)
  }
}

// One write, no read: the three fields of the activity document contract.
export function recordActivity(db: admin.firestore.Firestore, target: ActivityTarget) {
  const now = admin.firestore.FieldValue.serverTimestamp()
  return db.doc(target.path).set({
    lastActivityAt: now,
    writeCount: admin.firestore.FieldValue.increment(1),
    changed: { [target.resourceLinkId]: now }
  }, { merge: true })
}

// Records an answer write's activity, or answers why it records none.
export async function handleAnswerWrite(
  db: admin.firestore.Firestore, before: AnswerFields | undefined, after: AnswerFields | undefined
): Promise<Skip | null> {
  const target = activityTarget(before, after)
  if ("skip" in target) {
    return target.skip
  }
  await recordActivity(db, target)
  return null
}
