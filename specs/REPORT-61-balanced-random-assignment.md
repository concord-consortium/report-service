# AI4VS Balanced Random Assignment

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-61

**Status**: **Closed**

## Overview

Replace the `random-assignment` stub in the AI4VS FLVS pipeline with a real implementation that reads a student's demographic answers (Gender, Grade, Module, Race) from Firestore, maps them to categories using baked-in constants, looks up the treatment/control assignment from a 24-row stratified table, enrolls the student in the corresponding Portal class, and returns the assignment in `StepResult.summary` for the teacher notification email.

## Requirements

### Identifying demographic answers

- R1: The step must query the student's Firestore answer documents using the same pattern as `evaluate-completion`: query `sources/{source_key}/answers` filtered by `platform_id`, `resource_link_id`, `context_id`, and `platform_user_id`, using the Firebase client SDK with the job's `firebaseJwt`.
- R2: The step must identify the four demographic answers by matching **prompt substrings** (baked into the code) against the authored state embedded in each answer's `report_state`. Each answer doc's `report_state` is a JSON string containing an `authoredState` field (also a JSON string) which includes a `prompt` field. The step must match its built-in prompt substrings against these prompts to find the Gender, Grade, Module, and Race answers — no hard-coded `question_id` values. If multiple answer docs match the same prompt substring, or if any prompt substring matches zero docs, the step must fail with a descriptive error (logged) and a student-friendly message.
- R3: The step must extract the student's selected choice(s) from each demographic answer. The answer's `report_state.interactiveState` (JSON string) contains `selectedChoiceIds` (array of choice ID strings). The answer's `report_state.authoredState` contains the `choices` array with `id` and `content` fields, allowing the step to resolve choice IDs to human-readable text without any hard-coded choice ID mappings. If a `selectedChoiceId` is not found in the `authoredState.choices` array, the step must fail with a descriptive error logged and a student-friendly message returned.

### Resolving choices to categories

- R4: The step must map choice **content text** (from the authored state's `choices` array) to assignment-table categories using mappings baked into the code. Choice content text must be matched using exact string comparison after trimming leading/trailing whitespace. For example, `"Female" → Female`, `"9th Grade" → High`, `"Module 1: One-Variable Equations and Inequalities" → Mod1`. This makes the step resilient to activity re-authoring since it depends on prompt text and choice text, not IDs.
- R5: For the Race question (multi-select), a special binary reduction is used instead of the content-text mapping: if the student selected only "White" → `White`; if any non-White race is selected (regardless of whether White is also selected) → `non-White`. The "White" content string is a constant baked into the code, matched using the same exact-after-trim comparison as R4.

### Assignment lookup

- R6: The step must look up the student's assignment (treatment or control) based on their (Gender, Race, Grade, Module) stratum using the assignment table. Each stratum maps to exactly one deterministic assignment.
- R7: If a student's stratum is not found in the assignment table, the step must fail with a descriptive error logged and a student-friendly message returned.
- R8: The assignment table (all 24 strata) must be baked into the code as a constant.

### Portal enrollment

- R9: After determining the assignment, the step must enroll the student in the corresponding Portal class by calling `POST /api/v1/students/add_to_class` via `portalOidcFetch`. The request body must be JSON (`Content-Type: application/json`) and include `user_id` (from `platform_user_id` on the job document) and `clazz_id` (the Portal class ID from `request` parameters). This depends on a Portal-side change (RIGSE-338, implemented) to accept `user_id` as an alternative to `student_id`. The Portal-side change ensures `add_to_class` is idempotent — returning `{"success": true}` if the student is already enrolled.
- R10: On a successful Portal response (2xx with `{"success": true}`), proceed to return the step result. On failure (HTTP error, `{"success": false}`, network error, or a 2xx response that is not valid JSON or lacks the `success` field), the step must fail with a descriptive error logged and a student-friendly message returned.
- R11: The step must log the enrollment attempt and outcome (including the Portal response on failure).

### Result output

- R12: On success, return `{ success: true, summary: "Assigned to <class_name>" }` where `<class_name>` is the baked-in class name (e.g., `FL-spring-2026-GATOR` for treatment, `FL-spring-2026-SHARK` for control).
- R13: On failure, return `{ success: false, message: <student-friendly error> }`. Raw details must only be logged, not returned in the message.

### Configuration resilience

- R14: The step must bake all assignment logic into the code as constants: prompt substrings, choice-content-to-category mappings, the assignment table, class names, and the Race "White" value. The only values accepted from `request` parameters are the Portal class IDs for treatment and control.
- R15: The step resolves questions by matching prompt substrings against `report_state.authoredState.prompt` in the student's own answer documents. No external HTTP fetch required.

### Error handling

- R16: If any of the four required demographic answers is missing or has empty `selectedChoiceIds`, the step must fail with a student-friendly message indicating which question(s) need to be completed, using the dimension names (Gender, Grade, Module, Race).
- R17: For Gender and Grade (explicit-only mappings), if a student's answer choice content text is not found in the baked-in mapping, the step must fail with a descriptive error logged and a student-friendly message returned. Module uses a default fallback and Race uses binary reduction, so unmapped content cannot occur for those dimensions.
- R18: The step must validate required `request` parameters (Portal class IDs) at the start before querying Firestore.

### Testing

- R19: Unit tests must cover: successful assignment and enrollment, missing stratum, missing answer docs, empty selectedChoiceIds, unmapped choice content, missing Portal class ID parameters, prompt substring matching, choice content resolution, Race binary reduction, Portal enrollment success/failure, and Portal unexpected response handling.

## Technical Notes

- **Firestore query pattern**: Reuse the query from `evaluate-completion.ts` — query `sources/{source_key}/answers` with `where` clauses on platform_id, resource_link_id, context_id, platform_user_id. Use `getClientFirestore(firebaseJwt)` for client SDK access.
- **Answer document structure**: Each answer doc's `report_state` (JSON string) contains `authoredState` (JSON string with `prompt` and `choices` array) and `interactiveState` (JSON string with `selectedChoiceIds` array). Both are double-encoded JSON.
- **Prompt substring matching**: Case-insensitive substring match against raw HTML prompt. No HTML stripping needed — substrings are plain text within tags.
- **Choice content**: Content values are plain text (not HTML-wrapped), so no HTML stripping needed for choice matching.
- **Portal enrollment endpoint**: `POST /api/v1/students/add_to_class` with JSON body `{ "user_id": <id>, "clazz_id": <id> }`. Implemented in RIGSE-338.
- **Request parameters are untrusted**: `request` fields come from client POST body without whitelisting. Portal class IDs must be validated as present and non-empty.
- **Security note**: `platform_id` is used as `portalUrl` without allowlist validation, same as all pipeline steps. OIDC audience scoping limits risk. `platform_id` comes from LTI launch (job document), not from the untrusted `request` body.

## Out of Scope

- Persisting the assignment result to Firestore (result flows forward via StepResult; Portal enrollment is done via API).
- Using the `n` column from the assignment table (reserved for future pilots).
- Changes to the activity authoring or the "I'm Done!" button interactive.
- Deduplication — if a student triggers the pipeline twice, the same assignment is produced (deterministic), but the Portal `add_to_class` call fires again. Portal handles re-enrollment idempotently.
- Creating or managing Portal classes (assumed to already exist).
