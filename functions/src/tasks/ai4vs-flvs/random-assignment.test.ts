import { StepContext, StepResult } from "./types";
import { IJobDocument } from "../types";

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

// Mock portal-api
const mockPortalOidcFetch = jest.fn();
jest.mock("../portal-api", () => ({
  portalOidcFetch: (...args: any[]) => mockPortalOidcFetch(...args),
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

// Must import after jest.mock
import { randomAssignment } from "./random-assignment";

/** Build a mock Firestore answer doc with the given prompt and selected choices. */
const makeAnswerDoc = (
  prompt: string,
  choices: Array<{ id: string; content: string }>,
  selectedChoiceIds: string[],
) => ({
  data: () => ({
    report_state: JSON.stringify({
      authoredState: JSON.stringify({ prompt, choices }),
      interactiveState: JSON.stringify({ selectedChoiceIds }),
    }),
  }),
});

/** Standard demographic answer docs for a "happy path" student. */
const makeStandardAnswerDocs = (overrides?: {
  genderChoice?: string;
  gradeChoice?: string;
  moduleChoice?: string;
  raceChoices?: string[];
}) => {
  const gender = overrides?.genderChoice ?? "Female";
  const grade = overrides?.gradeChoice ?? "10th Grade";
  const module = overrides?.moduleChoice ?? "Module 1: One-Variable Equations and Inequalities";
  const races = overrides?.raceChoices ?? ["White"];

  const genderIdMap: Record<string, string> = { Female: "c1", Male: "c2", "Prefer not to answer": "c3" };
  const gradeIdMap: Record<string, string> = {
    "6th Grade": "g6", "7th Grade": "g7", "8th Grade": "g8", "9th Grade": "g9",
    "10th Grade": "g10", "11th Grade": "g11", "12th Grade": "g12", "Other": "gO",
  };
  const moduleIdMap: Record<string, string> = {
    "Module 1: One-Variable Equations and Inequalities": "m1",
    "Module 2: Two-Variable Linear Functions": "m2",
    "Module 3: Systems of Two Linear Equations": "m3",
    "Other/not sure": "mO",
  };
  const raceIdMap: Record<string, string> = {
    White: "rW", "Black or African American": "rB",
    "Hispanic or Latino": "rH", "Prefer to not answer": "rP",
  };

  return {
    docs: [
      makeAnswerDoc(
        "<p>What is your sex?</p>",
        [
          { id: "c1", content: "Female" },
          { id: "c2", content: "Male" },
          { id: "c3", content: "Prefer not to answer" },
        ],
        [genderIdMap[gender]],
      ),
      makeAnswerDoc(
        "<p>What grade are you in?</p>",
        [
          { id: "g6", content: "6th Grade" }, { id: "g7", content: "7th Grade" },
          { id: "g8", content: "8th Grade" }, { id: "g9", content: "9th Grade" },
          { id: "g10", content: "10th Grade" }, { id: "g11", content: "11th Grade" },
          { id: "g12", content: "12th Grade" }, { id: "gO", content: "Other" },
        ],
        [gradeIdMap[grade]],
      ),
      makeAnswerDoc(
        "<p>Which Algebra 1 module are you currently working on?</p>",
        [
          { id: "m1", content: "Module 1: One-Variable Equations and Inequalities" },
          { id: "m2", content: "Module 2: Two-Variable Linear Functions" },
          { id: "m3", content: "Module 3: Systems of Two Linear Equations" },
          { id: "mO", content: "Other/not sure" },
        ],
        [moduleIdMap[module] ?? "mO"],
      ),
      makeAnswerDoc(
        "<p>What is your race or ethnicity? (Select all that apply)</p>",
        [
          { id: "rW", content: "White" },
          { id: "rB", content: "Black or African American" },
          { id: "rH", content: "Hispanic or Latino" },
          { id: "rP", content: "Prefer to not answer" },
        ],
        races.map(r => raceIdMap[r]),
      ),
    ],
  };
};

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
});

describe("randomAssignment", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });
    mockGetDocs.mockResolvedValue(makeStandardAnswerDocs());
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

    it("calls portalOidcFetch with correct JSON body", async () => {
      await randomAssignment(makeContext());

      expect(mockPortalOidcFetch).toHaveBeenCalledWith({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/students/add_to_class",
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: expect.any(String),
      });

      const callArgs = mockPortalOidcFetch.mock.calls[0][0];
      const body = JSON.parse(callArgs.body);
      expect(body.user_id).toBe("12345");
      expect(body.clazz_id).toMatch(/^portal-class-/);
    });
  });

  describe("prompt substring matching", () => {
    it("matches case-insensitively", async () => {
      // Default prompts contain mixed case ("What is your sex?") and substrings are lowercase
      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(true);
    });

    it("fails when no doc matches a prompt substring", async () => {
      // Remove the Gender answer doc (first doc)
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs.splice(0, 1);
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Gender");
    });

    it("fails when multiple docs match the same prompt substring", async () => {
      const snapshot = makeStandardAnswerDocs();
      // Duplicate the Gender answer doc
      snapshot.docs.push(snapshot.docs[0]);
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Multiple answer docs"),
        // Note: no second arg for this error path
      );
    });
  });

  describe("choice content resolution", () => {
    it("resolves choice IDs to content text via authoredState.choices", async () => {
      // The happy path already exercises this; verify via successful result
      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(true);
    });

    it("fails when selectedChoiceId not found in authoredState.choices", async () => {
      const badDoc = {
        data: () => ({
          report_state: JSON.stringify({
            authoredState: JSON.stringify({
              prompt: "<p>What is your sex?</p>",
              choices: [{ id: "c1", content: "Female" }],
            }),
            interactiveState: JSON.stringify({ selectedChoiceIds: ["nonexistent-id"] }),
          }),
        }),
      };
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = badDoc;
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Choice ID"),
        // Note: no second arg
      );
    });
  });

  describe("category mapping", () => {
    it("maps 'Prefer not to answer' gender to Female", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({
        genderChoice: "Prefer not to answer",
      }));

      const result = await randomAssignment(makeContext());

      // "Prefer not to answer" → Female, with White/High/Mod1 → Female|White|High|Mod1 → control
      expect(result.success).toBe(true);
      expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
    });

    it("maps 6th/7th/8th Grade and Other to Mid", async () => {
      for (const grade of ["6th Grade", "7th Grade", "8th Grade", "Other"]) {
        mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ gradeChoice: grade }));

        const result = await randomAssignment(makeContext());

        // Female/White/Mid/Mod1 → treatment
        expect(result.success).toBe(true);
        expect(result.summary).toBe("Assigned to FL-spring-2026-GATOR");
      }
    });

    it("maps 9th–12th Grade to High", async () => {
      for (const grade of ["9th Grade", "10th Grade", "11th Grade", "12th Grade"]) {
        mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ gradeChoice: grade }));

        const result = await randomAssignment(makeContext());

        // Female/White/High/Mod1 → control
        expect(result.success).toBe(true);
        expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
      }
    });

    it("maps Module 3+ and Other/not sure to Other (default fallback)", async () => {
      for (const mod of ["Module 3: Systems of Two Linear Equations", "Other/not sure"]) {
        mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ moduleChoice: mod }));

        const result = await randomAssignment(makeContext());

        // Female/White/High/Other → control
        expect(result.success).toBe(true);
        expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
      }
    });

    it("fails with logged error on unmapped Gender choice", async () => {
      const badDoc = {
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
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = badDoc;
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Unmapped Gender choice")
      );
    });

    it("fails with logged error on unmapped Grade choice", async () => {
      const badDoc = {
        data: () => ({
          report_state: JSON.stringify({
            authoredState: JSON.stringify({
              prompt: "<p>What grade are you in?</p>",
              choices: [{ id: "gX", content: "Kindergarten" }],
            }),
            interactiveState: JSON.stringify({ selectedChoiceIds: ["gX"] }),
          }),
        }),
      };
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[1] = badDoc;
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Unmapped Grade choice")
      );
    });
  });

  describe("Race binary reduction", () => {
    it("maps only-White to White", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ raceChoices: ["White"] }));

      const result = await randomAssignment(makeContext());

      // Female/White/High/Mod1 → control
      expect(result.success).toBe(true);
      expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
    });

    it("maps White + another race to non-White", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({
        raceChoices: ["White", "Hispanic or Latino"],
      }));

      const result = await randomAssignment(makeContext());

      // Female/non-White/High/Mod1 → control
      expect(result.success).toBe(true);
      expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
    });

    it("maps only non-White race to non-White", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({
        raceChoices: ["Black or African American"],
      }));

      const result = await randomAssignment(makeContext());

      // Female/non-White/High/Mod1 → control
      expect(result.success).toBe(true);
      expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
    });

    it("maps 'Prefer to not answer' only to non-White", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({
        raceChoices: ["Prefer to not answer"],
      }));

      const result = await randomAssignment(makeContext());

      // Female/non-White/High/Mod1 → control
      expect(result.success).toBe(true);
      expect(result.summary).toBe("Assigned to FL-spring-2026-SHARK");
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

  describe("missing/empty answers", () => {
    it("names dimension in error when answer doc is missing for one dimension", async () => {
      const snapshot = makeStandardAnswerDocs();
      // Remove the Module answer doc (third doc)
      snapshot.docs.splice(2, 1);
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Module");
      expect(result.message).toContain("Please complete");
    });

    it("names all dimensions when multiple answer docs are missing", async () => {
      mockGetDocs.mockResolvedValue({ docs: [] });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Gender");
      expect(result.message).toContain("Grade");
      expect(result.message).toContain("Module");
      expect(result.message).toContain("Race");
    });

    it("names dimension in error when selectedChoiceIds is empty", async () => {
      const emptyDoc = {
        data: () => ({
          report_state: JSON.stringify({
            authoredState: JSON.stringify({
              prompt: "<p>What is your sex?</p>",
              choices: [{ id: "c1", content: "Female" }],
            }),
            interactiveState: JSON.stringify({ selectedChoiceIds: [] }),
          }),
        }),
      };
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = emptyDoc;
      mockGetDocs.mockResolvedValue(snapshot);

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Gender");
      expect(result.message).toContain("Please complete");
    });
  });

  // Note: The "missing stratum" code path (assignment table miss) is not reachable
  // through the public API because the category mappings produce exactly the 2×2×2×3 = 24
  // combinations covered by ASSIGNMENT_TABLE. The "all 24 assignment strata" test.each
  // above proves table completeness. The guard exists for safety if mappings change.

  describe("Portal enrollment", () => {
    it("succeeds on 2xx with {success: true}", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(true);
      expect(result.summary).toMatch(/^Assigned to /);
    });

    it("fails on HTTP error (e.g., 403)", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 403, data: { error: "forbidden" } });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal enrollment failed"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("fails on {success: false}", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: false } });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
    });

    it("fails on network error (fetch throws)", async () => {
      mockPortalOidcFetch.mockRejectedValue(new Error("ECONNREFUSED"));

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"),
        expect.any(Error)
      );
    });

    it("fails on non-JSON response (data is null)", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: null });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
    });

    it("fails on 2xx with JSON missing success field", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: {} });

      const result = await randomAssignment(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to complete your assignment");
    });

    it("logs enrollment attempt and outcome", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

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
  });

  describe("cleanup", () => {
    it("calls cleanup even on error", async () => {
      mockGetDocs.mockRejectedValue(new Error("Firestore query failed"));

      await randomAssignment(makeContext());

      expect(mockCleanup).toHaveBeenCalled();
    });

    it("handles cleanup failure gracefully", async () => {
      mockCleanup.mockRejectedValueOnce(new Error("cleanup error"));

      const result = await randomAssignment(makeContext());

      // Step still succeeds despite cleanup failure
      expect(result.success).toBe(true);
      expect(mockLoggerWarn).toHaveBeenCalledWith(
        expect.stringContaining("cleanup failed"),
        expect.any(Error)
      );
    });
  });
});
