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

// Mock firebase-functions logger
const mockLoggerError = jest.fn();
const mockLoggerWarn = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: jest.fn(),
    error: (...args: any[]) => mockLoggerError(...args),
    warn: (...args: any[]) => mockLoggerWarn(...args),
  },
}));

// Must import after jest.mock
import { DIMENSIONS, Dimension, DemographicsOutcome, readDemographics } from "./demographics";
import { SPRING_PRE_TEST } from "./pre-tests";
import { makeAnswerDoc, makeStandardAnswerDocs } from "./answer-doc-fixtures";

const read = (dimensions: readonly Dimension[] = DIMENSIONS): Promise<DemographicsOutcome> =>
  readDemographics({
    logPrefix: "test-step",
    jobPath: "sources/test-source/jobs/test-job-123",
    firebaseJwt: "mock-jwt-token",
    source_key: "test-source",
    platform_id: "https://learn.concord.org",
    resource_link_id: "678",
    context_id: "ctx-1",
    platform_user_id: "12345",
    preTest: SPRING_PRE_TEST,
    dimensions,
  });

/** The categories of a successful read, or a failure if the read did not succeed. */
const categoriesOf = (outcome: DemographicsOutcome) => {
  if (!outcome.ok) {
    throw new Error(`expected a successful read, got ${outcome.kind}`);
  }
  return outcome.categories;
};

describe("readDemographics", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetDocs.mockResolvedValue(makeStandardAnswerDocs());
  });

  describe("prompt substring matching", () => {
    it("matches case-insensitively", async () => {
      // The fixture prompts are mixed case ("What is your sex?") and the substrings are lowercase.
      expect(categoriesOf(await read()).Gender).toBe("Female");
    });

    it("reports a dimension as incomplete when no doc matches its prompt substring", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs.splice(0, 1);
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read();

      expect(outcome).toEqual({ ok: false, kind: "incomplete", missing: ["Gender"] });
    });

    it("is unmappable when multiple docs match the same prompt substring", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs.push(snapshot.docs[0]);
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read();

      expect(outcome).toEqual({ ok: false, kind: "unmappable" });
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("Multiple answer docs"));
    });

    it("skips a doc whose report_state cannot be parsed, and warns", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs.push({ data: () => ({ report_state: "not json" }) } as any);
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read();

      expect(outcome.ok).toBe(true);
      expect(mockLoggerWarn).toHaveBeenCalledWith(
        expect.stringContaining("unparseable report_state"),
        expect.any(Error),
      );
    });
  });

  describe("choice content resolution", () => {
    it("resolves choice IDs to content text via authoredState.choices", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ genderChoice: "Male" }));

      expect(categoriesOf(await read()).Gender).toBe("Male");
    });

    it("is unmappable when a selectedChoiceId is not in authoredState.choices", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = makeAnswerDoc(
        "<p>What is your sex?</p>", [{ id: "c1", content: "Female" }], ["nonexistent-id"],
      );
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read();

      expect(outcome).toEqual({ ok: false, kind: "unmappable" });
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("Choice ID"));
    });
  });

  describe("category mapping", () => {
    it("maps 'Prefer not to answer' gender to Female", async () => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ genderChoice: "Prefer not to answer" }));

      expect(categoriesOf(await read()).Gender).toBe("Female");
    });

    it.each(["6th Grade", "7th Grade", "8th Grade", "Other"])("maps %s to Mid", async (grade) => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ gradeChoice: grade }));

      expect(categoriesOf(await read()).Grade).toBe("Mid");
    });

    it.each(["9th Grade", "10th Grade", "11th Grade", "12th Grade"])("maps %s to High", async (grade) => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ gradeChoice: grade }));

      expect(categoriesOf(await read()).Grade).toBe("High");
    });

    it.each([
      ["Module 1: One-Variable Equations and Inequalities", "Mod1"],
      ["Module 2: Two-Variable Linear Functions", "Mod2"],
      ["Module 3: Systems of Two Linear Equations", "Other"],
      ["Other/not sure", "Other"],
    ])("maps module %s to %s", async (choice, expected) => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ moduleChoice: choice }));

      expect(categoriesOf(await read()).Module).toBe(expected);
    });

    it("is unmappable on an unmapped Gender choice", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = makeAnswerDoc(
        "<p>What is your sex?</p>", [{ id: "cX", content: "Unknown Choice" }], ["cX"],
      );
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read();

      expect(outcome).toEqual({ ok: false, kind: "unmappable" });
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("Unmapped Gender choice"));
    });

    it("is unmappable on an unmapped Grade choice", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[1] = makeAnswerDoc(
        "<p>What grade are you in?</p>", [{ id: "gX", content: "Kindergarten" }], ["gX"],
      );
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read();

      expect(outcome).toEqual({ ok: false, kind: "unmappable" });
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("Unmapped Grade choice"));
    });

    it("names the pre-test in the log line, so a wording fault is attributed to one config", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = makeAnswerDoc(
        "<p>What is your sex?</p>", [{ id: "cX", content: "Unknown Choice" }], ["cX"],
      );
      mockGetDocs.mockResolvedValue(snapshot);

      await read();

      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining(SPRING_PRE_TEST.label));
    });
  });

  describe("Race binary reduction", () => {
    it.each([
      [["White"], "White"],
      [["White", "Hispanic or Latino"], "non-White"],
      [["Black or African American"], "non-White"],
      [["Prefer to not answer"], "non-White"],
    ])("maps %j to %s", async (choices, expected) => {
      mockGetDocs.mockResolvedValue(makeStandardAnswerDocs({ raceChoices: choices as string[] }));

      expect(categoriesOf(await read()).Race).toBe(expected);
    });
  });

  describe("missing/empty answers", () => {
    it("names the dimension when one answer doc is missing", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs.splice(2, 1);
      mockGetDocs.mockResolvedValue(snapshot);

      expect(await read()).toEqual({ ok: false, kind: "incomplete", missing: ["Module"] });
    });

    it("names every dimension when no answer docs exist", async () => {
      mockGetDocs.mockResolvedValue({ docs: [] });

      expect(await read()).toEqual({
        ok: false, kind: "incomplete", missing: ["Gender", "Grade", "Module", "Race"],
      });
    });

    it("names the dimension when selectedChoiceIds is empty", async () => {
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs[0] = makeAnswerDoc("<p>What is your sex?</p>", [{ id: "c1", content: "Female" }], []);
      mockGetDocs.mockResolvedValue(snapshot);

      expect(await read()).toEqual({ ok: false, kind: "incomplete", missing: ["Gender"] });
    });

    it("logs the missing dimensions at error level", async () => {
      mockGetDocs.mockResolvedValue({ docs: [] });

      await read();

      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("missing or incomplete answers for Gender, Grade, Module, Race"),
      );
    });
  });

  describe("the requested dimension set", () => {
    it("reads only the requested dimensions, with no answer docs for the others present", async () => {
      // A full-time student answers Gender and Race only. The Grade and Module docs do not exist.
      const snapshot = makeStandardAnswerDocs();
      snapshot.docs = [snapshot.docs[0], snapshot.docs[3]];
      mockGetDocs.mockResolvedValue(snapshot);

      const outcome = await read(["Gender", "Race"]);

      expect(outcome).toEqual({ ok: true, categories: { Gender: "Female", Race: "White" } });
    });
  });

  describe("transport failures", () => {
    it("is failed, not unmappable, when the Firestore query throws", async () => {
      mockGetDocs.mockRejectedValue(new Error("Firestore query failed"));

      const outcome = await read();

      expect(outcome).toEqual({ ok: false, kind: "failed" });
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"), expect.any(Error),
      );
    });
  });

  describe("cleanup", () => {
    it("releases the client Firestore instance on success", async () => {
      await read();

      expect(mockCleanup).toHaveBeenCalled();
    });

    it("releases it on error too", async () => {
      mockGetDocs.mockRejectedValue(new Error("Firestore query failed"));

      await read();

      expect(mockCleanup).toHaveBeenCalled();
    });

    it("warns but does not fail the read when cleanup throws", async () => {
      mockCleanup.mockRejectedValueOnce(new Error("cleanup error"));

      const outcome = await read();

      expect(outcome.ok).toBe(true);
      expect(mockLoggerWarn).toHaveBeenCalledWith(
        expect.stringContaining("cleanup failed"), expect.any(Error),
      );
    });
  });
});
