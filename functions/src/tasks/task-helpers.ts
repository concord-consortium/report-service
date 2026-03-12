import admin from "firebase-admin";
import { IJobInfo, IJobDocument } from "./types";

const db = () => admin.firestore();

/**
 * Read the job document and return the full document data.
 * Returns null if the document does not exist.
 */
export const getJobDocument = async (jobPath: string): Promise<IJobDocument | null> => {
  const doc = await db().doc(jobPath).get();
  if (!doc.exists) return null;
  return doc.data() as IJobDocument;
};

/**
 * Update jobInfo fields on the job document using dot-notation
 * so we don't overwrite the entire jobInfo object.
 */
export const updateJobInfo = async (
  jobPath: string,
  updates: Partial<IJobInfo>
): Promise<void> => {
  const dotUpdates: Record<string, any> = {};
  for (const [key, value] of Object.entries(updates)) {
    dotUpdates[`jobInfo.${key}`] = value;
  }
  await db().doc(jobPath).update(dotUpdates);
};

/**
 * Atomically update jobInfo fields only if the current status is in the allowed set.
 * Returns true if the update was applied, false if skipped (doc missing or wrong status).
 */
export const guardedUpdate = async (
  jobPath: string,
  allowedStatuses: IJobInfo["status"][],
  updates: Record<string, any>
): Promise<boolean> => {
  const docRef = db().doc(jobPath);
  return db().runTransaction(async (txn) => {
    const snap = await txn.get(docRef);
    if (!snap.exists) {
      return false;
    }
    const data = snap.data() as IJobDocument;
    if (!allowedStatuses.includes(data.jobInfo?.status)) {
      return false;
    }
    txn.update(docRef, updates);
    return true;
  });
};

/**
 * Transition job to "running" status with startedAt and updatedAt.
 * Returns false if the job was cancelled (or otherwise not in "queued" state).
 */
export const markRunning = async (jobPath: string): Promise<boolean> => {
  const now = Date.now();
  return guardedUpdate(jobPath, ["queued"], {
    "jobInfo.status": "running",
    "jobInfo.startedAt": now,
    "jobInfo.updatedAt": now,
  });
};

/**
 * Transition job to a final status ("success" or "failure") with result.
 * Skips if job is already in a final state (cancelled/success/failure).
 */
export const markComplete = async (
  jobPath: string,
  status: "success" | "failure",
  result: { message: string; processingMessage?: string } & Record<string, any>
): Promise<void> => {
  const now = Date.now();
  await guardedUpdate(jobPath, ["queued", "running"], {
    "jobInfo.status": status,
    "jobInfo.result": result,
    "jobInfo.updatedAt": now,
    "jobInfo.completedAt": now,
  });
};

/**
 * Set the processingMessage on a running job (before the task delay).
 * Skips if job is no longer running (e.g. cancelled).
 */
export const setProcessingMessage = async (
  jobPath: string,
  processingMessage: string
): Promise<void> => {
  await guardedUpdate(jobPath, ["running"], {
    "jobInfo.result": { message: "", processingMessage },
    "jobInfo.updatedAt": Date.now(),
  });
};

/**
 * Create a failure IJobInfo for HTTP error responses (no Firestore document).
 */
export const makeFailureResponse = (
  request: { task: string } & Record<string, any>,
  message: string
): IJobInfo => {
  const now = Date.now();
  return {
    version: 1,
    id: "",
    status: "failure",
    request,
    result: { message },
    createdAt: now,
    completedAt: now,
  };
};
