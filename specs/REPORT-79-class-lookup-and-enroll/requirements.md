# Class Lookup Helper and Enroll-into-Class Pipeline Step

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-79
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

<!-- Rewritten during finalization. -->
Add a shared portal class-lookup helper (resolve a class by its environment-stable class word) and a pipeline step that enrolls a student into an author-specified class resolved by class word, so a button authored once works in both staging and production with no database ids embedded in it.

## Project Owner Overview

<!-- Rewritten during finalization. -->
This is the first of the fall-2026 "I'm Done" pipeline building blocks (REPORT-79, epic DT-20). Portal class and offering database ids differ between staging and production, so today's spring button hardcodes them, which does not travel between environments or scale to the ~24 fall classes. This story makes the pipeline resolve classes at run time by their human-assigned, environment-stable class word, and delivers the shared lookup helper the sibling fall stories (offering-state step, fall pipelines) reuse. It has no user-facing behavior change on its own; it is infrastructure the fall study is built on.

## Background

The "I'm Done" pipeline lives in `report-service/functions/` (`ai4vs-flvs/`). The spring pipeline's enroll step (`random-assignment.ts`) calls the portal's `add_to_class` with a **raw `clazz_id`** taken from the authored `treatment_class_id` / `control_class_id` params. Because portal ids differ per environment, those authored ids are not portable, and there is no class-lookup-by-word capability in report-service today (confirmed: no `classes/info` or `class_word` usage exists in `functions/src`).

REPORT-83 (this branch's parent) replaced the shared OIDC-mapped-admin auth with **scoped minted teacher tokens**: `getScopedPortalToken` / `portalTokenFetch`, the `classifyPortalFailure` / `messageForBucket` classifier, and a per-run token cache on `StepContext`, plus a `validatePortalHost` setup gate. Every portal call in the fall pipelines, including the ones this story adds, uses that infrastructure and acts as the **minted least-privileged teacher** of the relevant class, not as the forwarded student. (The Jira description's "act as the student" wording predates the RIGSE-352 mint pivot and is corrected here.)

The portal already exposes the endpoints this story needs (no new portal endpoints): `GET /api/v1/classes/info?class_word=` returns the class's id, `offerings[]` (id, name, active, locked, per-student metadata, external URL), and `teachers[]`; `GET /api/v1/offerings/:id` returns `clazz_id` and (as of RIGSE-352, **teacher-gated**) `class_word`; `POST /api/v1/students/add_to_class` enrolls a student into a class.

Per the epic's O14 decision, the fall flow uses a single shared pre-test button and selects the program (`fall-2026-fulltime` vs `-flex`) at run time from the student's **origin class word**, resolved from `resource_link_id`. That resolve, and the shared lookup helper, are owned by this story; the program dispatch and randomization that consume them are REPORT-82 / REPORT-81.

## Requirements

- **Class-lookup helper.** Add a helper that resolves a class by **class word** via `GET /api/v1/classes/info?class_word=<word>`, returning at least the class id, its offerings (id, name, active, locked, per-student metadata, activity URL), and its teachers. It obtains an **origin (unscoped) teacher** token via `getScopedPortalToken` (minting one on a cache miss, since the lookup may be the first portal call in its pipeline and the per-run cache starts empty) and sends it via the REPORT-83 `portalTokenFetch` path; any teacher token suffices, because `classes/info` performs no per-class authorization, so no destination-scoped mint is needed here. It classifies failures with the shared classifier. The destination-scoped cross-class mint is used for the subsequent `add_to_class`, **not** for this lookup, because the destination `clazz_id` is only known after the lookup returns. It is a shared helper reused by the enroll step (this story) and the offering-state step (REPORT-80); the teacher-notification email resolves its own `class_id` via the offering-read shipped in REPORT-83, not this helper.
- **Origin-class-word resolve (O14).** Add a resolve that returns the student's **origin class word** from the run context (`resource_link_id`) via the single call `GET /api/v1/offerings/:resource_link_id` → `class_word`. The merged portal serializer gates `class_word` on `clazz.is_teacher?(current_user) || admin`, and this story reads it with the **origin-class teacher** token the mint produces (a teacher of the origin class by construction), so the field is reliably present; no learner-scoped degradation applies, because these pipelines only ever mint teacher tokens. An unexpectedly-absent `class_word` (which should not occur with a teacher token) is treated as a **classified failure**, not a silent second-call path. **Decided: the two-call fallback (`offerings/:id` → `clazz_id` → `classes/:id` → `class_word`) is omitted** (see the resolved Open Question below): it is unreachable for these teacher-token pipelines, and omitting it removes the story's only real-PII surface. The resolve is consumed by the fall program selection (REPORT-82) and Gator/Shark target derivation (REPORT-81).
- **Enroll-into-class step.** Add a pipeline step that enrolls the student into a class **named by class word** (resolved to `clazz_id` via the helper), using `add_to_class`. The destination class word comes from **either an authored `target_class_word` param or a documented handoff field on the preceding step's result** (the randomization step's resolved `-Gator`/`-Shark` target; the exact field is pinned in `implementation.md`), never a raw `clazz_id`; the step itself performs no randomization or class-word derivation (that lives in REPORT-81). The current `StepResult` type (`{ success, message?, summary? }`) has **no structured output slot** and `stepResults` is consumed only for display, so the handoff has no home today; this story, first in the REPORT-79 → 81 → 82 order, **owns defining** the typed handoff field on `StepResult` that REPORT-81 later populates. Adding it is a change to the shared step contract, not a local detail, and the field name/shape is pinned in `implementation.md`.
- **Shared-teacher precondition for enroll.** The enrolling identity is a minted teacher **cross-class-scoped to the destination class**, which the mint resolves to a teacher **shared between the student's origin class and the destination class** (`add_to_class` authorizes `update_roster?` on the destination *and* student `:show?`, both satisfied by a shared teacher). A study whose origin and destination classes share no teacher yields a mint `422` → tell-your-teacher; a shared teacher is therefore an operator-verifiable setup precondition, as in the spring enroll.
- **Environment portability.** A button authored with a class word enrolls the student into the correct class in any environment, with **no database ids in the authored config**.
- **Idempotency.** Re-running the enroll step for a student already in the destination class is a **success**, not an error (double-click / retry / Cloud Tasks redelivery safe). This relies on the portal being idempotent server-side (`add_to_class` → `add_clazz` no-ops for an already-enrolled student, returning `{ success: true }`), so the step treats a 2xx success as success and needs no separate membership pre-check. The same server-side idempotency holds for REPORT-80's `update_student_metadata`, so both steps share the pattern.
- **Failure handling.** Lookup and enroll failures route through the shared classifier to the same coarse student messages REPORT-83 established (reload / tell-your-teacher / generic), and never log a token value. The lookup-failure log **should** include the attempted `class_word` (an authored, environment-stable identifier, not PII and not a token) plus the status, since a mis-authored word resolves to a `400` → tell-your-teacher and the word is the single most useful field for diagnosing it; this avoids the over-stripping seen in `send-email`'s offering-read failure log, which records only `{ status }` (`send-email.ts:94`) and drops the identifier. The `classes/info` response body, unlike a token, is **not** a real-PII sink, so the helper may log it like the three existing steps (`{ status, data: response.data }`, per `lock-activity.ts:70` / `random-assignment.ts:433` / `send-email.ts:115`). Verified both in rigse (@ `526cfb232`) and against the live portals: the `info` action calls `render_info(clazz, true)` (`classes_controller.rb:66`), hardcoding `anonymize=true`, so every student name comes back as the anonymized `"Student"` / id form (`get_info`, `classes_controller.rb:124-127`; `Portal::Student#anonymized_first_name` = `"Student"`, `portal/student.rb:70-72`), and student emails are synthetic `no-email-*@concord.org` placeholders on **all** environments (confirmed live against staging and production). `classes/info` therefore carries no real student PII for any caller. The only endpoint that would return real names is `classes#show` (`GET /api/v1/classes/:id`), which de-anonymizes via `has_full_access_to_student_data?` (`user.rb:482-490`) for a class-teacher token, and this story does **not** call it (the two-call `class_word` fallback is omitted, per the resolve requirement). REPORT-79 therefore has **no real-PII surface at all**: the only logging invariant is token-secrecy.
- **Keep roster data out of the StepResult.** `send-email` renders every prior step's `result.summary ?? result.message` into the teacher-notification email body (`send-email.ts:29-31`), so `StepResult` is a second sink, not just the log. The `classes/info` roster is anonymized + synthetic (above) and the story makes no `classes/:id` call (fallback omitted), so no real PII can reach `StepResult`; regardless, only non-PII display values (the resolved class word / class name) belong in `summary`, not the raw roster.

## Acceptance criteria

- A button authored with a **class word** enrolls the student into the correct class in any environment, with **no database ids** in the authored config.
- The lookup helper returns the class id, offerings (id, name, active, locked, per-student metadata, activity URL), and teachers for a given class word.
- The origin class word resolves from `resource_link_id` in a **single** `offerings/:id` call using the origin-class teacher token; an absent `class_word` fails the step with a classified message rather than silently falling back.
- The enroll step accepts its destination as a class word (authored param or the documented prior-step handoff), never a raw id, and enrolls via `add_to_class`.
- **Re-running** the enroll step for an already-enrolled student succeeds (no error), relying on the portal's server-side idempotency (verified in rigse: `Portal::Student#add_clazz` no-ops via `unless has_clazz?`, while the controller still returns a byte-identical `{ success: true }`). Neither the unit test nor the harness proves that portal no-op, because the portal returns the same `{ success: true }` whether or not the student was already enrolled, so there is nothing observable for the stub to reproduce; the no-op rests on the cited rigse verification alone. What the two tests do prove: the mocked-`fetch` unit test asserts a 2xx `{ success: true }` maps to success, and the harness re-run (a whole-pipeline re-submit) asserts the step / `StepContext` / `tokenCache` plumbing survives a second invocation end-to-end and still succeeds.
- A study whose origin and destination classes share no teacher surfaces the tell-your-teacher message (mint `422`), not a wrong-class enrollment.
- Lookup and enroll failures map to the REPORT-83 buckets (reload / tell-your-teacher / generic) with the correct student message.
- No token value appears in any log **or in the returned `StepResult.summary`/`message`** (which `send-email` renders into the teacher email); a unit test asserts it. No roster-PII assertion is required: `classes/info` hardcodes `anonymize=true` (names come back as the `"Student N"` form) with synthetic student emails, and the story makes no `classes/:id` call (the two-call fallback is omitted), so there is no real-PII surface to guard.

## Technical Notes

- **Files.** Likely a new lookup helper in `functions/src/tasks/portal-api.ts` (or a sibling module) and a new `enroll-specified-class` step under `functions/src/tasks/ai4vs-flvs/` (or a shared steps module the fall pipelines import); wired into `PIPELINES` by the fall-pipeline story, not here. The spring `random-assignment.ts` enroll is the reference pattern for the cross-class mint + `add_to_class` call.
- **Auth.** Reuse REPORT-83's `getScopedPortalToken` (teacher scope, optional `classId` for a cross-class mint), `portalTokenFetch`, `classifyPortalFailure`, `messageForBucket`, and the per-run `tokenCache` on `StepContext`. **These steps make no host check of their own and assume the `validatePortalHost` setup gate has already run**, so any pipeline that consumes them (REPORT-82) must apply the gate at setup before the pipeline loop. It is the token-exfiltration guard and must not be dropped when the steps are reused. Each step passes the validated, normalized base URL that gate produced (`StepContext.portalOrigin`) as `portalUrl` for its portal calls, never the raw `jobDoc.platform_id` (REPORT-83 rejects a non-bare-origin `platform_id` and keeps the raw value only as an identity key).
- **Verification.** This story wires no `PIPELINES` entry (REPORT-82 does), so it is verified by unit tests with mocked `fetch` (as REPORT-83) plus a new scenario in the local harness (`functions/harness/im-done-local/`) that drives the helper / resolve / enroll step against the stub portal. The unit tests must include a **token-secrecy assertion** for the lookup helper and enroll step (no token value on any path, in a log **or** on the returned `StepResult`). No roster-PII assertion is required: `classes/info` hardcodes `anonymize=true` with synthetic emails, and the story makes no `classes/:id` call (the two-call fallback is omitted), so there is no real-PII surface. The harness scenario **re-runs** the enroll step and asserts success; note what this does and does not prove (per the idempotency AC): it exercises re-invocation safety of the step / `StepContext` / `tokenCache` end-to-end, but it does not (and cannot) prove the portal's server-side no-op, which is wire-indistinguishable from a first enrollment and rests on the rigse verification.
- **Stub fidelity required for the enroll scenario.** The current stub's `classes/info` handler ignores the `class_word` query param and returns a single hard-coded class (`id: 90210`) for any word (`stub-portal.js:27-36,215-218`), and its enroll route returns `{ success: true }` statelessly. As-is, an enroll-into-destination scenario would resolve every word to the origin class and pass green without exercising class-word resolution or membership. The harness work in this story must therefore extend the stub so `classes/info` keys its response on the requested `class_word` (distinct origin vs destination classes and ids), so the scenario can assert the student is enrolled into the id the **destination** word resolves to, not a fixed one. This stub-fidelity requirement is pinned here because the "enrolls into the correct class" acceptance criterion depends on it; it is not a detail to be discovered in `implementation.md`.
- **Handoff contract (`StepResult`).** The current `StepResult` is `{ success, message?, summary? }` and `stepResults` is read only for display (`send-email.ts` renders it into the teacher email), so there is no structured slot for a resolved class word. The enroll step's prior-step handoff therefore requires a **typed output field on `StepResult`**, defined by this story and populated later by REPORT-81. The exact field name/shape is pinned in `implementation.md`; reusing `summary` (a display string) for it is rejected, since `send-email` would render the raw class word into the notification email.
- **Offering-read consolidation.** The origin-class-word resolve calls `GET /api/v1/offerings/:resource_link_id` with the origin teacher token, which is the **same call** `send-email` already makes for `clazz_id` (`send-email.ts`), and rigse's `offerings#show` returns `clazz_id` (unconditional) and `class_word` (teacher-gated) in one response. `implementation.md` should consider a single origin-offering read returning `{ clazz_id, class_word }` reused by both steps rather than two calls.
- **Portal contract verified (rigse, RIGSE-352 @ `526cfb232`).** The cross-repo claims in this spec were checked against rigse source: `classes#info` has no `authorize` / `before_action`, but calls `render_info(clazz, true)` (`classes_controller.rb:66`) so it **always** anonymizes student names to the `"Student"` / id form (`get_info`, `classes_controller.rb:124-127`; `Portal::Student#anonymized_first_name` = `"Student"`, `portal/student.rb:70-72`), and its student emails are synthetic `no-email-*@concord.org` placeholders (confirmed live against staging and production), so the body carries **no real student PII** for any caller; the teacher/admin de-anonymization is in the separate `classes#show` action (the `classes/:id` fallback, which this story omits), which unanonymizes names via `has_full_access_to_student_data?` (`user.rb:482-490`); `offerings#show` gates `class_word` on `clazz.is_teacher?(user) || admin` (`api/v1/offering.rb:98,135-138`); `add_to_class` double-authorizes `update_roster?` + student `:show?` and returns `{ success: true }` (`students_controller.rb:183-201`); `add_clazz` no-ops via `unless has_clazz?` (`portal/student.rb:166-170`); and the origin (no-`class_id`) teacher mint draws its subject strictly from `origin_clazz.teachers` (`oidc_mint_controller.rb:66-72`), so the single-call `class_word` read needs no fallback. The cross-class mint intersects origin/destination teachers and 422s when empty (`oidc_mint_controller.rb:52-65`).
- **Cross-class lookup assumption.** The helper can read a **target** class the acting teacher does not teach (e.g. REPORT-80 resolving a `-Gator` offering) only because `classes/info` currently performs no authorization. This is an accepted assumption, not a design we add to; if the portal later hardens `classes/info`, the helper would need a token scoped to the target class. Recorded so the dependency is visible, without taking on the portal change.
- **Portal contract (rigse, RIGSE-352 merged).** `classes#info` renders `{ id, name, class_hash, class_word, teachers[], students[] (always-anonymized names + synthetic emails), offerings[] }` (the `get_info` shape via `render_info(clazz, true)`); `offerings#show` renders `clazz_id` + teacher-gated `class_word`; `add_to_class` returns `{ success: true }` and double-authorizes `update_roster?` + student `:show?`. Error envelopes follow the REPORT-83 contract (full `error(...)` envelope vs thin Pundit `403` / `ParameterMissing` `400`).
- **Endpoint usage.** Resolve the origin class word via the single call `GET /api/v1/offerings/:resource_link_id` (`class_word`); the portal gates that field on `clazz.is_teacher?(current_user) || admin` (`api/v1/offering.rb#can_read_class_word?`), which the origin-class teacher mint satisfies, so the resolve is a single call; the two-call `offerings/:id` → `classes/:id` path is **omitted** (unreachable for teacher tokens, and its `classes/:id` read is the only real-PII surface, so dropping it is strictly better; see the resolved Open Question). Use `classes/info?class_word=` for the class-word → class / offerings / teachers lookup the helper exposes (which REPORT-80 reuses to match a target offering by name). Consume the portal endpoints as they are; no portal-side changes are in scope.

## Out of Scope

- Program selection / dispatch and the fall pipelines themselves (REPORT-82).
- Randomization tables and Gator/Shark target derivation (REPORT-81).
- The offering-state (lock/hide/open) step (REPORT-80), though it reuses this story's helper.
- Any portal-side (rigse) change; this story consumes the existing portal endpoints as they are.
- Wiring the new step into a live `PIPELINES` entry (done by REPORT-82).
- Changing the existing spring enroll: the spring path enrolls inside `random-assignment.ts` and is left untouched; this story adds a **new**, separate `enroll-specified-class` step for the fall pipelines.

## Open Questions

### RESOLVED: Does REPORT-79 include the origin-class-word resolve, or only the lookup helper + enroll step?
**Context**: The oob `stories.md` P1 explicitly scopes the origin-class-word resolve (O14) into REPORT-79 ("so P5 can pick the program and P3 can derive targets"), but the Jira summary/description name only the lookup helper and the enroll step. If it belongs to REPORT-82 instead, this story shrinks to the helper + enroll.
**Options considered**:
- A) Include the origin-class-word resolve here (matches oob P1); REPORT-82/81 consume it.
- B) Defer the resolve to REPORT-82 (matches the Jira text); REPORT-79 is only the helper + enroll step.
- C) Include only the resolve **helper** here (the reusable read), and leave "select the program from it" to REPORT-82.

**Decision**: **A**, delivered as a reusable **read** only (option C's scoping). REPORT-79 resolves `resource_link_id` → origin class word; REPORT-81 derives its `-Gator`/`-Shark` targets from that word and REPORT-82 classifies the program (`FT-`/`FL-`) from it. The fixed Jira dependency order is REPORT-79 → REPORT-81 → REPORT-82, so the read must exist here; the program-classification/dispatch logic itself stays in REPORT-82.

### RESOLVED: What is the authored contract for the enroll destination in this story?
**Context**: The step must accept "a class word (or a derivation rule, see the randomization story)". REPORT-79 owns the non-randomized, explicitly-named-word case; the randomized `origin + -Gator/-Shark` derivation is REPORT-81/82. Need the boundary pinned so the step's input contract is testable.
**Options considered**:
- A) REPORT-79 accepts only an explicit `target_class_word` param; the randomized destination is passed in (as a resolved word) by the randomization step.
- B) REPORT-79 also implements the `origin + -Gator/-Shark` derivation rule.
- C) REPORT-79 accepts either an explicit word or a pre-resolved word from a prior step, but implements no derivation.

**Decision**: **C**. The enroll step takes a destination class word from either an authored param or a preceding step's output, resolves it via the helper, and enrolls; it implements no derivation. The `origin + -Gator/-Shark` rule stays in REPORT-81, keeping derivation in one place and the enroll step reusable by both the non-randomized (explicit word) and randomized (handed-off word) paths.

### RESOLVED: How is "already enrolled" determined for idempotency?
**Context**: The AC requires re-running the enroll to succeed for an already-enrolled student. Options differ in cost and portal trust.
**Options considered**:
- A) Rely on the portal: treat a specific `add_to_class` response for an existing member as success (needs confirmation of what the portal returns when the student is already in the class).
- B) Pre-check membership via the lookup helper's `students[]` (or a class-membership read) and skip the enroll if already present.
- C) Both: pre-check, and also treat the portal's already-member response as success.

**Decision**: **A**. Confirmed in rigse that the portal is idempotent server-side: `add_to_class` → `Portal::Student#add_clazz` is `unless has_clazz?(clazz); clazzes << clazz`, so re-enrolling an existing member is a no-op that still renders `{ success: true }`. The step therefore treats a 2xx success as success with no membership pre-check (which also avoids an extra `classes#info` roster read). REPORT-80's `update_student_metadata` (`find_or_create_by` + `update!`) is idempotent the same way, so both steps share this pattern.

### RESOLVED: How does this story use `classes#info` given it is unauthenticated/PII-leaky?
**Context**: `classes#info` has no `authorize` and returns student emails. That is a pre-existing portal weakness; hardening it is portal (rigse) work and is explicitly out of scope for this feature.
**Options considered**:
- A) Proceed as-is; request only what we need.
- B) Block REPORT-79 on a portal fix.
- C) Prefer the teacher-gated `offerings/:id` + `classes/:id` reads where they suffice; use `classes/info` only where offerings/teachers-by-word is needed.

**Decision**: **Proceed as-is (A), using the endpoints as they exist (C's split as the natural design, not a security measure).** The origin-class-word resolve uses the teacher-gated `offerings/:id` (single call; the `classes/:id` fallback is omitted, see the resolved Open Question); `classes/info?class_word=` is used for the class → offerings/teachers lookup the helper exposes (which REPORT-80 needs to match a target offering by name). No portal-side change is in scope; per project direction we do not track or block on the portal's `classes#info` hardening.

**Correction (see sixth pass):** the "PII-leaky" framing of `classes#info` in this question is superseded. `classes#info` hardcodes `anonymize=true` (`render_info(clazz, true)`) and student emails are synthetic on all environments, so it exposes no real student PII. It is still unauthenticated and still used as-is; only the "leaks PII" premise was wrong.

### RESOLVED: Do we build the two-call `class_word` fallback, or omit it?
**Context**: The origin-class-word resolve reads `class_word` from `GET /api/v1/offerings/:resource_link_id`. RIGSE-352 gated that field on teacher-of-the-class, which raised a "if the token is learner-scoped, `class_word` is `nil`, so degrade to `offerings/:id` → `clazz_id` → `classes/:id` → `class_word`" fallback. Earlier passes deferred whether to build that fallback to `implementation.md`.
**Options considered**:
- A) Build the two-call fallback as a defensive path for an absent `class_word`.
- B) Omit it; treat an absent `class_word` as a classified failure (tell-your-teacher).

**Decision**: **B, omit it.** The fallback is unreachable for these pipelines and dropping it is strictly better:
- **Unreachable.** These pipelines only ever mint **teacher** tokens, and the origin-class-word resolve specifically uses the **origin-class** teacher token, whose subject the mint draws *strictly from `origin_clazz.teachers`* (`oidc_mint_controller.rb:66-72`) — a teacher of the origin class by construction. `offerings#show` gates `class_word` on `clazz.is_teacher?(current_user) || admin` (`api/v1/offering.rb`), always satisfied, so the single call returns `class_word` every time. The only edge case (an origin class with no teachers) fails the **mint** upstream and never reaches this read.
- **Correctness.** An absent `class_word` would signal a bug or misconfiguration; surfacing it as a classified failure is more honest than a silent second call that masks the anomaly.
- **No PII surface.** `classes#show` (`GET /api/v1/classes/:id`) is the only endpoint that de-anonymizes names for a class-teacher token (`has_full_access_to_student_data?`, `user.rb:482-490`), and the fallback is the only thing that would call it. Omitting the fallback means the story makes no `classes/:id` call, so it has **no real-PII surface at all**, and the roster-PII guard / unit test collapse to a single token-secrecy assertion.

**Where recorded**: the resolve requirement, the failure-handling / StepResult requirements, the no-PII acceptance criterion, the Verification and Endpoint-usage notes, and the second-pass "unreachable dead code" self-review item all reflect omit.

## Self-Review

### Senior Engineer

#### RESOLVED: The step-to-step handoff of the destination class word is undefined
The enroll step accepts a class word "supplied by a preceding step" (Q2 decision C), but the spec does not say **how** it is passed (a named `stepResults` key? a field on the run context?). Without a defined handoff, REPORT-81 (which produces the resolved `-Gator`/`-Shark` word) and this step could disagree. **Resolution**: Applied — the enroll requirement now states the destination is an authored `target_class_word` param or a documented handoff field on the preceding step's result, with the exact field to be pinned in `implementation.md`.

#### RESOLVED: The enroll's shared-teacher precondition is not restated
`add_to_class` double-authorizes `update_roster?` on the destination **and** student `:show?`, so the enrolling identity must be a teacher **shared** between the student's origin class and the destination class — exactly what the cross-class mint resolves (REPORT-83). This holds for an author-named destination too. **Resolution**: Applied — added a "Shared-teacher precondition for enroll" requirement and a matching acceptance criterion.

---

### QA Engineer

#### RESOLVED: No explicit, testable Acceptance Criteria section
The requirements fold acceptance into prose; the Jira's three ACs plus the new origin-resolve, the classifier buckets, and idempotency are not listed as crisp, testable criteria. **Resolution**: Applied — added an **Acceptance criteria** section covering the helper, the single-call origin resolve, class-word enroll with no db ids, idempotent re-run, the shared-teacher failure, the classifier buckets, and never-log.

#### RESOLVED: Verification approach for a story that wires no pipeline
REPORT-79 delivers the helper, resolve, and enroll step, but does not add them to any `PIPELINES` entry (that is REPORT-82), so there is no end-to-end pipeline to exercise here. **Resolution**: Applied — added a "Verification" Technical Note (unit tests with mocked `fetch` plus a new harness scenario against the stub portal).

---

### Security Engineer

#### RESOLVED: The steps assume the `platform_id` gate ran, but this story adds no gate
The helper, resolve, and enroll all call the portal at `platform_id`; the REPORT-83 `validatePortalHost` setup gate that structurally prevents forwarding a token to an untrusted host lives **per pipeline**, and this story wires no pipeline. **Resolution**: Applied — the Auth Technical Note now states the steps make no host check of their own and assume the gate has run, and that the consuming pipeline (REPORT-82) must apply it at setup.

#### RESOLVED: Never-log must cover the `classes/info` response, not just tokens
`classes/info` returns the class roster including **student emails**; logging that response body would leak PII even though it contains no token. **Resolution**: Applied — the failure-handling requirement and an acceptance criterion now forbid logging the `classes/info` response body / student PII in addition to tokens.

---

### Cross-Repo API Contract Reviewer

#### RESOLVED: The helper's cross-class `classes/info` read works only because that endpoint is unauthenticated
For a **target** class the acting teacher is not a teacher of (e.g. REPORT-80 resolving a `-Gator` offering), `classes/info` returns the data only because it has no `authorize` call today. Relying on that is fragile: if the portal later hardens `classes/info`, the helper would need a token scoped to the target class. **Resolution**: Applied — added a "Cross-class lookup assumption" Technical Note recording the dependency, without taking on the portal change.

---

### Product Manager

#### RESOLVED: Clarify this story does not modify the spring enroll
The spring enroll lives inside `random-assignment.ts` (assignment + enroll in one step); this story adds a **new**, separate `enroll-specified-class` step for the fall pipelines and leaves the spring path untouched. **Resolution**: Applied — added an Out-of-Scope bullet stating the spring enroll is untouched.

---

### Second pass (after applying round 1)

#### RESOLVED: The helper's token scoping is overstated and ignores a chicken-and-egg ordering
The class-lookup requirement says the helper "authenticates with a minted teacher token (**the acting teacher must be a teacher of that class**)", but that contradicts the cross-class-lookup assumption (the helper works on a class the acting teacher does *not* teach, because `classes/info` performs no authorization) and ignores an ordering problem: to enroll, the step must resolve the **destination** class word → `clazz_id` *before* it can mint a destination-scoped (cross-class) teacher token, so the lookup itself cannot use a destination-teacher token. **Resolution**: Applied — the class-lookup requirement now says the helper sends any available teacher token to the unauthenticated `classes/info`, and the destination-scoped cross-class mint is used for the subsequent `add_to_class`, not for the lookup.

#### RESOLVED: The "defensive" two-call resolve fallback may be unreachable dead code
Since `class_word` is reliably present on the single `offerings/:id` call with the origin-class teacher token (verified gate), the two-call fallback can never trigger for this pipeline's teacher tokens. Building and testing an unreachable path is waste. **Resolution**: Applied, then **decided (see the resolved Open Question "Do we build the two-call `class_word` fallback, or omit it?"): omit the fallback.** The resolve requirement, AC, and endpoint note now treat an absent `class_word` as a classified failure and drop the two-call path; the build-it-or-omit-it question, earlier deferred to `implementation.md`, is closed here as omit.

#### RESOLVED: "Reused by the teacher-notification email" no longer matches REPORT-83
The class-lookup requirement lists the helper as shared by "the enroll step, the offering-state step (REPORT-80), and the teacher-notification email." But REPORT-83's `send-email` already resolves its `class_id` via an **offering-read** (`GET /api/v1/offerings/:resource_link_id`), not `classes/info`, so notify does not use this helper. **Resolution**: Applied — the shared-by list now names the enroll step and the offering-state step (REPORT-80), and notes notify resolves its class via the REPORT-83 offering-read.

---

### Third pass (code-verified against rigse and report-service)

Every cross-repo claim in this spec was verified against rigse source (RIGSE-352 merged, `526cfb232`) and the report-service `functions/src` steps before these issues were written; all portal-contract claims held (recorded in the "Portal contract verified" Technical Note), so no factual corrections were needed and the single-call, no-fallback `class_word` read stands on verified ground. The four issues below are gaps the verification surfaced.

#### RESOLVED: Never-log-roster contradicts the reference logging pattern, with no test to enforce it (Security / QA)
The three existing steps all log `{ status, data: response.data }` on a portal failure (`lock-activity.ts:70`, `random-assignment.ts:433`, `send-email.ts:115`), and rigse's `classes#info` emits the **real** student email even when names are anonymized (`classes_controller.rb:126`). Copying that failure-log into the lookup helper would leak roster PII. **Resolution**: Applied. The failure-handling requirement and Verification note now warn against reusing `data: response.data` for `classes/info`, and an acceptance criterion requires a unit test asserting the helper logs no roster field / email on any path. **Superseded by the sixth pass (and the fallback-omit decision):** this item's premise (the `classes/info` body is real PII) was later disproved: emails are synthetic and `info` hardcodes `anonymize=true`, so the `classes/info` body may be logged. A roster-PII guard would attach only to the `classes/:id` fallback, which a later Open Question then **omitted**, so no roster-PII guard remains — only token-secrecy.

#### RESOLVED: The prior-step handoff has no representation in the current `StepResult` type (Architecture)
The enroll step accepts a destination word from "a documented handoff field on the preceding step's result," but `StepResult` is `{ success, message?, summary? }` and `stepResults` is consumed only for display, so no structured slot exists. **Resolution**: Applied. The enroll requirement and a new "Handoff contract" Technical Note state that this story (first in the REPORT-79 → 81 → 82 order) owns defining a typed handoff field on `StepResult` (a shared-contract change) that REPORT-81 later populates, with the exact shape pinned in `implementation.md`.

#### RESOLVED: The origin-class-word resolve duplicates send-email's offering-read (DRY, implementation)
The resolve's `GET /api/v1/offerings/:resource_link_id` → `class_word` is the same endpoint and token `send-email.ts` already calls for `clazz_id`, and rigse returns both fields in one `offerings#show` response. **Resolution**: Applied. Added an "Offering-read consolidation" Technical Note directing `implementation.md` to consider a single origin-offering read returning `{ clazz_id, class_word }` reused by both steps.

#### RESOLVED: The idempotency AC is a portal guarantee a mocked-fetch unit test cannot prove (QA)
`add_to_class` → `add_clazz` no-ops server-side (verified in rigse), so re-running enroll succeeds because of the portal, not report-service logic; a mocked-`fetch` test only asserts a 2xx `{ success: true }` maps to success. **Resolution**: Applied, then **revised by the fourth pass**: the AC and Verification note require a harness scenario that re-runs the enroll step and asserts success, but the earlier "the stub models the no-op" framing was corrected (the portal's no-op is wire-indistinguishable from a first enroll, so no stub can reproduce it). See the fourth-pass idempotency item for the honest statement of what the re-run proves.

---

### Fourth pass (fresh multi-role review, each issue verified against report-service `functions/` and rigse @ `526cfb232`)

Before writing each item below I re-verified the underlying code. Findings 1 and 2 critique the *resolution* the third pass adopted (the re-run harness scenario), which does not hold up once the current stub and the rigse wire shape are checked. Finding 3 extends the roster-PII guard to a second exfiltration channel the earlier Security items missed.

#### RESOLVED: The re-run harness scenario cannot verify idempotency; "the stub models the no-op" is not true (QA / Testability)
**Resolution**: Applied. The "stub models the no-op" wording was removed from the idempotency AC, the Verification note, and the third-pass item; all three now state honestly that the re-run proves step / `StepContext` / `tokenCache` re-invocation safety end-to-end, and that the portal no-op (wire-indistinguishable from a first enroll) rests on the rigse verification alone.

The third pass resolved the idempotency AC by adding a harness scenario that "re-runs the enroll step and asserts success (the stub's `add_to_class` models the no-op)" (AC line 43, Verification note line 52, third-pass item line 180). Verified against code, that resolution does not deliver what it claims:
- The stub's enroll route is **stateless** and returns `{ success: true }` on every call, tracking no membership (`stub-portal.js:84-93,196-198`). It does not model a no-op; it models unconditional success.
- Even a faithful, stateful stub **could not** observably model the no-op, because rigse's `add_clazz` no-ops but the controller still terminates in `render_ok` → `{ success: true }`, byte-identical to a first enrollment (`portal/student.rb:166-170`, `api/v1/students_controller.rb:197,255`). There is nothing on the wire for a stub to reproduce differently.
- The harness "re-run" is a whole-pipeline re-submit (`run.js`); what makes the second enroll return the same class is report-service's **own** assignment-doc dedup transaction (`random-assignment.ts:245-278`), not the portal. So the scenario exercises report-service re-invocation safety plus the 2xx→success mapping, which is exactly what the spec concedes the unit test already proves (AC line 43).

**Suggested resolution**: Drop "the stub models the no-op" wording from the AC, the Verification note, and the third-pass item. Restate the harness re-run's genuine value honestly (it proves the step/`StepContext`/`tokenCache` plumbing survives a second invocation end-to-end), and state plainly that neither the unit test nor the harness can prove the portal's server-side no-op, which rests on the cited rigse verification alone.

#### RESOLVED: The stub resolves every class word to one fixed class, so the enroll harness scenario cannot prove correct-class resolution (QA / Testability)
**Resolution**: Applied and **pinned into requirements**. Added a "Stub fidelity required for the enroll scenario" Verification note requiring the stub's `classes/info` to key its response on the requested `class_word` (distinct origin vs destination classes/ids) so the harness can assert enrollment into the id the destination word resolves to. Pinned in `requirements.md` (not deferred) because the "enrolls into the correct class" AC depends on it.

The Verification note promises "a new scenario in the local harness that drives the helper / resolve / enroll step against the stub portal" (line 52). Verified: the stub's `classes/info` handler ignores the `class_word` query param entirely and returns a single hard-coded class (`id: 90210`, `class_word: "FL-spring-2026-origin"`) for any word (`stub-portal.js:27-36,215-218`). A REPORT-79 scenario that enrolls a student into a **destination** class named by a different word would resolve that word to the origin class id, enroll into `90210`, and pass green while never exercising the "resolve the *correct* class by word" path the AC hinges on ("enrolls the student into the correct class in any environment ... resolved to `clazz_id` via the helper," lines 39, 42). Combined with the stateless enroll, the scenario as speced tests neither resolution nor idempotency.

**Suggested resolution**: The Verification note should require the stub's `classes/info` to key its response on the requested `class_word` (distinct origin vs destination classes/ids), so the harness scenario can assert the student is enrolled into the id the *destination* word resolves to, not a fixed one. Pin the stub-fidelity requirement here rather than leaving it to be discovered in `implementation.md`.

#### RESOLVED: The never-log-roster-PII guard misses the StepResult → teacher-email exfiltration channel (Security)
**Resolution**: Applied. Added a "Roster PII stays out of the StepResult, not just the log" requirement, extended the no-PII acceptance criterion to cover the returned `StepResult.summary`/`message` (which `send-email.ts:29-31` renders into the teacher email), and updated the Verification note's unit-test assertion to cover both the log and the `StepResult`. **Superseded by the sixth pass (and the fallback-omit decision):** the second-sink insight (`StepResult` → teacher email) stands, but its PII trigger does not for `classes/info` (anonymized names + synthetic emails); a real-names guard would attach only to the `classes/:id` fallback, which was then **omitted**, so the only `StepResult` assertion is token-secrecy.

The failure-handling requirement and its AC forbid **logging** the `classes/info` body / student emails (lines 35, 46), verified as real PII (`classes_controller.rb:125` emits `student.user.email` even under `anonymize=true`). But logs are not the only sink: `send-email.ts:29-31` renders every prior step's `result.summary ?? result.message` into the teacher-notification email body. If the lookup helper or enroll step ever placed any roster field (an email, a student name) into `StepResult.summary` or `message`, that PII would be emailed to the class teachers, bypassing the log-only guard. The spec already rejects reusing `summary` for the class-word handoff for a related reason (line 53), but does not state the roster-PII guard as covering this second channel.

**Suggested resolution**: Restate the guard as "never **log** and never place `classes/info` roster PII (student emails / names) into `StepResult.summary` or `message`," and note that `summary`/`message` flow into the `send-email` teacher notification (`send-email.ts:29-31`). Extend the no-log unit-test AC to also assert no roster field appears on the returned `StepResult`.

#### RESOLVED (minor): The helper's token wording implies a cached origin token always exists (Senior Engineer)
**Resolution**: Applied. The class-lookup requirement now says the helper obtains an origin (unscoped) teacher token via `getScopedPortalToken`, minting on a cache miss (the per-run cache starts empty and the lookup may be the first portal call), rather than implying reuse of an existing cached token.

The class-lookup requirement says the helper "sends a minted teacher token ... (any available teacher token suffices, e.g. the cached origin-class token ...)" (line 29). The token cache is per-run and empty at pipeline start (`index.ts:62`), and `getScopedPortalToken` mints on a cache miss (`portal-api.ts:207-219`), so the mechanism is fine, but the "e.g. the cached origin-class token" phrasing reads as if a cached token is guaranteed. If the lookup is the first portal call in its (REPORT-82) pipeline, there is no cached token to reuse. **Suggested resolution**: minor wording only, say the helper obtains an origin (unscoped) teacher token via `getScopedPortalToken`, minting on a cache miss, rather than implying reuse of an existing cached token.

---

### Fifth pass (fresh multi-role round on the post-fourth-pass requirements)

Re-reviewed the updated spec across QA, Security, DevOps/observability, and correctness lenses, spot-checking candidates against the code. One new minor item surfaced; nothing at medium or high severity.

#### RESOLVED (minor): The never-log emphasis risks stripping the one safe diagnostic (DevOps / Observability)
The failure-handling requirement forbids logging the `classes/info` body and says "log status and non-secret fields only," but does not affirmatively say to log the attempted `class_word`. Verified safe: `class_word` is an authored, environment-stable identifier, not PII and not a token, and a mis-authored word resolves to a `400` (`api_controller.rb:90`) → tell-your-teacher, where the word is the single most useful diagnostic. There is precedent for over-stripping (`send-email`'s offering-read failure log records only `{ status }`, `send-email.ts:94`), so a careful implementer could leave a production failure with no way to see which word failed. **Resolution**: Applied. The failure-handling requirement now states the lookup-failure log **should** include the attempted `class_word` while still excluding the response body.

---

---

### Sixth pass (live-portal probe + rigse re-verification of the roster-PII premise)

Before writing `implementation.md`, the roster-PII premise underlying the failure-handling / never-log guard was re-checked, both live and against rigse source, and it did not hold. This pass corrects it.

#### RESOLVED: The never-log guard rested on a false "`classes/info` leaks real student emails" premise (Security / Correctness)
Prior passes (first Security round, third pass, fourth-pass finding 3) justified a `classes/info`-specific never-log / never-into-`StepResult` guard on the claim that the body "carries the **real** student emails even when names are anonymized" (`classes_controller.rb:126`). Re-verified, that is wrong on both halves:
- Live probes of `GET /api/v1/classes/info?class_word=` against **staging** (`learn.portal.staging.concord.org`) and **production** (`learn.concord.org`) returned every student email as a synthetic `no-email-<uuid>@concord.org` placeholder. Student emails are not real on any environment.
- rigse's `info` action calls `render_info(clazz, true)` (`classes_controller.rb:66`), hardcoding `anonymize=true`, so `get_info` returns `anonymized_first_name` = `"Student"` + `anonymized_last_name` (`classes_controller.rb:124-127`, `portal/student.rb:70-72`). `classes/info` never returns real names, for any caller. The teacher/admin de-anonymization lives in the **separate** `show` action (`classes/:id`) via `has_full_access_to_student_data?` (`user.rb:482-490`), which is only reachable through the two-call fallback — now **omitted** (see the resolved Open Question), so this story never calls it.

So `classes/info` carries no real student PII, and a guard specific to it defends against a leak the endpoint cannot produce. **Resolution**: Applied. The failure-handling requirement, the roster-PII-in-`StepResult` requirement, the no-PII acceptance criterion, and the Verification note were rewritten: the `classes/info` body may be logged like the three existing steps; the only genuine real-PII surface would be the `classes/:id` fallback (`show` de-anonymizes names for a class-teacher token) — and a later Open Question **decided to omit that fallback**, so the story makes no `classes/:id` call and has no real-PII surface at all. The only unconditional unit-test assertion is token-secrecy, not roster-PII.

---

---

### Seventh pass (implementation-spec review; corrects the "no real-PII surface" conclusion)

Surfaced while writing `implementation.md` and re-verified against the RIGSE-352 checkout (`/home/doug/projects/rigse`, `api/v1/classes_controller.rb#get_info`).

#### RESOLVED: `classes/info` teachers[] carries real teacher names — "no real-PII surface at all" is too strong (Security, CONFIRMED)
The sixth pass correctly established that `classes/info` anonymizes **student** names (`render_info(clazz, true)` → `get_info` with `anonymize=true`) and returns synthetic student emails, and that omitting the `classes/:id` fallback removes the `classes#show` de-anonymization surface. But `get_info` returns **teachers'** `first_name`/`last_name` **unconditionally** (there is no anonymize branch on the `teachers[]` map), and `classes/info` is the endpoint this story's lookup helper calls. So the endpoint's response *does* carry real PII: **teacher names**. The prior conclusion "REPORT-79 has no real-PII surface at all ... leaves token-secrecy as the sole logging invariant" is therefore incorrect. **Correction**: the story's logging invariant is **token-secrecy AND teacher-name secrecy** — the lookup helper's `teachers[]` (real names) must never be logged or placed in a `StepResult` (`send-email` renders `summary`/`message` into the teacher email). The REPORT-79 enroll step is safe as written (it surfaces only the resolved class name + `class_word`, never `teachers[]`), and the guard is carried on the shared `PortalTeacher`/`PortalClass` types for REPORT-80, which also consumes the helper. The Failure-handling requirement, the "Keep roster data out of the StepResult" requirement, the no-PII acceptance criterion, and the Verification note should be read with "student roster is anonymized, but teacher names are real; keep `teachers[]` out of logs and `StepResult`" in place of "no real-PII surface at all." Note this is the one place the local RIGSE-352 checkout was consulted directly (`get_info`), reconfirming the offering shape (`url` = offering API url, `external_url` = activity url) at the same time — see `implementation.md`'s Cross-Repo self-review.

---

**Requirements self-review converged (with one seventh-pass correction).** Seven passes (Senior Engineer / QA / Security / Cross-Repo / PM, then a second and third pass, a fourth fresh code-verified round, a fifth round, a sixth live-probe + rigse re-verification that corrected the roster-PII premise, and a seventh implementation-spec pass that corrected the "no real-PII surface" conclusion) with every cross-repo and report-service claim ground-truthed against source (rigse @ `526cfb232`, the local RIGSE-352 checkout, and `functions/`) and, for the student-PII premise, against the live staging and production portals. All Open Questions and all Self-Review items are RESOLVED. The two-call `classes/:id` fallback is omitted (removing the `classes#show` student-name surface), and the logging invariant is **token-secrecy and teacher-name secrecy** (`classes/info` anonymizes students but returns real teacher names).
