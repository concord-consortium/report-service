import { StepContext, StepResult } from "./types";
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

/** Default transport: the offering-read resolves a class_id, then send_class_teachers succeeds. */
const setPortalResponses = (
  offering: { status: number; data: any } = { status: 200, data: { clazz_id: 999 } },
  send: { status: number; data: any } = { status: 200, data: { success: true } },
) => {
  mockPortalTokenFetch.mockImplementation((opts: any) =>
    opts.path.includes("send_class_teachers") ? Promise.resolve(send) : Promise.resolve(offering)
  );
};

const sendCall = () =>
  mockPortalTokenFetch.mock.calls.find(([o]: any[]) => o.path.includes("send_class_teachers"))?.[0];
const sendBody = () => JSON.parse(sendCall().body);

// resolveOriginOffering is NOT mocked in this file; it runs for real over the mocked transport, so
// the offering read is only observable as the fetch calls it makes.
const offeringCalls = () =>
  mockPortalTokenFetch.mock.calls.filter(([o]: any[]) => /\/api\/v1\/offerings\//.test(o.path));

// Mock firebase-functions logger
const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
  },
}));

// Must import after jest.mock
import { sendEmail } from "./send-email";

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
  firebaseJwt: "mock-jwt-token",
  stepResults,
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

describe("sendEmail", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetScopedPortalToken.mockResolvedValue({ ok: true, token: "minted-teacher-token", status: 201 });
    setPortalResponses();
  });

  describe("success", () => {
    it("mints, reads the offering, and sends to send_class_teachers with the resolved class_id", async () => {
      const result = await sendEmail(makeContext());

      expect(result).toEqual({ success: true });

      expect(mockGetScopedPortalToken).toHaveBeenCalledWith(
        expect.objectContaining({ tokenType: "teacher", pilot: "spring-2026" })
      );
      expect(mockGetScopedPortalToken.mock.calls[0][0].classId).toBeUndefined();

      expect(mockPortalTokenFetch).toHaveBeenCalledWith({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/offerings/678",
        method: "GET",
        token: "minted-teacher-token",
      });

      expect(sendCall()).toEqual({
        portalUrl: "https://learn.concord.org",
        path: "/api/v1/emails/send_class_teachers",
        method: "POST",
        token: "minted-teacher-token",
        headers: { "Content-Type": "application/json" },
        body: expect.any(String),
      });

      const body = sendBody();
      expect(body.class_id).toBe("999");
      expect(body.subject).toBe("AI4VS: Student completed pre-test");
      expect(body.message).toContain("AI4VS");
    });

    it("uses default subject when no override provided", async () => {
      await sendEmail(makeContext());

      expect(sendBody().subject).toBe("AI4VS: Student completed pre-test");
    });

    it("includes step results in email body", async () => {
      const stepResults: Record<string, StepResult> = {
        "evaluate-completion": { success: true, message: "8 of 10 questions completed" },
        "lock-activity": { success: true, message: "Pre-test locked" },
      };

      await sendEmail(makeContext({}, stepResults));

      const body = sendBody();
      expect(body.message).toContain("- evaluate-completion: 8 of 10 questions completed");
      expect(body.message).toContain("- lock-activity: Pre-test locked");
    });

    it("includes student link and offering ID in email body", async () => {
      await sendEmail(makeContext());

      const body = sendBody();
      expect(body.message).toContain("Student: https://learn.concord.org/users/12345");
      expect(body.message).toContain("Offering: 678");
    });

    it("logs the email attempt and success", async () => {
      await sendEmail(makeContext());

      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("sending email for user 12345")
      );
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("email sent successfully")
      );
    });
  });

  describe("origin class id handoff", () => {
    it("uses a published originClazzId and skips the offering read", async () => {
      const stepResults: Record<string, StepResult> = {
        "resolve-origin-class": {
          success: true,
          summary: "Origin class ft-2026-bingler",
          output: { originClassWord: "ft-2026-bingler", originClazzId: "30021" },
        },
      };

      const result = await sendEmail(makeContext({}, stepResults));

      expect(result).toEqual({ success: true });
      expect(offeringCalls()).toHaveLength(0);
      expect(sendBody().class_id).toBe("30021");
    });

    it("reads the offering itself when no step published an originClazzId", async () => {
      const result = await sendEmail(makeContext());

      expect(result).toEqual({ success: true });
      expect(offeringCalls()).toHaveLength(1);
      expect(sendBody().class_id).toBe("999");
    });
  });

  describe("email subject", () => {
    it("uses email_subject from request when provided", async () => {
      await sendEmail(makeContext({}, {}, { email_subject: "Custom Subject" }));

      expect(sendBody().subject).toBe("Custom Subject");
    });

    it("strips newlines from email_subject", async () => {
      await sendEmail(makeContext({}, {}, { email_subject: "Line1\nLine2\r\nLine3" }));

      expect(sendBody().subject).toBe("Line1 Line2 Line3");
    });

    it("truncates email_subject to 200 characters", async () => {
      const longSubject = "A".repeat(250);
      await sendEmail(makeContext({}, {}, { email_subject: longSubject }));

      expect(sendBody().subject).toBe("A".repeat(200));
    });

    it("falls back to default when email_subject is empty string", async () => {
      await sendEmail(makeContext({}, {}, { email_subject: "" }));

      expect(sendBody().subject).toBe("AI4VS: Student completed pre-test");
    });

    it("falls back to default when email_subject is non-string", async () => {
      await sendEmail(makeContext({}, {}, { email_subject: 42 }));

      expect(sendBody().subject).toBe("AI4VS: Student completed pre-test");
    });
  });

  describe("email body", () => {
    it("formats step results using summary when available", async () => {
      const stepResults: Record<string, StepResult> = {
        "random-assignment": {
          success: true,
          message: "random-assignment: success",
          summary: "Assigned to FL-spring-2026-GATOR",
        },
      };

      await sendEmail(makeContext({}, stepResults));

      const body = sendBody();
      expect(body.message).toContain("- random-assignment: Assigned to FL-spring-2026-GATOR");
      expect(body.message).not.toContain("random-assignment: success");
    });

    it("falls back to message when summary is not provided", async () => {
      const stepResults: Record<string, StepResult> = {
        "lock-activity": { success: true, message: "Pre-test locked" },
      };

      await sendEmail(makeContext({}, stepResults));

      expect(sendBody().message).toContain("- lock-activity: Pre-test locked");
    });

    it("falls back to 'completed' when neither summary nor message provided", async () => {
      const stepResults: Record<string, StepResult> = {
        "lock-activity": { success: true },
      };

      await sendEmail(makeContext({}, stepResults));

      expect(sendBody().message).toContain("- lock-activity: completed");
    });

    it("never renders a prior step's structured output into the body", async () => {
      const stepResults: Record<string, StepResult> = {
        "random-assignment": {
          success: true,
          summary: "Assigned to FT-fall-2026-A",
          output: { destinationClassWord: "FT-fall-2026-A-secret-handoff" },
        },
      };

      await sendEmail(makeContext({}, stepResults));

      expect(sendBody().message).not.toContain("FT-fall-2026-A-secret-handoff");
    });

    it("handles empty stepResults (no prior steps)", async () => {
      await sendEmail(makeContext({}, {}));

      const body = sendBody();
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
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("platform_id")
      );
    });

    it("returns failure when platform_user_id is missing", async () => {
      const result = await sendEmail(makeContext({ platform_user_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });

    it("returns failure when resource_link_id is missing", async () => {
      const result = await sendEmail(makeContext({ resource_link_id: undefined }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
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

  describe("mint failures", () => {
    it("returns the reload message when the mint reports an expired token", async () => {
      mockGetScopedPortalToken.mockResolvedValue({ ok: false, status: 422, reason: "expired" });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("reload the activity");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
    });
  });

  describe("offering-read failures", () => {
    it("returns the tell-teacher message and does not send on a 403", async () => {
      setPortalResponses({ status: 403, data: { success: false, message: "Not authorized" } });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(sendCall()).toBeUndefined();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("offering-read failed"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("returns the tell-teacher message and does not send on a 404", async () => {
      setPortalResponses({ status: 404, data: null });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(sendCall()).toBeUndefined();
    });

    it("returns the generic message when a 2xx offering has no clazz_id", async () => {
      setPortalResponses({ status: 200, data: {} });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(sendCall()).toBeUndefined();
    });

    it("returns the generic message and does not send on a 5xx", async () => {
      setPortalResponses({ status: 502, data: null });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
      expect(sendCall()).toBeUndefined();
    });
  });

  describe("send_class_teachers error responses", () => {
    it("returns the tell-teacher message on 403", async () => {
      setPortalResponses(undefined, { status: 403, data: { success: false, message: "Not authorized" } });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(result.message).not.toContain("403");
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("Portal returned 403"),
        expect.objectContaining({ status: 403 })
      );
    });

    it("returns the generic message on 500", async () => {
      setPortalResponses(undefined, { status: 500, data: null });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
    });

    it("returns the generic message on a 2xx without success", async () => {
      setPortalResponses(undefined, { status: 200, data: { success: false } });

      const result = await sendEmail(makeContext());

      expect(result.success).toBe(false);
      expect(result.message).toContain("Unable to send notification email");
    });
  });

  describe("network errors", () => {
    it("returns student-friendly message when fetch throws", async () => {
      mockPortalTokenFetch.mockRejectedValue(new Error("ECONNREFUSED"));

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
