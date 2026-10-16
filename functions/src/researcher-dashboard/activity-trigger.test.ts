import { researcherDashboardActivity } from "./activity-trigger"

jest.mock("firebase-admin", () => ({ __esModule: true, default: { firestore: () => ({}) } }))
jest.mock("firebase-functions", () => {
  const registration: { options?: unknown; path?: string } = {}
  return {
    registration,
    logger: { warn: jest.fn() },
    runWith: (options: unknown) => {
      registration.options = options
      return { firestore: { document: (path: string) => {
        registration.path = path
        return { onWrite: (onWrite: unknown) => onWrite }
      } } }
    }
  }
})

const functions = jest.requireMock("firebase-functions")
const handler = researcherDashboardActivity as unknown as (change: unknown, context: unknown) => Promise<null>
const write = (before: unknown, after: unknown) =>
  handler({ before: { data: () => before }, after: { data: () => after } }, { params: { source: "activity-player.concord.org", answerId: "answer-1" } })

const answer = {
  context_id: "c".repeat(48),
  platform_id: "https://learn.concord.org",
  platform_user_id: "1234",
  resource_link_id: "701"
}

beforeEach(() => functions.logger.warn.mockClear())

it("registers on every answer write with retries on", () => {
  expect(functions.registration).toEqual({ options: { failurePolicy: true }, path: "sources/{source}/answers/{answerId}" })
})

it("logs a skip for a malformed identifier, with its reason and the answer's path", async () => {
  await write(undefined, { ...answer, resource_link_id: "__x__" })
  expect(functions.logger.warn.mock.calls).toEqual([[
    "activity.skipped", { reason: "bad_resource_link_id", source: "activity-player.concord.org", answerId: "answer-1" }
  ]])
})

it("logs nothing for an expected skip", async () => {
  await write(answer, undefined)
  await write(answer, answer)
  expect(functions.logger.warn).not.toHaveBeenCalled()
})
