import { openTargetOffering, TARGET_OFFERING_NAME } from "./open-target-offering";
import { armFromClassWord } from "./fall-programs";
import { StepContext, StepResult } from "./types";
import { IJobDocument } from "../types";
import { createPortalTokenCache } from "../portal-api";

const harnessConfig = require("../../../harness/im-done-local/config");

// Mock portal-api minted-token entry points; keep the real classifier/messages
const mockGetScopedPortalToken = jest.fn();
const mockPortalTokenFetch = jest.fn();
jest.mock("../portal-api", () => ({
  ...jest.requireActual("../portal-api"),
  getScopedPortalToken: (...args: any[]) => mockGetScopedPortalToken(...args),
  portalTokenFetch: (...args: any[]) => mockPortalTokenFetch(...args),
}));

// Mock firebase-functions logger
const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
  },
}));

const CONTROL_WORD = "ft-2026-bingler-shark";
const TREATMENT_WORD = "ft-2026-bingler-gator";
const POST_TEST_NAME = "Orange Sequence for AI in Math (FLVS 26-27)";

/** The run's own offering, a decimal string as the portal sends it. */
const OWN_OFFERING_ID = "1194";
/** The target, a JSON number as classes/info sends it. */
const TARGET_OFFERING_ID = 845;

/** A sentinel that must never reach a log line or a StepResult. */
const OTHER_STUDENT_ID = 999999;

/** A get_info offering, carrying the whole class's metadata rows as the real endpoint does. */
const offering = (id: any, name: any, extra: Record<string, any> = {}) => ({
  id,
  name,
  active: true,
  locked: true,
  metadata: [
    { user_id: 27, active: true, locked: true },
    { user_id: OTHER_STUDENT_ID, active: false, locked: true },
  ],
  url: `http://portal/api/v1/offerings/${id}`,
  external_url: `http://portal/activities/${id}`,
  ...extra,
});

/** classes/info anonymizes students but NOT teachers, so these names are real. */
const classBody = (offerings: any[]) => ({
  id: 30001,
  name: "FT-2026-Bingler-Shark",
  class_word: CONTROL_WORD,
  teachers: [{ id: "http://portal/users/7", user_id: 7, first_name: "Ada", last_name: "Lovelace" }],
  students: [],
  offerings,
});

/** The target is uppercased and space-padded, so the default path exercises normalization. */
const DEFAULT_OFFERINGS = [
  offering(OWN_OFFERING_ID, POST_TEST_NAME),
  offering(TARGET_OFFERING_ID, `  ${TARGET_OFFERING_NAME.toUpperCase()}  `),
];

/**
 * A class holding neither the target nor anything like it. Shared by the diagnostic test and the
 * privacy test below, which are the two halves of the same rule: this branch holds the whole class
 * body, so it must log the offering names and nothing else off it.
 */
const NO_MATCH_OFFERINGS = [
  offering(OWN_OFFERING_ID, POST_TEST_NAME),
  offering(777, "Green Sequence for AI in Math (FLVS 26-27)"),
];

/** Route the one mocked fetch by method, so the class read and the write are both covered. */
const routeFetch = (
  offerings: any[],
  writeResponse: any = { status: 200, data: { active: true, locked: false } },
) =>
  mockPortalTokenFetch.mockImplementation(({ method }: any) =>
    method === "PUT"
      ? Promise.resolve(writeResponse)
      : Promise.resolve({ status: 200, data: classBody(offerings) }),
  );

const makeContext = (
  { classWord = CONTROL_WORD, seedHandoff = true } = {},
): StepContext => ({
  jobPath: "sources/test-source/jobs/test-job-123",
  jobDoc: {
    platform_id: "https://learn.concord.org",
    platform_user_id: "27",
    resource_link_id: OWN_OFFERING_ID,
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "fall-2026-fulltime" },
      createdAt: Date.now(),
    },
  } as IJobDocument,
  firebaseJwt: "mock-jwt-token",
  stepResults: seedHandoff
    ? { "resolve-origin-class": { success: true, output: { originClassWord: classWord } } }
    : {},
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

const putCalls = () => mockPortalTokenFetch.mock.calls.filter(([opts]) => opts.method === "PUT");

/** Everything the step logged or returned, for the privacy assertions. */
const allLoggedText = (result: StepResult) =>
  JSON.stringify([mockLoggerInfo.mock.calls, mockLoggerError.mock.calls, result]);

describe("openTargetOffering", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetScopedPortalToken.mockResolvedValue({ ok: true, token: "minted-teacher-token", status: 201 });
    routeFetch(DEFAULT_OFFERINGS);
  });

  describe("the write", () => {
    it("sends both flags, unlocking and revealing the target matched by name", async () => {
      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(true);
      // The canonical name, not the fixture's uppercased and padded form.
      expect(result.summary).toBe(`Opened ${TARGET_OFFERING_NAME} (unlocked and visible)`);
      expect(putCalls()).toHaveLength(1);
      expect(putCalls()[0][0]).toEqual({
        portalUrl: "https://learn.concord.org",
        path: `/api/v1/offerings/${TARGET_OFFERING_ID}/update_student_metadata`,
        method: "PUT",
        token: "minted-teacher-token",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "locked=false&active=true&user_id=27",
      });
    });

    it("requests an unscoped teacher token for both the class read and the write", async () => {
      await openTargetOffering(makeContext());

      // Both requests hit the shared per-run cache, so only one mint reaches the portal. That is
      // NOT what this asserts: getScopedPortalToken is mocked here, so the caching it performs is
      // mocked away with it. The mint count is observable in the harness stub's log instead.
      expect(mockGetScopedPortalToken).toHaveBeenCalledTimes(2);
      for (const [params] of mockGetScopedPortalToken.mock.calls) {
        expect(params.classId).toBeUndefined();
      }
    });

    it("writes active=true even when the class reports the target hidden with a contrary row", async () => {
      routeFetch([
        offering(OWN_OFFERING_ID, POST_TEST_NAME),
        offering(TARGET_OFFERING_ID, TARGET_OFFERING_NAME, {
          active: false,
          metadata: [{ user_id: 27, active: false, locked: true }],
        }),
      ]);

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(true);
      expect(putCalls()[0][0].body).toBe("locked=false&active=true&user_id=27");
    });

    it("still succeeds and still logs when a 2xx carries a null body", async () => {
      routeFetch(DEFAULT_OFFERINGS, { status: 204, data: null });

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(true);
      expect(mockLoggerInfo).toHaveBeenCalledWith(expect.stringContaining("opened offering"));
    });
  });

  describe("target selection", () => {
    it("fails permanently when no offering matches, logging the class's offering names", async () => {
      routeFetch(NO_MATCH_OFFERINGS);

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(putCalls()).toHaveLength(0);
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("no offering matched"),
        expect.objectContaining({
          class_offering_names: [POST_TEST_NAME, "Green Sequence for AI in Math (FLVS 26-27)"],
        }),
      );
    });

    it("fails rather than guessing when more than one offering matches", async () => {
      routeFetch([
        offering(TARGET_OFFERING_ID, TARGET_OFFERING_NAME),
        offering(846, TARGET_OFFERING_NAME.toLowerCase()),
      ]);

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(putCalls()).toHaveLength(0);
    });

    it("refuses to unlock the run's own offering, comparing a numeric id against a string one", async () => {
      routeFetch([offering(Number(OWN_OFFERING_ID), TARGET_OFFERING_NAME)]);

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(putCalls()).toHaveLength(0);
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("own offering"),
        expect.objectContaining({ target_offering_id: 1194, resource_link_id: "1194" }),
      );
    });

    it("resolves the target past an unnamed sibling offering", async () => {
      routeFetch([
        offering(777, null),
        offering(TARGET_OFFERING_ID, TARGET_OFFERING_NAME),
      ]);

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(true);
      expect(putCalls()[0][0].path).toContain(`/offerings/${TARGET_OFFERING_ID}/`);
    });
  });

  describe("arm classification", () => {
    it("does nothing for a treatment student, before any portal call", async () => {
      const result = await openTargetOffering(makeContext({ classWord: TREATMENT_WORD }));

      expect(result.success).toBe(true);
      expect(result.summary).toContain("No activity to open");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });

    it("fails permanently on a class word carrying neither arm suffix", async () => {
      const result = await openTargetOffering(makeContext({ classWord: "ft-2026-bingler" }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unclassifiable"),
        expect.objectContaining({ origin_class_word: "ft-2026-bingler" }),
      );
    });

    it("fails with the shared tell-teacher message when the handoff is absent", async () => {
      const result = await openTargetOffering(makeContext({ seedHandoff: false }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      // Not this step's own retryable message: a mis-wired stage is permanent until code changes.
      expect(result.message).not.toContain("Your work has been saved");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });
  });

  describe("missing context fields", () => {
    it("returns failure when resource_link_id is missing", async () => {
      const context = makeContext();
      context.jobDoc.resource_link_id = undefined;

      const result = await openTargetOffering(context);

      expect(result.success).toBe(false);
      expect(result.message).toContain("Your work has been saved");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("resource_link_id"));
    });

    it("returns failure when the Firebase JWT is missing", async () => {
      const context = makeContext();
      context.firebaseJwt = undefined;

      const result = await openTargetOffering(context);

      expect(result.success).toBe(false);
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });
  });

  describe("classified portal failures", () => {
    it("returns the tell-teacher message on a 403 write", async () => {
      routeFetch(DEFAULT_OFFERINGS, { status: 403, data: { success: false, message: "Not authorized" } });

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal returned 403"),
        expect.objectContaining({ status: 403 }),
      );
    });

    it("returns its own message on a 500 write, issuing exactly one PUT and no retry", async () => {
      routeFetch(DEFAULT_OFFERINGS, { status: 500, data: null });

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Your work has been saved");
      expect(putCalls()).toHaveLength(1);
    });

    it("returns the tell-teacher message when the class read is forbidden", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { success: false } });

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(putCalls()).toHaveLength(0);
    });

    it("returns the reload message when the mint reports an expired token", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422, reason: "expired" });

      const result = await openTargetOffering(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("reload the activity");
      expect(putCalls()).toHaveLength(0);
    });
  });

  describe("harness fixture agreement", () => {
    // The stub keeps these as literals so it stays buildless. These assertions are what replace the
    // import: a rename that misses config.js fails here rather than as a silently non-matching run.
    it("serves an offering named exactly the exported target constant", () => {
      expect(harnessConfig.TARGET_OFFERING_NAME).toBe(TARGET_OFFERING_NAME);
    });

    it("serves class words that classify as the arms their scenarios assume", () => {
      expect(armFromClassWord(harnessConfig.STUDY_CONTROL_CLASS.word)).toBe("control");
      expect(armFromClassWord(harnessConfig.TREATMENT_CLASS_WORD)).toBe("treatment");
    });
  });

  describe("privacy", () => {
    const expectNoLeaks = (result: StepResult) => {
      const text = allLoggedText(result);
      expect(text).not.toContain("Lovelace");
      expect(text).not.toContain("Ada");
      // metadata[] carries no names, so a name-only assertion would pass even if the whole class's
      // progress roster were dumped.
      expect(text).not.toContain(String(OTHER_STUDENT_ID));
    };

    it("leaks no teacher name and no foreign user_id on success", async () => {
      const result = await openTargetOffering(makeContext());
      expect(result.success).toBe(true);
      expectNoLeaks(result);
    });

    it("leaks nothing on the no-match branch, which holds the whole class body", async () => {
      routeFetch(NO_MATCH_OFFERINGS);
      const result = await openTargetOffering(makeContext());
      expect(result.success).toBe(false);
      expectNoLeaks(result);
    });

    it("leaks nothing on the self-target branch", async () => {
      routeFetch([offering(Number(OWN_OFFERING_ID), TARGET_OFFERING_NAME)]);
      const result = await openTargetOffering(makeContext());
      expect(result.success).toBe(false);
      expectNoLeaks(result);
    });
  });
});
