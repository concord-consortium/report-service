import * as functions from "firebase-functions";
import admin from "firebase-admin";
import cors from "cors";
import { CloudTasksClient } from "@google-cloud/tasks";
import { IJobInfo, IJobDocument, TASK_WORKER_QUEUE, TASK_WORKER_LOCATION } from "./types";
import { makeFailureResponse, updateJobInfo, getJobDocument, guardedUpdate } from "./task-helpers";
import { executeTask } from "./task-worker";

const corsHandler = cors({ origin: true });
const db = () => admin.firestore();
const tasksClient = new CloudTasksClient();

export const submitTask = functions.https.onRequest((req, res) => {
  corsHandler(req, res, async () => {
    try {
      // Method check
      if (req.method !== "POST") {
        res.status(405).json(makeFailureResponse(
          { task: "" },
          `Method ${req.method} not allowed. Use POST.`
        ));
        return;
      }

      const body = req.body;

      // Extract Firebase JWT from Authorization header (if present) to forward to task handler.
      // Not all tasks need it — individual handlers decide whether to require it.
      const authHeader = req.headers?.authorization;
      const firebaseJwt = authHeader?.startsWith("Bearer ") ? authHeader.slice(7) : undefined;

      // Route: cancel vs. job creation
      if (body.action === "cancel") {
        await handleCancel(body, res);
      } else {
        await handleCreateJob(body, res, firebaseJwt);
      }
    } catch (error) {
      functions.logger.error("submitTask: unexpected error", error);
      res.status(500).json(makeFailureResponse(
        { task: "" },
        `Unexpected server error: ${String(error)}`
      ));
    }
  });
});

async function handleCreateJob(
  body: any,
  res: functions.Response,
  firebaseJwt?: string
): Promise<void> {
  const { request, context } = body;

  // Validate required fields
  if (!request?.task) {
    res.status(400).json(makeFailureResponse(
      request ?? { task: "" },
      "Missing required field: request.task"
    ));
    return;
  }
  if (!context?.source_key) {
    res.status(400).json(makeFailureResponse(
      request,
      "Missing required field: context.source_key"
    ));
    return;
  }

  // Validate source_key format (no path traversal)
  if (!/^[a-zA-Z0-9._-]+$/.test(context.source_key)) {
    res.status(400).json(makeFailureResponse(
      request,
      "Invalid context.source_key format"
    ));
    return;
  }

  // Create job document with Firestore auto-ID
  const now = Date.now();
  const jobsCollection = db().collection(`sources/${context.source_key}/jobs`);
  const docRef = jobsCollection.doc(); // auto-generated ID
  const jobPath = docRef.path; // e.g., "sources/{source_key}/jobs/{id}"

  const jobInfo: IJobInfo = {
    version: 1,
    id: docRef.id,
    status: "queued",
    request,
    createdAt: now,
  };

  // Whitelist context fields — don't spread untrusted input.
  // Authenticated: interactiveId, user_type, source_key, resource_url, tool_id,
  //   platform_id, platform_user_id, context_id, resource_link_id, remote_endpoint
  // Anonymous: interactiveId, user_type, source_key, resource_url, tool_id,
  //   run_key, tool_user_id, platform_user_id
  const ALLOWED_CONTEXT_KEYS = [
    "interactiveId", "user_type", "source_key", "resource_url", "tool_id",
    "platform_id", "platform_user_id", "context_id", "resource_link_id",
    "remote_endpoint", "run_key", "tool_user_id",
  ];
  const safeContext: Record<string, any> = {};
  for (const key of ALLOWED_CONTEXT_KEYS) {
    if (context[key] !== undefined) {
      safeContext[key] = context[key];
    }
  }

  const jobDocument: IJobDocument = {
    ...safeContext,
    jobInfo,
  };

  // Write the job document (client sees it immediately via onSnapshot)
  await docRef.set(jobDocument);

  // Enqueue the task for async processing
  try {
    if (process.env.FUNCTIONS_EMULATOR === "true") {
      // In the emulator, CloudTasksClient connects to the real GCP API (not the emulator).
      // Call the worker logic directly instead.
      executeTask(jobPath, firebaseJwt).catch(err => {
        functions.logger.error("submitTask: emulator direct execution failed", err);
      });
    } else {
      // Production: enqueue via CloudTasksClient.createTask() which returns the full task
      // resource including its `name` (the task path needed for cancel/deleteTask).
      const project = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
      if (!project) {
        throw new Error("Could not determine GCP project ID from environment");
      }
      const queue = `projects/${project}/locations/${TASK_WORKER_LOCATION}/queues/${TASK_WORKER_QUEUE}`;
      const taskWorkerUrl = `https://${TASK_WORKER_LOCATION}-${project}.cloudfunctions.net/${TASK_WORKER_QUEUE}`;
      const serviceAccountEmail = `${project}@appspot.gserviceaccount.com`;

      const [task] = await tasksClient.createTask({
        parent: queue,
        task: {
          httpRequest: {
            httpMethod: "POST",
            url: taskWorkerUrl,
            headers: { "Content-Type": "application/json" },
            body: Buffer.from(JSON.stringify({ data: { jobPath, firebaseJwt } })).toString("base64"),
            oidcToken: {
              serviceAccountEmail,
              audience: taskWorkerUrl,
            },
          },
        },
      });

      // Store taskPath for cancel support (best-effort)
      if (task.name) {
        try {
          await db().doc(jobPath).update({ taskPath: task.name });
        } catch (taskPathError) {
          functions.logger.warn("submitTask: failed to store taskPath (cancel will not work for this job)", taskPathError);
        }
      }
    }
  } catch (enqueueError) {
    // Enqueue failed — update job to failure
    functions.logger.error("submitTask: enqueue failed", enqueueError);
    const failureInfo: Partial<IJobInfo> = {
      status: "failure",
      result: { message: `Failed to enqueue task: ${String(enqueueError)}` },
      updatedAt: Date.now(),
      completedAt: Date.now(),
    };
    await updateJobInfo(jobPath, failureInfo);
    res.status(500).json({ ...jobInfo, ...failureInfo });
    return;
  }

  // Return the IJobInfo portion
  res.status(200).json(jobInfo);
}

async function handleCancel(
  body: any,
  res: functions.Response
): Promise<void> {
  const { jobId, context } = body;

  // Validate required fields
  if (!jobId) {
    res.status(400).json(makeFailureResponse(
      { task: "" },
      "Missing required field: jobId"
    ));
    return;
  }
  if (!context?.source_key) {
    res.status(400).json(makeFailureResponse(
      { task: "" },
      "Missing required field: context.source_key"
    ));
    return;
  }

  // Validate source_key and jobId format (no path traversal)
  if (!/^[a-zA-Z0-9._-]+$/.test(context.source_key)) {
    res.status(400).json(makeFailureResponse(
      { task: "" },
      "Invalid context.source_key format"
    ));
    return;
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(jobId)) {
    res.status(400).json(makeFailureResponse(
      { task: "" },
      "Invalid jobId format"
    ));
    return;
  }

  const jobPath = `sources/${context.source_key}/jobs/${jobId}`;
  const jobDoc = await getJobDocument(jobPath);

  // Job not found
  if (!jobDoc) {
    res.status(404).json(makeFailureResponse(
      { task: "" },
      "Job not found"
    ));
    return;
  }

  const { jobInfo } = jobDoc;

  // Defensive: validate jobInfo exists
  if (!jobInfo?.status) {
    res.status(500).json(makeFailureResponse(
      { task: "" },
      "Job document has invalid jobInfo"
    ));
    return;
  }

  // Already in final state — no-op
  if (jobInfo.status === "success" || jobInfo.status === "failure" || jobInfo.status === "cancelled") {
    res.status(200).json(jobInfo);
    return;
  }

  // Attempt to delete the Cloud Task (requires CloudTasksClient)
  if (jobDoc.taskPath) {
    try {
      await tasksClient.deleteTask({ name: jobDoc.taskPath });
    } catch (deleteError) {
      // Swallow — task may already be in-flight or completed
      functions.logger.warn("submitTask cancel: failed to delete Cloud Task", deleteError);
    }
  }

  // Cancel via transaction — only if still in queued/running state
  const now = Date.now();
  const cancelled = await guardedUpdate(jobPath, ["queued", "running"], {
    "jobInfo.status": "cancelled",
    "jobInfo.updatedAt": now,
    "jobInfo.completedAt": now,
  });

  if (cancelled) {
    res.status(200).json({
      ...jobInfo,
      status: "cancelled",
      updatedAt: now,
      completedAt: now,
    });
  } else {
    // Another transition won the race — return current state
    const freshDoc = await getJobDocument(jobPath);
    res.status(200).json(freshDoc?.jobInfo ?? jobInfo);
  }
}
