# AI4VS Script Can Lock the Pre-Test Activity

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-66

**Status**: **Closed**

## Overview

Replace the stub lock-activity pipeline step in the ai4vs-flvs task handler with a real Portal API call that locks the student's pre-test activity, preventing further answer modifications after they click "I'm Done!"

## Requirements

- Replace the lock-activity stub in `functions/src/tasks/ai4vs-flvs/lock-activity.ts` with a real implementation that calls the Portal API to lock the student's pre-test activity.
- The Portal API call must use Google OIDC authentication (not bearer token / portal secret).
- The OIDC-authenticated fetch must be implemented as a **shared utility function** (`portalOidcFetch`) that any task can reuse.
- The shared function must:
  - Accept the target portal URL (audience) and request parameters (method, path, body, headers).
  - Use `google-auth-library` to obtain a Google OIDC ID token with the portal URL as the audience.
  - Send the request with `Authorization: Bearer <oidc-token>` header.
  - When `FUNCTIONS_EMULATOR` is true, use the `PORTAL_OIDC_TOKEN` environment variable as the bearer token instead of requesting one via `GoogleAuth`. If `PORTAL_OIDC_TOKEN` is not set in the emulator, fail with a clear error message rather than sending an unauthenticated request.
- The lock-activity step must:
  - Extract `platform_id`, `platform_user_id`, and `resource_link_id` from the job document.
  - Call `PUT {platform_id}/api/v1/offerings/{resource_link_id}/update_student_metadata` with `Content-Type: application/x-www-form-urlencoded` and a properly URL-encoded body (`locked=true&user_id={platform_user_id}`).
  - Return `{ success: true }` on a successful response.
  - Return `{ success: false, message: <student-friendly message> }` on failure (HTTP error, network error, missing context fields). For example: "Unable to lock your pre-test. Please try again or contact your teacher." Raw error details must only be logged, never returned in the message.
- The step must validate that required context fields (`platform_id`, `platform_user_id`, `resource_link_id`) are present before making the API call.
- The step must be idempotent — if the activity is already locked, a successful Portal response should be treated as success (no error on double-lock).
- The step must log the lock attempt and outcome (including raw error details on failure).
- Tests must be written for the lock-activity step and the shared OIDC utility.
- Documentation must be added in the functions README explaining how to set up and use the shared OIDC utility with the Firebase emulator, including the steps to generate a token via `gcloud auth print-identity-token` and set the `PORTAL_OIDC_TOKEN` environment variable.

## Technical Notes

- **StepContext** (`functions/src/tasks/ai4vs-flvs/types.ts`): Provides `jobPath`, `jobDoc` (IJobDocument), and optional `firebaseJwt`. The `jobDoc` contains context fields at the top level: `platform_id`, `platform_user_id`, `resource_link_id`, etc.
- **Google Auth Library**: Use `GoogleAuth` from `google-auth-library` (already a transitive dependency via `@google-cloud/tasks`). Not added as a direct dependency to avoid version drift on `firebase-admin` upgrades.
- **Portal OIDC setup**: The portal's `Admin::OidcClient` table maps the Cloud Function's service account `sub` to a Portal user. The service account must be registered in the Portal's admin UI for each environment.
- **OIDC audience matching**: The `platform_id` value in the job document is set from `APP_CONFIG[:site_url]` by the Portal's JWT controller — the same value the Portal uses for OIDC audience validation. They are guaranteed to match by construction, so no normalization is needed.
- **Field mapping**: `platform_user_id` in the job document equals the Portal's `users.id` primary key, which is what the `update_student_metadata` endpoint expects as the `user_id` parameter.
- **Request content type**: The Portal endpoint expects `application/x-www-form-urlencoded` body (`locked=true&user_id=123`). The endpoint is a partial update (Rails strong params) — omitting `active` is safe.
- **HTTP client**: Uses Node.js built-in `fetch` (Node 22 target) rather than axios.
- **Linked issues**: REPORT-67 (AI4VS Script can email teacher) and RIGSE-334 (Send email API) will also need Portal OIDC calls, making the shared utility immediately valuable.

## Out of Scope

- Implementing the random-assignment or send-email pipeline steps.
- Changes to the Portal's `update_student_metadata` endpoint itself.
- Registering the service account in the Portal's `Admin::OidcClient` table (operational task, not code).
- Unlocking activities (no unlock requirement exists).
- Changes to the pipeline orchestration or StepContext interface.
