import { lockActivity } from "./lock-activity";
import { StepContext } from "./types";
import { IJobDocument } from "../types";

// Mock portal-api
const mockPortalOidcFetch = jest.fn();
jest.mock("../portal-api", () => ({
  portalOidcFetch: (...args: any[]) => mockPortalOidcFetch(...args),
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
});

describe("lockActivity", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe("success", () => {
    it("calls Portal API and returns success on 200", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { locked: true, active: true } });

      const result = await lockActivity(makeContext());

      expect(result).toEqual({ success: true });
      expect(mockPortalOidcFetch).toHaveBeenCalledWith({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/offerings/1190/update_student_metadata",
        method: "PUT",
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
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { locked: true, active: true } });

      const result = await lockActivity(makeContext());

      expect(result).toEqual({ success: true });
    });
  });

  describe("missing context fields", () => {
    it("returns failure when platform_id is missing", async () => {
      const result = await lockActivity(makeContext({ platform_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(mockPortalOidcFetch).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("platform_id")
      );
    });

    it("returns failure when platform_user_id is missing", async () => {
      const result = await lockActivity(makeContext({ platform_user_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(mockPortalOidcFetch).not.toHaveBeenCalled();
    });

    it("returns failure when resource_link_id is missing", async () => {
      const result = await lockActivity(makeContext({ resource_link_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(mockPortalOidcFetch).not.toHaveBeenCalled();
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
    it("returns student-friendly message on 403", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 403, data: { error: "forbidden" } });

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
      expect(result.message).not.toContain("403");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal returned 403"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("returns student-friendly message on 500", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 500, data: null });

      const result = await lockActivity(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to lock your pre-test");
    });
  });

  describe("network errors", () => {
    it("returns student-friendly message when fetch throws", async () => {
      mockPortalOidcFetch.mockRejectedValue(new Error("ECONNREFUSED"));

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
