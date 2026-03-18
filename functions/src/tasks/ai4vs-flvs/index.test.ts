import { IJobDocument } from "../types";
import { StepContext } from "./types";

// Mock firebase-functions logger
const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
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
const mockLockActivity = jest.fn();
const mockRandomAssignment = jest.fn();
const mockSendEmail = jest.fn();

jest.mock("./evaluate-completion", () => ({
  evaluateCompletion: (ctx: StepContext) => {
    stepResultsSnapshots["evaluate-completion"] = { ...ctx.stepResults };
    return mockEvaluateCompletion(ctx);
  },
}));
jest.mock("./lock-activity", () => ({
  lockActivity: (ctx: StepContext) => {
    stepResultsSnapshots["lock-activity"] = { ...ctx.stepResults };
    return mockLockActivity(ctx);
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

import { ai4vsFlvs } from "./index";

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
    mockMarkComplete.mockResolvedValue(undefined);
    mockSetProcessingMessage.mockResolvedValue(undefined);
    // Clear snapshots
    for (const key of Object.keys(stepResultsSnapshots)) {
      delete stepResultsSnapshots[key];
    }
  });

  it("stepResults is empty for the first step handler", async () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true, message: "8 of 10 completed" });
    mockLockActivity.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: true, message: "stub" });
    mockSendEmail.mockResolvedValue({ success: true });

    await ai4vsFlvs("jobs/test", makeJobDoc(), "jwt-token");

    expect(stepResultsSnapshots["evaluate-completion"]).toEqual({});
  });

  it("stepResults contains first step's result when second handler runs", async () => {
    const evalResult = { success: true, message: "8 of 10 completed" };
    mockEvaluateCompletion.mockResolvedValue(evalResult);
    mockRandomAssignment.mockResolvedValue({ success: true, message: "stub" });
    mockLockActivity.mockResolvedValue({ success: true });
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
    mockLockActivity.mockResolvedValue(lockResult);
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

    expect(mockLockActivity).not.toHaveBeenCalled();
    expect(mockSendEmail).not.toHaveBeenCalled();

    expect(mockMarkComplete).toHaveBeenCalledWith(
      "jobs/test",
      "failure",
      expect.objectContaining({ message: "assignment failed" })
    );
  });

  it("updates the final success message", async () => {
    mockEvaluateCompletion.mockResolvedValue({ success: true });
    mockLockActivity.mockResolvedValue({ success: true });
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
    mockLockActivity.mockResolvedValue({ success: true });
    mockRandomAssignment.mockResolvedValue({ success: true });
    mockSendEmail.mockResolvedValue({ success: true });
  };

  beforeEach(() => {
    jest.clearAllMocks();
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
