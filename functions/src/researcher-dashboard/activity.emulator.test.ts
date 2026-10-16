import admin from "firebase-admin"
import { db } from "../test/emulator-setup"
import { handleAnswerWrite, recordActivity } from "./activity"
import { activityUserPath } from "./firestore-paths"

const PORTAL = "learn_portal_staging_concord_org"
const users = (classHash: string) => db.collection(`researcher_dashboard/${PORTAL}/activity/${classHash}/users`)

const answer = (classHash: string, fields: Record<string, unknown> = {}): Record<string, unknown> => ({
  id: "answer-1",
  question_id: "managed_interactive_1",
  type: "interactive_state",
  source_key: "activity-player.concord.org",
  tool_id: "activity-player",
  context_id: classHash,
  run_key: "",
  platform_id: "https://learn.portal.staging.concord.org",
  platform_user_id: "1234",
  resource_link_id: "701",
  created: "Thu, 15 Oct 2026 12:00:00 GMT",
  interactive_state_history_id: "history-1",
  report_state: JSON.stringify({ interactiveState: JSON.stringify({ foo: "bar" }) }),
  ...fields
})

const read = async (path: string) => (await db.doc(path).get()).data() as {
  lastActivityAt: admin.firestore.Timestamp
  writeCount: number
  changed: Record<string, admin.firestore.Timestamp>
}

it("creates the document on the first write and adds a key for another assignment", async () => {
  const path = activityUserPath(PORTAL, "1".repeat(48), "1234")

  await recordActivity(db, { path, resourceLinkId: "701" })
  const first = await read(path)
  expect(Object.keys(first).sort()).toEqual(["changed", "lastActivityAt", "writeCount"])
  expect(first.writeCount).toBe(1)
  expect(first.lastActivityAt).toBeInstanceOf(admin.firestore.Timestamp)
  expect(Object.keys(first.changed)).toEqual(["701"])

  await recordActivity(db, { path, resourceLinkId: "702" })
  const second = await read(path)
  expect(second.writeCount).toBe(2)
  expect(Object.keys(second.changed).sort()).toEqual(["701", "702"])
  expect(second.changed["701"].isEqual(first.changed["701"])).toBe(true)
  expect(second.lastActivityAt.valueOf() > first.lastActivityAt.valueOf()).toBe(true)
})

it("writes nothing for the writes it skips", async () => {
  const classHash = "2".repeat(48)
  const created = answer(classHash)
  expect(await handleAnswerWrite(db, undefined, created)).toBeNull()

  const changedFields = { report_state: JSON.stringify({ interactiveState: JSON.stringify({ foo: "baz" }) }) }
  const skipped: [Record<string, unknown> | undefined, Record<string, unknown> | undefined, string][] = [
    [created, undefined, "deleted"],
    [undefined, answer(classHash, { platform_user_id: "5678", platform_id: undefined, run_key: "run-key-1" }), "no_class"],
    [answer(classHash, { platform_user_id: "5678", context_id: "3".repeat(48) }), answer(classHash, { platform_user_id: "5678", ...changedFields }), "moved"],
    [answer(classHash, { platform_user_id: "5678" }), answer(classHash, { platform_user_id: "5678", created: "Thu, 15 Oct 2026 12:05:00 GMT" }), "unchanged"]
  ]
  for (const [before, after, skip] of skipped) {
    expect(await handleAnswerWrite(db, before, after)).toBe(skip)
  }

  const docs = await users(classHash).get()
  expect(docs.docs.map(d => d.id)).toEqual(["1234"])
})

it("keeps a class of 30 learners' concurrent writes apart, with none failing", async () => {
  const classHash = "4".repeat(48)
  const learners = Array.from({ length: 30 }, (_, i) => String(100 + i))
  const writes = learners.flatMap(learner => Array.from({ length: 5 }, (_, n) =>
    recordActivity(db, { path: activityUserPath(PORTAL, classHash, learner), resourceLinkId: String(700 + n) })))

  await Promise.all(writes)

  const docs = await users(classHash).get()
  expect(docs.size).toBe(30)
  const counts = docs.docs.map(d => d.get("writeCount") as number)
  expect(counts.reduce((a, b) => a + b, 0)).toBe(150)
  expect(counts).toEqual(learners.map(() => 5))
})
