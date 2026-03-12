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
 * Transition job to "running" status with startedAt and updatedAt.
 */
export const markRunning = async (jobPath: string): Promise<void> => {
  const now = Date.now();
  await updateJobInfo(jobPath, {
    status: "running",
    startedAt: now,
    updatedAt: now,
  });
};

/**
 * Transition job to a final status ("success" or "failure") with result,
 * updatedAt, and completedAt.
 */
export const markComplete = async (
  jobPath: string,
  status: "success" | "failure",
  result: { message: string; processingMessage?: string } & Record<string, any>
): Promise<void> => {
  const now = Date.now();
  await updateJobInfo(jobPath, {
    status,
    result,
    updatedAt: now,
    completedAt: now,
  });
};

/**
 * Set the processingMessage on a running job (before the task delay).
 */
export const setProcessingMessage = async (
  jobPath: string,
  processingMessage: string
): Promise<void> => {
  await updateJobInfo(jobPath, {
    result: { message: "", processingMessage },
    updatedAt: Date.now(),
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
