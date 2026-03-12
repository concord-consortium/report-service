import * as functions from "firebase-functions";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { getJobDocument, markRunning, markComplete } from "./task-helpers";
import { testSuccess } from "./test-success";
import { testFailure } from "./test-failure";

interface TaskPayload {
  jobPath: string;
}

// Task router: maps task name to handler function
const taskHandlers: Record<string, (jobPath: string, jobDoc: any) => Promise<void>> = {
  success: testSuccess,
  failure: testFailure,
};

/**
 * Core task execution logic — shared by onTaskDispatched (production)
 * and direct invocation (emulator, where CloudTasksClient is unavailable).
 */
export async function executeTask(jobPath: string): Promise<void> {
  const jobDoc = await getJobDocument(jobPath);

  if (!jobDoc) {
    functions.logger.warn(`executeTask: job document not found at ${jobPath}, skipping`);
    return;
  }

  const { jobInfo } = jobDoc;
  if (!jobInfo || !jobInfo.status || !jobInfo.request?.task) {
    functions.logger.error(`executeTask: invalid jobInfo at ${jobPath}`);
    if (jobInfo) {
      await markComplete(jobPath, "failure", {
        message: "Invalid job document: missing required jobInfo fields",
      });
    }
    return;
  }

  // markRunning uses a transaction: only transitions queued → running.
  // Returns false if the job was cancelled (or otherwise not queued).
  const started = await markRunning(jobPath);
  if (!started) {
    functions.logger.info(`executeTask: job at ${jobPath} is not in queued state (status: ${jobInfo.status}), skipping`);
    return;
  }

  const taskName = jobInfo.request.task;
  const handler = taskHandlers[taskName];

  if (!handler) {
    await markComplete(jobPath, "failure", {
      message: `Unknown task type: "${taskName}"`,
    });
    return;
  }

  try {
    await handler(jobPath, jobDoc);
  } catch (error) {
    await markComplete(jobPath, "failure", {
      message: `Task "${taskName}" failed: ${String(error)}`,
    });
  }
}

export const taskWorker = onTaskDispatched(
  {
    maxInstances: 1,
    rateLimits: { maxConcurrentDispatches: 1 },
  },
  async (req) => {
    const { jobPath } = req.data as TaskPayload;

    if (!jobPath) {
      functions.logger.error("taskWorker: missing jobPath in payload, skipping");
      return;
    }

    await executeTask(jobPath);
  }
);
