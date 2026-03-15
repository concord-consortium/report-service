# Initial Firebase Function for Button Interactive

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-60

**Status**: **Closed**

## Overview

Implement a Firebase HTTPS function (`submitTask`) with task routing and two test tasks (`success` and `failure`) that write success/failure status to a Firestore job document after a simulated delay. This mimics the demo harness callback tasks and enables end-to-end testing of the button interactive watching Firestore job state. Tasks are processed via Firebase Cloud Tasks with `maxConcurrentDispatches: 1` to guarantee single-job-at-a-time execution.

## Requirements

- Add a new Firebase HTTPS function exported from `functions/src/index.ts` (separate from the existing Express `api`)
- The function must handle CORS (the client makes cross-origin `fetch` calls from the browser)
- The function must reject non-POST requests (except OPTIONS for CORS preflight) with HTTP 405
- The function must handle POST requests with a JSON body containing:
  - `request`: `{ task: string } & Record<string, any>` — the task type and task-specific parameters
  - `context`: `Record<string, any>` — user identity and environment context (source_key, platform_id, platform_user_id, etc.)
- The `request.task` and `context.source_key` fields are required; the function must reject requests missing either
- The function must:
  1. Write a job document to `sources/{context.source_key}/jobs/{id}` in Firestore using Firestore's auto-generated document ID, with context fields at the top level, `jobInfo` containing `status: "queued"`, and no `taskPath` yet (client sees it immediately via `onSnapshot`)
  2. Enqueue a task to a Cloud Tasks queue containing the job's Firestore document path (e.g., `sources/{source_key}/jobs/{id}`) — the worker uses this path directly to read the document
  3. Construct and store the full Cloud Tasks path as `taskPath` on the job document (for cancel support)
  4. If the enqueue fails, update the job document's `jobInfo` to `status: "failure"` with an error message
- The Firestore job document structure (at `sources/{source_key}/jobs/{id}`):
  ```typescript
  {
    platform_id: string;
    platform_user_id: string;
    context_id: string;
    interactiveId: string;
    user_type: "authenticated" | "anonymous";
    run_key?: string;
    jobInfo: IJobInfo;
    taskPath?: string;
  }
  ```
- The `IJobInfo` interface:
  ```typescript
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
  ```
- On successful job creation, return HTTP 200 with the `IJobInfo` portion with `status: "queued"`
- On validation errors, return HTTP 400 with `IJobInfo` with `status: "failure"` (no Firestore document created)
- On server errors, return HTTP 500 with `IJobInfo` with `status: "failure"`
- A new Task Queue function (`onTaskDispatched`) must process enqueued tasks with `maxConcurrentDispatches: 1` and `maxInstances: 1`
- The function routes requests by checking `body.action`: if `"cancel"`, handle as cancel; otherwise treat as job creation
- Cancel requests require `jobId` and `context.source_key`; if job is in final state, cancel is a no-op; otherwise delete the Cloud Task and update status to `"cancelled"`
- The worker must check `jobInfo.status` before processing (cancelled = skip), validate document existence, mark `"running"` before executing, and handle unknown task types with failure
- On every status transition, set `jobInfo.updatedAt`; on final statuses, also set `jobInfo.completedAt`

### Test Tasks

- Two test tasks: `success` and `failure`
- Both set a processing message, wait 2 seconds, then write final status to the job document
- `success` task: sets `processingMessage: "Submitting your work..."`, then `status: "success"` with success message
- `failure` task: sets `processingMessage: "Checking your answers..."`, then `status: "failure"` with failure message
- Both support optional `message` and `processingMessage` overrides in `request`
- Job document update logic lives in shared `task-helpers.ts`

### Firestore Security Rules

- `sources/{source}/jobs/{document=**}` — allow read via existing `studentWorkRead()` function; deny client writes

## Technical Notes

- **Separate function**: `submitTask` is a standalone `functions.https.onRequest()` export, independent of the existing Express `api` and `bearerTokenAuth` middleware.
- **Cloud Tasks queue**: Worker exported as `taskWorker` using `onTaskDispatched` from `firebase-functions/v2/tasks`. Enqueue via `CloudTasksClient.createTask()` from `@google-cloud/tasks` with OIDC token for authentication. `createTask()` returns the task `name` stored as `taskPath` for cancel support.
- **Emulator support**: In the emulator (`FUNCTIONS_EMULATOR === "true"`), `CloudTasksClient` is bypassed and the worker logic (`executeTask`) is called directly, since the client library connects to the real GCP API rather than the emulator.
- **New dependency**: `@google-cloud/tasks` ^6.2.1 — used for `createTask()` (enqueue) and `deleteTask()` (cancel). `firebase-admin/functions` `enqueue()` was considered but its `id` option is not available in `firebase-admin` v10.x.
- **Firebase Functions version**: `firebase-functions` ^4.0.0, `firebase-admin` ^10.0.0. Cloud Tasks requires v2 imports (`firebase-functions/v2/tasks`).
- **Split error handling**: Enqueue failure marks the job as failure. TaskPath update failure is best-effort (warning only) — the job still succeeds but cancel won't work for that job.
- **Payload format**: `onTaskDispatched` reads `req.body.data`, so payload is wrapped as `{ data: { jobPath } }`.

## Out of Scope

- JWT authentication / verification on the Cloud Function endpoint (future ticket)
- Caller identity verification on the Cloud Function endpoint (future ticket — depends on JWT auth)
- Actual student answer reading and completion checking logic (future ticket)
- Portal API calls (future ticket)
- OIDC token acquisition for Portal authentication (future ticket)
- Client SDK usage for student-scoped Firestore reads (future ticket)
- UI/frontend button interactive implementation
- Rate limiting or abuse prevention on the new endpoint
