import { StepContext, StepResult, readStepOutputField } from "./types";
import { IJobDocument } from "../types";
import { createPortalTokenCache, TELL_TEACHER_MESSAGE } from "../portal-api";

// Mock the minted-token entry points; keep the real classifier/messages
const mockGetScopedPortalToken = jest.fn();
const mockPortalTokenFetch = jest.fn();
jest.mock("../portal-api", () => ({
  ...jest.requireActual("../portal-api"),
  getScopedPortalToken: (...args: any[]) => mockGetScopedPortalToken(...args),
  portalTokenFetch: (...args: any[]) => mockPortalTokenFetch(...args),
}));

const mockResolveOriginOffering = jest.fn();
jest.mock("../portal-reads", () => ({
  resolveOriginOffering: (...args: any[]) => mockResolveOriginOffering(...args),
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
import { resolveOriginClass } from "./resolve-origin-class";

const ORIGIN_TOKEN = "minted-origin-token-sentinel";

const makeContext = (overrides: Partial<IJobDocument> = {}): StepContext => ({
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
      request: { task: "ai4vs-flvs", pilot: "fall-2026-green" },
      createdAt: Date.now(),
    },
    ...overrides,
  } as IJobDocument,
  firebaseJwt: "mock-jwt-token",
  stepResults: {},
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

describe("resolveOriginClass", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetScopedPortalToken.mockResolvedValue({ ok: true, token: ORIGIN_TOKEN, status: 201 });
    mockResolveOriginOffering.mockResolvedValue({
      status: 200, offering: { clazzId: 90210, classWord: "ft-2026-bingler" },
    });
  });

  describe("the happy path", () => {
    it("publishes the origin class word for the later steps", async () => {
      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(true);
      expect(result.output?.originClassWord).toBe("ft-2026-bingler");
      expect(result.summary).toBe("Origin class ft-2026-bingler");
    });

    it("mints an unscoped teacher token and reads the run's offering with it", async () => {
      await resolveOriginClass(makeContext());

      expect(mockGetScopedPortalToken).toHaveBeenCalledWith(
        expect.objectContaining({
          portalUrl: "https://learn.concord.org",
          firebaseToken: "mock-jwt-token",
          tokenType: "teacher",
          pilot: "fall-2026-green",
        }),
      );
      expect(mockGetScopedPortalToken.mock.calls[0][0].classId).toBeUndefined();
      expect(mockResolveOriginOffering).toHaveBeenCalledWith(
        "https://learn.concord.org", ORIGIN_TOKEN, "678",
      );
    });

    it("makes no portal write of its own", async () => {
      await resolveOriginClass(makeContext());

      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });
  });

  describe("normalization to the portal's stored form", () => {
    it("publishes the class word in the portal's stored form", async () => {
      // The portal always stores lowercase, so this is a no-op on real data. Asserted anyway,
      // because it is what lets every consumer match exactly instead of case-insensitively.
      mockResolveOriginOffering.mockResolvedValue({
        status: 200, offering: { clazzId: 90210, classWord: "  FT-2026-Bingler  " },
      });

      const result = await resolveOriginClass(makeContext());

      expect(result.output?.originClassWord).toBe("ft-2026-bingler");
    });

    it("treats a whitespace-only class word as absent", async () => {
      mockResolveOriginOffering.mockResolvedValue({
        status: 200, offering: { clazzId: 90210, classWord: "   " },
      });

      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toBe(TELL_TEACHER_MESSAGE);
    });
  });

  describe("required context", () => {
    it("fails when resource_link_id is missing", async () => {
      const result = await resolveOriginClass(makeContext({ resource_link_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to look up your class");
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("resource_link_id"));
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });

    it("fails when the Firebase JWT is missing", async () => {
      const context = makeContext();
      context.firebaseJwt = undefined;

      const result = await resolveOriginClass(context);

      expect(result.success).toBe(false);
      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("Firebase JWT"));
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });
  });

  describe("classified failures", () => {
    it("gives the reload message when the mint reports an expired token", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422, reason: "expired" });

      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("reload the activity");
      expect(mockResolveOriginOffering).not.toHaveBeenCalled();
    });

    it("gives the tell-teacher message when the offering read is forbidden", async () => {
      mockResolveOriginOffering.mockResolvedValue({ status: 403 });

      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("offering-read failed"),
        expect.objectContaining({ status: 403 }),
      );
    });

    it("gives the generic message when the offering read fails with a 500", async () => {
      mockResolveOriginOffering.mockResolvedValue({ status: 500 });

      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to look up your class");
    });

    it("logs at error with the offering id when a 200 carries no class_word", async () => {
      mockResolveOriginOffering.mockResolvedValue({ status: 200, offering: { clazzId: 90210 } });

      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toBe(TELL_TEACHER_MESSAGE);
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("offering 678 returned no class_word"),
      );
    });

    it("fails with the generic message when the read throws", async () => {
      mockResolveOriginOffering.mockRejectedValue(new Error("ECONNREFUSED"));

      const result = await resolveOriginClass(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to look up your class");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unexpected error"), expect.any(Error),
      );
    });
  });

  describe("token secrecy", () => {
    it("puts no token value in any log argument or in the returned result", async () => {
      const result = await resolveOriginClass(makeContext());

      const logged = JSON.stringify(mockLoggerInfo.mock.calls.concat(mockLoggerError.mock.calls));
      expect(logged).not.toContain(ORIGIN_TOKEN);
      expect(JSON.stringify(result)).not.toContain(ORIGIN_TOKEN);
    });
  });
});

describe("readStepOutputField", () => {
  const withOutput = (outputs: Array<StepResult["output"]>): Record<string, StepResult> => {
    const results: Record<string, StepResult> = {};
    outputs.forEach((output, i) => {
      results[`step-${i}`] = { success: true, output };
    });
    return results;
  };

  it("returns undefined when no step published the field", () => {
    expect(readStepOutputField({}, "originClassWord")).toBeUndefined();
    expect(readStepOutputField(withOutput([undefined, {}]), "originClassWord")).toBeUndefined();
  });

  it("skips a step whose output is absent, and one whose value is blank", () => {
    const results = withOutput([undefined, { originClassWord: "  " }, { originClassWord: "ft-2026-long" }]);

    expect(readStepOutputField(results, "originClassWord")).toBe("ft-2026-long");
  });

  it("takes the first non-blank value in insertion order, which is pipeline order", () => {
    const results = withOutput([{ originClassWord: "ft-2026-first" }, { originClassWord: "ft-2026-second" }]);

    expect(readStepOutputField(results, "originClassWord")).toBe("ft-2026-first");
  });

  it("trims the value it returns", () => {
    expect(readStepOutputField(withOutput([{ originClassWord: "  ft-2026-torres " }]), "originClassWord"))
      .toBe("ft-2026-torres");
  });

  it("reads each field independently, so two producers do not collide", () => {
    const results = withOutput([{ originClassWord: "ft-2026-newlon" }, { destinationClassWord: "ft-2026-newlon-gator" }]);

    expect(readStepOutputField(results, "originClassWord")).toBe("ft-2026-newlon");
    expect(readStepOutputField(results, "destinationClassWord")).toBe("ft-2026-newlon-gator");
  });
});
