import { activityTarget, Skip } from "./activity"

const HASH = "c".repeat(48)
const OTHER_HASH = "d".repeat(48)
const PATH = `researcher_dashboard/learn_concord_org/activity/${HASH}/users/1234`

const answer = (fields: Record<string, unknown> = {}): Record<string, unknown> => ({
  id: "answer-1",
  question_id: "managed_interactive_1",
  type: "interactive_state",
  source_key: "activity-player.concord.org",
  tool_id: "activity-player",
  resource_url: "https://example.com/701",
  context_id: HASH,
  run_key: "",
  remote_endpoint: "https://learn.concord.org/dataservice/external_activity_data/abc",
  platform_id: "https://learn.concord.org",
  platform_user_id: "1234",
  resource_link_id: "701",
  created: "Thu, 15 Oct 2026 12:00:00 GMT",
  interactive_state_history_id: "history-1",
  report_state: JSON.stringify({ interactiveState: JSON.stringify({ foo: "bar" }) }),
  ...fields
})

const without = (fields: Record<string, unknown>, key: string) => {
  const { [key]: _, ...rest } = fields
  return rest
}

describe("activityTarget", () => {
  it("records a create under the answer's portal, class and learner", () => {
    expect(activityTarget(undefined, answer())).toEqual({ path: PATH, resourceLinkId: "701" })
  })

  it("records an update that changes the answer", () => {
    const after = answer({
      report_state: JSON.stringify({ interactiveState: JSON.stringify({ foo: "baz" }) }),
      created: "Thu, 15 Oct 2026 12:05:00 GMT"
    })
    expect(activityTarget(answer(), after)).toEqual({ path: PATH, resourceLinkId: "701" })
  })

  it("records a collaborator's copy, and their later save of it, under the collaborator", () => {
    const copy = answer({
      platform_user_id: "5678",
      collaboration_owner_id: "1234",
      collaborators_data_url: "https://learn.concord.org/api/v1/collaborations/9/collaborators_data"
    })
    const target = { path: `researcher_dashboard/learn_concord_org/activity/${HASH}/users/5678`, resourceLinkId: "701" }
    expect(activityTarget(undefined, copy)).toEqual(target)

    const laterSave = {
      ...copy,
      report_state: JSON.stringify({ interactiveState: JSON.stringify({ foo: "solo" }) }),
      created: "Thu, 15 Oct 2026 12:10:00 GMT"
    }
    expect(activityTarget(copy, laterSave)).toEqual(target)
  })

  it("records numeric identifiers as their strings, and a save whose platform_user_id differs from before only in type as the same learner", () => {
    const numeric = answer({ platform_user_id: 1234, resource_link_id: 701 })
    expect(activityTarget(undefined, numeric)).toEqual({ path: PATH, resourceLinkId: "701" })

    const after = answer({ report_state: JSON.stringify({ interactiveState: JSON.stringify({ foo: "baz" }) }) })
    expect(activityTarget(answer({ platform_user_id: 1234 }), after)).toEqual({ path: PATH, resourceLinkId: "701" })
  })

  it("records the longest identifiers it accepts", () => {
    const longest = answer({ platform_id: `https://${"a".repeat(253)}`, platform_user_id: "1".repeat(18), resource_link_id: "2".repeat(18) })
    expect(activityTarget(undefined, longest)).toEqual({
      path: `researcher_dashboard/${"a".repeat(253)}/activity/${HASH}/users/${"1".repeat(18)}`,
      resourceLinkId: "2".repeat(18)
    })
  })

  it("skips a delete", () => {
    expect(activityTarget(answer(), undefined)).toEqual({ skip: "deleted" })
  })

  it("skips an anonymous answer", () => {
    const anonymous = answer({ run_key: "run-key-1", platform_id: undefined, platform_user_id: undefined, context_id: undefined })
    expect(activityTarget(undefined, anonymous)).toEqual({ skip: "no_class" })
  })

  it.each(["platform_id", "platform_user_id", "context_id", "resource_link_id"])("skips an answer with no %s", key => {
    expect(activityTarget(undefined, without(answer(), key))).toEqual({ skip: "no_class" })
  })

  it("skips a move to another class", () => {
    expect(activityTarget(answer(), answer({ context_id: OTHER_HASH }))).toEqual({ skip: "moved" })
  })

  it("skips a write that changes the learner", () => {
    expect(activityTarget(answer(), answer({ platform_user_id: "5678" }))).toEqual({ skip: "moved" })
  })

  it("skips a re-save that changes only the per-save fields", () => {
    const resave = answer({ created: "Thu, 15 Oct 2026 12:05:00 GMT", interactive_state_history_id: "history-2" })
    expect(activityTarget(answer(), resave)).toEqual({ skip: "unchanged" })
  })

  it("skips a re-save whose keys come back in another order, nested keys included", () => {
    const before = answer({ answer: { choice_ids: ["choice-1"], text: "because" } })
    const reordered = Object.fromEntries(Object.entries({
      ...before, answer: { text: "because", choice_ids: ["choice-1"] }, created: "Thu, 15 Oct 2026 12:05:00 GMT"
    }).reverse())
    expect(activityTarget(before, reordered)).toEqual({ skip: "unchanged" })
  })

  it("records a re-save that reorders an array", () => {
    const before = answer({ answer: { choice_ids: ["choice-1", "choice-2"] } })
    const after = answer({ answer: { choice_ids: ["choice-2", "choice-1"] } })
    expect(activityTarget(before, after)).toEqual({ path: PATH, resourceLinkId: "701" })
  })

  it("skips a move to a malformed class as a move", () => {
    expect(activityTarget(answer(), answer({ context_id: "not/a/class" }))).toEqual({ skip: "moved" })
  })

  it("records a re-save that changes a nested value", () => {
    const before = answer({ answer: { choice_ids: ["choice-1"], text: "because" } })
    const after = answer({ answer: { choice_ids: ["choice-2"], text: "because" } })
    expect(activityTarget(before, after)).toEqual({ path: PATH, resourceLinkId: "701" })
  })

  it.each<[string, Record<string, unknown>, Skip]>([
    ["a platform_id that is not a URL", { platform_id: "learn.concord.org" }, "bad_platform_id"],
    ["a platform_id with no host", { platform_id: "foo:bar" }, "bad_platform_id"],
    ["a context_id with a slash", { context_id: `${"c".repeat(24)}/${"c".repeat(23)}` }, "bad_class_hash"],
    ["a platform_user_id with a slash", { platform_user_id: "12/34" }, "bad_user_id"],
    ["a platform_user_id with a leading zero", { platform_user_id: "0123" }, "bad_user_id"],
    ["a resource_link_id Firestore reserves", { resource_link_id: "__x__" }, "bad_resource_link_id"],
    ["a platform_id whose host Firestore reserves as a document id", { platform_id: "https://__x__" }, "bad_platform_id"],
    ["a platform_id whose host is longer than a DNS name", { platform_id: `https://${"a".repeat(254)}` }, "bad_platform_id"],
    ["a platform_user_id of 19 digits", { platform_user_id: "1".repeat(19) }, "bad_user_id"],
    ["a resource_link_id of 19 digits", { resource_link_id: "1".repeat(19) }, "bad_resource_link_id"]
  ])("skips %s", (_, fields, skip) => {
    expect(activityTarget(undefined, answer(fields))).toEqual({ skip })
  })
})
