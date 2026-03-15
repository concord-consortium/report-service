# "I'm Done!" Button Interactive Script for AI4VS

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-64

**Status**: **Closed**

## Overview

Add an `ai4vs-flvs` task handler to the existing task framework that implements the "I'm Done!" button workflow for the AI4VS FLVS Spring Pilot. This is a framework story: the handler defines the fixed pipeline and stub functions for each step, with follow-on stories providing the real implementations.

## Requirements

- Register a new task handler named `ai4vs-flvs` in the `taskHandlers` map in `task-worker.ts`
- The handler must follow the existing pattern: `(jobPath: string, jobDoc: IJobDocument) => Promise<void>`
- The handler must require a `pilot` parameter in `request`. If missing, fail with message: `"Missing required field: request.pilot"`
- If an unrecognized `pilot` value is provided, the handler must fail with message: `"Unknown pilot: <value>"`
- This story implements the `spring-2026` pilot; future pilots (e.g., fall 2026) will update this handler.
- The handler must execute a fixed pipeline of steps in order:
  1. **Evaluate completion** — Check that the student has completed the pre-test (e.g., answered enough questions to meet a threshold)
  2. **Lock activity** — Lock the pre-test so the student cannot go back and change answers
  3. **Random assignment** — Assign the student to one of the treatment classes based on demographic answers
  4. **Send email** — Notify teacher/project admin via a TBD Portal endpoint
- The handler must check each step's result and exit early if any step returns failure:
  - Mark the job as `failure` with the step's failure message
  - Skip remaining steps
  - (For this story all stubs return success, so the early-exit path won't trigger -- but the conditional logic must be in place for follow-on stories)
- If all steps succeed, mark the job as `success` with message: "Task completed (stub mode -- no real actions performed)."
- Each step must be implemented as a separate stub function in its own file under `functions/src/tasks/ai4vs-flvs/`
- Each stub function must:
  - Accept the job path and job document
  - Log via `functions.logger.info` with the step name and job path (e.g., `"ai4vs-flvs: evaluate-completion stub called for <jobPath>"`)
  - Return a result indicating success (stubs always succeed for now)
  - Parameter shapes for each step will be defined by follow-on stories
- Use `setProcessingMessage` to update the user with progress as each step executes
- The handler must use the existing `markComplete` helper for final status transitions

## Technical Notes

- **Handler location**: New files under `functions/src/tasks/ai4vs-flvs/` with an `index.ts` barrel export
- **Existing handler pattern**: See `test-success.ts` -- a handler receives `(jobPath, jobDoc)`, optionally calls `setProcessingMessage`, then calls `markComplete`
- **Task registration**: Add to `taskHandlers` in `task-worker.ts`:
  ```typescript
  import { ai4vsFlvs } from "./ai4vs-flvs";
  const taskHandlers = { success: testSuccess, failure: testFailure, "ai4vs-flvs": ai4vsFlvs };
  ```
- **Request shape**: The `request` object in `IJobInfo` already supports `{ task: string } & Record<string, any>`, so step-specific parameters (e.g., completion threshold, target class names) can be passed as additional properties
- **Stub function signature**: Each step stub should have a consistent interface, e.g.:
  ```typescript
  type StepResult = { success: boolean; message?: string };
  type StepHandler = (jobPath: string, jobDoc: IJobDocument) => Promise<StepResult>;
  ```
- **Portal API**: Follow-on stories will need to call the Portal API for locking activities and class assignment. Known endpoint:
  - `GET /api/v1/classes/info?class_word=<class_word>` -- Look up class ID from class word (avoids hardcoding class IDs)
- **Random assignment algorithm**: Defined in an [external document](https://docs.google.com/document/d/1voQIoI0KeLlTFQggTY0gVmmbCDi7a5odqnoqmMBDhUk/edit?usp=sharing) linked from the Jira ticket. Assigns students based on grade level, sex, race, and one other variable. Previously assigned students impact subsequent assignments.
- **Firestore context**: The job document already contains context fields (platform_id, platform_user_id, etc.) at the top level, which follow-on stories will use for Portal API calls.
- **Spring Pilot classes**: `FL-spring-2026` (initial class), `FL-spring-2026-GATOR` and `FL-spring-2026-SHARK` (treatment classes).

## Out of Scope

- Full implementation of completion evaluation logic (reading student answers, calculating percentages)
- Full implementation of activity locking via Portal API
- Full implementation of the random assignment algorithm
- Full implementation of email sending via Portal API (depends on RIGSE-334)
- Unlock activity and class assignment capabilities from the Jira ticket (follow-on stories)
- JWT authentication on the submitTask endpoint (separate story)
- UI/frontend changes to the button interactive
- Firestore security rules changes (covered in REPORT-60)
