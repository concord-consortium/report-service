# Implementation Plan: Fall-2026 pipeline stages (pre-test, curriculum, post-test)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-82
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## How this plan was verified

Every runtime claim below was executed before it was written, not inferred. The throwaway files have
been deleted and the tree is clean; the results are recorded here so a later reader does not have to
redo them.

| Check | Result |
|---|---|
| The harness's existing seeded answers really do land the two programs in opposite arms | Confirmed. Driving the real `fallRandomAssignment` over `config.js`'s `ANSWERS` in `seed.js`'s real `report_state` shape, with only the Firestore read and `getAlternatingAssignment` stubbed: `ft-2026-bingler` resolves stratum `Female\|White\|Bingler`, n1 `treatment`, destination `ft-2026-bingler-gator`; `fl-2026-section1` resolves `Female\|White\|High\|Mod1`, n1 `control`, destination `fl-2026-section1-shark`. Both legacy harness words still fail to classify. |
| The two assignment-document formulas, as a plain-node file must write them | Confirmed byte-identical to `perClassScope` and `pooledProgramScope`. A fall full-time scenario reusing `CONTEXT` computes `8f77e38c5fed…`, the same id the live spring `happy` run was observed to write; its own launch context moves it to `27a8aa7791f9…`. The pooled flex id `bea6161208a0…` is unmoved by a per-scenario launch context, as R15a warns. |
| Handler-identity assertion (R16) under this repo's `jest.mock` factory style | Works, **but not as `it.each([...] as const)`**: jest 24's typings flatten the tuple and `PIPELINES[pilot]` fails `TS2538`. The table must be declared `Array<[string, StepHandler[]]>`. See the PIPELINES step. |
| R16b's snapshot key | The entry name is **not reachable** from a handler: the runner passes only `StepContext`, which carries no entry name, and deriving it from what has accumulated in `stepResults` picks spring's name every time. Keying on the pilot works and survives two pipelines driven in one file. See the PIPELINES step. |
| R16a's four new mocks | Confirmed: with all four mocked the file loads and all assertions pass. Separately confirmed that the shipped `it.each(Object.entries(PIPELINES))` covers the three new pipelines with **no edit**, contributing three extra assertions on its own. |
| The R11/R12 edit against the shipped suites | Written for real and run: **26 suites, 480 passed, 4 skipped (484 total)**, unchanged from the baseline. No shipped test asserts that `send-email` reads the offering on a stage that also runs `resolve-origin-class`. |
| `firestore.rules`' `learnerOwner` | Read first-hand: checks `user_type`, `platform_user_id` and `platform_id` only, with an explicit comment that read rules do not require a matching `context_id`. Per-scenario `context_id` therefore needs no re-minted learner token (R15c). |
| Harness baseline before any change | `run-all.js` on this branch after a fresh build and seed: **28/28 scenarios passed**. |

## Implementation Plan

### Retire the stale `fall-2026-fulltime` pilot value

**First deliberately.** It is trivial and inert, and it touches four files across both the source tree
and the harness, so placed later it adds noise to the diffs of the two substantive source commits that
would surround it.

**Summary**: R3 and R3a. A precedent cleanup, not a fix: `pilot` reaches only the portal mint's audit
`description` in all four places. It is worth doing completely because R2a's rule (no program-shaped
pilot value, ever) is the kind that is followed by copying the nearest example, and the nearest
example today is the one shape it forbids.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/enroll-specified-class.test.ts` — a fixture **and an assertion**
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts` — a fixture
- `functions/harness/im-done-local/scenarios.js` — a per-scenario pilot
- `functions/harness/im-done-local/run-step.js` — `buildContext` takes it as an argument

**Estimated diff size**: ~40 lines

`enroll-specified-class.test.ts:59` (fixture) and `:100` (the assertion pinning the value the mint is
called with) both become `fall-2026-green`. They must change together or the test fails.
`open-target-offering.test.ts:105` becomes `fall-2026-orange`.

In the harness, one literal cannot be stage-correct for every run-step scenario: three of them drive
`enrollSpecifiedClass`, a pre-test step, and four drive `openTargetOffering`, a post-test step. So the
pilot joins the per-scenario step selection `scenarios.js` already carries:

```js
const OPEN_TARGET_STEP = {
  driver: "run-step",
  stepModule: "open-target-offering",
  stepExport: "openTargetOffering",
  stepName: "open-target",
  // The post-test stage's pilot. Inert as behaviour (it reaches only the mint's audit description),
  // but a run-step scenario should not model a stage it is not driving.
  pilot: "fall-2026-orange",
};
```

and `run-step.js`'s `buildContext` takes it, defaulting to the pre-test value for the enroll
scenarios:

```js
const buildContext = (scenario, tokenCache, stepResults) => ({
  ...
      request: {
        task: "ai4vs-flvs",
        pilot: scenario.pilot || "fall-2026-green",
        target_class_word: scenario.targetClassWord,
      },
  ...
});
```

The call site changes from `buildContext(scenario.targetClassWord, …)` to `buildContext(scenario, …)`.

---

### Publish and consume the origin class id

**Summary**: R11 and R12. `resolveOriginClass` publishes the launch offering's class id on
`StepOutput`; `sendEmail` consumes it when present and keeps its own read as the fallback that
`spring-2026` and the fall curriculum stage both still take. Independently committable and
independently revertable, which matters because the RESOLVED question on R11 records this as the one
requirement that could be dropped with no consequence beyond a redundant portal read.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/types.ts` — the new `StepOutput` field
- `functions/src/tasks/ai4vs-flvs/resolve-origin-class.ts` — publish it
- `functions/src/tasks/ai4vs-flvs/resolve-origin-class.test.ts` — assert it is published, as a string
- `functions/src/tasks/ai4vs-flvs/send-email.ts` — consume it, keep the fallback
- `functions/src/tasks/ai4vs-flvs/send-email.test.ts` — assert both paths

**Estimated diff size**: ~130 lines

`types.ts`, beside `originClassWord`:

```ts
  /**
   * The launch offering's class id, published by resolve-origin-class from the SAME
   * offerings#show response that yields originClassWord. send-email needs it for
   * send_class_teachers and would otherwise re-read the offering.
   *
   * ⚠️ A STRING, because readStepOutputField accepts nothing else, while resolveOriginOffering
   * types clazzId as `number | string` and the portal serves a JSON number. Publishing the raw
   * value hands back undefined and send-email falls back forever, silently, with nothing failing.
   *
   * Safe to log: a database id, neither PII nor a token.
   */
  originClazzId?: string;
```

`resolve-origin-class.ts`, at the success return:

```ts
    return {
      success: true,
      summary: `Origin class ${classWord}`,
      output: { originClassWord: classWord, originClazzId: String(origin.offering.clazzId) },
    };
```

The step's header comment currently carries a `⚠️` paragraph describing the duplicate read as
"knowingly left in place" and assigning the tidy-up to the stage wiring. That paragraph is now
false and is replaced by a short note that the id is published here and that `send-email` keeps a
fallback for the stages that have no `resolve-origin-class`.

`send-email.ts`. `stepResults` joins the destructure at the top of `sendEmail`, `readStepOutputField`
joins the `./types` import, and the offering read becomes conditional:

```ts
    // send_class_teachers needs the origin class_id, but this step holds only resource_link_id.
    // A stage that ran resolve-origin-class already paid for that read and published the id, so
    // take the handoff when it is there. The read below is RETAINED as a fallback and is NOT dead
    // code: spring-2026 has no resolve-origin-class step and neither does the fall curriculum
    // stage, so both reach it on every run.
    let classId = readStepOutputField(stepResults, "originClazzId");
    if (!classId) {
      const origin = await resolveOriginOffering(portalOrigin, token, String(resource_link_id));
      if (!origin.offering) {
        functions.logger.error(`send-email: offering-read failed for ${jobPath}`, { status: origin.status });
        const offeringBucket = classifyPortalFailure({ status: origin.status });
        return { success: false, message: messageForBucket(offeringBucket, STUDENT_FAILURE_MESSAGE) };
      }
      classId = String(origin.offering.clazzId);
    }
```

Tests. `resolve-origin-class.test.ts` gains one assertion in the happy-path block, that the published
`originClazzId` is the string form of the fixture's numeric `clazz_id`. That is an assertion inside an
existing `it`, so it adds no test to the count.

`send-email.test.ts` gains **two tests**, both using the existing
`makeContext(overrides, stepResults, requestOverrides)` helper.

⚠️ Note what is mocked there, because it is not what it would be natural to assume: this file does
**not** mock `resolveOriginOffering`. It mocks `portalTokenFetch` (and `getScopedPortalToken`) and
lets the real `resolveOriginOffering` run over that transport. The thing an assertion can count is
therefore `portalTokenFetch` calls whose `path` matches `/api/v1/offerings/`, not a step-level mock:

```ts
const offeringCalls = () =>
  mockPortalTokenFetch.mock.calls.filter(([o]: any[]) => /\/api\/v1\/offerings\//.test(o.path));
```

With a seeded `resolve-origin-class` output there are **zero** such calls and the POST body carries
the handoff's class id; with empty `stepResults` there is exactly **one** and the four shipped
`offering-*` failure classifications still apply. That second test is what pins R12, and it is the
branch the whole spring pilot lives on.

Both tests were written as described and run against the real change, and all 480 shipped tests pass
unmodified.

---

### Wire the three fall stages into PIPELINES

**Summary**: R1, R2, R4, R5, R6, R9, R10, R10a and R8a. The story's actual subject. Also R16, R16a
and R16b, which are the tests that make the wiring assertable rather than merely written.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/index.ts` — four imports, three entries, R8a's two log lines
- `functions/src/tasks/ai4vs-flvs/index.test.ts` — four mocks, the lock mock's snapshot key, the ordered-handler assertion

**Estimated diff size**: ~200 lines

`index.ts` imports `resolveOriginClass`, `fallRandomAssignment`, `enrollSpecifiedClass` and
`openTargetOffering`, then adds three entries after `spring-2026`:

```ts
  // The fall-2026 study's three "I'm Done" trigger points. The colour is the study's and the
  // portal's vocabulary (the sequences are named Green/Blue/Orange Sequence for AI in Math), but it
  // is not self-describing: green = pre-test, blue = curriculum, orange = post-test.
  //
  // BOTH cohorts run these same three stages. The only program-dependent behaviour in the study is
  // inside fall-random-assignment, which resolves the program from the origin class word itself, so
  // this table stays keyed by stage and never by program. A pilot value such as "fall-2026-fulltime"
  // is forbidden: one shared Green button serves both cohorts.
  "fall-2026-green": [
    { name: "evaluate-completion", processingMessage: "Checking your answers…", handler: evaluateCompletion },
    { name: "resolve-origin-class", processingMessage: "Looking up your class…", handler: resolveOriginClass },
    { name: "random-assignment", processingMessage: "Assigning you to a class…", handler: fallRandomAssignment },
    { name: "enroll-class", processingMessage: "Adding you to your class…", handler: enrollSpecifiedClass },
    // Lock AFTER the enrol, so a failed enrolment leaves the student unlocked and able to re-click.
    { name: "lock-pre-test", processingMessage: "Locking your pre-test…", handler: lockCurrentOffering },
    { name: "send-email", processingMessage: "Notifying your teacher…", handler: sendEmail },
  ],
  // Opens NOTHING. The PI opens the post-test by hand on a fixed date, gated on Blue completion
  // data she inspects herself. The lock IS the completion record she reads off the roster, so this
  // stage's whole job is to record and report, and it applies to both arms.
  "fall-2026-blue": [
    { name: "lock-curriculum", processingMessage: "Locking this activity…", handler: lockCurrentOffering },
    { name: "send-email", processingMessage: "Notifying your teacher…", handler: sendEmail },
  ],
  // ⚠️ The lock PRECEDES the open, and that order is load-bearing rather than incidental:
  // open-target-offering's "Your work has been saved" copy (REPORT-80 R12) is guaranteed true only
  // while a failed lock aborts before the open runs. Reordering these two requires that message to
  // be revisited in the same change.
  "fall-2026-orange": [
    { name: "resolve-origin-class", processingMessage: "Looking up your class…", handler: resolveOriginClass },
    { name: "lock-post-test", processingMessage: "Locking your post-test…", handler: lockCurrentOffering },
    // "Checking" rather than "Opening": roughly half the cohort is treatment and the step returns
    // immediately for every one of them without a portal call, so "opening" would promise something
    // that does not happen. True on both arms.
    { name: "open-curriculum", processingMessage: "Checking for your other activity…", handler: openTargetOffering },
    { name: "send-email", processingMessage: "Notifying your teacher…", handler: sendEmail },
  ],
```

R8a's two log lines. One after the pipeline is selected, one on the failure path:

```ts
  // Three stages now run over the SAME step modules, so a step-name log prefix no longer identifies
  // the run. The only ai4vs-flvs line in the loop is the success line, so without these a stage that
  // fails at its first entry emits nothing naming the stage, and recovering it means joining the log
  // back to the job document through jobPath. Neither line carries a token or any student PII: the
  // pilot is an authored string and the step name is ours.
  functions.logger.info(`ai4vs-flvs: running pilot ${request.pilot} for ${jobPath}`);
```

```ts
    if (!result.success) {
      functions.logger.error(
        `ai4vs-flvs: pilot ${request.pilot} failed at step "${step.name}" for ${jobPath}`,
      );
      await markComplete(jobPath, "failure", {
        message: result.message ?? `Step "${step.name}" failed`,
      });
      return;
    }
```

The failure line carries both the pilot and the step name so it is self-sufficient, rather than
relying on the reader having the preceding info line.

`index.test.ts`. Three edits, of which the first is build-breaking and the second is a correction.

**R16a, four new mocks.** Only `fall-random-assignment` has to be mocked: unmocked it throws
`ReferenceError: fetch is not defined` through `demographics` → `firebase-client` → `firebase/auth`,
which fails the whole suite file rather than one assertion. It is **not** `firebase-admin`;
`assignment-doc` loads fine. The other three are mocked by convention, so every handler the table
reaches is stubbed from one place:

```ts
const mockResolveOriginClass = jest.fn();
const mockFallRandomAssignment = jest.fn();
const mockEnrollSpecifiedClass = jest.fn();
const mockOpenTargetOffering = jest.fn();

jest.mock("./resolve-origin-class", () => ({
  resolveOriginClass: (ctx: StepContext) => mockResolveOriginClass(ctx),
}));
jest.mock("./fall-random-assignment", () => ({
  fallRandomAssignment: (ctx: StepContext) => mockFallRandomAssignment(ctx),
}));
jest.mock("./enroll-specified-class", () => ({
  enrollSpecifiedClass: (ctx: StepContext) => mockEnrollSpecifiedClass(ctx),
}));
jest.mock("./open-target-offering", () => ({
  openTargetOffering: (ctx: StepContext) => mockOpenTargetOffering(ctx),
}));
```

**R16b, the lock mock's snapshot key.** The shipped mock writes its snapshot under a hardcoded
`stepResultsSnapshots["lock-activity"]`, which is spring's entry name and is wrong for the three fall
pipelines. R16b offers "an appended list, or keyed off the run's current entry name"; the entry name
is **not available**, because the runner passes only `StepContext` to a handler and `StepContext`
carries no entry name. Deriving it from what has accumulated in `stepResults` was tried and does not
work either: none of the four candidate names is present when the lock runs, so spring's wins every
time. The key becomes the pilot:

```ts
// Keyed on the PILOT, not the entry name. One handler now runs under four different entry names
// (spring's lock-activity plus lock-pre-test / lock-curriculum / lock-post-test), and the runner
// does not tell a handler which entry it is executing, so the pilot is the only thing in scope that
// distinguishes the four. A single hardcoded key silently collides once more than one pipeline is
// driven in this file.
jest.mock("./lock-current-offering", () => ({
  lockCurrentOffering: (ctx: StepContext) => {
    stepResultsSnapshots[`lock:${ctx.jobDoc.jobInfo.request.pilot}`] = { ...ctx.stepResults };
    return mockLockCurrentOffering(ctx);
  },
}));
```

No shipped assertion reads `stepResultsSnapshots["lock-activity"]` today, so this is a correction to
dead weight rather than a change under a passing test.

**R16, the ordered-handler-list assertion.** Handler identity rather than entry name, so the wiring is
asserted and not the table's own labels restated. Note the explicit table type: written as
`it.each([...] as const)` this does not compile under jest 24, whose `it.each` typings flatten the
tuple so that `pilot` types as the whole row and `PIPELINES[pilot]` fails `TS2538`.

⚠️ **This is the build-breaking half of the step.** `index.test.ts` imports none of the eight
handlers today (its imports are `IJobDocument`, `StepContext`, `ai4vsFlvs`, `PIPELINES` and
`TELL_TEACHER_MESSAGE`), so the table below does not compile until they are added. `StepHandler`
joins the `./types` import, and eight named imports join it beside the existing `./index` one:

```ts
import { evaluateCompletion } from "./evaluate-completion";
import { lockCurrentOffering } from "./lock-current-offering";
import { randomAssignment } from "./random-assignment";
import { sendEmail } from "./send-email";
import { resolveOriginClass } from "./resolve-origin-class";
import { fallRandomAssignment } from "./fall-random-assignment";
import { enrollSpecifiedClass } from "./enroll-specified-class";
import { openTargetOffering } from "./open-target-offering";
```

Each resolves to the mock this file installs, which is the same reference `index.ts` holds, so
identity comparison is what the assertion actually performs. Verified by writing the whole thing out
and running it: the table compiles, the assertion passes, and `toEqual` genuinely discriminates (a
deliberately mis-ordered list and a list of look-alike stand-in functions both fail).

```ts
  const EXPECTED_HANDLERS: Array<[string, StepHandler[]]> = [
    ["spring-2026", [evaluateCompletion, randomAssignment, lockCurrentOffering, sendEmail]],
    ["fall-2026-green", [
      evaluateCompletion, resolveOriginClass, fallRandomAssignment,
      enrollSpecifiedClass, lockCurrentOffering, sendEmail,
    ]],
    ["fall-2026-blue", [lockCurrentOffering, sendEmail]],
    ["fall-2026-orange", [resolveOriginClass, lockCurrentOffering, openTargetOffering, sendEmail]],
  ];
  it.each(EXPECTED_HANDLERS)("selects the expected ordered handlers for %s", (pilot, handlers) => {
    expect(PIPELINES[pilot].map(step => step.handler)).toEqual(handlers);
  });
```

Nothing else in the file changes. The shipped `it.each(Object.entries(PIPELINES))` duplicate-name
assertion enumerates the table, so it covers the three fall stages the moment they are added: this
step contributes **+7** tests, of which three arrive for free from that existing test (one pipeline
becoming four) and four are `EXPECTED_HANDLERS`' rows. The running totals are derived once, in
Verification below, rather than restated per step.

---

### Add the fall fixtures and per-scenario launch contexts to the harness config

**Summary**: R15a and R15b's fixture work, plus the two constants R15d duplicates. No scenario uses
any of this yet, so the harness stays green through this commit.

**Files affected**:
- `functions/harness/im-done-local/config.js` — class fixtures, per-scenario launch contexts, duplicated constants
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts` — pins for the duplicated constants

**Estimated diff size**: ~200 lines

The shared `CONTEXT` is **unchanged**. Fall scenarios carry overrides, added beside it:

```js
// Per-scenario launch contexts for the fall stages. ADDITIONS, not edits: CONTEXT keeps its current
// values, because stub-portal.js gives the study control class an Orange offering whose id IS
// CONTEXT.resource_link_id, precisely so the by-name match has to discriminate AGAINST the offering
// the student launched from rather than picking the only one available. That is the property
// open-target-happy exercises.
//
// ⚠️ The isolation this buys is FULL-TIME's only. perClassScope hashes resource_link_id and
// context_id, so without its own pair a fall full-time run lands in the SAME assignment document as
// the spring `happy` scenario (verified: both 8f77e38c5fed…), where the per-student de-duplication
// hands it spring's arm and the scenario silently stops testing what it claims to. pooledProgramScope
// takes program, interactiveId and platform_id and nothing else, so the flex scenario's own pair
// changes its document id not at all; flex is separated from spring by the pooled namespace prefix
// and by FLEX_PROGRAM being in the hash. The consequence to hold on to is that the flex assignment
// document is per PROGRAM, not per scenario.
const FALL_CONTEXTS = {
  "fall-green-fulltime": { resource_link_id: "im-done-fall-green-ft", context_id: "im-done-fall-green-ft-ctx" },
  "fall-green-flex": { resource_link_id: "im-done-fall-green-flex", context_id: "im-done-fall-green-flex-ctx" },
  "fall-orange-control": { resource_link_id: "im-done-fall-orange", context_id: "im-done-fall-orange-ctx" },
};
```

The `classes/info` fixtures, traced against the two callers rather than assumed. The **origin**
class is not resolved through `classes/info` at all (`resolveOriginClass` uses `offerings#show`), so
the two registration words are deliberately absent **from this set**:

```js
// classes/info is read by exactly TWO steps: enroll-specified-class looks up the DESTINATION word,
// and open-target-offering looks up the ORIGIN word on the post-test stage. The registration words
// (ft-2026-bingler, fl-2026-section1) are looked up by neither, and are deliberately not here, so
// the fixture set does not imply the origin is resolved through this endpoint. They ARE served by
// offerings#show, from the separate identity map below.
const FALL_FT_TREATMENT_CLASS = { id: 30011, word: "ft-2026-bingler-gator", name: "FT-2026-Bingler-Gator" };
const FALL_FLEX_CONTROL_CLASS = { id: 30012, word: "fl-2026-section1-shark", name: "FL-2026-Section1-Shark" };
// For the arm the sticky assignment can flip to. An edited ANSWERS or an un-reset pooled document
// lands the flex scenario in treatment, whose destination would otherwise have no fixture; that
// surfaces as a classes#info 400 and the generic tell-your-teacher message, with nothing naming the
// missing fixture. Full-time's flipped destination is ft-2026-bingler-shark, which already exists as
// STUDY_CONTROL_CLASS, so only the flex arm has this hole.
const FALL_FLEX_TREATMENT_CLASS = { id: 30013, word: "fl-2026-section1-gator", name: "FL-2026-Section1-Gator" };
```

`ft-2026-bingler-shark` needs nothing new: it is already `STUDY_CONTROL_CLASS`, and it serves as both
the post-test scenario's origin and full-time's flipped destination.

The two **registration** classes, which the fixture set above deliberately excludes and which the
stub nonetheless has to be able to serve:

```js
// ⚠️ NOT classes/info fixtures, and they must not be added to CLASSES_BY_WORD. A fall pre-test
// launches from a registration class, so resolveOriginClass reads one through offerings#show and
// every downstream decision hangs off the class word it publishes; but no step ever looks these
// words up by name, which is the property the comment above records. They are therefore a separate
// identity-only pair, consumed by stub-portal.js's ORIGIN_IDENTITY_BY_WORD and by nothing else.
//
// Without them the pre-test scenarios do not fail loudly, they fail WRONGLY: offerings#show falls
// back to the spring origin class, resolveOriginClass publishes fl-spring-2026-origin,
// classifyFallProgram returns undefined, and the run reports "unclassifiable origin class word",
// which reads as a pipeline fault. Verified by reproducing the lookup over this fixture set.
const FALL_FT_REGISTRATION_CLASS = { id: 30021, word: "ft-2026-bingler", name: "FT-2026-Bingler" };
const FALL_FLEX_REGISTRATION_CLASS = { id: 30022, word: "fl-2026-section1", name: "FL-2026-Section1" };
```

`TREATMENT_CLASS_WORD`'s comment is corrected in the same edit. It currently reads "Needs no class
fixture: the arm check short-circuits before any portal call, so nothing ever looks this word up",
which was true of `openTargetOffering` and stops being true of the harness the moment the full-time
pre-test scenario enrols into that word. It becomes a reference to `FALL_FT_TREATMENT_CLASS` above,
noting that the arm-check claim still holds for `open-target-treatment`.

The two constants R15d needs, duplicated rather than imported, matching the documented precedent
`TARGET_OFFERING_NAME` set four lines above them:

```js
// ⚠️ Duplicates of fall-programs.ts's DESTINATION_SUFFIX and FLEX_PROGRAM. Literals rather than
// imports for the same reason TARGET_OFFERING_NAME is one: run.js requires only fs, crypto, ./config,
// ./scenarios and firebase-admin, and giving it a dependency on a build would oblige it to carry
// run-step.js's existsSync guard. Both are pinned by a unit test in open-target-offering.test.ts.
//
// ⚠️ FLEX_PROGRAM is hashed into the pooled assignment document id, so a rename is a data migration
// rather than a refactor; the pin is what makes a rename fail loudly here too.
const DESTINATION_SUFFIX = { treatment: "-gator", control: "-shark" };
const FLEX_PROGRAM = "fall-2026-flex";
```

`open-target-offering.test.ts` pins both beside the `TARGET_OFFERING_NAME` pin already at `:348`,
importing the harness config the same way that test already does. **Two** added `it`s inside the
existing `describe("harness fixture agreement")`, one per constant, matching that block's existing
one-concern-per-`it` shape; the count below assumes exactly that.

One more constant, for the enrolment assertion two steps below. It sits beside `SCENARIO_FILE`, which
is the same mechanism in the other direction:

```js
// Written by stub-portal.js on every add_to_class, read by run.js after a run. The stub and the
// driver are separate processes, so a file is the channel available, as .scenario already is.
const LAST_ENROLL_FILE = `${__dirname}/.last-enroll.json`;
```

`.last-enroll.json` joins `.scenario` and `.run-context.json` in the harness's gitignore entry.

`EXPECTED_CLASS` and `ANSWERS` stay exactly as they are. The demographic answers are what make the
two pre-test scenarios land in opposite arms, and this step must not touch them.

---

### Serve a per-scenario class identity from the stub portal

**Summary**: R15b's second half. `offerings#show` currently serves one hardcoded class identity, which
would leave a post-test run reporting origin class `ft-2026-bingler-shark` while `send-email` posts
the notification to class `90210`. The stub also starts recording the `add_to_class` body, which is
what lets the driver assert the enrolment the pipeline actually performed. Still no scenario uses any
of this, so the harness stays green.

**Files affected**:
- `functions/harness/im-done-local/stub-portal.js`

**Estimated diff size**: ~160 lines

The whole class identity moves together, not just the word:

```js
// ⚠️ All THREE identity fields are per scenario, not just class_word. Making only the word
// scenario-aware would leave a post-test run reporting origin class ft-2026-bingler-shark while
// send-email posts the teacher notification to class 90210, and THE SCENARIO WOULD NOT CATCH IT,
// because send-email's R12 fallback reads the same wrong value from this same response: the handoff
// and the fallback would agree on being wrong.
//
// ⚠️ A SEPARATE map from CLASSES_BY_WORD, and deliberately a superset of it. classes/info serves
// only the words a step looks up BY NAME; offerings#show additionally has to serve the two
// registration classes, which a fall pre-test launches from and which no step ever looks up. Keeping
// one map for both would force the registration words into the classes/info fixture set and make it
// imply the origin is resolved through that endpoint, which is exactly what config.js's comment
// exists to deny.
const ORIGIN_IDENTITY_BY_WORD = {
  ...CLASSES_BY_WORD,
  // No offerings: these are never served through classes/info, so the list is never read.
  [storedClassWord(FALL_FT_REGISTRATION_CLASS.word)]: classInfoFor(FALL_FT_REGISTRATION_CLASS, []),
  [storedClassWord(FALL_FLEX_REGISTRATION_CLASS.word)]: classInfoFor(FALL_FLEX_REGISTRATION_CLASS, []),
};

// Returns undefined for a DECLARED word with no fixture, so the caller can fail loudly. A scenario
// that declares nothing keeps today's shared identity, which is what leaves all 28 existing
// scenarios unchanged.
const originClassFor = (scenarioName) => {
  const scenario = SCENARIOS[scenarioName];
  const word = scenario && scenario.originClassWord;
  return word ? ORIGIN_IDENTITY_BY_WORD[storedClassWord(word)] : classInfo;
};
```

`offeringResponse` takes the active scenario name and reads its `clazz_id`, `clazz_hash` and
`class_word` off that class rather than off the module-level `classInfo`. The `no_clazz` behaviour is
unchanged; it must keep omitting `clazz_id`, which is the whole point of that scenario.

⚠️ **A missing fixture is a 500 with a named cause, not a fallback.** This is the one place the stub
does not model the portal, deliberately. It sits in `offeringResponse`'s `default:` branch, so the
four behaviour branches (`forbidden`, `notfound`, `no_clazz`, `server_error`) still return their own
responses without consulting a class at all:

```js
// ⚠️ NEVER fall back to classInfo here. A scenario whose declared originClassWord has no fixture
// would then be served the SPRING origin class, resolveOriginClass would publish
// fl-spring-2026-origin, classifyFallProgram would return undefined, and the run would fail with
// "unclassifiable origin class word" — a pipeline-shaped message for a fixture-shaped fault. A 500
// plus this line in terminal 2 names the actual cause.
const origin = originClassFor(scenarioName);
if (!origin) {
  console.error(`[stub] scenario "${scenarioName}" declares an originClassWord with no class fixture`);
  return { status: 500, body: errorEnvelope("stub misconfiguration: no class fixture for this scenario's originClassWord") };
}
```

`CLASSES_BY_WORD` gains the three new fall classes. `studyControlClassInfo`'s Orange offering id
follows the post-test scenario's `resource_link_id`, so the class contains the offering the student
launched from, as the real study class does:

```js
const studyControlClassInfo = classInfoFor(STUDY_CONTROL_CLASS, [
  // The post-test the student launched from. A correct by-name match must NOT select it.
  // ⚠️ This id is NOT here to exercise REPORT-80's self-target guard, which compares the offering
  // that matched the BLUE target name (id 845) against resource_link_id and never looks at this one.
  // That guard is reached only by open-target-offering.test.ts, from a shape no harness scenario
  // reproduces.
  { id: FALL_CONTEXTS["fall-orange-control"].resource_link_id, name: "Orange Sequence for AI in Math (FLVS 26-27)", locked: false },
  { id: 845, name: TARGET_OFFERING_NAME, locked: true },
]);
```

⚠️ This changes the id `open-target-happy` sees from `im-done-offering-1` to the post-test scenario's
`resource_link_id`. Checked: that scenario depends on the target's **name**, not on the Orange
offering's id, so it is unaffected.

Acceptance for this commit is **two** scenarios, not one. `open-target-happy` covers the Orange
offering id move, and specifically must, since this commit moves that id out from under the scenario
built to discriminate against it. `happy` covers the `offeringResponse` rewrite itself: it is the
only currently-shipped scenario that reads `offerings#show` (through `send-email`), so it is what
proves a scenario declaring no `originClassWord` still gets today's identity unchanged.

Finally, the enrolment recorder. `add_to_class` is the one call whose **payload** encodes a decision
the pipeline made that nothing else in a harness run observes:

```js
// Record the enrolment so run.js can assert the class the pipeline actually enrolled into, rather
// than only the arm it stored. Written on every add_to_class, including the failure behaviours, so a
// stale file from an earlier scenario can never be mistaken for this run's.
//
// Non-secret by construction: clazz_id and user_id only, never the Authorization header or the
// forwarded token. Same masking rule as the request log two lines below it.
if (route === "enroll") {
  fs.writeFileSync(LAST_ENROLL_FILE, JSON.stringify({
    scenario: name, clazz_id: body.clazz_id, user_id: body.user_id, status: result.status,
  }));
}
```

---

### Seed answers per scenario

**Summary**: R15c. Today's four fixed answer document ids cannot hold three scenarios' answers at
once, and the failure is silent and points at the wrong thing.

**Files affected**:
- `functions/harness/im-done-local/seed.js`

**Estimated diff size**: ~70 lines

`seed.js:26` builds `` `${CONTEXT.source_key}-ans-${answer.key}` ``: four ids independent of scenario,
written with `.set()`. `run-all.js` and the README both say to seed once, so one run has to hold every
scenario's answers simultaneously; three scenarios by four answers yields **4 documents, not 12**,
each written three times, last writer wins. The two losing scenarios then have no answers under their
own `resource_link_id`/`context_id`, so `evaluateCompletion` counts zero and reports "You have
completed 0 of 4 required questions" while `readDemographics` reports every question skipped. Both
read as a pipeline fault.

`seed.js` therefore loops over the scenarios that need answers, and the document id carries the
scenario:

```js
const scenariosNeedingAnswers = Object.entries(SCENARIOS).filter(([, s]) => s.seedAnswers);

for (const [scenarioName, scenario] of scenariosNeedingAnswers) {
  const context = { ...CONTEXT, ...(scenario.context || {}) };
  for (const answer of ANSWERS) {
    // ⚠️ The id carries the SCENARIO. Without it every scenario writes the same four ids and the
    // last seeded one wins, leaving the others with no answers under their own launch context.
    const docId = `${context.source_key}-${scenarioName}-ans-${answer.key}`;
    await answersCol.doc(docId).set({ ...context-derived fields..., report_state: buildReportState(answer) });
  }
}
```

⚠️ **The collection is cleared first, and that is not optional.** Changing the id scheme leaves the
four previously-seeded documents in place: the emulator imports and exports its data, so they survive
a restart, and they carry the same `platform_id` / `resource_link_id` / `context_id` as the `happy`
scenario's new ones. `findAnswerByPrompt` throws when more than one document matches a prompt, so a
re-seed without a delete turns the previously-green `happy` scenario into an `unmappable` failure that
looks like an authoring fault. `seed.js` deletes every document under
`sources/<source_key>/answers` before writing, which also makes the README's existing "re-run to reset
the answers" claim true rather than approximately true.

The spring `happy` scenario gains `seedAnswers: true` and no `context`, so it keeps seeding under the
shared `CONTEXT` exactly as today, only under a scenario-qualified id.

---

### Make the driver's request, expectations and read-back per scenario

**Summary**: R15d. `run.js` today hardcodes the pre-test shape: one `REQUEST`, one `CONTEXT`, one
`EXPECTED_CLASS`, one document-id formula, and an assignment comparison on every successful run. A
post-test scenario makes no assignment, so `readAssignedClass()` would return `undefined` and the
scenario would report FAIL on a run in which every step succeeded.

**Files affected**:
- `functions/harness/im-done-local/run.js` — per-scenario request, expectations and read-back
- `functions/harness/im-done-local/scenarios.js` — `happy`'s two new declarations, see below
- `functions/harness/im-done-local/config.js` — `EXPECTED_CLASS` removed

**Estimated diff size**: ~175 lines

The submitted request and context become per scenario, defaulting to today's values so every existing
scenario is unchanged:

```js
const request = { ...REQUEST, ...(scenario.request || {}) };
const context = { ...CONTEXT, ...(scenario.context || {}) };
```

`CLASS_BY_ASSIGNMENT` is **retired**. Three different values are in play and only one of them is
stored: the document holds an **arm** (`"treatment"` / `"control"`), today's table maps that arm to a
display **name** (`FL-spring-2026-SHARK`), and a class **word** is the lowercase form the portal
stores. The read-back now composes the scenario's origin word with the arm's suffix, which exercises
the same `DESTINATION_SUFFIX` round trip the pipeline uses instead of a second hand-maintained table:

```js
// Two formulas, not one variant of one. Full-time uses the per-class document (which includes the
// launch context, so it is per scenario); flex uses the pooled document, which is keyed on the
// PROGRAM and is therefore shared by every flex scenario that will ever exist.
const assignmentDocId = (scenario, context) => {
  if (scenario.assignmentScope === "pooled") {
    return sha256(`ai4vs-flvs-assignments-pooled|${FLEX_PROGRAM}|${context.interactiveId}|${context.platform_id}`);
  }
  return sha256(`ai4vs-flvs-assignments|${context.interactiveId}|${context.platform_id}|${context.resource_link_id}|${context.context_id}`);
};

// The stored value is an ARM. The word is derived, which is what makes this assert the same
// DESTINATION_SUFFIX round trip the pipeline depends on.
const readAssignedWord = async (scenario, context) => {
  const snap = await admin.firestore().doc(`sources/${context.source_key}/jobs-task-data/${assignmentDocId(scenario, context)}`).get();
  if (!snap.exists) {
    return undefined;
  }
  for (const stratum of Object.values(snap.data().strata || {})) {
    const arm = stratum.users && stratum.users[context.platform_user_id];
    if (arm) {
      return `${scenario.originClassWord}${DESTINATION_SUFFIX[arm]}`;
    }
  }
  return undefined;
};
```

Both formulas were verified byte-identical to `perClassScope` and `pooledProgramScope`.

The success-path check becomes explicit rather than implied. A scenario declares either the word it
expects or that it makes no assignment:

```js
  let classOk = true;
  if (expect.status === "success" && expect.assignedClassWord) {
    const assigned = await readAssignedWord(scenario, context);
    classOk = assigned === expect.assignedClassWord;
    console.log(`assigned class word: ${assigned} (expected ${expect.assignedClassWord})`);
  } else if (expect.status === "success" && expect.noAssignment) {
    console.log("(this stage makes no assignment; no read-back)");
  }
```

⚠️ **`happy`'s declaration lands in THIS commit, not the later scenarios one, and the commit is
unsound without it.** The spring `happy` scenario declares
`originClassWord: "fl-spring-2026-origin"` and `expect.assignedClassWord:
"fl-spring-2026-origin-shark"`, which is the same fact its current `EXPECTED_CLASS` comparison
asserts, expressed as the word rather than the display name. `EXPECTED_CLASS` is removed from
`config.js` in the same commit, since nothing reads it afterwards.

The reason to be explicit about the commit boundary is that omitting the declaration produces no
error, only silence. The new check reads
`if (expect.status === "success" && expect.assignedClassWord)`, so a `happy` declaring neither
`assignedClassWord` nor `noAssignment` takes **neither** branch: `classOk` stays `true` and the
read-back never runs. This commit deletes the old comparison, so `happy` would lose its assignment
verification outright while still reporting PASS, and every following commit would inherit a harness
that silently no longer checks the one thing it was written to check.

That is also what makes this commit's acceptance check falsifiable rather than vacuous: "all 28
existing scenarios pass" would be satisfied by a `readAssignedWord` that returned `undefined`
unconditionally. The check to run is **`happy` passing with its assignment read-back and its
enrolment assertion both active**, which a broken `readAssignedWord` or a broken
`assignmentDocId` fails immediately.

**The enrolment assertion, which is the only check here that observes the pipeline rather than the
harness.** Everything above reads an **arm** out of the document and recomposes the word from
`scenario.originClassWord` and the harness's own `DESTINATION_SUFFIX`, then compares it to a literal
in the same file. Both sides of that comparison are harness values; the destination word the pipeline
computed is never seen. That gap is not academic, because R15b gives all four subclass words a
`classes/info` fixture on purpose (so a sticky flipped arm is diagnosable), which means a pipeline
that appended the **wrong suffix** would resolve a real class, enrol successfully, and pass:

```js
// The pipeline resolved a class WORD to a class ID and enrolled into it. Asserting the id is what
// makes this scenario observe that decision; the assignment read-back above only observes the arm,
// and recomposes the word from harness constants.
const readEnrolledClassId = () => {
  if (!fs.existsSync(LAST_ENROLL_FILE)) {
    return undefined;
  }
  return JSON.parse(fs.readFileSync(LAST_ENROLL_FILE, "utf8")).clazz_id;
};
```

`run.js` deletes `LAST_ENROLL_FILE` before submitting, so a stale record from the previous scenario
cannot satisfy this run. A scenario that expects an enrolment declares the class id it expects
(`expect.enrolledClassId`), and the check is skipped for scenarios that enrol nothing, exactly as the
assignment read-back is.

⚠️ **The comparison is stringified on both sides, and that is not defensive tidiness.** The two
enrolling steps disagree on the type they post, and the two declaring scenarios disagree on the type
they hold:

| Enroller | Posts | Scenario declares |
|---|---|---|
| `enroll-specified-class.ts:125,148` | `String(lookup.class.id)`, so `"30011"` | `FALL_FT_TREATMENT_CLASS.id`, the **number** `30011` |
| `random-assignment.ts:125` (spring) | `String(classId)` over `control_class_id` | `REQUEST.control_class_id`, already the string `"im-done-shark-202"` |

A `===` comparison therefore passes for `happy` and fails for both fall pre-test scenarios, on the
one assertion that was added because the assignment read-back never observes a pipeline decision. An
assertion that always fails is no better than the gap it replaces, and the temptation on a red run is
to delete it:

```js
const enrollOk = String(readEnrolledClassId()) === String(expect.enrolledClassId);
```

This also strengthens `happy`, which has the same blind spot today and gains the same assertion —
noting that its expected value comes from `REQUEST.control_class_id` rather than from a
`classes/info` fixture, since spring authors raw class ids and never resolves a word.

---

### Add the three end-to-end fall scenarios

**Summary**: R15 and R15e. The commit that turns everything above on. Every preceding harness step
kept the suite green by adding unused capability; this one is where the fall stages actually run.

**Files affected**:
- `functions/harness/im-done-local/scenarios.js`

**Estimated diff size**: ~90 lines

```js
  "fall-green-fulltime": {
    describe: "The whole fall pre-test stage for a FULL-TIME student: complete, resolve, randomize, enroll, lock, notify.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-green-fulltime"],
    request: { pilot: "fall-2026-green", min_completed_questions: 4 },
    originClassWord: "ft-2026-bingler",
    assignmentScope: "per-class",
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      assignedClassWord: "ft-2026-bingler-gator", enrolledClassId: FALL_FT_TREATMENT_CLASS.id,
    },
  },
  // ⚠️ The SAME seeded answers as the full-time scenario, landing in the OPPOSITE arm. That is the
  // point: it can only pass if the program resolved from the origin class word actually selected a
  // different strata table. Verified against the real steps before this was written.
  "fall-green-flex": {
    describe: "The same pre-test stage for a FLEX student, whose identical answers must land in the opposite arm.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-green-flex"],
    request: { pilot: "fall-2026-green", min_completed_questions: 4 },
    originClassWord: "fl-2026-section1",
    assignmentScope: "pooled",
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      assignedClassWord: "fl-2026-section1-shark", enrolledClassId: FALL_FLEX_CONTROL_CLASS.id,
    },
  },
  // The only stage where two offering-state steps coexist, so the only place R9's entry-name
  // uniqueness actually bites, and the only end-to-end exercise of the teacher email rendering a lock
  // line beside an open line. It makes no assignment, which is why the driver's read-back had to stop
  // being implied by success.
  "fall-orange-control": {
    describe: "The whole fall post-test stage for a CONTROL student: resolve, lock the post-test, open the curriculum, notify.",
    behavior: OK,
    context: FALL_CONTEXTS["fall-orange-control"],
    request: { pilot: "fall-2026-orange", email_subject: "AI4VS: Student completed post-test" },
    originClassWord: STUDY_CONTROL_CLASS.word,
    expect: { status: "success", messageIncludes: "teacher has been notified", noAssignment: true },
  },
```

The post-test scenario carries no `seedAnswers`: its stage runs no `evaluateCompletion` and no
`readDemographics`, so it needs no answers at all.

Acceptance for this commit is `run-all.js` reporting 31/31, and terminal 2 showing the post-test run
making one mint, one `GET offerings/:id`, one `GET classes/info`, two `PUT`s and one
`POST send_class_teachers`, with no second offering read (which is R11 working end to end).

---

### Document the harness's fall behaviour

**Summary**: R15f, plus the README's claim that the fall steps run only as direct-step scenarios,
which stops being true.

**Files affected**:
- `functions/harness/im-done-local/README.md`

**Estimated diff size**: ~60 lines

The README gains the three fall scenarios in its scenario list, and a short section recording that a
fall scenario's assigned arm is **sticky** across re-runs. The stickiness is correct and is what R18
asserts, but from outside it means editing the demographic answers and re-running yields the *old*
arm with nothing on screen explaining why. It names the document to delete, **for both formulas**:

- the full-time scenario's is the per-class document, hashed over its own `resource_link_id` and
  `context_id`, so it is per scenario;
- the flex scenario's is the pooled document, keyed on the program, so deleting it resets every flex
  scenario at once, including any added later.

Deliberately not automated: a driver that cleared the assignment on every run would destroy the one
property R18 exists to demonstrate.

---

### Run the pre-launch checklist

**Summary**: R17. Not code. Every item is portal-side state the pipeline cannot establish for itself,
and each failure is invisible until a student clicks and then affects a whole arm at once.

**Files affected**: none in this repo.

**Estimated diff size**: 0 lines

📋 **The checklist**: https://gist.github.com/dougmartin/2b07c5b6794eebbcc0c743e94b06ec41 (secret
gist, created 2026-07-30, carries its own run log). ⚠️ It must be **copied into the closed spec
summary** when REPORT-82 is closed, since this spec folder collapses to a single file at close and the
re-run trigger outlives the story.

Run against the real fall classes once they exist, re-run after any portal-side change to them, and
record the result on REPORT-82. The items are listed in full in requirements.md R17, whose authoring
bullet now also carries R13's prohibition: **the pre-test button must not author
`target_class_word`**. That is the one authoring rule in this story with a real code guard behind it
(`enroll-specified-class.ts:44-60` hard-fails an authored word that differs from the randomisation
handoff, with its own log line), so the failure is loud rather than silent — but the guard fires on a
student's click, and this checklist is the only place it can be caught before one. Two carry the
longest detection lag and cannot be caught any other way: that `TARGET_OFFERING_NAME` matches the Blue
offering's name **as the portal serves it**, and that the three sequences carry the right initial
class-level state per arm. The second is **owned by the PI**, and her commitment on record covers the
Orange row only, so the Blue / `-shark` cell is the one to put to her first: an unlocked Blue in a
`-shark` class produces no error, no log line and no failed run, and it puts the intervention into the
control arm.

## Verification

After the last code step, on a clean tree:

- `npx jest` reports **26 suites, 491 passed, 4 skipped (495 total)**. Derived rather than guessed,
  and each row below is what its step adds:

  | Step | Adds | Running total |
  |---|---|---|
  | (baseline, measured on this branch) | — | 484 |
  | Retire the stale pilot | 0 (edits fixtures and one assertion in place) | 484 |
  | Publish and consume the origin class id | +2 (`send-email.test.ts`; the `resolve-origin-class.test.ts` addition is an assertion inside an existing `it`) | 486 |
  | Wire the three fall stages into PIPELINES | +7 (4 `EXPECTED_HANDLERS` rows, 3 from the shipped duplicate-name `it.each` going from one pipeline to four) | 493 |
  | Add the fall fixtures | +2 (the `DESTINATION_SUFFIX` and `FLEX_PROGRAM` pins) | **495** |
  | every remaining step | 0 (harness only) | 495 |

  The 4 skipped are the baseline's and are untouched. The suite count stays at **26**: no step adds a
  test file. The emulator suite runs separately under `npm run test:emulator` and is excluded from
  that count.

  ⚠️ The 486 and 493 rows were **measured**, not projected: the source-side plan was applied in full
  to a scratch tree and the suite run, giving 26 suites / 487 passed / 4 skipped / 491 total with the
  two `send-email.test.ts` tests not yet written, which is the 493 row minus those two. If the pins
  in the last row are written as one `it` rather than two, the final total is 494; that is the only
  degree of freedom left in the number.
- `npm run build`, then the harness in three terminals, then `node harness/im-done-local/seed.js` and
  `node harness/im-done-local/run-all.js`: **31/31 scenarios pass** (28 today plus the three fall
  ones).
- The baseline both numbers are measured against was taken on this branch before any change: 26
  suites / 484 total, and 28/28 harness scenarios.

## Open Questions

### RESOLVED: Should the pre-test scenarios assert the enrolment itself, or only the assignment document?

**Context**: R15 says the two pre-test scenarios "assert the destination class the student was
actually enrolled in rather than only the completion text". The plan above reads the arm back from the
persisted assignment document and derives the word. That proves the strata-to-class mapping and that
some enrolment succeeded, but not that that exact class reached the portal, which the README already
says plainly about today's check. Asserting the enrolment itself means the stub recording the
`add_to_class` body and the driver reading it back, which is a new channel between the two processes
(a file the stub writes, most likely, since they are separate processes).

**Options considered**:
- A) Keep the assignment-document read-back as planned. The gap is pre-existing, documented, and the
  same for spring.
- B) Have the stub record the last `add_to_class` body to a file and have `run.js` assert the
  `clazz_id` matches the fixture for the expected word. Closes the gap for the fall scenarios and for
  `happy` at the same time.
- C) B, but for all portal calls, so any scenario can assert any request body.

**Decision**: **B** (Doug, 2026-07-30), scoped to `add_to_class` only.

What settled it is a property of the planned read-back that R15d does not state: it reads an **arm**
out of the assignment document and recomposes the word from `scenario.originClassWord` and the
harness's own duplicated `DESTINATION_SUFFIX`, then compares that to a literal in the same file. Both
sides are harness values, so the destination word the pipeline computed is never observed. Combined
with R15b's deliberate decision to give all four subclass words a `classes/info` fixture, a pipeline
that appended the wrong suffix would resolve a real class, enrol successfully, and pass the scenario.
Asserting the `clazz_id` in the `add_to_class` body is the one check that observes what the pipeline
decided. It costs about 30 lines across the stub and the driver, and `happy` gains the same assertion.

C was declined: a general request-recording channel is the same mechanism generalised, nothing else in
the plan needs it, and it invites scenarios that assert request shapes the unit tests already own.
Recording the `send_class_teachers` body instead was also considered and rejected, even though the
email already carries both the assigned word and the enrolled class name: it would make scenarios
depend on rendered teacher-facing copy, which R10 expects to keep changing.

Consequence recorded in requirements.md: R15d's claim that the word-over-arm read-back "makes the
read-back exercise the same `DESTINATION_SUFFIX` round trip" is corrected, since what actually
protects the duplicated constants is the unit-test pin.

---

### RESOLVED: Where does the R17 pre-launch checklist live as a working artifact?

**Context**: R17 is a task on this story with a result to be recorded on the ticket, but the plan's
last step produces no file. The checklist currently exists only as prose inside requirements.md, which
is not a thing anyone can tick off, and the story is closed by `cc-close-spec` into a summary that may
not carry it.

**Options considered**:
- A) A `checklist.md` in the spec folder, ticked off in a commit when it is run.
- B) A Jira comment on REPORT-82 posted when the classes exist, with the result recorded as a reply.
- C) Leave it in requirements.md R17 and record only the outcome on the ticket.
- D) A secret gist, linked from requirements.md R17 and from the ticket, copied into the closed spec
  summary when the story closes.

**Decision**: **D** (Doug, 2026-07-30), created at
https://gist.github.com/dougmartin/2b07c5b6794eebbcc0c743e94b06ec41

A was ruled out on a property of this repo rather than on preference: closed specs collapse to a
single file (`specs/REPORT-81-pilot-configurable-randomization.md` is the precedent), so a
`checklist.md` inside the folder stops existing at close, while R17's re-run trigger ("after any
portal-side change to them") outlives the story. There is no `docs/` directory, so A's only durable
variant would have been inventing one for a single file.

D keeps the tickable copy and its run log somewhere that survives both the close and the repo's own
conventions, while requirements.md R17 stays canonical for the reasoning. The gist is **secret**
(unlisted, not private), which was checked rather than assumed to be acceptable: this repo is public,
so the class words, the five teacher surnames and even the teachers' full names in
`strata-tables.ts`'s `FULL_TIME_TABLE` are already openly published, and the gist adds no exposure
that does not already exist.

⚠️ What D does **not** solve, stated so nobody assumes otherwise: nothing makes a future portal-side
change trigger a re-run. That remains a human commitment, exactly as it is today.

---

### RESOLVED: Is the commit split right, particularly the four harness steps?

**Context**: The plan is nine steps, of which four are harness plumbing (config, stub, seed, driver)
that add capability nothing uses until the fifth adds the scenarios. That ordering is deliberate: it
keeps `run-all.js` green at every commit, since a scenario declared before its driver support would
fail.

⚠️ **An earlier draft of this question claimed those four commits "cannot be judged by running
anything, only by reading". That is false, and it was the whole argument for collapsing them.** Each
has a real acceptance check:

| Plumbing commit | How it is verified |
|---|---|
| config fixtures | `npx jest`: the commit adds the unit-test pins for the duplicated `DESTINATION_SUFFIX` and `FLEX_PROGRAM` (495 total). |
| stub identities | `open-target-happy`, and specifically it must be, since this commit moves the Orange offering's id out from under the scenario built to discriminate against it. |
| seeding | `happy` still passing, which is exactly what the collection-clearing change could break. |
| driver | `happy` passing with its assignment read-back AND its enrolment assertion active (the commit carries `happy`'s declarations for exactly this reason), plus the other 27 scenarios still passing. |

**Options considered**:
- A) Keep the split as planned. Each commit is small and reviewable; the harness stays green throughout.
- B) Collapse the four plumbing commits plus the scenarios into one "fall harness scenarios" commit
  (~500 lines). Reviewable as a working whole, at the top of the size guideline.
- C) Collapse config+stub into one and seed+driver+scenarios into another, splitting the difference.

**Decision**: **A** (Doug, 2026-07-30), with the stale-pilot cleanup moved to **first**.

The correction above is what settles it: the split is not four unreviewable commits followed by a
payoff, it is four commits that each keep a green suite green. B would fold the Orange-offering-id
change, the answers-collection clearing and the driver rewrite into a single commit of roughly 590
lines (larger than this question's original estimate, since the enrolment recorder landed after it was
written), and a broken `open-target-happy` would then have to be bisected inside one commit rather than
attributed to the one that moved the id.

The reorder is separate and minor: the pilot cleanup is inert and spans four files across both the
source tree and the harness, so as the third commit it would add noise to the diffs of the two
substantive source commits on either side of it. As the first, it is out of the way.

## Self-Review (Round 1)

Six lenses: Senior Engineer, QA Engineer, Build / Release Engineer, Security and Privacy Engineer,
Portal API reviewer, Spec Editor. Student, Teacher, Education Researcher and WCAG were dropped: this
document's deltas are wiring and harness plumbing, and requirements.md's Rounds 1 and 3 closed the
student- and researcher-facing questions with verified findings that nothing here reopens.

Every finding below was checked by running code before it was written down. The source-side plan was
**applied for real** to a scratch working tree (types.ts, resolve-origin-class.ts, send-email.ts,
index.ts and index.test.ts), the suite was run, and the tree was reverted; the harness-side findings
were checked by reproducing the proposed code paths in a standalone node script. Candidates that did
not survive verification are recorded at the end.

Baseline re-measured on this branch before any change: `npx jest` reports **26 suites, 480 passed, 4
skipped (484 total)**, unchanged from what the plan records.

### Senior Engineer

#### RESOLVED: The stub's per-scenario origin identity resolves through the one map the plan deliberately leaves the registration words out of

The two steps disagree with each other, and the disagreement fails both pre-test scenarios.

"Add the fall fixtures" states, with a written rationale: "The registration words (`ft-2026-bingler`,
`fl-2026-section1`) are looked up by nothing and are deliberately not here, so the fixture set does
not imply the origin is resolved through this endpoint." That is correct about `classes/info`.

"Serve a per-scenario class identity" then resolves the `offerings#show` identity through
`CLASSES_BY_WORD`, which is that same fixture map:

```js
const originClassFor = (scenarioName) => {
  const scenario = SCENARIOS[scenarioName];
  const word = scenario && scenario.originClassWord;
  return (word && CLASSES_BY_WORD[storedClassWord(word)]) || classInfo;
};
```

Both pre-test scenarios declare a **registration** word as `originClassWord`, so the lookup misses and
the `|| classInfo` fallback serves spring's origin class instead, silently. Reproduced against the
proposed config and stub code:

| Scenario | declares | `offerings#show` serves | `classifyFallProgram` |
|---|---|---|---|
| `fall-green-fulltime` | `ft-2026-bingler` | `class_word: fl-spring-2026-origin`, `clazz_id: 90210` | **undefined** |
| `fall-green-flex` | `fl-2026-section1` | `class_word: fl-spring-2026-origin`, `clazz_id: 90210` | **undefined** |
| `fall-orange-control` | `ft-2026-bingler-shark` | `class_word: ft-2026-bingler-shark`, `clazz_id: 30002` | full-time |

`fl-spring-2026-origin` is precisely the word requirements.md's verification item 7 records as
unclassifiable, so `fallRandomAssignment` returns the tell-your-teacher message and both new pre-test
scenarios FAIL. The last harness commit reports **29/31**, not 31/31, and the symptom
("unclassifiable origin class word") names the pipeline rather than the fixture.

It is also the one defect the commit split cannot surface early: the config commit and the stub
commit are each independently green, and the contradiction between them only becomes observable at
the seventh commit, when the scenarios that exercise it arrive.

Suggested resolution: the two registration classes need an `offerings#show` identity even though they
need no `classes/info` entry. Either add them to `CLASSES_BY_WORD` (harmless: nothing queries
`classes/info` for them, so only the comment's claim needs softening), or give `originClassFor` its
own identity map so the two concerns stay separate and the R15b rationale survives intact. Whichever
is chosen, the `|| classInfo` fallback should be replaced by a loud failure for a scenario that
declares an `originClassWord` the stub cannot serve, since a silent fallback to spring's class is
what makes this misdiagnose as a pipeline fault.

**Resolution** (Doug, 2026-07-30): the **separate identity map**, chosen over folding the
registration words into `CLASSES_BY_WORD` because it keeps R15b's "the origin is not resolved through
`classes/info`" claim literally true rather than merely commented. The config step gains
`FALL_FT_REGISTRATION_CLASS` and `FALL_FLEX_REGISTRATION_CLASS` as an identity-only pair, explicitly
marked as not `classes/info` fixtures; the stub step gains `ORIGIN_IDENTITY_BY_WORD`, a superset of
`CLASSES_BY_WORD`, and `originClassFor` now returns `undefined` for a declared word with no fixture
so `offeringResponse` can answer with a 500 and a `console.error` naming the cause. The
`|| classInfo` fallback is gone; a scenario that declares nothing still gets today's identity, which
is what keeps the 28 existing scenarios unchanged. The stub commit's acceptance check was also
widened to `happy` as well as `open-target-happy`, since `happy` is the only shipped scenario that
reads `offerings#show` and is therefore what exercises the `offeringResponse` rewrite at all.

---

#### RESOLVED: The `index.test.ts` edit list omits the eight handler imports the ordered-handler assertion needs

The PIPELINES step scopes `index.test.ts` to "four mocks, the lock mock's snapshot key, the
ordered-handler assertion", and says only that "`StepHandler` joins the `./types` import".
`EXPECTED_HANDLERS` references eight handler identifiers, and `index.test.ts` imports **none** of them
today: its imports are `IJobDocument`, `StepContext`, `ai4vsFlvs`, `PIPELINES` and
`TELL_TEACHER_MESSAGE`. Eight named imports have to be added or the file does not compile.

Mechanical, but worth stating in a plan whose value is that it can be typed in as written, and it is
the one edit in that step that is build-breaking rather than additive.

Verified that the assertion otherwise works exactly as the plan claims. Written out in full against
this file's mock style and run: the `Array<[string, StepHandler[]]>` table compiles under jest 24, the
imported handler is the same reference `index.ts` holds (so identity holds through the mock), and
`toEqual` genuinely discriminates: a deliberately mis-ordered list and a list of look-alike stand-in
functions both fail as they should.

Suggested resolution: the step lists the eight imports alongside `StepHandler`.

**Resolution** (Doug, 2026-07-30): the PIPELINES step now writes the eight imports out in full, flags
that half of the R16 edit as build-breaking rather than additive (matching how R16a's
`fall-random-assignment` mock is already flagged), and records that each import resolves to this
file's own mock, which is why identity comparison is what the assertion performs.

---

#### RESOLVED: The R11/R12 test description names a mock `send-email.test.ts` does not have

The step says the first new test asserts that "the mocked `resolveOriginOffering` is **not** called".
`send-email.test.ts` does not mock `resolveOriginOffering`; it mocks `portalTokenFetch` (and
`getScopedPortalToken`) and lets the real `resolveOriginOffering` run over that transport. The
assertion available is on the fetch calls whose path matches `/api/v1/offerings/`, not on a
step-level mock.

Small, but it is the difference between a test that can be written from the plan and one that cannot.
Verified by writing both tests as described and running them: with a seeded `originClazzId` there are
zero offering-path fetches and the POST body carries the handoff's id; with empty `stepResults` there
is exactly one, and all four shipped `offering-*` failure classifications still pass.

Suggested resolution: reword to name `portalTokenFetch`'s offering-path calls as the thing asserted.

**Resolution** (Doug, 2026-07-30): the R11/R12 step now carries a ⚠️ note that
`resolveOriginOffering` is not mocked in that file, gives the `offeringCalls()` filter the assertion
actually uses, and states the expected counts (zero on the handoff path, one on the fallback). It
also records that the `resolve-origin-class.test.ts` addition is an assertion inside an existing
`it`, so it contributes no test to the totals below.

### QA Engineer

#### RESOLVED: `expect.enrolledClassId` compares a number fixture against the string the enrol step actually posts

The driver step declares the new enrolment assertion, and the scenarios step supplies
`enrolledClassId: FALL_FT_TREATMENT_CLASS.id`, which is the **number** `30011`.
`enroll-specified-class.ts:125` builds `const destinationClassId = String(lookup.class.id)` and
`:148` posts `clazz_id: destinationClassId`, so the stub records, and `readEnrolledClassId()` reads
back, the **string** `"30011"`. A `===` comparison is false and both pre-test scenarios fail the very
assertion that was added to close a real gap.

This is worth catching because of what the assertion is for. The RESOLVED question chose option B
precisely because the assignment read-back compares two harness values and never observes the
pipeline's decision; an assertion that always fails is no better than the gap it replaces, and the
temptation on a red run is to delete it.

`happy` is unaffected either way: spring's `random-assignment.ts:125` posts
`clazz_id: String(classId)` over `control_class_id`, which is already the string
`"im-done-shark-202"`.

Suggested resolution: the driver step states the comparison as `String(actual) === String(expected)`,
so the check does not depend on which of the two callers wrote the body. (Also worth noting in the
same place: `happy`'s expected value is `REQUEST.control_class_id`, not a `classes/info` fixture, so
the step's phrase "read off the same `config.js` fixture the stub serves" is true of the fall
scenarios only.)

**Resolution** (Doug, 2026-07-30): the driver step now carries the two-row table of what each
enroller posts against what each scenario declares, states the comparison as
`String(readEnrolledClassId()) === String(expect.enrolledClassId)`, and corrects the claim about
where `happy`'s expected value comes from.

---

#### RESOLVED: `happy`'s read-back declaration belongs to no commit, so the rewritten check is silently skipped

The driver step lists **`run.js` alone** under "Files affected", but its own body requires a
`scenarios.js` edit: "The spring `happy` scenario declares `originClassWord: "fl-spring-2026-origin"`
and `expect.assignedClassWord: "fl-spring-2026-origin-shark"`". The scenarios step that follows lists
`scenarios.js` but shows only the three new fall entries. So that edit is assigned to no step at all.

The consequence is not a compile error, it is silence. The new check is
`if (expect.status === "success" && expect.assignedClassWord)`, so a `happy` that declares neither
`assignedClassWord` nor `noAssignment` takes **neither** branch: `classOk` stays `true` and the
assignment read-back never runs. The same commit deletes `EXPECTED_CLASS` and the comparison that used
it, so `happy` loses its assignment verification outright while still reporting PASS.

That also makes this step's stated acceptance check vacuous. "All 28 existing scenarios passing
against the rewritten read-back" would be satisfied by a `readAssignedWord` that returned `undefined`
unconditionally, because on this plan as written nothing calls it.

Suggested resolution: `scenarios.js` joins the driver step's "Files affected" with `happy`'s two new
declarations, so the commit that replaces the check also re-enables it. The acceptance check should
then say that `happy` passes **with** its assignment read-back and enrolment assertion active, which
is a claim the run can actually falsify.

**Resolution** (Doug, 2026-07-30): the driver step's "Files affected" now names all three files it
really touches (`run.js`, `scenarios.js` for `happy`'s declarations, `config.js` for the
`EXPECTED_CLASS` removal), a ⚠️ block records why omitting the declaration is silent rather than
loud, and both the step's acceptance check and the commit-split table's driver row were rewritten to
require `happy` passing **with** the read-back and the enrolment assertion active.

---

#### RESOLVED: The verification section's test totals are wrong in two places, and the two disagree with each other

Two numbers are stated, both `492`, and they cannot both be right because steps that add tests fall
between them.

Measured rather than derived. The source-side plan was applied in full (R11/R12, the three `PIPELINES`
entries, R8a's two log lines, the four new mocks, the R16b key, and the four-row `EXPECTED_HANDLERS`)
and the suite run:

| Point | Plan says | Measured |
|---|---|---|
| After the PIPELINES step | 492 total | **491 total** (26 suites, 487 passed, 4 skipped) |
| Final, after every step | 492 total | **≥ 493**, before the config commit's pins |

484 + 4 (the four `EXPECTED_HANDLERS` rows) + 3 (the shipped duplicate-name `it.each` going from one
pipeline to four) = 491. The R11/R12 step lands **before** the PIPELINES step and adds two
`send-email.test.ts` tests, so the running total at the PIPELINES step is 493 in plan order; and the
config step lands after it and adds the `DESTINATION_SUFFIX` / `FLEX_PROGRAM` pins, which follow the
`describe("harness fixture agreement")` precedent of one or two further `it`s. The final number is 494
or 495 depending on how those pins are grouped.

It matters because "26 suites, 492 total" is written as the acceptance gate for the whole story: a
developer who lands the work and sees 494 has to decide whether they added something they should not
have, and the honest answer is that the target was never derived.

Two things the same measurement confirmed, recorded so they are not re-checked: all 480 shipped tests
pass unmodified with R11/R12 applied, exactly as the step claims; and the suite count stays at 26.

Suggested resolution: state the final expected total as a range or re-derive it after the pins are
written, and drop the intermediate per-step total, which is the number that cannot be kept true as
steps are reordered.

**Resolution** (Doug, 2026-07-30): Verification now derives the total once, in a per-step table
ending at **26 suites, 491 passed, 4 skipped (495 total)**, and records which rows were measured
rather than projected. The PIPELINES step's own sentence drops its running total in favour of "+7",
so a reorder cannot falsify it. The last degree of freedom was closed by fixing the shape of the
config pins at two `it`s (one per constant, matching the existing `describe("harness fixture
agreement")` block); written as one, the total is 494, and that is stated.

### Spec Editor

#### RESOLVED: R13's "must not be authored" rule has no landing place in the plan

requirements.md R13 makes `target_class_word` a rule the pre-test button must obey, and R13 calls it "a
documented authoring rule backed by an existing guard". The guard is real, verified at
`enroll-specified-class.ts:44-60`: an authored word differing from the handoff is a hard configuration
error with its own log line, so the failure is loud rather than silent.

The documentation is what is missing. No step in this plan puts the rule anywhere a button author
would meet it: not in `index.ts`'s new comment block, not in the harness README, and not in the R17
checklist. The checklist's authoring bullet covers the pilot value, `min_completed_questions` and
`email_subject`, and stops there. Since this spec folder collapses into a single closed summary at
close, the rule's only home today is a document that is about to become an archive.

Low severity, since the guard means a violation fails loudly on the first student click rather than
routing a cohort into one class. But R17 is where every other authoring rule in this story is
enforced, and this is the only one left out of it.

Suggested resolution: one more clause on R17's authoring bullet, which is where R14's identical
"nothing in code can detect an omission" problem was already sent.

**Resolution** (Doug, 2026-07-30): requirements.md R17 gains a bullet of its own for it, naming the
guard at `enroll-specified-class.ts:44-60`, recording that the failure is loud rather than silent
(which is why it sits below the four items whose failures are not), and stating that it applies to
the pre-test button only since the other two stages contain no enrol step for the guard to fire in.
The R17 step in this plan points at it.

⚠️ **Manual follow-up, not done here**: the tickable copy of the checklist is the secret gist
(https://gist.github.com/dougmartin/2b07c5b6794eebbcc0c743e94b06ec41), which this review cannot edit.
The new bullet has to be added there too, or the run log will tick a checklist one item shorter than
the canonical one.

### Candidates checked and dropped

Recorded so they are not raised again.

- **"`String(origin.offering.clazzId)` can publish the literal string `undefined`."** It cannot.
  `portal-reads.ts`'s `resolveOriginOffering` returns `{ status }` with **no** `offering` whenever
  `clazz_id` is absent or null, so the `!origin.offering` guard above it is total and `clazzId` is
  always defined at that line. This is also why the `offering-no-clazz` harness scenario fails at
  `send-email` rather than posting to class `"undefined"`.
- **"The per-scenario `context_id` breaks the single seeded learner token."** Re-confirmed from the
  third end this time: `submit-task.ts:98-108` whitelists context keys (`context_id` and
  `resource_link_id` are both in `ALLOWED_CONTEXT_KEYS`) and never compares either to a token claim,
  and `demographics.ts:236-241` filters on `platform_id`, `resource_link_id`, `context_id` and
  `platform_user_id`, so per-scenario contexts isolate the answer sets exactly as R15c needs.
- **"Seeding answers only for scenarios carrying `seedAnswers` strands the ~20 other spring pipeline
  scenarios."** It does not. `mint-*`, `lock-*`, `offering-*` and `send-*` all run the spring pipeline
  past `evaluate-completion` and `random-assignment`, but the answers query matches on the launch
  context **fields**, not the document id, so all of them read the four documents seeded under
  `happy`'s scenario-qualified ids. The plan's `seedAnswers: true` on `happy` alone is sufficient.
- **"The post-test stage's portal-call count is optimistic."** It holds. `resolve-origin-class`,
  `offering-state.ts:87` (both the lock and the open) and `send-email` all call
  `getScopedPortalToken` with `tokenType: "teacher"` and no `class_id`, so the per-run cache serves
  one unscoped mint: 1 mint, 1 `GET offerings/:id`, 1 `GET classes/info`, 2 `PUT`s, 1 `POST`, and no
  second offering read.
- **"R16b's snapshot key edit is unnecessary."** The edit is correct and its stated premise
  ("no shipped assertion reads `stepResultsSnapshots["lock-activity"]`") was verified: the three
  snapshot reads are on `evaluate-completion`, `random-assignment` and `send-email`, and the
  `"lock-activity"` string at `index.test.ts:137` is a `stepResults` key inside the send-email
  snapshot, not a snapshot key. Worth noting only that nothing in this plan drives two pipelines in
  one file, so the collision the key change guards against is not one this story creates.
- **"R3's four occurrences are miscounted or misclassified."** All four are exactly as tabled,
  including that `enroll-specified-class.test.ts:100` is an assertion on the mint call
  (`expect.objectContaining({ tokenType: "teacher", pilot: "fall-2026-fulltime" })`) and not a
  fixture.
- **"The `fall-orange-control` scenario has a fixture gap of its own."** Traced end to end against the
  proposed stub: `offerings#show` serves `ft-2026-bingler-shark` / `30002`, the by-name match selects
  Blue at id `845`, the self-target guard compares `845` against `im-done-fall-orange` and passes, and
  `send-email` takes the `originClazzId` handoff. That scenario works as written.

### Re-run against the amended plan

No new findings. The one amendment large enough to introduce its own defect was re-run rather than
re-read: the `ORIGIN_IDENTITY_BY_WORD` design was reproduced over the amended fixture set and all four
properties hold.

| Case | Result |
|---|---|
| `fall-green-fulltime` | serves `ft-2026-bingler` / `30021` → classifies **full-time** |
| `fall-green-flex` | serves `fl-2026-section1` / `30022` → classifies **flex** |
| `fall-orange-control` | serves `ft-2026-bingler-shark` / `30002` → classifies full-time, unchanged |
| a scenario declaring nothing (`happy`, and the other 27) | serves `fl-spring-2026-origin` / `90210`, today's identity, unchanged |
| a scenario declaring a typo'd word | `undefined` → the 500 and the named `console.error`, not a silent fallback |
