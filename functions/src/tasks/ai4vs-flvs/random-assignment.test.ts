import { createHash } from "crypto";
import { StepContext, StepResult } from "./types";
import { IJobDocument } from "../types";
import { createPortalTokenCache } from "../portal-api";

// Mock firebase-client
const mockGetDocs = jest.fn();
const mockCleanup = jest.fn().mockResolvedValue(undefined);
jest.mock("../../firebase-client", () => ({
  getClientFirestore: jest.fn().mockResolvedValue({
    firestore: {},
    cleanup: () => mockCleanup(),
  }),
}));

// Mock firestore query functions — getDocs is the one that returns answer data
jest.mock("firebase/firestore", () => ({
  collection: jest.fn(),
  query: jest.fn(),
  where: jest.fn(),
  getDocs: (...args: any[]) => mockGetDocs(...args),
}));

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
const mockLoggerWarn = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
    warn: (...args: any[]) => mockLoggerWarn(...args),
  },
}));

// Mock firebase-admin for assignment document transactions
const mockTransactionGet = jest.fn();
const mockTransactionSet = jest.fn();
const mockDocRef = { path: "mock-doc-ref" };
const mockDoc = jest.fn().mockReturnValue(mockDocRef);
const mockRunTransaction = jest.fn((fn: any) =>
  fn({ get: mockTransactionGet, set: mockTransactionSet })
);
jest.mock("firebase-admin", () => ({
  __esModule: true,
  default: {
    firestore: () => ({
      doc: (...args: any[]) => mockDoc(...args),
      runTransaction: (fn: any) => mockRunTransaction(fn),
    }),
  },
}));

// Must import after jest.mock
import { randomAssignment } from "./random-assignment";
import { makeStandardAnswerDocs } from "./answer-doc-fixtures";

/** Build a StepContext with all fields needed by random-assignment. */
const makeContext = (
  overrides: Partial<IJobDocument> = {},
  requestOverrides: Record<string, any> = {},
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
      request: {
        task: "ai4vs-flvs",
        pilot: "spring-2026",
        treatment_class_id: "portal-class-100",
        control_class_id: "portal-class-200",
        ...requestOverrides,
      },
      createdAt: Date.now(),
    },
    ...overrides,
  } as IJobDocument,
  firebaseJwt: "mock-jwt-token",
  stepResults: {},
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

describe("randomAssignment", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetScopedPortalToken.mockResolvedValue({ ok: true, token: "minted-teacher-token", status: 201 });
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { success: true } });
    mockGetDocs.mockResolvedValue(makeStandardAnswerDocs());
    // Default: empty assignment document (first student scenario)
    mockTransactionGet.mockResolvedValue({ exists: false, data: () => undefined });
  });

  describe("request parameter validation", () => {
    it("returns student-friendly message when treatment_class_id is missing", async () => {
      const result = await randomAssignment(makeContext({}, { treatment_class_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("treatment_class_id")
      );
      expect(mockGetDocs).not.toHaveBeenCalled();
    });

    it("returns student-friendly message when control_class_id is missing", async () => {
      const result = await randomAssignment(makeContext({}, { control_class_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("control_class_id")
      );
    });

    it("logs both parameter names when both class IDs are missing", async () => {
      await randomAssignment(makeContext({}, {
        treatment_class_id: undefined,
        control_class_id: undefined,
      }));

      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringMatching(/treatment_class_id.*control_class_id/)
      );
    });

    it("rejects whitespace-only class IDs", async () => {
      const result = await randomAssignment(makeContext({}, {
        treatment_class_id: "   ",
        control_class_id: "  ",
      }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockGetDocs).not.toHaveBeenCalled();
    });

    it("returns student-friendly message when firebaseJwt is missing", async () => {
      const ctx = makeContext();
      ctx.firebaseJwt = undefined;

      const result = await randomAssignment(ctx);

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Firebase JWT")
      );
    });

    it("returns student-friendly message when context fields are missing", async () => {
      const result = await randomAssignment(makeContext({
        platform_id: undefined,
        platform_user_id: undefined,
      }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringMatching(/platform_user_id.*platform_id/)
      );
    });
  });

  describe("successful assignment and enrollment", () => {
    it("returns summary with class name", async () => {
      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(true);
      expect(result.summary).toMatch(/^Assigned to FL-spring-2026-(GATOR|SHARK)$/);
    });

    it("mints a cross-class teacher token for the destination class", async () => {
      await randomAssignment(makeContext());

      expect(mockGetScopedPortalToken).toHaveBeenCalledWith(
        expect.objectContaining({
          portalUrl: "https://learn.concord.org",
          firebaseToken: "mock-jwt-token",
          tokenType: "teacher",
          classId: expect.stringMatching(/^portal-class-/),
          pilot: "spring-2026",
        })
      );
    });

    it("enrolls with the minted token and the unchanged JSON body", async () => {
      await randomAssignment(makeContext());

      expect(mockPortalTokenFetch).toHaveBeenCalledWith({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/students/add_to_class",
        method: "POST",
        token: "minted-teacher-token",
        headers: { "Content-Type": "application/json" },
        body: expect.any(String),
      });

      const callArgs = mockPortalTokenFetch.mock.calls[0][0];
      const body = JSON.parse(callArgs.body);
      expect(body.user_id).toBe("12345");
      expect(body.clazz_id).toMatch(/^portal-class-/);
      // The minted scope must match the class actually enrolled into.
      expect(mockGetScopedPortalToken.mock.calls[0][0].classId).toBe(body.clazz_id);
    });
  });

  describe("all 24 assignment strata", () => {
    // Representative choices for each category
    const genderChoices: Record<string, string> = { Female: "Female", Male: "Male" };
    const raceChoices: Record<string, string[]> = { White: ["White"], "non-White": ["Black or African American"] };
    const gradeChoices: Record<string, string> = { High: "9th Grade", Mid: "7th Grade" };
    const moduleChoices: Record<string, string> = {
      Mod1: "Module 1: One-Variable Equations and Inequalities",
      Mod2: "Module 2: Two-Variable Linear Functions",
      Other: "Other/not sure",
    };

    const strata: Array<[string, string, string, string, "treatment" | "control"]> = [
      ["Female", "White",     "High", "Mod2",  "treatment"],
      ["Male",   "non-White", "High", "Mod2",  "control"],
      ["Male",   "White",     "Mid",  "Mod2",  "treatment"],
      ["Female", "White",     "High", "Mod1",  "control"],
      ["Female", "White",     "Mid",  "Mod1",  "treatment"],
      ["Female", "non-White", "High", "Mod1",  "control"],
      ["Male",   "White",     "High", "Mod2",  "treatment"],
      ["Female", "White",     "Mid",  "Other", "control"],
      ["Male",   "non-White", "High", "Mod1",  "treatment"],
      ["Female", "White",     "Mid",  "Mod2",  "control"],
      ["Female", "non-White", "High", "Mod2",  "treatment"],
      ["Female", "White",     "High", "Other", "control"],
      ["Female", "non-White", "High", "Other", "treatment"],
      ["Male",   "White",     "High", "Other", "control"],
      ["Female", "non-White", "Mid",  "Mod2",  "treatment"],
      ["Male",   "non-White", "High", "Other", "control"],
      ["Male",   "White",     "Mid",  "Other", "treatment"],
      ["Male",   "non-White", "Mid",  "Other", "control"],
      ["Female", "non-White", "Mid",  "Other", "treatment"],
      ["Male",   "non-White", "Mid",  "Mod2",  "control"],
      ["Male",   "White",     "Mid",  "Mod1",  "treatment"],
      ["Male",   "White",     "High", "Mod1",  "control"],
      ["Female", "non-White", "Mid",  "Mod1",  "treatment"],
      ["Male",   "non-White", "Mid",  "Mod1",  "control"],
    ];

    const className: Record<string, string> = {
      treatment: "FL-spring-2026-GATOR",
      control: "FL-spring-2026-SHARK",
    };

    it.each(strata)(
      "%s|%s|%s|%s → %s",
      async (gender, race, grade, module, expected) => {
        mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({
          genderChoice: genderChoices[gender],
          gradeChoice: gradeChoices[grade],
          moduleChoice: moduleChoices[module],
          raceChoices: raceChoices[race],
        }));

        const result = await randomAssignment(makeContext());

        expect(result).toEqual({ success: true, summary: `Assigned to ${className[expected]}` });
      },
    );
  });

  // Note: The "missing stratum" code path (assignment table miss) is not reachable
  // through the public API because the category mappings produce exactly the 2×2×2×3 = 24
  // combinations covered by ASSIGNMENT_TABLE. The "all 24 assignment strata" test.each
  // above proves table completeness. The guard exists for safety if mappings change.

  describe("Portal enrollment", () => {
    it("succeeds on 2xx with {success: true}", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(true);
      expect(result.summary).toMatch(/^Assigned to /);
    });

    it("fails on HTTP error (e.g., 403) with the tell-teacher message", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { error: "forbidden" } });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal enrollment failed"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("fails on {success: false} with the generic message", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { success: false } });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
    });

    it("fails on network error (fetch throws)", async () => {
      mockPortalTokenFetch.mockRejectedValue(new Error("ECONNREFUSED"));

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"),
        expect.any(Error)
      );
    });

    it("fails on non-JSON response (data is null)", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: null });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
    });

    it("fails on 2xx with JSON missing success field", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: {} });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
    });

    it("returns the reload message when the mint reports an expired token", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422, reason: "expired" });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("reload the activity");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("returns the tell-teacher message when the mint fails without a shared teacher", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422 });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("logs enrollment attempt and outcome", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await randomAssignment(makeContext());

      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("enrolling user 12345")
      );
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("successfully enrolled")
      );
    });
  });

  describe("Firestore errors", () => {
    it("returns failure when Firestore query throws", async () => {
      mockGetDocs.mockRejectedValue(new Error("Firestore query failed"));

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"),
        expect.any(Error)
      );
    });

    it("gives an unmappable answer the same generic message as a transport failure", async () => {
      // Spring deliberately does not distinguish the two kinds; the fall step does.
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = {
        data: () => ({
          report_state: JSON.stringify({
            authoredState: JSON.stringify({
              prompt: "<p>What is your sex?</p>",
              choices: [{ id: "cX", content: "Unknown Choice" }],
            }),
            interactiveState: JSON.stringify({ selectedChoiceIds: ["cX"] }),
          }),
        }),
      };
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(result.message).not.toContain("tell your teacher");
    });
  });

  describe("alternating assignment integration", () => {
    it("writes to the shipped per-class assignment document, unchanged", async () => {
      // Pinned against a direct sha256 of the shipped input string rather than against
      // perClassScope, so a re-keying of spring's live documents fails here. A changed id would
      // treat every already-assigned spring student as new.
      const docId = createHash("sha256")
        .update("ai4vs-flvs-assignments|interactive-1|https://learn.concord.org|678|ctx-1")
        .digest("hex");

      await randomAssignment(makeContext());

      expect(mockDoc).toHaveBeenCalledWith(`sources/test-source/jobs-task-data/${docId}`);
    });

    it("returns student-friendly error when transaction fails", async () => {
      mockRunTransaction.mockRejectedValueOnce(new Error("transaction failed"));

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"),
        expect.any(Error)
      );
    });

    it("returns correct class name after alternation to control", async () => {
      // Simulate second student: nextAssignment is "control"
      mockTransactionGet.mockResolvedValue({
        exists: true,
        data: () => ({
          strata: {
            "Female|White|High|Mod1": {
              nextAssignment: "control",
              users: { "other-user": "treatment" },
            },
          },
        }),
      });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(true);
      expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
    });

    it("returns student-friendly error when interactiveId is missing", async () => {
      const result = await randomAssignment(makeContext({ interactiveId: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("interactiveId")
      );
    });
  });
});
