# Activity Completion Check

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-62

**Status**: **Closed**

## Overview

Replace the stub `evaluate-completion` pipeline step with real completion-check logic that enforces a configurable minimum question count before a student can proceed through the AI4VS button interactive pipeline. Introduces a shared `answerIsCompleted()` utility that evaluates answer document content (not just existence) for all four answer types.

## Requirements

- **R1**: The `evaluate-completion` step must read a `min_completed_questions` parameter from `jobDoc.jobInfo.request`.
- **R2**: `min_completed_questions` must be validated as a positive integer (>= 1). If missing or invalid, the step must fail with a descriptive error message.
- **R3**: The step must query the student's answer documents (existing Firestore query filtering by `platform_id`, `resource_link_id`, `context_id`, `platform_user_id`) and count the number of completed answers.
- **R4**: An answer document counts as "completed" when its `answer` field contains a meaningful response:
  - `multiple_choice_answer`: `answer.choice_ids` is a non-empty array.
  - `open_response_answer`: `answer` is a non-empty string after trimming whitespace.
  - `image_question_answer`: `answer.image_url` is a non-empty string or `answer.text` is a non-empty string.
  - `interactive_state`: parse the `report_state` JSON string, extract the `interactiveState` field, parse it, and check that it is a non-null object with at least one key. If `report_state` is missing or either JSON parse fails, the answer is "not completed" (do not throw).
  - Any type: an answer with a non-empty `attachments` field is considered completed regardless of the `answer` field. `attachments` is a top-level field on the answer document (a `Record<string, IReadableAttachmentInfo>`); "non-empty" means the object has at least one key.
  - Unknown `type` values: treated as "not completed" (do not throw).
- **R5**: If the number of completed answers is less than `min_completed_questions`, the step must fail (return `{ success: false, message }`) with a user-facing failure message.
- **R6**: The failure message must be configurable via an optional `min_completed_questions_failure_message` request parameter.
  - The default message must include the current completed count, e.g.: `"You have completed ${completed} of ${min_completed_questions} required questions. Please answer more questions in this activity."`
  - Custom messages must support template variables `${completed}` and `${min_completed_questions}`, which are substituted with the actual values at runtime.
- **R7**: If the number of completed answers is greater than or equal to `min_completed_questions`, the step must succeed.
- **R8**: The step must continue to use the Firebase client SDK (not the Admin SDK) to read answers, preserving the security-rules enforcement validated in REPORT-63.
- **R9**: The step must continue to handle the existing edge cases: missing Firebase JWT (fail), missing required context fields (fail).
- **R10**: The answer-evaluation logic (determining whether a Firestore answer doc represents a completed response) must be implemented as a shared utility outside the `ai4vs-flvs/` task folder, so it can be reused by other task handlers in the future. The utility implements the completion rules defined in R4 for all four answer types, even though the current pilot only uses multiple choice and open response.

## Technical Notes

- The `request` object is available at `jobDoc.jobInfo.request` and is passed through from the `submitTask` POST body. The button interactive in question-interactives is responsible for including `min_completed_questions` and optionally `min_completed_questions_failure_message` in the request payload.
- The existing Firestore query in `evaluate-completion.ts` already returns all answer documents for the student in the given activity context. The query result `snapshot.docs` provides the raw document data.
- The `IJobInfo.request` type is `{ task: string } & Record<string, any>`, so no type changes are needed to accommodate the new parameters.
- The existing cleanup pattern (try/finally with `cleanup()`) must be preserved.
- No changes are needed to `submit-task.ts`, `task-worker.ts`, or the pipeline definition in `ai4vs-flvs/index.ts`.
- **Prior art**: Activity Player's `answerHasResponse()` in `embeddable-utils.ts` and `getAnswerWithMetadata()` define the canonical answer structure. R4 intentionally diverges from `answerHasResponse()` by checking answer content rather than just answer type.
- The `report_state` field is a JSON string with structure: `{ mode: "report", authoredState: string, interactiveState: string, interactive: { id, name } }`. The `interactiveState` within it is itself a JSON string that must be parsed separately.

## Out of Scope

- **Required-question `submitted` check**: Activity Player's `answerHasResponse()` also checks `authoredState.required` and rejects answers without `submitted === true`. This requires access to the activity structure (authored state per embeddable), which is not available in the current Firestore query. This can be added in a follow-up story if needed.
- **Per-activity thresholds**: The threshold applies to the total completed-answer count for the activity context, not per-section or per-page.
- **Changes to question-interactives**: The button interactive sending the `min_completed_questions` parameter is a separate concern in the question-interactives repo.
- **Other pipeline steps**: lock-activity, random-assignment, and send-email remain stubs.
