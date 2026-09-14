import { IJobDocument } from "../types";
import { StepContext } from "./types";

const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
const mockLoggerWarn = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
    warn: (...args: any[]) => mockLoggerWarn(...args),
  },
}));

// The query builders are stubbed so the filters the step applies are observable.
const mockCleanup = jest.fn();
const mockGetClientFirestore = jest.fn();
jest.mock("../../firebase-client", () => ({
  getClientFirestore: (...args: any[]) => mockGetClientFirestore(...args),
}));
const mockCollection = jest.fn();
const mockQuery = jest.fn();
const mockWhere = jest.fn();
const mockGetDocs = jest.fn();
jest.mock("firebase/firestore", () => ({
  ...jest.requireActual("firebase/firestore"),
  collection: (...args: any[]) => mockCollection(...args),
  query: (...args: any[]) => mockQuery(...args),
  where: (...args: any[]) => mockWhere(...args),
  getDocs: (...args: any[]) => mockGetDocs(...args),
}));

import { evaluateCompletion, CHECK_FAILED_MESSAGE } from "./evaluate-completion";
import { createPortalTokenCache } from "../portal-api";

const JOB_PATH = "sources/test-source/jobs/test-job-123";

const makeContext = (request: Record<string, any>): StepContext => ({
  jobPath: JOB_PATH,
  jobDoc: {
    platform_id: "https://learn.concord.org",
    platform_user_id: 27,
    resource_link_id: "845",
    context_id: "class-hash",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "fall-2026-blue", ...request },
      createdAt: Date.now(),
    },
  } as unknown as IJobDocument,
  firebaseJwt: "jwt-token",
  stepResults: {},
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

/** A snapshot of `completed` answered multiple-choice docs plus `untouched` empty interactive states. */
const snapshotOf = (completed: number, untouched: number) => ({
  size: completed + untouched,
  docs: [
    ...Array.from({ length: completed }, () => ({
      data: () => ({ type: "multiple_choice_answer", answer: { choice_ids: ["c1"] } }),
    })),
    ...Array.from({ length: untouched }, () => ({
      data: () => ({ type: "interactive_state", report_state: JSON.stringify({ interactiveState: "{}" }) }),
    })),
  ],
});

describe("evaluateCompletion", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockCleanup.mockResolvedValue(undefined);
    mockGetClientFirestore.mockResolvedValue({ firestore: {}, cleanup: mockCleanup });
    mockCollection.mockReturnValue("answers-ref");
    mockQuery.mockReturnValue("the-query");
    mockWhere.mockImplementation((field, op, value) => ({ field, op, value }));
  });

  describe("a misauthored min_completed_questions", () => {
    // The explicit table type is required: jest 24's it.each typings flatten an inline tuple table.
    const MISAUTHORED: Array<[string, Record<string, any>]> = [
      ["absent", {}],
      ["a non-numeric string", { min_completed_questions: "four" }],
      ["zero", { min_completed_questions: "0" }],
      ["a fraction", { min_completed_questions: "2.5" }],
    ];
    it.each(MISAUTHORED)("fails before Firestore with the student-facing message when %s", async (_label, request) => {
      const result = await evaluateCompletion(makeContext(request));

      expect(result).toEqual({ success: false, message: CHECK_FAILED_MESSAGE });
      expect(mockGetClientFirestore).not.toHaveBeenCalled();
      expect(mockGetDocs).not.toHaveBeenCalled();
    });

    it("logs the raw value at error so the fault is diagnosable from the log", async () => {
      await evaluateCompletion(makeContext({ min_completed_questions: "four" }));

      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining(`min_completed_questions is missing or not a positive integer (got "four") for ${JOB_PATH}`)
      );
    });

    it("says so when the parameter is absent", async () => {
      await evaluateCompletion(makeContext({}));

      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("(got undefined)"));
    });

    it("keeps the raw value out of the student message", async () => {
      const result = await evaluateCompletion(makeContext({ min_completed_questions: "four" }));

      expect(result.message).not.toContain("four");
    });
  });

  describe("counting", () => {
    it("queries the launch's answers by all four identity fields", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 0));

      await evaluateCompletion(makeContext({ min_completed_questions: "4" }));

      expect(mockCollection).toHaveBeenCalledWith({}, "sources/test-source/answers");
      expect(mockQuery).toHaveBeenCalledWith(
        "answers-ref",
        { field: "platform_id", op: "==", value: "https://learn.concord.org" },
        { field: "resource_link_id", op: "==", value: "845" },
        { field: "context_id", op: "==", value: "class-hash" },
        { field: "platform_user_id", op: "==", value: 27 },
      );
      expect(mockGetDocs).toHaveBeenCalledWith("the-query");
    });

    it("counts only documents that pass answerIsCompleted", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 3));

      const result = await evaluateCompletion(makeContext({ min_completed_questions: "5" }));

      expect(result.success).toBe(false);
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("4 of 7 answer(s) completed (need 5)")
      );
    });

    it("releases the client after a refusal and after a pass", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 0));

      await evaluateCompletion(makeContext({ min_completed_questions: "5" }));
      await evaluateCompletion(makeContext({ min_completed_questions: "4" }));

      expect(mockCleanup).toHaveBeenCalledTimes(2);
    });
  });

  describe("a short count", () => {
    beforeEach(() => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 3));
    });

    it("is an expected failure carrying the authored template with both variables filled", async () => {
      const result = await evaluateCompletion(makeContext({
        min_completed_questions: "5",
        min_completed_questions_failure_message:
          "You have answered ${completed} of the ${min_completed_questions} questions needed.",
      }));

      expect(result).toEqual({
        success: false,
        expected: true,
        message: "You have answered 4 of the 5 questions needed.",
      });
    });

    it("falls back to the default text when no template is authored", async () => {
      const result = await evaluateCompletion(makeContext({ min_completed_questions: "5" }));

      expect(result).toEqual({
        success: false,
        expected: true,
        message: "You have completed 4 of 5 required questions. Please answer more questions in this activity.",
      });
    });

    it("logs nothing at error", async () => {
      await evaluateCompletion(makeContext({ min_completed_questions: "5" }));

      expect(mockLoggerError).not.toHaveBeenCalled();
    });
  });

  describe("enough answers", () => {
    it("passes with the line send-email renders", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 3));

      const result = await evaluateCompletion(makeContext({ min_completed_questions: "4" }));

      expect(result).toEqual({ success: true, message: "4 of 4 questions completed" });
    });
  });
});
