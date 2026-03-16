import { sendEmail } from "./send-email";
import { StepContext, StepResult } from "./types";
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

const makeContext = (
  overrides: Partial<IJobDocument> = {},
  stepResults: Record<string, StepResult> = {},
  requestOverrides: Record<string, any> = {},
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
      request: { task: "ai4vs-flvs", pilot: "spring-2026", ...requestOverrides },
      createdAt: Date.now(),
    },
    ...overrides,
  } as IJobDocument,
  stepResults,
});

describe("sendEmail", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe("success", () => {
    it("calls Portal API with correct JSON body and returns success on 200", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const result = await sendEmail(makeContext());

      expect(result).toEqual({ success: true });
      expect(mockPortalOidcFetch).toHaveBeenCalledWith({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/emails/oidc_send",
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: expect.any(String),
      });

      // Verify the body is valid JSON with subject and message
      const callArgs = mockPortalOidcFetch.mock.calls[0][0];
      const body = JSON.parse(callArgs.body);
      expect(body.subject).toBe("AI4VS: Student completed pre-test");
      expect(body.message).toContain("AI4VS");
    });

    it("uses default subject when no override provided", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext());

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.subject).toBe("AI4VS: Student completed pre-test");
    });

    it("includes step results in email body", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const stepResults: Record<string, StepResult> = {
        "evaluate-completion": { success: true, message: "8 of 10 questions completed" },
        "lock-activity": { success: true, message: "Pre-test locked" },
      };

      await sendEmail(makeContext({}, stepResults));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.message).toContain("- evaluate-completion: 8 of 10 questions completed");
      expect(body.message).toContain("- lock-activity: Pre-test locked");
    });

    it("includes student link and offering ID in email body", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext());

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.message).toContain("Student: https://learn.concord.org/users/12345");
      expect(body.message).toContain("Offering: 678");
    });

    it("logs the email attempt and success", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext());

      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("sending email for user 12345")
      );
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("email sent successfully")
      );
    });
  });

  describe("email subject", () => {
    it("uses email_subject from request when provided", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext({}, {}, { email_subject: "Custom Subject" }));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.subject).toBe("Custom Subject");
    });

    it("strips newlines from email_subject", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext({}, {}, { email_subject: "Line1\nLine2\r\nLine3" }));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.subject).toBe("Line1 Line2 Line3");
    });

    it("truncates email_subject to 200 characters", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const longSubject = "A".repeat(250);
      await sendEmail(makeContext({}, {}, { email_subject: longSubject }));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.subject).toBe("A".repeat(200));
    });

    it("falls back to default when email_subject is empty string", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext({}, {}, { email_subject: "" }));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.subject).toBe("AI4VS: Student completed pre-test");
    });

    it("falls back to default when email_subject is non-string", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext({}, {}, { email_subject: 42 }));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.subject).toBe("AI4VS: Student completed pre-test");
    });
  });

  describe("email body", () => {
    it("formats step results using summary when available", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const stepResults: Record<string, StepResult> = {
        "random-assignment": {
          success: true,
          message: "random-assignment: success",
          summary: "Assigned to FL-spring-2026-GATOR",
        },
      };

      await sendEmail(makeContext({}, stepResults));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.message).toContain("- random-assignment: Assigned to FL-spring-2026-GATOR");
      expect(body.message).not.toContain("random-assignment: success");
    });

    it("falls back to message when summary is not provided", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const stepResults: Record<string, StepResult> = {
        "lock-activity": { success: true, message: "Pre-test locked" },
      };

      await sendEmail(makeContext({}, stepResults));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.message).toContain("- lock-activity: Pre-test locked");
    });

    it("falls back to 'completed' when neither summary nor message provided", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      const stepResults: Record<string, StepResult> = {
        "lock-activity": { success: true },
      };

      await sendEmail(makeContext({}, stepResults));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.message).toContain("- lock-activity: completed");
    });

    it("handles empty stepResults (no prior steps)", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 200, data: { success: true } });

      await sendEmail(makeContext({}, {}));

      const body = JSON.parse(mockPortalOidcFetch.mock.calls[0][0].body);
      expect(body.message).toContain("Pipeline Results:");
      // No step result lines after "Pipeline Results:"
      const lines = body.message.split("\n");
      const pipelineIdx = lines.indexOf("Pipeline Results:");
      expect(pipelineIdx).toBeGreaterThan(-1);
      expect(lines.length).toBe(pipelineIdx + 1);
    });
  });

  describe("missing context fields", () => {
    it("returns failure when platform_id is missing", async () => {
      const result = await sendEmail(makeContext({ platform_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(mockPortalOidcFetch).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("platform_id")
      );
    });

    it("returns failure when platform_user_id is missing", async () => {
      const result = await sendEmail(makeContext({ platform_user_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(mockPortalOidcFetch).not.toHaveBeenCalled();
    });

    it("returns failure when resource_link_id is missing", async () => {
      const result = await sendEmail(makeContext({ resource_link_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(mockPortalOidcFetch).not.toHaveBeenCalled();
    });

    it("reports all missing fields in the log", async () => {
      await sendEmail(makeContext({
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

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(result.message).not.toContain("403");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal returned 403"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("returns student-friendly message on 500", async () => {
      mockPortalOidcFetch.mockResolvedValue({ status: 500, data: null });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
    });
  });

  describe("network errors", () => {
    it("returns student-friendly message when fetch throws", async () => {
      mockPortalOidcFetch.mockRejectedValue(new Error("ECONNREFUSED"));

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(result.message).not.toContain("ECONNREFUSED");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("request failed"),
        expect.any(Error)
      );
    });
  });
});
