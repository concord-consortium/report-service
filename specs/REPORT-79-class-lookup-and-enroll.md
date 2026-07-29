# Class Lookup Helper and Enroll-into-Class Pipeline Step

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-79

**Status**: **Closed**

## Overview

Add a shared portal class-lookup helper (resolve a class by its environment-stable class word) and a pipeline step that enrolls a student into an author-specified class resolved by class word, so a button authored once works in both staging and production with no database ids embedded in it.

This is the first of the fall-2026 "I'm Done" pipeline building blocks (epic DT-20). Portal class and offering database ids differ between staging and production, so the spring button hardcodes them, which does not travel between environments or scale to the ~24 fall classes. This story makes the pipeline resolve classes at run time by their human-assigned, environment-stable class word, and delivers the shared lookup helper the sibling fall stories (offering-state step, fall pipelines) reuse. It has no user-facing behavior change on its own; it is infrastructure the fall study is built on.

## Requirements

- **Class-lookup helper.** A helper that resolves a class by **class word** via `GET /api/v1/classes/info?class_word=<word>`, returning at least the class id, its offerings (id, name, active, locked, per-student metadata, activity URL), and its teachers. It obtains an **origin (unscoped) teacher** token via `getScopedPortalToken` (minting one on a cache miss, since the lookup may be the first portal call in its pipeline and the per-run cache starts empty) and sends it via the REPORT-83 `portalTokenFetch` path; any teacher token suffices, because `classes/info` performs no per-class authorization, so no destination-scoped mint is needed here. Failures are classified with the shared classifier. The destination-scoped cross-class mint is used for the subsequent `add_to_class`, **not** for this lookup, because the destination `clazz_id` is only known after the lookup returns. It is a shared helper reused by the enroll step (this story) and the offering-state step (REPORT-80); the teacher-notification email resolves its own `class_id` via the offering-read shipped in REPORT-83, not this helper.
- **Origin-class-word resolve (O14).** A resolve that returns the student's **origin class word** from the run context (`resource_link_id`) via the single call `GET /api/v1/offerings/:resource_link_id` to `class_word`. The merged portal serializer gates `class_word` on `clazz.is_teacher?(current_user) || admin`, and this story reads it with the **origin-class teacher** token the mint produces (a teacher of the origin class by construction), so the field is reliably present; no learner-scoped degradation applies, because these pipelines only ever mint teacher tokens. The two-call fallback (`offerings/:id` to `clazz_id` to `classes/:id` to `class_word`) is omitted. *(Delivered as a reusable read only: `resolveOriginOffering` returns `{ clazzId, classWord }`. Treating an unexpectedly-absent `class_word` as a classified failure belongs to the consuming step, which is REPORT-81 / REPORT-82 work; no step in this story reads the origin class word.)*
- **Enroll-into-class step.** A pipeline step that enrolls the student into a class **named by class word** (resolved to `clazz_id` via the helper), using `add_to_class`. The destination class word comes from **either an authored `target_class_word` param or a documented handoff field on the preceding step's result**, never a raw `clazz_id`; the step itself performs no randomization or class-word derivation (that lives in REPORT-81). Because `StepResult` had no structured output slot, this story **owns defining** the typed handoff field that REPORT-81 later populates.
- **Shared-teacher precondition for enroll.** The enrolling identity is a minted teacher **cross-class-scoped to the destination class**, which the mint resolves to a teacher **shared between** the student's origin class and the destination class (`add_to_class` authorizes `update_roster?` on the destination *and* student `:show?`, both satisfied by a shared teacher). A study whose origin and destination classes share no teacher yields a mint `422` to tell-your-teacher, so a shared teacher is an operator-verifiable setup precondition, as in the spring enroll.
- **Environment portability.** A button authored with a class word enrolls the student into the correct class in any environment, with **no database ids in the authored config**.
- **Idempotency.** Re-running the enroll step for a student already in the destination class is a **success**, not an error (double-click / retry / Cloud Tasks redelivery safe). This relies on the portal being idempotent server-side (`add_to_class` to `add_clazz` no-ops for an already-enrolled student, returning `{ success: true }`), so the step treats a 2xx success as success and needs no separate membership pre-check.
- **Failure handling.** Lookup and enroll failures route through the shared classifier to the same coarse student messages REPORT-83 established (reload / tell-your-teacher / generic), and never log a token value. The lookup-failure log **includes** the attempted `class_word` (an authored, environment-stable identifier, not PII and not a token) plus the status, since a mis-authored word resolves to a `400` to tell-your-teacher and the word is the single most useful field for diagnosing it. The `classes/info` response body carries no real *student* PII (the endpoint hardcodes `anonymize=true` and student emails are synthetic on all environments), but it does carry real **teacher names**, so `teachers[]` must never be logged.
- **Keep roster data out of the StepResult.** `send-email` renders every prior step's `result.summary ?? result.message` into the teacher-notification email body, so `StepResult` is a second sink, not just the log. Only non-PII display values (the resolved class word / class name) belong in `summary`, and the looked-up class's `teachers[]` must never reach it.

## Technical Notes

- **Files.** The reads live in a new `functions/src/tasks/portal-reads.ts`; the step is `functions/src/tasks/ai4vs-flvs/enroll-specified-class.ts`. The spring `random-assignment.ts` enroll is the reference pattern for the cross-class mint plus `add_to_class` call.
- **Auth.** Reuse REPORT-83's `getScopedPortalToken` (teacher scope, optional `classId` for a cross-class mint), `portalTokenFetch`, `classifyPortalFailure`, `messageForBucket`, and the per-run `tokenCache` on `StepContext`. **These steps make no host check of their own and assume the `validatePortalHost` setup gate has already run**, so any pipeline that consumes them (REPORT-82) must apply the gate at setup before the pipeline loop. It is the token-exfiltration guard and must not be dropped when the steps are reused. Each step passes the validated, normalized base URL that gate produced (`StepContext.portalOrigin`) as `portalUrl` for its portal calls, never the raw `jobDoc.platform_id`.
- **Verification.** Unit tests with mocked `fetch` (as REPORT-83) plus local-harness scenarios that drive the step against the stub portal, including a token-secrecy and teacher-name-secrecy assertion (no token value and no real teacher name on any path, in a log **or** on the returned `StepResult`). The harness re-runs the enroll step and asserts success; this exercises re-invocation safety of the step / `StepContext` / `tokenCache` end to end, but it does not (and cannot) prove the portal's server-side no-op, which is wire-indistinguishable from a first enrollment and rests on the rigse verification.
- **Stub fidelity.** The stub's `classes/info` keys its response on the requested `class_word` (distinct origin vs destination classes and ids) so the scenario exercises class-word resolution rather than passing green against a single fixed class, and its offering fixtures carry the `url` / `external_url` fields real `get_info` always returns.
- **Portal contract verified (rigse, RIGSE-352 @ `526cfb232` and a later local checkout).** `classes#info` has no `authorize` / `before_action` but calls `render_info(clazz, true)`, so it **always** anonymizes student names, and student emails are synthetic `no-email-*@concord.org` placeholders (confirmed live against staging and production); it returns teachers' real `first_name` / `last_name` unconditionally. `offerings#show` gates `class_word` on `clazz.is_teacher?(user) || admin`. `add_to_class` double-authorizes `update_roster?` plus student `:show?` and returns `{ success: true }`; `add_clazz` no-ops via `unless has_clazz?`. `classes#info` on a miss returns `error('The requested class was not found')`, which defaults to **400**. The origin (no-`class_id`) teacher mint draws its subject strictly from `origin_clazz.teachers`; the cross-class mint intersects origin/destination teachers and 422s when empty.
- **Cross-class lookup assumption.** The helper can read a **target** class the acting teacher does not teach (e.g. REPORT-80 resolving a `-Gator` offering) only because `classes/info` currently performs no authorization. This is an accepted assumption, not a design to build on; if the portal later hardens `classes/info`, the helper would need a token scoped to the target class.

## Out of Scope

- Program selection / dispatch and the fall pipelines themselves (REPORT-82).
- Randomization tables and Gator/Shark target derivation (REPORT-81).
- The offering-state (lock/hide/open) step (REPORT-80), though it reuses this story's helper.
- Any portal-side (rigse) change; this story consumes the existing portal endpoints as they are.
- Wiring the new step into a live `PIPELINES` entry (done by REPORT-82).
- Changing the existing spring enroll: the spring path enrolls inside `random-assignment.ts` and is left untouched; this story adds a **new**, separate `enroll-specified-class` step for the fall pipelines.

## Not Yet Implemented

- **No `PIPELINES` entry for the new step.** The step ships unwired by design; REPORT-82 owns adding the fall pilots that reach it. Consequence: the harness cannot drive it through `submitTask`, which is why the direct-step driver exists.
- **The origin-class-word resolve has no consumer yet.** `resolveOriginOffering` returns `class_word`, but only `send-email`'s `clazz_id` use is wired. The "an absent `class_word` fails the step with a classified message" behavior lands with the consuming step (REPORT-81 target derivation, REPORT-82 program classification).
- **No shared `enrollStudentInClass` helper.** The new step's cross-class mint plus `add_to_class` plus classify sequence duplicates ~15 lines of `random-assignment.ts`, deliberately left inline (see the decision below). Extracting a shared helper that `random-assignment` also adopts becomes worthwhile only if a third enroll caller appears.
- **`StepOutput.destinationClassWord` is defined but never populated.** REPORT-81's randomization step writes it; this story only defines the field, consumes it in the enroll step, and proves `send-email` never renders it.

## Decisions

### Does REPORT-79 include the origin-class-word resolve, or only the lookup helper and enroll step?
**Context**: The oob `stories.md` P1 explicitly scopes the origin-class-word resolve (O14) into REPORT-79, but the Jira summary/description name only the lookup helper and the enroll step.
**Options considered**:
- A) Include the origin-class-word resolve here; REPORT-82/81 consume it.
- B) Defer the resolve to REPORT-82; REPORT-79 is only the helper plus enroll step.
- C) Include only the resolve **helper** here (the reusable read), leaving "select the program from it" to REPORT-82.

**Decision**: **A**, delivered as a reusable **read** only (option C's scoping). REPORT-79 resolves `resource_link_id` to the origin class word; REPORT-81 derives its `-Gator` / `-Shark` targets from that word and REPORT-82 classifies the program (`FT-` / `FL-`) from it. The fixed Jira dependency order is REPORT-79 to REPORT-81 to REPORT-82, so the read must exist here.

---

### What is the authored contract for the enroll destination in this story?
**Context**: The step must accept "a class word (or a derivation rule)". REPORT-79 owns the non-randomized, explicitly-named-word case; the randomized `origin + -Gator/-Shark` derivation is REPORT-81/82.
**Options considered**:
- A) Accept only an explicit `target_class_word` param; the randomized destination is passed in as a resolved word by the randomization step.
- B) Also implement the `origin + -Gator/-Shark` derivation rule.
- C) Accept either an explicit word or a pre-resolved word from a prior step, but implement no derivation.

**Decision**: **C**. The enroll step takes a destination class word from either an authored param or a preceding step's output, resolves it via the helper, and enrolls; it implements no derivation. That keeps derivation in one place and the enroll step reusable by both the non-randomized and randomized paths.

---

### How is "already enrolled" determined for idempotency?
**Context**: The AC requires re-running the enroll to succeed for an already-enrolled student. Options differ in cost and portal trust.
**Options considered**:
- A) Rely on the portal: treat the `add_to_class` response for an existing member as success.
- B) Pre-check membership via the lookup helper's `students[]` and skip the enroll if already present.
- C) Both: pre-check, and also treat the portal's already-member response as success.

**Decision**: **A**. Confirmed in rigse that the portal is idempotent server-side: `add_to_class` to `Portal::Student#add_clazz` is `unless has_clazz?(clazz); clazzes << clazz`, so re-enrolling an existing member is a no-op that still renders `{ success: true }`. The step treats a 2xx success as success with no membership pre-check, which also avoids an extra roster read.

---

### How does this story use `classes#info`, given it is unauthenticated?
**Context**: `classes#info` has no `authorize`. Hardening it is portal (rigse) work and explicitly out of scope.
**Options considered**:
- A) Proceed as-is; request only what we need.
- B) Block REPORT-79 on a portal fix.
- C) Prefer the teacher-gated `offerings/:id` and `classes/:id` reads where they suffice; use `classes/info` only where offerings/teachers-by-word is needed.

**Decision**: **Proceed as-is (A)**, with C's split as the natural design rather than a security measure. The origin-class-word resolve uses the teacher-gated `offerings/:id`; `classes/info?class_word=` is used for the class to offerings/teachers lookup the helper exposes. The question's original "PII-leaky" framing was later disproved: `classes/info` hardcodes `anonymize=true` and student emails are synthetic, so it exposes no real *student* PII. It does return real *teacher* names, which is what the logging invariant guards.

---

### Do we build the two-call `class_word` fallback, or omit it?
**Context**: RIGSE-352 gated `class_word` on teacher-of-the-class, which raised a "if the token is learner-scoped, degrade to `offerings/:id` to `clazz_id` to `classes/:id` to `class_word`" fallback.
**Options considered**:
- A) Build the two-call fallback as a defensive path for an absent `class_word`.
- B) Omit it; treat an absent `class_word` as a classified failure.

**Decision**: **B, omit it.** The fallback is unreachable (these pipelines only mint teacher tokens, and the origin mint draws its subject strictly from `origin_clazz.teachers`, so the gate is always satisfied; an origin class with no teachers fails the mint upstream). Surfacing an absent `class_word` as a classified failure is more honest than a silent second call that masks the anomaly, and omitting the fallback means the story never calls `classes#show`, the only endpoint that de-anonymizes student names.

---

### What is the name and shape of the typed handoff field on `StepResult`?
**Context**: This story owns the structured slot REPORT-81 populates with the resolved destination class word. It cannot be `summary` / `message`, which `send-email` renders into the teacher email.
**Options considered**:
- A) `output?: StepOutput` where `StepOutput = { destinationClassWord?: string }`.
- B) `output?: Record<string, unknown>`: a generic, untyped bag.
- C) A dedicated top-level field, e.g. `destinationClassWord?: string` directly on `StepResult`.
- D) A templated `StepResult<TOutput = StepOutput>`.

**Decision**: **A**, a plain non-generic `output?: StepOutput`. Excess-property checking already gives producer-side typo safety, and the consumer reads a runtime-guarded `string | undefined` either way, so the generic (D) closes no gap that matters; C pollutes the shared type with one story's concern. Adding the default type param later stays backward-compatible.

---

### Do we consolidate `send-email`'s offering-read now, or leave it and only add the new helper?
**Context**: The origin-offering read already existed inline in the shipped `send-email` step, and this story needs the same read plus `class_word`.
**Options considered**:
- A) Extract `resolveOriginOffering` and refactor `send-email` onto it now.
- B) Add the helper for this story's use only; leave `send-email`'s inline read untouched.

**Decision**: **A**, as its own isolated, behavior-preserving commit. The only behavior change is dropping the `reason: data?.details?.reason` argument to `classifyPortalFailure`, which `offerings#show` never returns, so the existing `send-email` offering-read tests stay green (verified).

---

### How does the harness exercise the new step, given this story wires no `PIPELINES` entry?
**Context**: The harness runs through `submitTask` to `ai4vsFlvs` to `PIPELINES[request.pilot]`, and only `spring-2026` is wired.
**Options considered**:
- A) A direct step driver (`run-step.js`) that imports the compiled step, builds a `StepContext`, and calls it directly.
- B) A harness-only pilot added to `PIPELINES`.
- C) Defer any harness coverage to REPORT-82.

**Decision**: **A**, verified end to end with a throwaway POC before the plan was finalized. A standalone Node process can run the full origin-mint to `classes/info` to cross-class-mint to `add_to_class` sequence against the stub; **the enroll step reads no Firestore**, so the driver needs only the stub, not the emulator. The driver must set `FUNCTIONS_EMULATOR=true` and `PORTAL_OIDC_TOKEN` so `portalOidcFetch` uses the env-token auth path. B was rejected because it adds a production `PIPELINES` entry this story's scope assigns to REPORT-82; C contradicts the requirements.

---

### Where do the portal reads live: a new `portal-reads.ts`, or added to `portal-api.ts`?
**Context**: `portal-api.ts` is transport/auth/mint/classify with no endpoint-specific reads, while the new functions are endpoint-specific reads returning domain shapes.
**Options considered**:
- A) A new `functions/src/tasks/portal-reads.ts` sibling.
- B) Add them into `portal-api.ts`.

**Decision**: **A**. It keeps the layering explicit (`portal-api` = how to call the portal, `portal-reads` = specific reads returning domain types) and gives REPORT-80 a natural module to import the shared lookup from.

---

### Which offering field is the "activity URL"?
**Context**: `get_info` returns each offering with **two** URL fields: `url` (`api_v1_offering_url`, the offering's own API url) and `external_url` (`offering.runnable.url`, the underlying activity url). The draft mapped `url` as the activity URL, which is wrong, and REPORT-80 imports the type.
**Decision**: `PortalOffering` exposes both, as `offeringApiUrl` (from `url`) and `activityUrl` (from `external_url`), and a unit test asserts `activityUrl` maps from `external_url` and not from `url`.

---

### Is `classes/info` a real-PII surface?
**Context**: Successive passes swung between "it leaks student emails" and "it has no real-PII surface at all". Both were wrong.
**Decision**: `classes/info` anonymizes **students** (`render_info(clazz, true)`) and its student emails are synthetic on all environments, but it returns **teachers'** real `first_name` / `last_name` unconditionally. The logging invariant is therefore **token-secrecy AND teacher-name secrecy**: the helper's `teachers[]` must never be logged or placed in a `StepResult`. The guard is carried on the shared `PortalTeacher` / `PortalClass` types for REPORT-80, and the enroll step's unit tests assert both sentinels are absent from every logger call and from the returned result.

---

### What happens when an authored `target_class_word` and a prior step's handoff word are both present?
**Context**: The first draft preferred the authored word and logged at info. Since `target_class_word` is a per-launch request param, a button authored with a fixed word **and** wired to randomization would route every student to the one authored class, silently defeating randomization for the whole study, and an info-level log is low-visibility for that blast radius.
**Options considered**:
- A) Authored silently wins, logged at info.
- B) Differing words are a hard configuration error.

**Decision**: **B**. `resolveDestinationWord` returns a discriminated result, and an authored word that **differs** from a present handoff yields the tell-your-teacher message, an **error** log, and **no portal calls**. An authored word **equal** to the handoff is not a conflict. Missing-both is a separate reason mapped to the generic message. There is no intended "authored overrides randomization" use case, so the conflict is treated as a mis-authoring to be fixed, not a preference to be guessed through.

---

### How does the harness prove the step enrolled into the *correct* class?
**Context**: An earlier plan had the driver assert the enrolled `clazz_id` equals the destination id, which is not implementable: the step returns the class **name** in its summary, the stub's enroll route is stateless with no echo of the posted body, and the driver runs the step in-process while the stub is a separate process.
**Decision**: The stub serves a destination class with a **distinct name and id** (`30001` / `FT-fall-2026-A`, versus the origin `90210` / `FL-spring-2026-origin`), and the driver asserts the returned `summary` names the **destination** class on **both** runs. The summary's class name flows from resolving the destination word against the class-word-keyed stub, so it proves correct-class resolution without observing the raw `clazz_id`; asserting `success` alone would not, because the stateless stub returns `{ success: true }` even for a wrong-class resolution.

---

### Should the enroll mint plus `add_to_class` plus classify sequence be extracted, as the offering-read was?
**Context**: The new step's last two stages are near-identical to `random-assignment.ts`, yet this story *does* extract the analogous offering-read into a shared helper. The asymmetry is real.
**Decision**: Keep the enroll inline, deliberately. The only other enroll caller is the shipped spring `random-assignment`, whose enroll is embedded in Firestore assignment logic and is explicitly out of scope to modify here (unlike the offering-read, a self-contained call that consolidates cleanly); REPORT-80 does not enroll, so there is no third caller; and the reusable seam already exists one level down (`getScopedPortalToken` / `portalTokenFetch` / `classifyPortalFailure` / `messageForBucket`), so the duplication is ~15 lines of orchestration that reads more clearly inline. If a third enroll caller appears, extracting a shared `enrollStudentInClass` that `random-assignment` also adopts is a backward-compatible follow-up.

---

### Do the read helpers return the portal's error body on failure?
**Context**: `lookupClassByWord` / `resolveOriginOffering` return only `{ status }` on a non-2xx, so the calling step cannot log the portal's error body.
**Decision**: Status-only, accepted. The attempted `class_word` (which the step logs) is the single most useful diagnostic for the dominant failure, a mis-authored word, and keeping the reads body-free keeps them lean. Adding `data` to the read result later is backward-compatible.

---

### What did the shipped code have to change from the plan?
**Context**: Recorded during implementation so the plan and the code agree.
**Decision**: Five deltas, all forced by a check or by a gap in the plan's own harness design. (1) `tslint`'s `no-shadowed-variable` forced four local renames in the enroll step (`handedOff`, and `originMintBucket` / `lookupBucket` / `enrollMintBucket` / `enrollBucket`). (2) `portal-reads.test.ts` mocks `./portal-api` wholesale instead of spreading `requireActual`, which would load `firebase-functions` for no benefit; the step tests keep the spread because they need the real classifier. (3) Harness scenarios carry a `driver: "run-step"` field and `run-all.js` dispatches on it, since it otherwise submits every scenario as a `spring-2026` pipeline run. (4) The class fixtures moved to `config.js` (both the stub and the scenarios need them), and the planned "`class_word=` behavior key" is implemented as a `classes: "ok" | "forbidden"` behavior plus a third scenario, keeping the stub's every-behavior-has-a-scenario invariant true. (5) `run-step.js` asserts the student `message` on failure scenarios, symmetric with the summary assertion on success. `send-email`'s tests needed no retarget (the transport-level mocks intercept the helper's call transparently) and instead gained the regression test that keeps a step's structured `output` out of the teacher email.
