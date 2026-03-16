# AI4VS Script Can Email Teacher

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-67


**Status**: **Closed**

## Overview

Replace the send-email stub in the AI4VS FLVS pipeline with a real implementation that calls the Portal's `POST /api/v1/emails/oidc_send` endpoint to notify the teacher when a student completes the "I'm Done!" process. This also adds pipeline step result accumulation so the email includes a summary of all prior steps.

## Requirements

### Send-email step
- Replace the send-email stub in `functions/src/tasks/ai4vs-flvs/send-email.ts` with a real implementation that calls the Portal's `POST /api/v1/emails/oidc_send` endpoint.
- The Portal API call must use the shared `portalOidcFetch` utility from `functions/src/tasks/portal-api.ts`.
- The request body must be JSON with `subject` (string) and `message` (string, plain text) fields.
- The `Content-Type` header must be `application/json`.
- The step must extract `platform_id`, `platform_user_id`, and `resource_link_id` from the job document.
- The step must validate that all three fields are present before making the API call (consistent with `lock-activity` pattern).
- On a successful Portal response (2xx), return `{ success: true }`.
- On failure (HTTP error, network error, missing fields), return `{ success: false, message: <student-friendly message> }`. Raw error details must only be logged, never returned in the message.
- The step must log the email attempt and outcome (including raw error details on failure).
- The step must be idempotent — sending a duplicate email is acceptable (no deduplication required), but the step should not crash or fail if called twice.
- Update the pipeline orchestrator's final success message to a student-appropriate message: `"Done! Your teacher has been notified."`.
- Tests must be written for the send-email step.
- Tests must also cover the pipeline orchestrator's step result accumulation — verifying that `stepResults` is correctly populated and passed to subsequent steps.
- Tests must cover `email_subject` sanitization — verifying that newlines are stripped and values exceeding 200 characters are truncated.

### Email content
- The email is sent to the OIDC-mapped Portal user (the teacher/project admin, e.g., Trudi Lord), configured in the Portal's `Admin::OidcClient` table.
- The default email subject is `"AI4VS: Student completed pre-test"`. An optional `email_subject` parameter in `request` can override this default. Since `request` fields are user-controlled (not whitelisted in `submit-task.ts`), the override must be sanitized: strip newlines and truncate to 200 characters.
- The email body must include a nicely formatted summary of all prior pipeline step results (from the accumulated results in StepContext). Each step's name and result message should be clearly presented.
- The email body should include a link to the student's Portal user record (`{platform_id}/users/{platform_user_id}`) so the teacher can identify the student.
- The email body should include the `resource_link_id` (offering ID) for cross-reference.

### Pipeline step result accumulation
- Expand `StepContext` in `functions/src/tasks/ai4vs-flvs/types.ts` to carry accumulated step results through the pipeline.
- Add an optional `summary` field to `StepResult` for descriptive text intended for the email (e.g., "Assigned to FL-spring-2026-GATOR"). The existing `message` field remains for student-facing text. The send-email step uses `summary ?? message` when building the email body.
- Add a `stepResults` map (keyed by step name) to `StepContext` that stores each completed step's `StepResult`.
- Update the pipeline orchestrator in `functions/src/tasks/ai4vs-flvs/index.ts` to record each step's result into `stepResults` after it completes successfully.
- The send-email step reads accumulated results from `stepResults` to build the email body.

## Technical Notes

- **Portal endpoint** (RIGSE-334): `POST /api/v1/emails/oidc_send` with JSON body `{ "subject": "...", "message": "..." }`. Sends to `current_user` (OIDC-mapped Portal user). Returns JSON success/failure.
- **Shared OIDC utility**: `portalOidcFetch` in `functions/src/tasks/portal-api.ts` handles OIDC token acquisition (Google Auth in production, `PORTAL_OIDC_TOKEN` env var in emulator).
- **StepContext**: Provides `jobPath`, `jobDoc` (IJobDocument with context fields at top level), and optional `firebaseJwt`.
- **Context fields available**: `platform_id`, `platform_user_id`, `resource_link_id`, `context_id`, `source_key`, `resource_url`, `tool_id`, `interactiveId`, `remote_endpoint`, `run_key`, `tool_user_id`.
- **Existing pattern**: The `lock-activity.ts` step follows the same pattern — extract fields from `jobDoc`, validate, call `portalOidcFetch`, handle success/failure.
- **Email recipient**: The OIDC client is mapped to the teacher/project admin in the Portal's `Admin::OidcClient` table. The `oidc_send` endpoint sends to that mapped user.
- **Step result accumulation**: StepContext is expanded with a `stepResults` map so earlier step results (e.g., random-assignment class name) flow forward to the send-email step. The orchestrator records each step's result into `stepResults` *before* calling the next handler, so each step only sees prior steps' results.
- **JSON body encoding**: `portalOidcFetch` accepts `body` as a raw string. The send-email step must use `JSON.stringify({ subject, message })` (unlike lock-activity which uses `URLSearchParams`).
- **`request` fields are user-controlled**: Unlike `context` fields (whitelisted in `submit-task.ts` lines 99-109), the `request` object is stored as-is from the client POST body. Any `request` field used in the send-email step (e.g., `email_subject`) must be treated as untrusted input and sanitized.

## Out of Scope

- Changes to the Portal's `POST /api/v1/emails/oidc_send` endpoint (covered by RIGSE-334).
- HTML email formatting (the Portal endpoint only supports plain text).
- Implementing the random-assignment step (separate story).
- Rate limiting or deduplication of emails.
- Sending emails to arbitrary recipients (the Portal endpoint only sends to the OIDC-mapped user).
