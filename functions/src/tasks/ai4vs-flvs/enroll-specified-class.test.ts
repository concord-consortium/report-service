import { StepContext, StepResult } from "./types";
import { IJobDocument } from "../types";
import { createPortalTokenCache } from "../portal-api";

// Mock the minted-token entry points; keep the real classifier/messages
const mockGetScopedPortalToken = jest.fn();
const mockPortalTokenFetch = jest.fn();
jest.mock("../portal-api", () => ({
  ...jest.requireActual("../portal-api"),
  getScopedPortalToken: (...args: any[]) => mockGetScopedPortalToken(...args),
  portalTokenFetch: (...args: any[]) => mockPortalTokenFetch(...args),
}));

const mockLookupClassByWord = jest.fn();
jest.mock("../portal-reads", () => ({
  lookupClassByWord: (...args: any[]) => mockLookupClassByWord(...args),
}));

const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
  },
}));

// Must import after jest.mock
import { enrollSpecifiedClass } from "./enroll-specified-class";

const DESTINATION_WORD = "FT-fall-2026-A";
const TEACHER_NAME_SENTINEL = "Lovelace";
const ORIGIN_TOKEN = "minted-origin-token-sentinel";
const ENROLL_TOKEN = "minted-class-token-sentinel";

const destinationClass = {
  id: 30001,
  name: "FT-fall-2026-A",
  classWord: DESTINATION_WORD,
  teachers: [{ id: "https://learn.concord.org/users/7", user_id: 7, first_name: "Ada", last_name: TEACHER_NAME_SENTINEL }],
  offerings: [],
};

const makeContext = (
  requestOverrides: Record<string, any> = { target_class_word: DESTINATION_WORD },
  stepResults: Record<string, StepResult> = {},
  overrides: Partial<IJobDocument> = {},
): StepContext => ({
  jobPath: "sources/test-source/jobs/test-job-123",
  jobDoc: {
    platform_id: "https://learn.concord.org",
    platform_user_id: 12345,
    resource_link_id: "678",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "fall-2026-fulltime", ...requestOverrides },
      createdAt: Date.now(),
    },
    ...overrides,
  } as IJobDocument,
  firebaseJwt: "mock-jwt-token",
  stepResults,
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

const enrollCall = () =>
  mockPortalTokenFetch.mock.calls.find(([o]: any[]) => o.path.includes("add_to_class"))?.[0];
const enrollBody = () => JSON.parse(enrollCall().body);
const mintCallFor = (classId?: string) =>
  mockGetScopedPortalToken.mock.calls.find(([o]: any[]) => o.classId === classId)?.[0];

describe("enrollSpecifiedClass", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetScopedPortalToken.mockImplementation((opts: any) =>
      Promise.resolve({
        ok: true,
        token: opts.classId === undefined ? ORIGIN_TOKEN : ENROLL_TOKEN,
        status: 201,
      })
    );
    mockLookupClassByWord.mockResolvedValue({ status: 200, class: destinationClass });
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { success: true } });
  });

  describe("destination resolved from the authored word", () => {
    it("looks up the authored word and enrolls into the class it resolves to", async () => {
      const result = await enrollSpecifiedClass(makeContext());

      expect(result).toEqual({ success: true, summary: "Enrolled in FT-fall-2026-A" });

      expect(mockLookupClassByWord).toHaveBeenCalledWith(
        "https://learn.concord.org", ORIGIN_TOKEN, DESTINATION_WORD
      );
      expect(mintCallFor(undefined)).toEqual(
        expect.objectContaining({ tokenType: "teacher", pilot: "fall-2026-fulltime" })
      );
      expect(mintCallFor("30001")).toEqual(
        expect.objectContaining({ tokenType: "teacher", classId: "30001" })
      );
      expect(enrollCall()).toEqual({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/students/add_to_class",
        method: "POST",
        token: ENROLL_TOKEN,
        headers: { "Content-Type": "application/json" },
        body: expect.any(String),
      });
      expect(enrollBody()).toEqual({ user_id: "12345", clazz_id: "30001" });
    });

    it("takes the destination id from the lookup, so the authored config carries none", async () => {
      mockLookupClassByWord.mockResolvedValue({ status: 200, class: { ...destinationClass, id: 40002 } });
      const context = makeContext();

      await enrollSpecifiedClass(context);

      expect(enrollBody().clazz_id).toBe("40002");
      expect(mintCallFor("40002")).toBeDefined();
      expect(JSON.stringify(context.jobDoc.jobInfo.request)).not.toContain("40002");
    });

    it("trims surrounding whitespace from the authored word", async () => {
      await enrollSpecifiedClass(makeContext({ target_class_word: `  ${DESTINATION_WORD}  ` }));

      expect(mockLookupClassByWord).toHaveBeenCalledWith(
        expect.any(String), expect.any(String), DESTINATION_WORD
      );
    });
  });

  describe("destination resolved from a prior step's handoff", () => {
    it("uses output.destinationClassWord when no word is authored", async () => {
      const result = await enrollSpecifiedClass(makeContext({}, {
        "random-assignment": { success: true, output: { destinationClassWord: DESTINATION_WORD } },
      }));

      expect(result.success).toBe(true);
      expect(mockLookupClassByWord).toHaveBeenCalledWith(
        expect.any(String), expect.any(String), DESTINATION_WORD
      );
      expect(enrollBody().clazz_id).toBe("30001");
    });

    it("takes the first prior step that set a destination word", async () => {
      await enrollSpecifiedClass(makeContext({}, {
        "evaluate-completion": { success: true, message: "8 of 10 questions completed" },
        "random-assignment": { success: true, output: { destinationClassWord: DESTINATION_WORD } },
        "later-step": { success: true, output: { destinationClassWord: "FT-fall-2026-Z" } },
      }));

      expect(mockLookupClassByWord).toHaveBeenCalledWith(
        expect.any(String), expect.any(String), DESTINATION_WORD
      );
    });

    it("proceeds when the authored word equals the handoff word", async () => {
      const result = await enrollSpecifiedClass(makeContext(
        { target_class_word: DESTINATION_WORD },
        { "random-assignment": { success: true, output: { destinationClassWord: DESTINATION_WORD } } },
      ));

      expect(result.success).toBe(true);
      expect(mockLookupClassByWord).toHaveBeenCalledWith(
        expect.any(String), expect.any(String), DESTINATION_WORD
      );
    });
  });

  describe("destination word problems", () => {
    it("fails without any portal call when the authored word differs from the handoff", async () => {
      const result = await enrollSpecifiedClass(makeContext(
        { target_class_word: "FT-fall-2026-B" },
        { "random-assignment": { success: true, output: { destinationClassWord: DESTINATION_WORD } } },
      ));

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("conflicting destination words")
      );
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
      expect(mockLookupClassByWord).not.toHaveBeenCalled();
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("fails without any portal call when neither a param nor a handoff supplies a word", async () => {
      const result = await enrollSpecifiedClass(makeContext({}, {
        "evaluate-completion": { success: true, message: "8 of 10 questions completed" },
      }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to enroll you in your class");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("no destination class word")
      );
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("treats a blank authored word as missing", async () => {
      const result = await enrollSpecifiedClass(makeContext({ target_class_word: "   " }));

      expect(result.success).toBe(false);
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });
  });

  describe("missing context fields", () => {
    it("returns failure when platform_id is missing", async () => {
      const result = await enrollSpecifiedClass(makeContext(undefined, {}, { platform_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to enroll you in your class");
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("platform_id"));
    });

    it("returns failure when platform_user_id is missing", async () => {
      const result = await enrollSpecifiedClass(makeContext(undefined, {}, { platform_user_id: undefined }));

      expect(result.success).toBe(false);
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });

    it("returns failure when the Firebase JWT is missing", async () => {
      const context = makeContext();
      context.firebaseJwt = undefined;

      const result = await enrollSpecifiedClass(context);

      expect(result.success).toBe(false);
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("missing Firebase JWT"));
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });
  });

  describe("re-running the step", () => {
    it("succeeds again when the portal reports success for an already-enrolled student", async () => {
      const context = makeContext();

      const first = await enrollSpecifiedClass(context);
      const second = await enrollSpecifiedClass(context);

      expect(first).toEqual({ success: true, summary: "Enrolled in FT-fall-2026-A" });
      expect(second).toEqual({ success: true, summary: "Enrolled in FT-fall-2026-A" });
    });
  });

  describe("mint failures", () => {
    it("returns the tell-teacher message and does not enroll when no teacher is shared with the destination", async () => {
      mockGetScopedPortalToken.mockImplementation((opts: any) =>
        opts.classId === undefined
          ? Promise.resolve({ ok: true, token: ORIGIN_TOKEN, status: 201 })
          : Promise.resolve({ ok: false, status: 422 })
      );

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(enrollCall()).toBeUndefined();
    });

    it("returns the reload message when the origin mint reports an expired token", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422, reason: "expired" });

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("reload the activity");
      expect(mockLookupClassByWord).not.toHaveBeenCalled();
    });
  });

  describe("lookup failures", () => {
    it("returns the tell-teacher message and logs the attempted class word on a 400", async () => {
      mockLookupClassByWord.mockResolvedValue({ status: 400 });

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("class lookup failed"),
        { status: 400, class_word: DESTINATION_WORD }
      );
      expect(enrollCall()).toBeUndefined();
      expect(mintCallFor("30001")).toBeUndefined();
    });

    it("returns the generic message on a 5xx", async () => {
      mockLookupClassByWord.mockResolvedValue({ status: 502 });

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to enroll you in your class");
    });
  });

  describe("enroll failures", () => {
    it("returns the tell-teacher message on a 403", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { success: false, message: "Not authorized" } });

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(result.message).not.toContain("403");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal enrollment failed"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("returns the generic message on a 2xx without success", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { success: false } });

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to enroll you in your class");
    });

    it("returns the generic message on a 500", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 500, data: null });

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to enroll you in your class");
    });

    it("returns the generic message when the fetch throws", async () => {
      mockPortalTokenFetch.mockRejectedValue(new Error("ECONNREFUSED"));

      const result = await enrollSpecifiedClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to enroll you in your class");
      expect(result.message).not.toContain("ECONNREFUSED");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"),
        expect.any(Error)
      );
    });
  });

  describe("token and teacher-name secrecy", () => {
    const loggedText = () =>
      JSON.stringify(mockLoggerInfo.mock.calls.concat(mockLoggerError.mock.calls));

    const expectNoSecrets = (result: StepResult) => {
      for (const sentinel of [ORIGIN_TOKEN, ENROLL_TOKEN, TEACHER_NAME_SENTINEL]) {
        expect(loggedText()).not.toContain(sentinel);
        expect(JSON.stringify(result)).not.toContain(sentinel);
      }
    };

    it("leaks no token and no teacher name on the success path", async () => {
      expectNoSecrets(await enrollSpecifiedClass(makeContext()));
    });

    it("leaks no token and no teacher name when the lookup fails", async () => {
      mockLookupClassByWord.mockResolvedValue({ status: 400 });

      expectNoSecrets(await enrollSpecifiedClass(makeContext()));
    });

    it("leaks no token and no teacher name when the cross-class mint fails", async () => {
      mockGetScopedPortalToken.mockImplementation((opts: any) =>
        opts.classId === undefined
          ? Promise.resolve({ ok: true, token: ORIGIN_TOKEN, status: 201 })
          : Promise.resolve({ ok: false, status: 422 })
      );

      expectNoSecrets(await enrollSpecifiedClass(makeContext()));
    });

    it("leaks no token and no teacher name when the enroll fails", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { success: false, message: "Not authorized" } });

      expectNoSecrets(await enrollSpecifiedClass(makeContext()));
    });
  });
});
