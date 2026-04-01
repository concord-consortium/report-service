# AI4VS "I'm Done" Button Fit and Finish

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-68

**Status**: **Closed**

## Overview

Two fit-and-finish changes to the AI4VS FLVS "I'm Done" button pipeline: (1) make the final success message configurable via `request.completion_message` with a default fallback, and (2) alternate treatment/control assignments within each demographic stratum using a persistent Firebase assignment document with per-student deduplication.

## Requirements

### Configurable done message

- R1: The pipeline success message must be configurable via an optional `request.completion_message` parameter.
- R2: If the parameter is not provided, is not a string, or is empty/whitespace-only after trimming, the current default message ("Done! Your teacher has been notified.") must be used.
- R3: No template variable substitution is required for the done message.

### Alternating treatment/control assignment

- R4: Within each stratum bucket, students must be assigned alternately between treatment and control classes. The assignment document stores a `nextAssignment` field per stratum. If null or missing (first student), the `ASSIGNMENT_TABLE` value is used. After each assignment, `nextAssignment` is flipped to the opposite class.
- R5: A persistent assignment document must be maintained in the `sources/{source_key}/jobs-task-data/` collection with a deterministic document ID derived from a SHA-256 hash of a pipe-delimited string: `"ai4vs-flvs-assignments|{interactiveId}|{platform_id}|{resource_link_id}|{context_id}"`. All five fields must be present and non-empty. The document must have a `type` field with value `"ai4vs-flvs-assignments"`, store the scoping fields for human readability, and contain a `strata` map. Each stratum entry stores `nextAssignment` and a `users` map keyed by `platform_user_id` with the assignment key (`"treatment"` or `"control"`) as the value.
- R6: The lookup/update of the assignment document must use a Firestore transaction (Admin SDK) to ensure atomic read-modify-write.
- R7: If the assignment document does not yet exist for an offering (first student), it must be created automatically. The first student in each bucket always gets the n1 assignment.
- R8: The existing `ASSIGNMENT_TABLE` continues to define the "n1" (first) assignment for each stratum. No changes to the table values.
- R9: The step must continue to return `{ success: true, summary: "Assigned to <class_name>" }` with the actual assigned class name.
- R14: If a student has already been assigned within the same stratum and offering scope, the step must return the same assignment without flipping `nextAssignment` (deduplication).

### Error handling

- R10: If the Firebase transaction for the assignment document fails, the step must fail with a descriptive error logged and a student-friendly message returned.

### Testing

- R12: Unit tests cover configurable done message with custom value, missing/empty/whitespace-only/non-string parameter falling back to default.
- R13: Unit tests cover alternating assignments, assignment document creation, transaction correctness, correct class name in summary, and deduplication.

## Technical Notes

- **Assignment document ID**: `SHA-256("ai4vs-flvs-assignments|{interactiveId}|{platform_id}|{resource_link_id}|{context_id}")` as a hex string. Direct document get by ID — no query or composite index needed.
- **`interactiveId` source**: `jobDoc.interactiveId` — a whitelisted context field from the LTI launch context, stable across all student submissions for the same interactive.
- **Admin SDK for assignment document**: Admin SDK used for the transaction; Client SDK continues for reading student answers. No Firestore security rules needed for `jobs-task-data`.
- **Alternation logic**: Read `strata[key].nextAssignment` — if null/missing, use `ASSIGNMENT_TABLE[key]`. Flip to opposite after assigning. Store user assignment in `strata[key].users[platform_user_id]` for deduplication.
- **Document size**: ~50 bytes per user entry. At 10,000 students, ~500KB — well within Firestore's 1MB doc limit.
- **Pipeline step reordering**: Pipeline order changed to evaluate-completion → **random-assignment → lock-activity** → send-email. If random assignment fails, the activity remains unlocked so the student can retry.

## Out of Scope

- Changes to the `ASSIGNMENT_TABLE` values themselves.
- Changes to the button interactive or activity authoring.
- Retroactive rebalancing of students already assigned.
- Template variable substitution in the done message.
- Changes to the failure message (already configurable in evaluate-completion).

## Decisions

### What request parameter name for the configurable done message?
**Context**: The done message needs a parameter name in the `request` object, following existing naming conventions.
**Options considered**:
- A) `done_message`
- B) `success_message`
- C) `completion_message`

**Decision**: C) `completion_message`

---

### What Firebase path should the assignment document use?
**Context**: The document needs to be scoped per offering to track alternating assignments. The existing data model uses `sources/{source_key}/...` as the top-level path.
**Options considered**:
- A) `sources/{source_key}/assignment-counters/{resource_link_id}` — a single document per offering with stratum keys as fields
- B) `sources/{source_key}/assignment-counters/{resource_link_id}/strata/{stratum_key}` — one document per stratum per offering
- C) A top-level collection outside `sources/`

**Decision**: `sources/{source_key}/jobs-task-data/` — a generic collection for task data, reusable by other tasks in the future. The document has `type: "ai4vs-flvs-assignments"` and uses a deterministic SHA-256 document ID derived from scoping fields (no query needed).

---

### Should the assignment document use Admin SDK or Client SDK for the transaction?
**Context**: The random-assignment step uses the Client SDK for reading student answers. The assignment document is server-side state, not per-user data.
**Options considered**:
- A) Admin SDK — cleaner for server-side state, no security rules needed, but mixes SDKs in the step
- B) Client SDK — consistent with existing code, but requires new Firestore security rules

**Decision**: A) Admin SDK — server-side state doesn't need security rules, and Admin SDK is already available in the functions environment.

---

### What is the correct offering-scoping key for the assignment document?
**Context**: The document must be unique per offering. Several fields on the job document could serve as the scoping key.
**Options considered**:
- A) `resource_link_id` alone
- B) `context_id + resource_link_id`
- C) `source_key + resource_link_id`

**Decision**: `platform_id + resource_link_id + context_id` — all three fields stored on the document. The document lives under `sources/{source_key}/jobs-task-data/` so `source_key` is implicit in the path. Additionally, `interactiveId` and `type` are included in the hash to ensure uniqueness across interactives and task types.

---

### How should the assignment document be uniquely identified?
**Context**: Auto-generated Firestore IDs require a query to find the document; a deterministic ID enables direct get-by-ID.

**Decision**: Use a deterministic document ID derived from `SHA-256(type|interactiveId|platform_id|resource_link_id|context_id)` as a hex string. This eliminates the need for queries and composite indexes. The scoping fields are also stored on the document for human readability.

---

### What document structure for tracking alternating assignments?
**Context**: The document needs to track which class to assign next and which students have already been assigned (for deduplication).
**Options considered**:
- A) Nested map with per-stratum `count` and `users`
- B) Flat counters map + separate users map
- C) Derive count from users map (no explicit counter)
- D) Store `nextAssignment` directly (no counter at all) + `users` map for dedup

**Decision**: D) Store `nextAssignment` per stratum (the class to assign next, flipped after each assignment) and a `users` map keyed by `platform_user_id`. No counter needed — `nextAssignment` directly tells you what to do next. If null/missing, fall back to the `ASSIGNMENT_TABLE` value (n1).

---

### Should the dedup path skip the Portal enrollment call?
**Context**: When a student re-runs the pipeline and hits the dedup path, the cached assignment is returned. The Portal `add_to_class` API is idempotent.

**Decision**: Left to implementation — either skipping or repeating the Portal call produces the correct outcome. The Portal API handles re-enrollment idempotently (RIGSE-338).

---

### Idempotency: duplicate pipeline runs and the assignment state
**Context**: If a student triggers the pipeline twice, the alternation state could drift if the counter/nextAssignment is updated on each run.

**Decision**: Added R14 — deduplicate by `platform_user_id` per stratum. On re-runs, return the cached assignment from the `users` map without flipping `nextAssignment`.

---

### Alternating assignment is predictable, not random
**Context**: The alternation pattern is fully deterministic and predictable, which could be a concern for allocation concealment in a randomized controlled trial.

**Decision**: No change needed — the alternating pattern is the explicit experiment design from the researcher, not an approximation of randomization. Students don't observe or control the counter.

---

### Pipeline step ordering
**Context**: The original pipeline order was evaluate-completion → lock-activity → random-assignment → send-email. If random assignment fails after locking, the student can't retry.

**Decision**: Reordered to evaluate-completion → **random-assignment → lock-activity** → send-email. If random assignment fails, the activity remains unlocked so the student can retry after correcting any issues.
