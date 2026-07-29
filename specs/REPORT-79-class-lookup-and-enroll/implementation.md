# Implementation Plan: Class Lookup Helper and Enroll-into-Class Pipeline Step

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-79
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Orientation (verified against the current tree)

The fall "I'm Done" steps this story adds are built entirely from REPORT-83 infrastructure that already exists in `functions/src/tasks/portal-api.ts`:

- `getScopedPortalToken({ cache, portalUrl, firebaseToken, tokenType, classId?, pilot })` mints (or returns a cached) teacher token. Omit `classId` for the origin (unscoped) mint; pass it for a destination-scoped cross-class mint. (`portal-api.ts:200-219`)
- `portalTokenFetch({ portalUrl, path, method, token, body?, headers? })` performs the bearer call and returns `{ status, data }`. The token is opaque, never logged. (`portal-api.ts:86-93`)
- `classifyPortalFailure({ status, reason? })` → `PortalFailureBucket` (`Reload` / `TellTeacher` / `Generic`); `messageForBucket(bucket, genericFallback)` maps to the coarse student string. Only mint `422 reason:"expired"` is `Reload`; every other 4xx is `TellTeacher`; the rest is `Generic`. (`portal-api.ts:152-198`)
- The per-run token cache lives on `StepContext.tokenCache` (`index.ts:62`), keyed `teacher:<classId | "origin">`, empty at pipeline start.
- The validated, normalized portal base URL lives on `StepContext.portalOrigin` (the `url.origin` `validatePortalHost` returns at the setup gate). Every step passes `portalOrigin` as `portalUrl` for its portal calls and never the raw `jobDoc.platform_id`, which REPORT-83 keeps only as an identity value. The steps this story adds follow the same rule.

The reference enroll is the spring `randomAssignment` step (`random-assignment.ts:397-436`): cross-class mint scoped to the destination `classId`, then `POST /api/v1/students/add_to_class` with `{ user_id, clazz_id }`, treating a 2xx `{ success: true }` as success and routing every other outcome through the classifier. This story's enroll is the same call, differing only in that the destination `clazz_id` is **resolved from a class word at run time** instead of read from an authored `treatment_class_id` / `control_class_id`.

The origin-offering read already exists inline in `send-email` (`send-email.ts:84-97`): `GET /api/v1/offerings/:resource_link_id` with the origin teacher token, reading `clazz_id`. rigse returns `class_word` in the **same** response (teacher-gated, satisfied by the origin-class teacher token), so this story's origin-class-word resolve is that same call reading one more field.

**Shared contract facts that shape the steps below:**

- `StepResult` is `{ success: boolean; message?: string; summary?: string }` (`types.ts:4`). There is **no** structured output slot. `send-email` renders every prior step's `result.summary ?? result.message` into the teacher-notification email body (`send-email.ts:29-31`), so neither `summary` nor `message` can carry the machine-readable destination class word. This story owns adding the typed handoff field (REPORT-81 populates it).
- The harness (`functions/harness/im-done-local/`) drives runs through `submitTask` → `executeTask` → `ai4vsFlvs`, which selects steps from `PIPELINES[request.pilot]` (`index.ts:17-24, 45`). Only `spring-2026` is wired. This story adds **no** `PIPELINES` entry (REPORT-82 owns that), so the harness cannot reach the new step through a pilot pipeline without extra scaffolding (see the Open Question on harness verification).
- The stub's `classes/info` handler ignores the `class_word` query param and returns a single hard-coded class (`id: 90210`, `class_word: "FL-spring-2026-origin"`) for any word (`stub-portal.js:27-36, 215-218`); its `add_to_class` is stateless `{ success: true }` (`stub-portal.js:84-93`). Requirements pin that the enroll scenario needs `classes/info` keyed on `class_word` (distinct origin vs destination ids) so "enrolls into the correct class" is actually exercised.

## Implementation Plan

### Add the typed step-handoff field and the shared portal-read helpers

**Summary**: Establish the two shared foundations the enroll step and the fall siblings build on, with nothing student-facing yet: (1) the typed handoff field on `StepResult`, and (2) the class-lookup-by-word read and the origin-offering read (returning `{ clazz_id, class_word }`), both as pure portal reads that take an already-minted token. Kept in one commit because the reads' return types and the handoff type are the contract the next commits import.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/types.ts` — add the typed handoff field to `StepResult`.
- `functions/src/tasks/portal-reads.ts` — **new**: `lookupClassByWord`, `resolveOriginOffering`, and their return types.
- `functions/src/tasks/portal-reads.test.ts` — **new**: unit tests (mocked `portalTokenFetch`), including token-secrecy.

**Estimated diff size**: ~320 lines (most of it the new test file).

**`types.ts` change (before → after):**

```ts
// before
export type StepResult = { success: boolean; message?: string; summary?: string };

// after
/**
 * Machine-readable handoff between pipeline steps. Unlike `summary`/`message`
 * (which send-email renders into the teacher-notification email, send-email.ts:29-31),
 * `output` is NEVER rendered into any human-facing sink, so it is the only safe
 * carrier for values a later step consumes (e.g. a resolved destination class word).
 * REPORT-79 defines it; REPORT-81's randomization step populates destinationClassWord.
 */
export interface StepOutput {
  /** Class word the enroll step should resolve and enroll into (REPORT-81 sets it). */
  destinationClassWord?: string;
}

export type StepResult = {
  success: boolean;
  message?: string;
  summary?: string;
  output?: StepOutput;
};
```

`index.ts` already copies each `result` into `stepContext.stepResults[step.name]` wholesale (`index.ts:74`), so `output` rides along with no pipeline-loop change. `send-email`'s body builder reads only `summary ?? message` (`send-email.ts:30`), so `output` is structurally excluded from the email; no send-email change is required for safety, and a regression test asserts it.

**`portal-reads.ts` (new, full):**

```ts
import { portalTokenFetch } from "./portal-api";

/** One offering as returned inside classes#info's `offerings[]` (get_info shape). */
export interface PortalOffering {
  id: number;
  name: string;
  active: boolean;
  locked: boolean;
  /** Per-student metadata array; opaque to this story, surfaced for REPORT-80. */
  metadata: unknown[];
  /** The offering's own portal API URL (get_info `url` => api_v1_offering_url). */
  offeringApiUrl?: string;
  /** The underlying activity URL (get_info `external_url` => runnable.url); what REPORT-80 needs. */
  activityUrl?: string;
}

/**
 * PII NOTE: unlike students (get_info anonymizes their names, and student emails are
 * synthetic), get_info returns teachers' REAL first_name/last_name. `teachers[]` is
 * therefore real PII — never log a PortalClass.teachers[] and never place it in a
 * StepResult. The REPORT-79 enroll step surfaces only class name + class_word, so it
 * is safe; this guard exists for REPORT-80 and any future consumer of the helper.
 */
export interface PortalTeacher {
  id: string;
  user_id: number;
  first_name: string;
  last_name: string;
}

/** The subset of classes#info this story and REPORT-80 consume. */
export interface PortalClass {
  id: number;
  name: string;
  classWord: string;
  teachers: PortalTeacher[];
  offerings: PortalOffering[];
}

export interface ClassLookupResult {
  status: number;
  class?: PortalClass;
}

/**
 * Resolve a class by its environment-stable class word via
 * GET /api/v1/classes/info?class_word=<word>.
 *
 * `classes#info` performs no per-class authorization, so ANY valid teacher token
 * suffices — the caller passes the origin (unscoped) teacher token. The endpoint
 * hardcodes anonymize=true (names come back as "Student"), and student emails are
 * synthetic on all environments, so the body carries no real student PII.
 *
 * The token is passed straight to portalTokenFetch and never inspected here.
 */
export const lookupClassByWord = async (
  portalUrl: string,
  token: string,
  classWord: string,
): Promise<ClassLookupResult> => {
  const path = `/api/v1/classes/info?class_word=${encodeURIComponent(classWord)}`;
  const response = await portalTokenFetch({ portalUrl, path, method: "GET", token });

  const ok = response.status >= 200 && response.status < 300 && response.data?.id !== undefined;
  if (!ok) {
    return { status: response.status };
  }

  const data = response.data;
  const resolved: PortalClass = {
    id: data.id,
    name: data.name,
    classWord: data.class_word,
    teachers: Array.isArray(data.teachers) ? data.teachers : [],
    offerings: Array.isArray(data.offerings)
      ? data.offerings.map((o: any) => ({
          id: o.id,
          name: o.name,
          active: !!o.active,
          locked: !!o.locked,
          metadata: Array.isArray(o.metadata) ? o.metadata : [],
          // get_info returns BOTH: `url` = the offering's API URL, `external_url` = the activity URL.
          offeringApiUrl: typeof o.url === "string" ? o.url : undefined,
          activityUrl: typeof o.external_url === "string" ? o.external_url : undefined,
        }))
      : [],
  };
  return { status: response.status, class: resolved };
};

export interface OriginOffering {
  clazzId: number | string;
  classWord?: string;
}

export interface OriginOfferingResult {
  status: number;
  offering?: OriginOffering;
}

/**
 * Read the student's origin offering by resource_link_id, returning both clazz_id
 * (unconditional) and class_word (teacher-gated; present for the origin-class
 * teacher token these pipelines mint) from the single offerings#show response.
 * This is the same GET send-email makes for clazz_id; both consume this helper.
 */
export const resolveOriginOffering = async (
  portalUrl: string,
  token: string,
  offeringId: string,
): Promise<OriginOfferingResult> => {
  const response = await portalTokenFetch({
    portalUrl,
    path: `/api/v1/offerings/${offeringId}`,
    method: "GET",
    token,
  });
  const clazzId = response.data?.clazz_id;
  const ok =
    response.status >= 200 && response.status < 300 && clazzId !== undefined && clazzId !== null;
  if (!ok) {
    return { status: response.status };
  }
  return {
    status: response.status,
    offering: {
      clazzId,
      classWord: typeof response.data?.class_word === "string" ? response.data.class_word : undefined,
    },
  };
};
```

Both helpers take a token and return a plain result; they perform no minting and no classification, so the calling step owns the classifier + student message (matching how the existing steps keep policy in the step and transport in `portal-api`). A lookup failure returns only `{ status }`; the **step** logs the attempted `class_word` + status (safe, non-PII, non-token, per the fifth-pass requirement).

**Tests (`portal-reads.test.ts`)**: mock `portalTokenFetch`; the `get_info` fixture mirrors the real shape (offering with both `url` and `external_url`, teachers with real names). Assert (a) `lookupClassByWord` builds `?class_word=` url-encoded and maps a `get_info` body to `PortalClass`, including `activityUrl` from `external_url` (not `url`); (b) it returns `{ status }` only on non-2xx / missing `id`; (c) `resolveOriginOffering` returns `{ clazzId, classWord }` from one response and `{ status }` when `clazz_id` is absent; (d) neither helper places the token anywhere in its return value (token-secrecy).

---

### Route send-email's offering-read through the shared helper (consolidation)

**Summary**: Replace `send-email`'s inline `GET /api/v1/offerings/:id` + `clazz_id` extraction with `resolveOriginOffering`, so the origin-offering read has a single implementation both steps share. Behavior-preserving; discrete so its risk to a shipped step is isolated and reviewable on its own.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/send-email.ts` — call `resolveOriginOffering` instead of the inline fetch.
- `functions/src/tasks/ai4vs-flvs/send-email.test.ts` — retarget the offering-read mocks/assertions at the helper (behavior unchanged).

**Estimated diff size**: ~70 lines.

**`send-email.ts` change (before → after):**

```ts
// before (send-email.ts:83-97) — note REPORT-83 ships this with portalUrl: portalOrigin
const offeringResp = await portalTokenFetch({
  portalUrl: portalOrigin,
  path: `/api/v1/offerings/${resource_link_id}`,
  method: "GET",
  token,
});
const classId = offeringResp.data?.clazz_id;
const offeringOk =
  offeringResp.status >= 200 && offeringResp.status < 300 && classId !== undefined && classId !== null;
if (!offeringOk) {
  functions.logger.error(`send-email: offering-read failed for ${jobPath}`, { status: offeringResp.status });
  const offeringBucket = classifyPortalFailure({ status: offeringResp.status, reason: offeringResp.data?.details?.reason });
  return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
}

// after — pass the same validated origin the step already destructures (context.portalOrigin)
const origin = await resolveOriginOffering(portalOrigin, token, String(resource_link_id));
if (!origin.offering) {
  functions.logger.error(`send-email: offering-read failed for ${jobPath}`, { status: origin.status });
  const offeringBucket = classifyPortalFailure({ status: origin.status });
  return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
}
const classId = origin.offering.clazzId;
```

Note the `reason` on the offering-read classify was always `undefined` in practice (`offerings#show` returns no `details.reason`), so dropping it is behavior-preserving; the existing send-email tests for 403/404/no-clazz/5xx stay green.

---

### Add the enroll-specified-class step

**Summary**: The story's core deliverable: a step that resolves an author-specified (or handed-off) destination class word to a `clazz_id` via `lookupClassByWord`, then enrolls the student with a destination-scoped cross-class mint + `add_to_class`, idempotent and classifier-routed, leaking no token or roster into logs or `StepResult`.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/enroll-specified-class.ts` — **new**: the step.
- `functions/src/tasks/ai4vs-flvs/enroll-specified-class.test.ts` — **new**: unit tests (mocked `getScopedPortalToken` / `portalTokenFetch` / helpers).

**Estimated diff size**: ~380 lines (most of it tests).

**`enroll-specified-class.ts` (new, full):**

```ts
import * as functions from "firebase-functions";
import { StepContext, StepResult } from "./types";
import {
  getScopedPortalToken, portalTokenFetch, classifyPortalFailure, messageForBucket, TELL_TEACHER_MESSAGE,
} from "../portal-api";
import { lookupClassByWord } from "../portal-reads";

const STUDENT_FAILURE_MESSAGE =
  "Unable to enroll you in your class. Please try again or contact your teacher.";

/**
 * Destination class word: an authored `target_class_word` request param, or the
 * preceding step's `output.destinationClassWord` handoff. Exactly ONE upstream step
 * (REPORT-81's randomization) is expected to set `destinationClassWord`; the scan
 * takes the first that does (Record iteration is insertion = pipeline order).
 * Never a raw clazz_id — no db ids in the authored config.
 *
 * Precedence is deliberately NOT "authored silently wins". `target_class_word` is a
 * per-launch request param, so a button authored with a fixed word AND wired to
 * REPORT-81 randomization would route EVERY student to the one authored class,
 * silently defeating randomization for the whole study (a study-wide blast radius an
 * info-level log easily hides). There is no intended "authored overrides
 * randomization" use case, so an authored word that DIFFERS from a present handoff is
 * treated as a hard configuration error (`conflict`, mapped to tell-your-teacher and
 * logged at error), not a silent preference. An authored word EQUAL to the handoff is
 * not a conflict. Missing-both is a separate `missing` reason.
 */
type DestinationWordResolution =
  | { ok: true; word: string }
  | { ok: false; reason: "missing" | "conflict" };

const resolveDestinationWord = (context: StepContext, jobPath: string): DestinationWordResolution => {
  const authoredRaw = context.jobDoc.jobInfo.request.target_class_word;
  const authored = typeof authoredRaw === "string" && authoredRaw.trim() ? authoredRaw.trim() : undefined;

  let handoff: string | undefined;
  for (const result of Object.values(context.stepResults)) {
    const word = result.output?.destinationClassWord;
    if (typeof word === "string" && word.trim()) {
      handoff = word.trim();
      break;
    }
  }

  if (authored && handoff && authored !== handoff) {
    functions.logger.error(
      `enroll-specified-class: conflicting destination words (authored target_class_word differs from the handoff destinationClassWord); refusing to guess for ${jobPath}`,
    );
    return { ok: false, reason: "conflict" };
  }

  const word = authored ?? handoff;
  if (!word) {
    return { ok: false, reason: "missing" };
  }
  return { ok: true, word };
};

/**
 * Enroll the student into an author-specified (or handed-off) class, resolved by
 * class word at run time. Like lock-activity / send-email, this step makes NO host
 * check of its own: it assumes the consuming pipeline (REPORT-82) ran validatePortalHost
 * at setup before the pipeline loop, and it uses the validated, normalized base URL that
 * gate produced (StepContext.portalOrigin) for every portal call, never the raw
 * jobDoc.platform_id. That gate is the token-exfiltration guard and must not be dropped
 * when this step is wired into a pipeline.
 */
export const enrollSpecifiedClass = async (context: StepContext): Promise<StepResult> => {
  const { jobPath, jobDoc, firebaseJwt, tokenCache, portalOrigin } = context;
  const { platform_id, platform_user_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  if (!platform_id || !platform_user_id) {
    const missing = [!platform_id && "platform_id", !platform_user_id && "platform_user_id"]
      .filter(Boolean).join(", ");
    functions.logger.error(`enroll-specified-class: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (!firebaseJwt) {
    functions.logger.error(`enroll-specified-class: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  const destination = resolveDestinationWord(context, jobPath);
  if (!destination.ok) {
    if (destination.reason === "conflict") {
      // A study-wide authoring mistake (authored word vs randomization handoff), not a
      // transient error and not something to guess through: tell the teacher.
      return { success: false, message: TELL_TEACHER_MESSAGE };
    }
    functions.logger.error(`enroll-specified-class: no destination class word (param or handoff) for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  const destinationWord = destination.word;

  try {
    // 1) Origin (unscoped) teacher token — any teacher token can read classes/info.
    const originToken = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
    });
    if (!originToken.ok || !originToken.token) {
      const bucket = classifyPortalFailure({ status: originToken.status, reason: originToken.reason });
      return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
    }

    // 2) Resolve the destination class word -> clazz_id via the shared helper.
    const lookup = await lookupClassByWord(portalOrigin, originToken.token, destinationWord);
    if (!lookup.class) {
      // Safe to log the attempted word: authored, environment-stable, not PII, not a token.
      functions.logger.error(
        `enroll-specified-class: class lookup failed for ${jobPath}`,
        { status: lookup.status, class_word: destinationWord },
      );
      const bucket = classifyPortalFailure({ status: lookup.status });
      return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
    }
    const destinationClassId = String(lookup.class.id);

    // 3) Destination-scoped cross-class mint (a teacher shared between origin and destination).
    const enrollToken = await getScopedPortalToken({
      cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher",
      classId: destinationClassId, pilot,
    });
    if (!enrollToken.ok || !enrollToken.token) {
      const bucket = classifyPortalFailure({ status: enrollToken.status, reason: enrollToken.reason });
      return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
    }

    // 4) Enroll. Server-side idempotent: an already-enrolled student still returns { success: true }.
    functions.logger.info(
      `enroll-specified-class: enrolling user ${platform_user_id} into ${lookup.class.name} (${destinationClassId}) at ${platform_id} (${jobPath})`,
    );
    const response = await portalTokenFetch({
      portalUrl: portalOrigin,
      path: "/api/v1/students/add_to_class",
      method: "POST",
      token: enrollToken.token,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: String(platform_user_id), clazz_id: destinationClassId }),
    });

    if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
      functions.logger.info(`enroll-specified-class: enrolled user ${platform_user_id} into ${lookup.class.name} (${jobPath})`);
      // summary is display-only (rendered into the teacher email); a non-PII class name is fine.
      return { success: true, summary: `Enrolled in ${lookup.class.name}` };
    }

    functions.logger.error(
      `enroll-specified-class: Portal enrollment failed for ${jobPath}`,
      { status: response.status, data: response.data },
    );
    const bucket = classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason });
    return { success: false, message: messageForBucket(bucket, STUDENT_FAILURE_MESSAGE) };
  } catch (error) {
    functions.logger.error(`enroll-specified-class: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
};
```

**Unit tests (`enroll-specified-class.test.ts`)** — mock `getScopedPortalToken`, `portalTokenFetch`, and `lookupClassByWord`; keep the real classifier:

- **Resolves by authored word**: `target_class_word: "FT-fall-2026-A"` → looks up that word → cross-class mint uses the resolved `clazz_id` → `add_to_class` posts that `clazz_id`; asserts **no db id ever appears in the request** (input is the word).
- **Resolves by handoff**: no param, a prior `stepResults` entry with `output.destinationClassWord` → same path.
- **Conflict when both present and differing**: an authored `target_class_word` and a *differing* handoff word → failure with the tell-your-teacher message, an **error** log records the conflict, and **no portal calls** are made (randomization is not silently defeated).
- **Both present but equal**: an authored word equal to the handoff → proceeds normally (not a conflict), resolving that word.
- **No destination word** (neither param nor handoff) → failure, generic message, no portal calls.
- **Idempotent re-run**: a 2xx `{ success: true }` maps to `{ success: true }` (the only wire-observable behavior; see the AC note — the portal no-op is not observable).
- **Shared-teacher failure**: the destination-scoped mint returns `422` (no shared teacher) → `tell your teacher`; no `add_to_class` call.
- **Classifier buckets**: lookup `400` → tell-teacher (and the log includes `class_word`, not the body only); enroll `403` → tell-teacher; enroll `nonsuccess`/`5xx` → generic; thrown fetch → generic.
- **Token- and teacher-name secrecy**: across success and every failure path, neither a minted token value **nor** any real teacher name from the looked-up class appears in any `logger` call **or** on the returned `StepResult` (`summary`/`message`/`output`). The lookup fixture returns a class whose `teachers[]` carries a sentinel real name and whose mint returns a sentinel token; assert both sentinels are absent from `JSON.stringify` of all logger args and of the result. (get_info does not anonymize teacher names, so this is a real-PII guard, not just token-secrecy.)

---

### Extend the harness to exercise the enroll step against a class-word-keyed stub

**Summary**: Give the stub real class-word fidelity and add a way to drive the new step end to end against it, so "enrolls into the **correct** class" and re-run safety are actually exercised, not merely asserted in mocked unit tests. Exact driving mechanism depends on the resolved Open Question below.

**Files affected**:
- `functions/harness/im-done-local/stub-portal.js` — key `classes/info` on the `class_word` query param; serve distinct origin vs destination classes with distinct ids; and give the offering fixtures the `url` / `external_url` fields real `get_info` always returns (a pre-existing stub-fidelity gap, see below).
- `functions/harness/im-done-local/scenarios.js` — add enroll-specified-class scenarios.
- `functions/harness/im-done-local/run-step.js` — **new**: the verified Option-A direct step driver (imports the compiled `enrollSpecifiedClass` from `lib/`, builds a `StepContext` with `target_class_word` set to the **destination** word and `portalOrigin` set to the stub base URL — since the step reads `context.portalOrigin`, not `jobDoc.platform_id`, for its portal calls — runs it twice for the re-run assertion). Asserts the returned `StepResult.summary` contains the **destination class's distinctive name** on **both** runs. The driver runs the step in-process while the stub is a separate process, so it cannot observe the POST body `{ user_id, clazz_id }`; the reachable signal is the returned `summary` (`Enrolled in ${lookup.class.name}`), whose name flows from resolving the destination word against the class-word-keyed stub. Asserting the destination name (distinct from the origin class name) therefore proves "enrolls into the correct class" and stable re-resolution, whereas asserting `success` alone would not (the stateless stub returns `{ success: true }` even for a wrong-class resolution). Sets `FUNCTIONS_EMULATOR=true` + `PORTAL_OIDC_TOKEN` for the mint auth path. **Needs only the stub, not the emulator** — the enroll step reads no Firestore (verified by POC). **Build prerequisite**: unlike `run.js` (which drives everything through the emulator and imports no compiled step code), `run-step.js` `require`s compiled step code from `lib/`, so it requires a prior `npm run build`; the driver checks that `lib/tasks/ai4vs-flvs/enroll-specified-class.js` exists at startup and exits with a clear "run `npm run build` first" message when it is missing, so a stale/absent `lib/` fails loudly instead of throwing a confusing module-not-found error.
- `functions/harness/im-done-local/README.md` — document the new driver and scenario(s), noting `run-step.js` runs stub-only (no `npm run emulator` / `seed.js` needed) but **does** require a prior `npm run build` because it imports compiled `lib/` (call this out so a reviewer running against a stale/absent `lib/` is not surprised).

**Estimated diff size**: ~200 lines.

The `run-step.js` shape is proven: the POC ran the exact origin-mint → `classes/info` → cross-class-mint → `add_to_class` sequence via the real compiled `portal-api`, standalone against the stub, with the re-run reusing the `tokenCache` (zero second-run mints). The real driver differs only in `require`-ing the compiled `enrollSpecifiedClass` rather than inlining the sequence.

**Stub `classes/info` change (before → after):**

```js
// before (stub-portal.js:215-218)
} else if (req.method === "GET" && path === "/api/v1/classes/info") {
  route = "classes-info";
  result = { status: 200, body: classInfo };

// after — key the response on the requested class_word so a destination word
// resolves to a DISTINCT class/id from the origin, and an unknown word 400s
// (mirroring rigse: classes#info returns error('The requested class was not
// found'), and API::APIController#error defaults to status 400).
} else if (req.method === "GET" && path === "/api/v1/classes/info") {
  route = "classes-info";
  const word = url.searchParams.get("class_word");
  const found = CLASSES_BY_WORD[word];
  result = found
    ? { status: 200, body: found }
    : { status: 400, body: errorEnvelope("The requested class was not found") };
```

`CLASSES_BY_WORD` is a small map: the origin class (existing `classInfo`, `id: 90210`, `name: "FL-spring-2026-origin"`) plus at least one destination class with a **distinct name and id** (e.g. `FT-fall-2026-A` → `id: 30001`, `name: "FT-fall-2026-A"`), so the scenario can assert the returned `summary` names the **destination** class the destination word resolves to, not the origin. A `class_word=` behavior key drives the failure scenario (unknown-word `400` / forbidden), mirroring the other endpoints.

While this handler is being touched, close a pre-existing stub-fidelity gap: the current `classInfo.offerings[]` entry (`{ id: 555, name, active, locked, metadata }`, `stub-portal.js:35`) omits the `url` and `external_url` fields that real `get_info` **always** returns (rigse `classes_controller.rb:161-162`: `:url => api_v1_offering_url`, `:external_url => runnable.url`). The REPORT-79 enroll scenario ignores offerings, so this does not affect this story, but REPORT-80 builds its offering-matching scenarios on this same stub and cannot exercise the helper's `activityUrl` (mapped from `external_url`) path against a fixture that lacks it. Give both the origin and the new destination offering fixtures `url` and `external_url` so `classes/info` mirrors the real `get_info` offering shape now, rather than deferring the fidelity fix into REPORT-80's scenario work.

**Scenarios** added to `scenarios.js`: `enroll-happy` (resolves the destination word to its distinct class and asserts the `summary` names it), `enroll-unknown-word` (lookup `400` → tell-your-teacher), and a re-run assertion (invoke the step twice with the same context/tokenCache; both succeed and name the destination class).

---

## Open Questions

<!-- Implementation-focused questions only. Requirements questions live in requirements.md and are all RESOLVED. -->

### RESOLVED: What is the name/shape of the typed handoff field on `StepResult`?
**Context**: This story owns adding the structured slot REPORT-81 will populate with the resolved destination class word (it cannot be `summary`/`message`, which send-email renders into the teacher email). The field is a shared-contract change other stories import, so its shape should be deliberate.
**Options considered**:
- A) `output?: StepOutput` where `StepOutput = { destinationClassWord?: string }` — typed, minimal, self-documenting; grows by adding named fields. (Used in the draft above.)
- B) `output?: Record<string, unknown>` — generic bag; flexible but untyped, and easy to misspell keys across stories.
- C) A dedicated top-level field, e.g. `destinationClassWord?: string` directly on `StepResult` — flattest, but pollutes the shared type with one story's concern and doesn't generalize to REPORT-80/82 handoffs.
- D) A templated `StepResult<TOutput = StepOutput>` — considered and rejected: the `Record<string, StepResult>` bag erases the per-step type on the consumer side, and object-literal excess-property checks already catch producer typos, so the generic adds ceremony (rippling through `StepHandler`/`PipelineStep`/the loop) for only a marginal, opt-in producer-narrowing gain. The default type-param can be added later, backward-compatibly, if per-step narrowing is ever wanted.

**Decision**: **A** — plain non-generic `output?: StepOutput` with `StepOutput = { destinationClassWord?: string }`. Excess-property checking already gives producer-side typo safety; the consumer reads a runtime-guarded `string | undefined` either way, so the generic (D) closes no gap that matters here. Adding the default type param stays available as a backward-compatible future change.

### RESOLVED: Do we consolidate send-email's offering-read now, or leave it and only add the new helper?
**Context**: The origin-offering read (`GET /api/v1/offerings/:id`) already exists inline in the shipped `send-email` step. This story needs the same read (plus `class_word`). The draft extracts `resolveOriginOffering` and refactors send-email onto it (the "Route send-email through the shared helper" commit).
**Options considered**:
- A) Extract `resolveOriginOffering` and refactor send-email to use it now (DRY; one implementation; small, isolated, behavior-preserving change to a shipped step).
- B) Add `resolveOriginOffering` for this story's use only; leave send-email's inline read untouched (zero risk to a shipped step; two copies of the same read until a later cleanup).

**Decision**: **A** — extract `resolveOriginOffering` and refactor send-email onto it as its own isolated, behavior-preserving commit (the "Route send-email through the shared helper" step). The only change to send-email's behavior is dropping the `reason: data?.details?.reason` argument to `classifyPortalFailure`, which `offerings#show` never returns, so the existing send-email offering-read tests stay green.

### RESOLVED: How does the harness exercise the new step, given this story wires no `PIPELINES` entry?
**Context**: The harness runs through `submitTask` → `ai4vsFlvs` → `PIPELINES[request.pilot]`, and only `spring-2026` is wired; REPORT-82 owns adding a fall pipeline. To drive the new step end to end against the stub, the harness needs a path to it.
**Options considered**:
- A) **Direct step driver** (`run-step.js`): a new harness script that imports the compiled `enrollSpecifiedClass` from `lib/`, builds a `StepContext` (the stub `platform_id` + a forwarded firebase token), and calls it directly (twice, for the re-run assertion). Keeps `index.ts` untouched (faithful to "wires no pipeline"); exercises the real step + real stub + real mint/cache/classifier, but not the `submitTask` → pipeline-loop plumbing (which is REPORT-83's and unchanged).
- B) **Harness-only pilot**: add a small `PIPELINES` entry (e.g. `"fall-enroll-harness"`) containing the origin-resolve + enroll step, used only by the harness. Exercises the full submit→loop path, but adds a production `index.ts` entry this story's scope explicitly assigns to REPORT-82, and needs config/run wiring for the new pilot + a `target_class_word` request param.
- C) Defer any harness coverage to REPORT-82 (when a real fall pipeline exists); REPORT-79 ships unit tests only. Contradicts the requirements, which pin a harness scenario and stub-fidelity fix in this story.

**Decision**: **A** — a direct step driver, **verified end to end before finalizing this plan** (throwaway POC replicating the step's call sequence against the real compiled `lib/tasks/portal-api.js` and the running stub). The POC confirmed:
- A standalone Node process (no emulator) can `require` the compiled step-layer code and run the full origin-mint → `classes/info` lookup → cross-class-mint → `add_to_class` sequence against the stub, returning `{ success: true }`.
- **The enroll step reads no Firestore** (unlike `random-assignment`, which needs answer docs), so the driver needs only the stub — **not** the Firebase emulator. This makes `run-step.js` materially simpler than `run.js`.
- The load-bearing env detail: the driver must set `FUNCTIONS_EMULATOR=true` and `PORTAL_OIDC_TOKEN=<any>` so `portalOidcFetch` uses the env-token auth path (`portal-api.ts:48-57`) instead of real GoogleAuth. Necessary and sufficient.
- Re-invoking the step twice with the **same** `tokenCache` issued zero mints on the second run (origin + destination tokens both cache-reused), directly exercising the re-invocation-safety value the idempotency AC claims for the harness.
- No token value appeared in the results or the stub log on any path (token-secrecy).

The "Extend the harness" commit below is updated to reflect A (no emulator dependency for this driver).

### RESOLVED: Where do the portal reads live — a new `portal-reads.ts`, or added to `portal-api.ts`?
**Context**: `portal-api.ts` today is transport/auth/mint/classify (no endpoint-specific reads). `lookupClassByWord` / `resolveOriginOffering` are endpoint-specific reads that return domain shapes.
**Options considered**:
- A) New `functions/src/tasks/portal-reads.ts` sibling (draft choice) — keeps `portal-api.ts` focused on transport/auth; groups the fall reads REPORT-80 also imports.
- B) Add them into `portal-api.ts` — one portal module, but mixes generic transport with endpoint-specific domain reads.

**Decision**: **A** — new `functions/src/tasks/portal-reads.ts`. Keeps the layering explicit (`portal-api` = how to call the portal; `portal-reads` = specific reads returning domain types) and gives REPORT-80 a natural module to import the shared lookup from.

## Self-Review

Roles: Senior Engineer, Security Engineer, QA Engineer, Cross-Repo API Contract Reviewer. Cross-repo claims re-verified against the RIGSE-352 checkout at `/home/doug/projects/rigse` (`get_info` in `api/v1/classes_controller.rb`).

### Cross-Repo API Contract Reviewer

#### RESOLVED: PortalOffering maps the wrong field as the activity URL (CONFIRMED)
`get_info` returns each offering with **two** URL fields: `:url => api_v1_offering_url(offering.id)` (the offering's own API URL) and `:external_url => offering.runnable.url` (the underlying activity URL). The draft's `PortalOffering.url` mapped `o.url`, which is the API URL, not the "underlying activity URL" the requirements name. REPORT-80 imports `PortalOffering`, so shipping the wrong field now would propagate the error. **Resolution**: Applied — `PortalOffering` now has `offeringApiUrl` (from `url`) and `activityUrl` (from `external_url`); the mapper and the `portal-reads.test.ts` fixture use the real `get_info` shape (`{ id, name, active, locked, metadata, url, external_url }`) and assert `activityUrl` maps from `external_url`.

---

### Security Engineer

#### RESOLVED: classes/info teachers[] carries real teacher names — the "no real-PII surface" conclusion is incomplete (CONFIRMED)
`get_info` anonymizes **students** (`anonymize ? student.anonymized_first_name : ...`, and student emails are synthetic) but returns **teachers'** real `first_name`/`last_name` unconditionally (no anonymize branch). `classes/info` is the endpoint this story's `lookupClassByWord` calls, so its response *does* contain real PII (teacher names) — the requirements' "REPORT-79 has no real-PII surface at all" was too strong. The REPORT-79 enroll step never logs or returns `teachers[]` (it surfaces only the class name + `class_word`), so this story is safe as drafted, but the shared `lookupClassByWord` returns the full `PortalClass.teachers[]`, and REPORT-80 (which imports it) could log it. **Resolution**: Applied — (a) a PII guard on `PortalTeacher` in the plan states teacher names are real PII and must never be logged or placed in a `StepResult`; (b) the enroll step's secrecy test now asserts no teacher-name sentinel appears in logs or the `StepResult`, alongside token-secrecy; (c) requirements.md's PII analysis is corrected by an appended seventh-pass note (the logging invariant covers tokens **and teacher names**, not "no real-PII surface at all").

#### RESOLVED: The enroll step should state it assumes the validatePortalHost gate ran
Like `lock-activity` / `send-email`, `enrollSpecifiedClass` makes no host check of its own; it relies on the consuming pipeline (REPORT-82) having run `validatePortalHost` at setup. **Resolution**: Applied — a header comment on `enrollSpecifiedClass` states it makes no host check and assumes the gate ran, and that the gate must not be dropped when the step is wired into a pipeline.

---

### Senior Engineer

#### RESOLVED: The destination-word handoff scans all prior results with no documented single-writer rule
`resolveDestinationWord` returns the first prior `stepResults` entry whose `output.destinationClassWord` is set. `Record` iteration is insertion order (= pipeline order), so "first" is deterministic, but the contract that **exactly one** upstream step sets it was implicit. **Resolution**: Applied — `resolveDestinationWord`'s doc comment now states exactly one upstream step (REPORT-81) is expected to set `destinationClassWord`, the authored param wins when both are present, and the function logs at info when both a param and a differing handoff are present; a unit test covers the both-present precedence + log.

#### RESOLVED (accepted as-is): The read helpers discard the response body on failure, losing 4xx diagnostics
`lookupClassByWord` / `resolveOriginOffering` return only `{ status }` on a non-2xx, so the calling step cannot log the portal's error body even though the `classes/info` body is now deemed safe to log. The step still logs the attempted `class_word` + status (the key diagnostic). **Resolution**: Accepted status-only. The attempted `class_word` is the single most useful diagnostic for a mis-authored word (the dominant failure), and keeping the reads body-free keeps them lean and side-effect-free. If a portal error body ever proves necessary, adding `data` to the read result is a backward-compatible change.

---

### QA Engineer

#### RESOLVED: The harness enroll scenario must assert the DESTINATION class, and the re-run must assert a stable resolution
The stub-fidelity fix keys `classes/info` on `class_word` with a destination class distinct from the origin. The `run-step.js` driver must pass a `target_class_word` that resolves to the **destination** and assert the step actually resolved to it (not the origin), or the "enrolls into the correct class" AC is not actually exercised (the POC used the origin word and asserted `90210`, which is exactly the confusion the requirements warn about). **Resolution**: Applied, then **corrected by the eighth pass**: the driver runs the step in-process against a separate-process, stateless stub, so it cannot observe the posted `clazz_id`; it asserts on the returned `StepResult.summary` (`Enrolled in ${lookup.class.name}`) instead. The harness commit pins a destination class with a distinct **name and id** (`30001`, `"FT-fall-2026-A"`, distinct from the origin `90210` / `"FL-spring-2026-origin"`) in `CLASSES_BY_WORD`, and `run-step.js` passes the destination `target_class_word` and asserts the `summary` names the destination class on **both** runs. See the eighth-pass item for why the summary-name assertion (not a `clazz_id` assertion) is the reachable signal.

#### RESOLVED: Dropping `reason` from send-email's offering classify keeps existing tests green
Verified against `send-email.test.ts`: the offering-read failure tests exercise 403/404/no-clazz/5xx and none assert `details.reason` behavior (`offerings#show` never returns it), so the Step B refactor is behavior-preserving as claimed. No change needed.

---

### Eighth pass (fresh code-verified review of the implementation plan)

Each item below was ground-truthed against `functions/` and the local rigse checkout before being written; two were checked with throwaway tests. The rigse checkout was at `6f4c49288` (a descendant of the pinned RIGSE-352 `526cfb232`), so line numbers may have drifted, but the semantics the plan relies on were re-confirmed. Most prior-pass claims held (teacher-name PII, offering `url`/`external_url` split, `class_word` teacher-gating, `add_to_class` returning `{ success: true }` with no PII in failure bodies); the two findings below are real gaps the verification surfaced, plus one confirmation.

#### RESOLVED: The harness cannot observe the enrolled `clazz_id`, so the earlier "assert `clazz_id === 30001`" plan was not implementable (QA / Testability, CONFIRMED)
The prior harness plan had `run-step.js` "assert the enrolled `clazz_id` equals the destination id (`30001`)". Verified against code, the driver cannot see that value:
- The enroll step returns `{ success: true, summary: \`Enrolled in ${lookup.class.name}\` }` (the class **name**, not the id).
- The stub's enroll route is stateless `{ success: true }` with no echo of the posted body (`stub-portal.js:84-93,196-198`), and the plan's stub change touches only the `classes/info` route, not the enroll route.
- `run-step.js` drives the compiled step **in-process**, while the stub is a **separate process**, so it never sees the POST body `{ user_id, clazz_id }`.

So the only signal reachable to the driver is the returned `summary`. Asserting `success` alone would not prove correct-class resolution, because the stateless stub returns `{ success: true }` even when a wrong (origin) word resolves, which is exactly the confusion the fourth-pass requirements item warned about. **Resolution**: Applied. The destination fixture now carries a distinct **name and id** (`"FT-fall-2026-A"` / `30001`, vs origin `"FL-spring-2026-origin"` / `90210`), and `run-step.js` asserts the returned `summary` names the **destination** class on both runs. `summary`'s class name flows from `lookup.class.name`, i.e. from resolving the destination word against the class-word-keyed stub, so it proves correct-class resolution without needing to observe the raw `clazz_id`. (If the raw id is ever wanted, the alternative is to extend the stub's enroll route to record the last `{ user_id, clazz_id }`; the summary assertion was chosen because it needs no extra stub state.)

#### RESOLVED: The stub's unknown-`class_word` status (404) did not mirror rigse (400) (Cross-Repo fidelity, CONFIRMED)
The prior stub change returned `{ status: 404 }` for an unknown `class_word`. Verified against rigse: `classes#info` on a miss does `return error('The requested class was not found')` (`classes_controller.rb`), and `API::APIController#error(message, status = 400, ...)` defaults to **400** (`api_controller.rb`). The stub exists to mirror the real controllers' wire shapes, so 404 misrepresents the real 400. The classifier buckets both to tell-your-teacher (any non-`422:expired` 4xx), so the scenario outcome is unchanged, but the stub should still be faithful. **Resolution**: Applied. The stub's `class_word`-miss branch now returns `{ status: 400, body: errorEnvelope("The requested class was not found") }`, and the `enroll-unknown-word` scenario is documented as a `400`.

#### RESOLVED (confirmation, no change): Step B's mock retarget is optional, not required for green tests
Step B says to "retarget the offering-read mocks/assertions at the helper." Verified with a throwaway test that a `jest.mock("../portal-api")` in `send-email.test.ts` transparently intercepts the `portalTokenFetch` call `resolveOriginOffering` makes from the sibling `portal-reads.ts` module (the sentinel token reached the mocked transport). So the existing send-email offering-read tests stay green **without** any retargeting; retargeting is optional clarity, not a correctness requirement. No plan change needed; recorded so the "tests stay green" claim is not read as depending on the retarget.

---

### Ninth pass (fresh multi-role review, every finding code-verified before write-up)

A clean-slate review pass (Senior Engineer / correctness, QA / Testability, Cross-Repo fidelity, Architecture / DRY). Before writing each item, the underlying claim was ground-truthed against `functions/` and the rigse `rails/` checkout, and the proposed `lookupClassByWord` mapping was exercised with a throwaway probe against a realistic `get_info` fixture. That probe confirmed the mapping picks `activityUrl` from `external_url` (not `url`), that `PortalClass` never surfaces students or their emails, and that it **does** surface real teacher names, so the teacher-name PII guard from the seventh pass is genuinely load-bearing. All prior-pass cross-repo claims re-confirmed (teacher names real and unconditional at `classes_controller.rb:145-146`; students anonymized via `render_info(clazz, true)`; offering `url` vs `external_url` split at `161-162`; `info` unauthenticated and 400-on-miss at `59-67`; `offerings#show` `class_word` gate at `offering.rb:137`; `add_to_class` double-authorize → `{ success: true }` with `add_clazz` no-op). Four findings, all now applied.

#### RESOLVED: Both-present precedence silently defeated randomization; the log under-alarmed a study-wide misconfiguration (Senior Engineer / Correctness, CONFIRMED)
The prior `resolveDestinationWord` did `return authored ?? handoff` and logged at **info** when an authored `target_class_word` and a differing handoff were both present. Verified: `target_class_word` is a per-launch request param, so a button authored with a fixed word AND wired to REPORT-81 randomization would route **every** student to the one authored class, silently defeating randomization for the whole study; an info-level log is low-visibility for that blast radius, and the spec's "explicit authoring is intentional" rationale implied an override feature that was never a declared use case. **Resolution**: Applied. `resolveDestinationWord` now returns a discriminated `DestinationWordResolution` (`{ ok: true, word } | { ok: false, reason: "missing" | "conflict" }`); an authored word that **differs** from a present handoff is a hard `conflict` → the step returns the tell-your-teacher message, logs at **error**, and makes **no** portal calls. An authored word **equal** to the handoff is not a conflict. The unit-test bullets replace the old "precedence" test with a "conflict when both present and differing" test (tell-teacher, error log, no portal calls) plus a "both present but equal → proceeds" test.

#### RESOLVED: `run-step.js` depended on a compiled `lib/` the harness flow never builds (QA / Testability, CONFIRMED)
Verified: the existing `run.js` `require`s no compiled step code (it drives everything through the emulator and `submitTask`), `package.json` `main` is `lib/index.js` with `outDir: "lib"`, and no harness script runs `tsc`. The new direct driver `require`s `lib/tasks/ai4vs-flvs/enroll-specified-class.js`, a build prerequisite that was unstated; a reviewer running against a stale or absent `lib/` would hit a confusing module-not-found error. **Resolution**: Applied. The `run-step.js` files-affected note now pins the `npm run build` prerequisite and specifies a startup existence check on the compiled step with a clear "run `npm run build` first" message; the README bullet calls out the build requirement.

#### RESOLVED: The stub's offering fixtures omitted `url` / `external_url` that real `get_info` always returns (Cross-Repo fidelity, CONFIRMED)
Verified: `stub-portal.js:35` serves `offerings: [{ id, name, active, locked, metadata }]` with no `url` / `external_url`, whereas rigse's `get_info` always includes both (`classes_controller.rb:161-162`). REPORT-79's enroll scenario ignores offerings so it is unaffected, but REPORT-80 builds offering-matching scenarios on this same stub and cannot exercise the helper's `activityUrl` (from `external_url`) against a fixture that lacks it. **Resolution**: Applied. Since the harness step already rewrites the `classes/info` handler for `class_word` keying, it now also gives both the origin and the new destination offering fixtures `url` and `external_url`, so `classes/info` mirrors the real `get_info` offering shape instead of deferring the fidelity fix into REPORT-80.

#### RESOLVED (documented decision, no code change): The enroll mint + `add_to_class` + classify sequence is duplicated with `random-assignment`, asymmetric with the offering-read consolidation (Architecture / DRY)
Verified: the new step's steps 3-4 are near-identical to `random-assignment.ts:398-437` (cross-class mint → `add_to_class` with `{ user_id, clazz_id }` → 2xx-`success` check → classify), yet this story *does* extract the analogous offering-read into a shared helper and refactors shipped `send-email` onto it. The asymmetry is real but the right call is **not** to extract here, and the fix is to make that deliberate rather than silent: (a) the only other enroll caller is the shipped spring `random-assignment`, whose enroll is embedded in Firestore assignment logic and is explicitly out of scope to modify in this story (unlike the offering-read, a self-contained call that consolidates cleanly); (b) REPORT-80 does **not** enroll (it is offering-state + `update_student_metadata`), so there is no third caller — extracting a helper used by only the new step would add indirection without reducing the copy count; (c) the reusable seam already exists one level down (`getScopedPortalToken` / `portalTokenFetch` / `classifyPortalFailure` / `messageForBucket`), so the "duplication" is ~15 lines of orchestration that reads more clearly inline. **Resolution**: Documented as a deliberate decision here (and as the rationale for why the offering-read is consolidated but the enroll is not); if a third enroll caller ever appears, extracting a shared `enrollStudentInClass` helper that `random-assignment` also adopts becomes worthwhile and is a backward-compatible follow-up.

---

**Implementation self-review converged (nine passes).** The seven requirements/implementation passes, the eighth code-verified pass, and this ninth fresh multi-role pass (each finding ground-truthed against `functions/` and the rigse `rails/` checkout, with the proposed `lookupClassByWord` mapping exercised by a throwaway probe) leave all Open Questions and Self-Review items RESOLVED. Net changes from the ninth pass: both-present destination words now hard-fail as a `conflict` (tell-your-teacher, error log, no portal calls) rather than silently preferring the authored word; `run-step.js` pins its `npm run build` prerequisite and checks for the compiled step at startup; the stub's offering fixtures gain the real `get_info` `url` / `external_url` fields; and the enroll-sequence duplication with `random-assignment` is recorded as a deliberate, in-scope-bounded decision. The harness proves correct-class resolution via the returned `summary`'s destination class name (the reachable in-process signal), and the stub mirrors rigse's `400` for an unknown `class_word`.
