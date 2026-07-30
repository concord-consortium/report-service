import { StepContext, StepResult } from "./types";
import { IJobDocument } from "../types";
import { createPortalTokenCache, TELL_TEACHER_MESSAGE } from "../portal-api";
import { AssignmentScope, perClassScope, pooledProgramScope } from "./assignment-doc";
import { FLEX_PROGRAM } from "./fall-programs";

// Mock firebase-client
const mockGetDocs = jest.fn();
jest.mock("../../firebase-client", () => ({
  getClientFirestore: jest.fn().mockResolvedValue({
    firestore: {},
    cleanup: jest.fn().mockResolvedValue(undefined),
  }),
}));

jest.mock("firebase/firestore", () => ({
  collection: jest.fn(),
  query: jest.fn(),
  where: jest.fn(),
  getDocs: (...args: any[]) => mockGetDocs(...args),
}));

// Mock portal-api's minted-token entry points; keep the real classifier/messages
const mockPortalTokenFetch = jest.fn();
jest.mock("../portal-api", () => ({
  ...jest.requireActual("../portal-api"),
  getScopedPortalToken: jest.fn(),
  portalTokenFetch: (...args: any[]) => mockPortalTokenFetch(...args),
}));

// Mock the assignment core so the scope handed to it can be asserted; keep the real constructors,
// which are what the scope assertions compare against.
const mockGetAlternatingAssignment = jest.fn();
jest.mock("./assignment-doc", () => ({
  ...jest.requireActual("./assignment-doc"),
  getAlternatingAssignment: (...args: any[]) => mockGetAlternatingAssignment(...args),
}));

const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
    warn: jest.fn(),
  },
}));

// Must import after jest.mock
import { fallRandomAssignment } from "./fall-random-assignment";
import { makeAnswerDoc, makeStandardAnswerDocs } from "./answer-doc-fixtures";
// Imported as a namespace so one test can spy on the read; every other test drives the real one
// through the mocked getDocs.
import * as demographics from "./demographics";

/** One of the five real teacher full names, none of which may reach a log or a StepResult. */
const TEACHER_NAME_SENTINEL = "Alyssa";

const ORIGIN_STEP = "resolve-origin-class";

/** `originClassWord: null` builds a context in which no step published the handoff. */
const makeContext = (
  originClassWord: string | null = "ft-2026-bingler",
  overrides: Partial<IJobDocument> = {},
): StepContext => ({
  jobPath: "sources/test-source/jobs/test-job-123",
  jobDoc: {
    platform_id: "https://learn.concord.org",
    platform_user_id: 12345,
    resource_link_id: "678",
    source_key: "test-source",
    context_id: "ctx-1",
    interactiveId: "interactive-1",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "fall-2026-green" },
      createdAt: Date.now(),
    },
    ...overrides,
  } as IJobDocument,
  firebaseJwt: "mock-jwt-token",
  stepResults: originClassWord === null
    ? {}
    : { [ORIGIN_STEP]: { success: true, output: { originClassWord } } as StepResult },
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

/** The demographic answer docs a full-time student has: Gender and Race, and nothing else. */
const fullTimeAnswerDocs = (overrides?: { genderChoice?: string; raceChoices?: string[] }) => {
  const all = makeStandardAnswerDocs(overrides);
  return { docs: [all.docs[0], all.docs[3]] };
};

const scopeHandedToCore = (): AssignmentScope => mockGetAlternatingAssignment.mock.calls[0][1];
const stratumKeyHandedToCore = (): string => mockGetAlternatingAssignment.mock.calls[0][3];
const n1HandedToCore = (): string => mockGetAlternatingAssignment.mock.calls[0][4];

describe("fallRandomAssignment", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetDocs.mockResolvedValue(fullTimeAnswerDocs());
    mockGetAlternatingAssignment.mockResolvedValue("treatment");
  });

  describe("full-time students", () => {
    it("assigns from Gender and Race only, with no Grade or Module answer docs present", async () => {
      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(result.success).toBe(true);
      expect(stratumKeyHandedToCore()).toBe("Female|White|Bingler");
    });

    it("takes the seed arm of the block its class word names", async () => {
      // The Bingler block starts on treatment; the next test shows Hankamp's starts on control.
      // That ft-2026-bingler reaches the row labelled "Alyssa Bingler" is asserted in
      // fall-programs.test.ts, where the full name can be read without leaving the step.
      await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(n1HandedToCore()).toBe("treatment");
    });

    it("gives each teacher their own seed arm for the same demographics", async () => {
      await fallRandomAssignment(makeContext("ft-2026-hankamp"));

      expect(stratumKeyHandedToCore()).toBe("Female|White|Hankamp");
      expect(n1HandedToCore()).toBe("control");
    });

    it("keeps the shipped per-class scope, so two classes do not alternate against each other", async () => {
      await fallRandomAssignment(makeContext("ft-2026-bingler"));
      const bingler = scopeHandedToCore();

      mockGetAlternatingAssignment.mockClear();
      await fallRandomAssignment(makeContext("ft-2026-hankamp", {
        resource_link_id: "679", context_id: "ctx-2",
      }));
      const hankamp = scopeHandedToCore();

      expect(bingler).toEqual(perClassScope("interactive-1", "https://learn.concord.org", "678", "ctx-1"));
      expect(hankamp).toEqual(perClassScope("interactive-1", "https://learn.concord.org", "679", "ctx-2"));
      expect(bingler.docId).not.toBe(hankamp.docId);
    });

    it("stops with tell-your-teacher and logs the surname when it is absent from the table", async () => {
      const result = await fallRandomAssignment(makeContext("ft-2026-nobody"));

      expect(result.success).toBe(false);
      expect(result.message).toBe(TELL_TEACHER_MESSAGE);
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("no full-time stratum"),
        expect.objectContaining({ teacher_surname: "nobody", origin_class_word: "ft-2026-nobody" }),
      );
      expect(mockGetAlternatingAssignment).not.toHaveBeenCalled();
    });
  });

  describe("flex students", () => {
    beforeEach(() => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs());
    });

    it("assigns using all four demographic answers", async () => {
      const result = await fallRandomAssignment(makeContext("fl-2026-section1"));

      expect(result.success).toBe(true);
      // Female / White / 10th Grade / Module 1 => Female|White|High|Mod1, which seeds on control.
      expect(stratumKeyHandedToCore()).toBe("Female|White|High|Mod1");
      expect(n1HandedToCore()).toBe("control");
    });

    it("stops with a complete-your-answers message when a flex-only question is unanswered", async () => {
      mockGetDocs.mockResolvedValue(fullTimeAnswerDocs());

      const result = await fallRandomAssignment(makeContext("fl-2026-section1"));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Please complete");
      expect(result.message).toContain("Grade");
      expect(result.message).toContain("Module");
    });

    it("pools the three sections onto one document id", async () => {
      const sections = [["678", "ctx-1"], ["679", "ctx-2"], ["680", "ctx-3"]];
      const scopes: AssignmentScope[] = [];

      for (const [resourceLinkId, contextId] of sections) {
        mockGetAlternatingAssignment.mockClear();
        await fallRandomAssignment(makeContext("fl-2026-section1", {
          resource_link_id: resourceLinkId, context_id: contextId,
        }));
        scopes.push(scopeHandedToCore());
      }

      expect(new Set(scopes.map(scope => scope.docId)).size).toBe(1);
      expect(scopes[0]).toEqual(pooledProgramScope(FLEX_PROGRAM, "interactive-1", "https://learn.concord.org"));
    });
  });

  describe("the origin class word handoff", () => {
    it("stops with tell-your-teacher when no step published one", async () => {
      const result = await fallRandomAssignment(makeContext(null));

      expect(result.success).toBe(false);
      expect(result.message).toBe(TELL_TEACHER_MESSAGE);
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("no originClassWord handoff"));
      expect(mockGetDocs).not.toHaveBeenCalled();
    });

    it("stops with tell-your-teacher and logs the word when neither prefix matches", async () => {
      const result = await fallRandomAssignment(makeContext("spring-2026-origin"));

      expect(result.success).toBe(false);
      expect(result.message).toBe(TELL_TEACHER_MESSAGE);
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unclassifiable origin class word"),
        expect.objectContaining({ origin_class_word: "spring-2026-origin" }),
      );
      expect(mockGetDocs).not.toHaveBeenCalled();
    });
  });

  describe("the destination class word", () => {
    it("appends -gator for treatment and publishes it on output", async () => {
      mockGetAlternatingAssignment.mockResolvedValue("treatment");

      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(result.output).toEqual({ destinationClassWord: "ft-2026-bingler-gator" });
      expect(result.summary).toBe("Assigned to ft-2026-bingler-gator");
    });

    it("appends -shark for control", async () => {
      mockGetAlternatingAssignment.mockResolvedValue("control");

      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(result.output).toEqual({ destinationClassWord: "ft-2026-bingler-shark" });
    });

    it("derives it in the portal's stored form, all lowercase", async () => {
      const result = await fallRandomAssignment(makeContext("fl-2026-section2"));

      expect(result.output?.destinationClassWord).toBe(result.output?.destinationClassWord?.toLowerCase());
    });
  });

  describe("required context", () => {
    it("fails when a context field is missing", async () => {
      const result = await fallRandomAssignment(makeContext("ft-2026-bingler", { interactiveId: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("interactiveId"));
    });

    it("fails when the Firebase JWT is missing", async () => {
      const context = makeContext("ft-2026-bingler");
      context.firebaseJwt = undefined;

      const result = await fallRandomAssignment(context);

      expect(result.success).toBe(false);
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("Firebase JWT"));
    });
  });

  describe("the permanent/transient message split", () => {
    it("gives tell-your-teacher, not the retry message, for a choice the config cannot map", async () => {
      const docs = fullTimeAnswerDocs();
      docs.docs[0] = makeAnswerDoc(
        "<p>What is your sex?</p>", [{ id: "cX", content: "Non-binary" }], ["cX"],
      );
      mockGetDocs.mockResolvedValue(docs);

      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(result.success).toBe(false);
      expect(result.message).toBe(TELL_TEACHER_MESSAGE);
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining('Unmapped Gender choice: "Non-binary"'));
    });

    it("gives tell-your-teacher when a required dimension resolves to no category", async () => {
      // Only reachable if the dimension set and the table it feeds go out of step, which is a code
      // change rather than anything a student can do, so it is permanent.
      const spy = jest.spyOn(demographics, "readDemographics")
        .mockResolvedValue({ ok: true, categories: { Gender: "Female" } });

      try {
        const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

        expect(result.success).toBe(false);
        expect(result.message).toBe(TELL_TEACHER_MESSAGE);
        expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("resolved no category for Race"));
      } finally {
        spy.mockRestore();
      }
    });

    it("keeps the retry message for a transport failure", async () => {
      mockGetDocs.mockRejectedValue(new Error("Firestore query failed"));

      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(result.message).not.toContain("tell your teacher");
    });

    it("keeps the retry message when the assignment transaction throws", async () => {
      mockGetAlternatingAssignment.mockRejectedValue(new Error("transaction failed"));

      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("assignment transaction failed"), expect.any(Error),
      );
    });
  });

  describe("scope and secrecy", () => {
    it("makes no portal write of its own", async () => {
      await fallRandomAssignment(makeContext("ft-2026-bingler"));

      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("puts no real teacher name in any log argument or in the returned result", async () => {
      const result = await fallRandomAssignment(makeContext("ft-2026-bingler"));

      const logged = JSON.stringify(mockLoggerInfo.mock.calls.concat(mockLoggerError.mock.calls));
      expect(logged).not.toContain(TEACHER_NAME_SENTINEL);
      expect(JSON.stringify(result)).not.toContain(TEACHER_NAME_SENTINEL);
    });

    it("puts no real teacher name in the logs on the unmatched-surname path either", async () => {
      const result = await fallRandomAssignment(makeContext("ft-2026-nobody"));

      const logged = JSON.stringify(mockLoggerInfo.mock.calls.concat(mockLoggerError.mock.calls));
      expect(logged).not.toContain(TEACHER_NAME_SENTINEL);
      expect(JSON.stringify(result)).not.toContain(TEACHER_NAME_SENTINEL);
    });
  });
});
