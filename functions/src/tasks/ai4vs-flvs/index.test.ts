import { IJobDocument } from "../types";
import { StepContext, StepHandler } from "./types";

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

// Mock task-helpers
const mockMarkComplete = jest.fn();
const mockSetProcessingMessage = jest.fn();
jest.mock("../task-helpers", () => ({
  markComplete: (...args: any[]) => mockMarkComplete(...args),
  setProcessingMessage: (...args: any[]) => mockSetProcessingMessage(...args),
}));

// Mock all step handlers — capture stepResults snapshots at call time
const stepResultsSnapshots: Record<string, Record<string, any>> = {};

const mockEvaluateCompletion = jest.fn();
const mockLockCurrentOffering = jest.fn();
const mockRandomAssignment = jest.fn();
const mockSendEmail = jest.fn();
const mockResolveOriginClass = jest.fn();
const mockFallRandomAssignment = jest.fn();
const mockEnrollSpecifiedClass = jest.fn();
const mockOpenTargetOffering = jest.fn();

jest.mock("./evaluate-completion", () => ({
  evaluateCompletion: (ctx: StepContext) => {
    stepResultsSnapshots["evaluate-completion"] = { ...ctx.stepResults };
    return mockEvaluateCompletion(ctx);
  },
}));
// Keyed on the PILOT, not the entry name. One handler now runs under four different entry names
// (spring's lock-activity plus lock-pre-test / lock-curriculum / lock-post-test), and the runner
// does not tell a handler which entry it is executing, so the pilot is the only thing in scope that
// distinguishes the four. A single hardcoded key silently collides once more than one pipeline is
// driven in this file.
jest.mock("./lock-current-offering", () => ({
  lockCurrentOffering: (ctx: StepContext) => {
    stepResultsSnapshots[`lock:${ctx.jobDoc.jobInfo.request.pilot}`] = { ...ctx.stepResults };
    return mockLockCurrentOffering(ctx);
  },
}));
jest.mock("./random-assignment", () => ({
  randomAssignment: (ctx: StepContext) => {
    stepResultsSnapshots["random-assignment"] = { ...ctx.stepResults };
    return mockRandomAssignment(ctx);
  },
}));
jest.mock("./send-email", () => ({
  sendEmail: (ctx: StepContext) => {
    stepResultsSnapshots["send-email"] = { ...ctx.stepResults };
    return mockSendEmail(ctx);
  },
}));
// fall-random-assignment has to be mocked: unmocked it throws "fetch is not defined" through
// demographics → firebase-client → firebase/auth, failing the whole file rather than one assertion.
// The other three load fine unmocked and are stubbed only so every handler the table reaches is
// stubbed from one place.
jest.mock("./resolve-origin-class", () => ({
  resolveOriginClass: (ctx: StepContext) => mockResolveOriginClass(ctx),
}));
jest.mock("./fall-random-assignment", () => ({
  fallRandomAssignment: (ctx: StepContext) => mockFallRandomAssignment(ctx),
}));
jest.mock("./enroll-specified-class", () => ({
  enrollSpecifiedClass: (ctx: StepContext) => mockEnrollSpecifiedClass(ctx),
}));
jest.mock("./open-target-offering", () => ({
  openTargetOffering: (ctx: StepContext) => mockOpenTargetOffering(ctx),
}));

import { ai4vsFlvs, PIPELINES } from "./index";
import { TELL_TEACHER_MESSAGE } from "../portal-api";
import { evaluateCompletion } from "./evaluate-completion";
import { lockCurrentOffering } from "./lock-current-offering";
import { randomAssignment } from "./random-assignment";
import { sendEmail } from "./send-email";
import { resolveOriginClass } from "./resolve-origin-class";
import { fallRandomAssignment } from "./fall-random-assignment";
import { enrollSpecifiedClass } from "./enroll-specified-class";
import { openTargetOffering } from "./open-target-offering";

describe("PIPELINES table", () => {
  // A duplicate entry name is invisible everywhere else: index.ts's `stepResults[step.name] = result`
  // is the single writer, so the first result is overwritten, and send-email renders one line per key,
  // so the teacher's email loses a line while the run still reports success. Driving a pipeline cannot
  // detect it, because collapsing is exactly what a duplicate does.
  //
  // it.each rather than a loop inside one `it`: once more pipelines exist, a loop reports
  // "expected 3, received 2" without naming which pipeline is at fault.
  it.each(Object.entries(PIPELINES))("gives every step in %s a distinct name", (_pilot, steps) => {
    const names = steps.map(step => step.name);
    expect(new Set(names).size).toBe(names.length);
  });

  // Handler identity rather than entry name, so this asserts the wiring instead of restating the
  // table's own labels. Each imported handler resolves to this file's mock, which is the same
  // reference index.ts holds. The explicit table type is required: written as `[...] as const`,
  // jest 24's it.each typings flatten the tuple and PIPELINES[pilot] fails to compile.
  const EXPECTED_HANDLERS: Array<[string, StepHandler[]]> = [
    ["spring-2026", [evaluateCompletion, randomAssignment, lockCurrentOffering, sendEmail]],
    ["fall-2026-green", [
      evaluateCompletion, resolveOriginClass, fallRandomAssignment,
      enrollSpecifiedClass, lockCurrentOffering, sendEmail,
    ]],
    ["fall-2026-blue", [lockCurrentOffering, sendEmail]],
    ["fall-2026-orange", [resolveOriginClass, lockCurrentOffering, openTargetOffering, sendEmail]],
  ];
  it.each(EXPECTED_HANDLERS)("selects the expected ordered handlers for %s", (pilot, handlers) => {
    expect(PIPELINES[pilot].map(step => step.handler)).toEqual(handlers);
  });
});

describe("orchestrator stepResults accumulation", () => {
  const makeJobDoc = (): IJobDocument => ({
    platform_id: "https://learn.concord.org",
    platform_user_id: 12345,
    resource_link_id: "678",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "spring-2026" },
      createdAt: Date.now(),
    },
  } as IJobDocument);

  beforeEach(() => {
    jest.clearAllMocks();
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org";
    mockMarkComplete.mockResolvedValue(undefined);
    mockSetProcessingMessage.mockResolvedValue(undefined);
    // Clear snapshots
    for (const key of Object.keys(stepResultsSnapshots)) {
      delete stepResultsSnapshots[key];
    }
  });

  it("stepResults is empty for the first step handler", async () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true, message: "8 of 10 completed" });
    mockLockCurrentOffering.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: true, message: "stub" });
    mockSendEmail.mockResolvedValue({ success: true });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(stepResultsSnapshots["evaluate-completion"]).toEqual({});
  });

  it("stepResults contains first step's result when second handler runs", async () => {
    const evalResult = { success: true, message: "8 of 10 completed" };
    mockEvaluateCompletion.mockResolvedValue(evalResult);
    mockRandomAssignment.mockResolvedValue({ success: true, message: "stub" });
    mockLockCurrentOffering.mockResolvedValue({ success: true });
    mockSendEmail.mockResolvedValue({ success: true });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(stepResultsSnapshots["random-assignment"]).toEqual({
      "evaluate-completion": evalResult,
    });
  });

  it("stepResults contains all prior results when send-email runs", async () => {
    const evalResult = { success: true, message: "8 of 10 completed" };
    const lockResult = { success: true };
    const assignResult = { success: true, message: "stub", summary: "Assigned to GATOR" };
    mockEvaluateCompletion.mockResolvedValue(evalResult);
    mockLockCurrentOffering.mockResolvedValue(lockResult);
    mockRandomAssignment.mockResolvedValue(assignResult);
    mockSendEmail.mockResolvedValue({ success: true });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(stepResultsSnapshots["send-email"]).toEqual({
      "evaluate-completion": evalResult,
      "lock-activity": lockResult,
      "random-assignment": assignResult,
    });
  });

  it("does not record the failed step's result when pipeline aborts", async () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true, message: "ok" });
    mockRandomAssignment.mockResolvedValue({ success: false, message: "assignment failed" });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(mockLockCurrentOffering).not.toHaveBeenCalled();
    expect(mockSendEmail).not.toHaveBeenCalled();

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "failure",
      expect.objectContaining({ message: "assignment failed" })
    );
  });

  // The failure line's level, which decides whether "the student has not answered enough questions
  // yet" shows up in an error count. It is the most frequent way a run stops, on all four pilots.
  it("logs an unexpected step failure at error level", async () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: false, message: "assignment failed" });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining('failed at step "random-assignment"'));
    expect(mockLoggerWarn).not.toHaveBeenCalled();
  });

  it("logs a step failure the step declares expected at warn level instead", async () => {
    mockEvaluateCompletion.mockResolvedValue({
      success: false, expected: true, message: "You have completed 2 of 4 required questions.",
    });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(mockLoggerWarn).toHaveBeenCalledWith(expect.stringContaining('failed at step "evaluate-completion"'));
    expect(mockLoggerError).not.toHaveBeenCalled();
    // Same student message either way: the flag governs the log level and nothing else.
    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "failure",
      expect.objectContaining({ message: "You have completed 2 of 4 required questions." })
    );
  });

  it("updates the final success message", async () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true });
    mockLockCurrentOffering.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: true });
    mockSendEmail.mockResolvedValue({ success: true });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });
});

describe("configurable completion message", () => {
  const makeJobDocWithMessage = (completion_message?: any): IJobDocument => ({
    platform_id: "https://learn.concord.org",
    platform_user_id: 12345,
    resource_link_id: "678",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: {
        task: "ai4vs-flvs",
        pilot: "spring-2026",
        ...(completion_message !== undefined ? { completion_message } : {}),
      },
      createdAt: Date.now(),
    },
  } as IJobDocument);

  const setupAllStepsSuccess = () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true });
    mockLockCurrentOffering.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: true });
    mockSendEmail.mockResolvedValue({ success: true });
  };

  beforeEach(() => {
    jest.clearAllMocks();
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org";
    mockMarkComplete.mockResolvedValue(undefined);
    mockSetProcessingMessage.mockResolvedValue(undefined);
    for (const key of Object.keys(stepResultsSnapshots)) {
      delete stepResultsSnapshots[key];
    }
    setupAllStepsSuccess();
  });

  it("uses custom completion_message when provided as non-empty string", async () => {
    await ai4vsFlvs("jobs/test", makeJobDocWithMessage("Great job! You're all set."), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Great job! You're all set." })
    );
  });

  it("falls back to default when completion_message is not provided", async () => {
    await ai4vsFlvs("jobs/test", makeJobDocWithMessage(), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });

  it("falls back to default when completion_message is empty string", async () => {
    await ai4vsFlvs("jobs/test", makeJobDocWithMessage(""), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });

  it("falls back to default when completion_message is whitespace-only", async () => {
    await ai4vsFlvs("jobs/test", makeJobDocWithMessage("   \t  "), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });

  it("falls back to default when completion_message is a number", async () => {
    await ai4vsFlvs("jobs/test", makeJobDocWithMessage(42), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });

  it("falls back to default when completion_message is a boolean", async () => {
    await ai4vsFlvs("jobs/test", makeJobDocWithMessage(true), "jwt-token");

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });
});

describe("platform_id host gate", () => {
  const makeJobDoc = (platform_id: any): IJobDocument => ({
    platform_id,
    platform_user_id: 12345,
    resource_link_id: "678",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "spring-2026" },
      createdAt: Date.now(),
    },
  } as IJobDocument);

  beforeEach(() => {
    jest.clearAllMocks();
    process.env.TRUSTED_PORTAL_HOSTS = "learn.concord.org";
    mockMarkComplete.mockResolvedValue(undefined);
    mockSetProcessingMessage.mockResolvedValue(undefined);
    mockEvaluateCompletion.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: true });
    mockLockCurrentOffering.mockResolvedValue({ success: true });
    mockSendEmail.mockResolvedValue({ success: true });
  });

  it("fails at setup for an untrusted platform_id without running any step", async () => {
    await ai4vsFlvs("jobs/test", makeJobDoc("https://evil.com"), "jwt-token");

    expect(mockEvaluateCompletion).not.toHaveBeenCalled();
    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "failure",
      { message: TELL_TEACHER_MESSAGE }
    );
  });

  it("fails at setup for a non-https platform_id on a trusted host", async () => {
    await ai4vsFlvs("jobs/test", makeJobDoc("http://learn.concord.org"), "jwt-token");

    expect(mockEvaluateCompletion).not.toHaveBeenCalled();
    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "failure",
      { message: TELL_TEACHER_MESSAGE }
    );
  });

  it("logs the rejected host only, never a token", async () => {
    await ai4vsFlvs("jobs/test", makeJobDoc("https://evil.com"), "jwt-token");

    const rejectionLog = mockLoggerError.mock.calls.find(
      ([msg]: any[]) => typeof msg === "string" && msg.includes("rejected untrusted platform_id")
    );
    expect(rejectionLog).toBeDefined();
    expect(rejectionLog[1]).toEqual({ host: "evil.com" });
    expect(JSON.stringify(mockLoggerError.mock.calls)).not.toContain("jwt-token");
  });

  it("proceeds into the pipeline for a trusted https platform_id", async () => {
    await ai4vsFlvs("jobs/test", makeJobDoc("https://learn.concord.org"), "jwt-token");

    expect(mockEvaluateCompletion).toHaveBeenCalled();
    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "success",
      expect.objectContaining({ message: "Done! Your teacher has been notified." })
    );
  });
});
