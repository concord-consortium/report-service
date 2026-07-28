import { lockActivity } from "./lock-activity";
import { StepContext } from "./types";
import { IJobDocument } from "../types";
import { createPortalTokenCache } from "../portal-api";

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

const makeContext = (overrides: Partial<IJobDocument> = {}): StepContext => ({
  jobPath: "sources/test-source/jobs/test-job-123",
  jobDoc: {
    platform_id: "https://learn.concord.org",
    platform_user_id: 27,
    resource_link_id: "1190",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "spring-2026" },
      createdAt: Date.now(),
    },
    ...overrides,
  } as IJobDocument,
  firebaseJwt: "mock-jwt-token",
  stepResults: {},
  tokenCache: createPortalTokenCache(),
});

describe("lockActivity", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetScopedPortalToken.mockResolvedValue({ ok: true, token: "minted-teacher-token", status: 201 });
    mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { locked: true, active: true } });
  });

  describe("success", () => {
    it("mints the origin token and locks with it, preserving the form body", async () => {
      const result = await lockActivity(makeContext());

      expect(result).toEqual({ success: true });
      expect(mockGetScopedPortalToken).toHaveBeenCalledWith(
        expect.objectContaining({
          portalUrl: "https://learn.concord.org",
          firebaseToken: "mock-jwt-token",
          tokenType: "teacher",
          pilot: "spring-2026",
        })
      );
      expect(mockGetScopedPortalToken.mock.calls[0][0].classId).toBeUndefined();
      expect(mockPortalTokenFetch).toHaveBeenCalledWith({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/offerings/1190/update_student_metadata",
        method: "PUT",
        token: "minted-teacher-token",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "locked=true&user_id=27",
      });
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("locking offering 1190")
      );
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("successfully locked")
      );
    });

    it("treats already-locked activity as success (idempotency)", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 200, data: { locked: true, active: true } });

      const result = await lockActivity(makeContext());

      expect(result).toEqual({ success: true });
    });
  });

  describe("missing context fields", () => {
    it("returns failure when platform_id is missing", async () => {
      const result = await lockActivity(makeContext({ platform_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("platform_id")
      );
    });

    it("returns failure when platform_user_id is missing", async () => {
      const result = await lockActivity(makeContext({ platform_user_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("returns failure when resource_link_id is missing", async () => {
      const result = await lockActivity(makeContext({ resource_link_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("reports all missing fields in the log", async () => {
      await lockActivity(makeContext({
        platform_id: undefined,
        platform_user_id: undefined,
        resource_link_id: undefined,
      }));

      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringMatching(/platform_id.*platform_user_id.*resource_link_id/)
      );
    });
  });

  describe("Portal error responses", () => {
    it("returns the tell-teacher message on 403", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 403, data: { error: "forbidden" } });

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(result.message).not.toContain("403");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal returned 403"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("returns the generic message on 500", async () => {
      mockPortalTokenFetch.mockResolvedValue({ status: 500, data: null });

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
    });
  });

  describe("mint failures", () => {
    it("returns the reload message when the mint reports an expired token", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422, reason: "expired" });

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("reload the activity");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });

    it("returns the tell-teacher message on a mint auth failure", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 403 });

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });
  });

  describe("network errors", () => {
    it("returns student-friendly message when fetch throws", async () => {
      mockPortalTokenFetch.mockRejectedValue(new Error("ECONNREFUSED"));

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(result.message).not.toContain("ECONNREFUSED");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("request failed"),
        expect.any(Error)
      );
    });
  });
});
