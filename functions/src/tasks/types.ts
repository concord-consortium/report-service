/** Queue name — must match the export name in index.ts */
export const TASK_WORKER_QUEUE = "taskWorker";
/** Region where the task worker is deployed */
export const TASK_WORKER_LOCATION = "us-central1";

export interface IJobInfo {
  version: 1;
  id: string;
  status: "queued" | "running" | "success" | "failure" | "cancelled";
  request: { task: string } & Record<string, any>;
  result?: { message: string; processingMessage?: string } & Record<string, any>;
  createdAt: number;
  updatedAt?: number;
  startedAt?: number;
  completedAt?: number;
}

/**
 * The full Firestore document stored at sources/{source_key}/jobs/{id}.
 * Context fields are spread at the top level for Firestore rules and queries.
 * The client reads doc.data().jobInfo as IJobInfo.
 */
export interface IJobDocument {
  // Context fields (from POST body context object)
  [key: string]: any;
  // Nested job state
  jobInfo: IJobInfo;
  // Full Cloud Tasks path for cancel/delete (server-internal)
  taskPath?: string;
}
