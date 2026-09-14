# Implementation Plan: Completion gate on the Blue and Orange "I'm Done" buttons

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-133
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Four commits and two non-code steps. The first commit is the whole behavior change and is deployable
on its own; the other three are the test, the harness and the prose that the requirements attach to
it. The two steps after them are the staging check and production deploy (R9) and the production
authoring the gate is inert without (R11). Nothing in `lockCurrentOffering`, `openTargetOffering` or
`sendEmail` is touched.

The assumptions the plan rests on were checked before it was written (see the requirements spec's
round-2 self-review and the throwaway runs on 2026-09-14): `evaluate-completion.ts` imports cleanly
under jest with only `../../firebase-client` mocked and the `firebase/firestore` query builders
stubbed; both parameter faults return before `getClientFirestore`; and a Blue scenario with four
seeded answers and a threshold of 5 is refused end to end through the emulator with no
`update_student_metadata` and no `send_class_teachers` reaching the stub.

---

### Gate the Blue and Orange stages, and pin the new tables

**Summary**: R1, R2, R3, R4 and the code half of R8. One entry at the front of each of the two fall
stage arrays, reusing the Green entry verbatim, plus the comment edits the change invalidates and
the `EXPECTED_HANDLERS` rows that pin the new order. The REPORT-82 amendment rides in the same
commit because it is the prose that describes the contract being changed. Deployable alone: with
this commit, a Blue or Orange button authored without a threshold fails every press with the
existing internal message, which R10 replaces in the next commit.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/index.ts`: two new entries, two comment edits
- `functions/src/tasks/ai4vs-flvs/index.test.ts`: `EXPECTED_HANDLERS` rows for both pilots
- `specs/REPORT-82-fall-2026-pipeline-stages.md`: amendment notes on R5a, R5b, R10's entry-names table and R13

**Estimated diff size**: ~40 lines

`index.ts`, the fall header comment gains the ordering rule that Green's inline comment already
states for the enrol, so the three stages share one statement of it:

```ts
  // BOTH cohorts run these same three stages. The only program-dependent behaviour in the study is
  // inside fall-random-assignment, which resolves the program from the origin class word itself, so
  // this table stays keyed by stage and never by program. A pilot value such as "fall-2026-fulltime"
  // is forbidden: one shared Green button serves both cohorts.
  //
  // evaluate-completion is FIRST on every fall stage. It makes no portal call and it precedes the
  // lock, so a refused press writes nothing and leaves the student unlocked, able to answer more and
  // click again. One resource_link_id spans the whole sequence, so the count is sequence-wide.
  "fall-2026-green": [
```

The Blue entry and its comment:

```ts
  // Opens NOTHING. The PI opens the post-test by hand on a fixed date, gated on Blue completion
  // data she inspects herself. The lock IS the completion record she reads off the roster, and the
  // completion check in front of it is what makes that record mean "did the work" rather than
  // "pressed the button". Applies to both arms.
  "fall-2026-blue": [
    { name: "evaluate-completion", processingMessage: "Checking your answers\u2026", handler: evaluateCompletion },
    { name: "lock-curriculum", processingMessage: "Locking this activity\u2026", handler: lockCurrentOffering },
    { name: "send-email", processingMessage: "Notifying your teacher\u2026", handler: sendEmail },
  ],
```

The Orange entry; the existing "lock PRECEDES the open" comment is unchanged and still true:

```ts
  "fall-2026-orange": [
    { name: "evaluate-completion", processingMessage: "Checking your answers\u2026", handler: evaluateCompletion },
    { name: "resolve-origin-class", processingMessage: "Looking up your class\u2026", handler: resolveOriginClass },
    { name: "lock-post-test", processingMessage: "Locking your post-test\u2026", handler: lockCurrentOffering },
    // "Checking" rather than "Opening": ... (unchanged)
    { name: "open-curriculum", processingMessage: "Checking for your other activity\u2026", handler: openTargetOffering },
    { name: "send-email", processingMessage: "Notifying your teacher\u2026", handler: sendEmail },
  ],
```

`index.test.ts`, the two rows in `EXPECTED_HANDLERS`. Handler identity, in order, so a Blue entry
placed after the lock fails here and nowhere else:

```ts
    ["fall-2026-blue", [evaluateCompletion, lockCurrentOffering, sendEmail]],
    ["fall-2026-orange", [
      evaluateCompletion, resolveOriginClass, lockCurrentOffering, openTargetOffering, sendEmail,
    ]],
```

The distinct-name test in the same `describe` needs no change; it iterates the table.

`specs/REPORT-82-fall-2026-pipeline-stages.md`, one note after each of R5a and R5b, one under R10's
entry-names table (which also covers the logging requirement's "First entry" column above it) and one
under the R13 table. The spec is closed, so these are amendments rather than rewrites:

```markdown
**R5a.** ... the threshold, not the mechanism, is what is missing.

> **Amended by REPORT-133 (2026-09):** the PI set the thresholds on 2026-09-02 and both stages now run
> `evaluate-completion` first. See `specs/REPORT-133-blue-orange-completion-gate/`.
```

```markdown
The compensating control is the PI's own judgement, ...

> **Amended by REPORT-133 (2026-09):** superseded. With the gate in place the lock records that the
> student answered at least the authored number of questions, on both stages.
```

```markdown
`lockCurrentOffering` therefore appears under three different entry names across the three stages,
which is exactly the latitude REPORT-80 reserved when it kept spring's `lock-activity`.

> **Amended by REPORT-133 (2026-09):** the curriculum stage is now `evaluate-completion`,
> `lock-curriculum`, `send-email` and the post-test stage `evaluate-completion`, `resolve-origin-class`,
> `lock-post-test`, `open-curriculum`, `send-email`, so the "First entry" column in the logging table
> above reads `evaluate-completion` on all three stages.
```

```markdown
`min_completed_questions` is required on the pre-test stage: `evaluateCompletion` fails the run if it
is absent or not a positive integer.

> **Amended by REPORT-133 (2026-09):** required on the curriculum and post-test stages too, with
> `min_completed_questions_failure_message` worded for a sequence. See that spec's R11.
```

---

### Student-facing message on a misauthored threshold, with the step's first unit test

**Summary**: R10 and R6's new test file. The step keeps hard-failing when `min_completed_questions`
is absent or not a positive integer, but the student now reads a message they can act on and the
detail goes to the function log at error. The two existing checks collapse into one, since
`Number(undefined)` and `Number(null)` both fail the integer test and the log line carries the raw
value either way. The test is the step's first direct coverage and pins every branch R6 lists.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.ts`: message constant, one combined check, one error log
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.test.ts`: new

**Estimated diff size**: ~215 lines

`evaluate-completion.ts`, the constant, exported so the test and any future caller pin the text
rather than restate it. Declared the way `TELL_TEACHER_MESSAGE` and `RELOAD_MESSAGE` are in
`portal-api.ts`, with one line naming the rejected alternative:

```ts
// Not TELL_TEACHER_MESSAGE: "setting up your class" is wrong for a misauthored button parameter.
export const CHECK_FAILED_MESSAGE =
  "Something went wrong checking your answers. Please tell your teacher.";
```

The parameter check, replacing the two `if` blocks between the context-field check and
`getClientFirestore`:

```ts
  // Validate min_completed_questions before establishing Firestore connection
  const { request } = jobDoc.jobInfo;
  const rawMinCompleted = request.min_completed_questions;
  const minCompleted = Number(rawMinCompleted);
  if (!Number.isInteger(minCompleted) || minCompleted < 1) {
    functions.logger.error(
      `evaluate-completion: min_completed_questions is missing or not a positive integer (got ${JSON.stringify(rawMinCompleted)}) for ${jobPath}`
    );
    return { success: false, message: CHECK_FAILED_MESSAGE };
  }
```

`JSON.stringify(undefined)` is `undefined`, so an absent parameter logs `got undefined`, which is the
wording a reader searching the log for the fault will try. Nothing in the log line is PII: the value
is authored and `jobPath` is what every other line in the step already carries.

`evaluate-completion.test.ts`, in full. `firebase-client` is mocked so no client SDK is initialized;
`firebase/firestore`'s builders are stubbed so the query is a value the test can inspect, with
`getDocs` returning a snapshot shaped like the real one. `answerIsCompleted` is the real predicate,
so the fixtures use real document shapes rather than a `completed` flag:

```ts
import { IJobDocument } from "../types";
import { StepContext } from "./types";

const mockLoggerInfo = jest.fn();
const mockLoggerError = jest.fn();
const mockLoggerWarn = jest.fn();
jest.mock("firebase-functions", () => ({
  logger: {
    info: (...args: any[]) => mockLoggerInfo(...args),
    error: (...args: any[]) => mockLoggerError(...args),
    warn: (...args: any[]) => mockLoggerWarn(...args),
  },
}));

// The query builders are stubbed so the filters the step applies are observable.
const mockCleanup = jest.fn();
const mockGetClientFirestore = jest.fn();
jest.mock("../../firebase-client", () => ({
  getClientFirestore: (...args: any[]) => mockGetClientFirestore(...args),
}));
const mockCollection = jest.fn();
const mockWhere = jest.fn();
const mockGetDocs = jest.fn();
jest.mock("firebase/firestore", () => ({
  ...jest.requireActual("firebase/firestore"),
  collection: (...args: any[]) => mockCollection(...args),
  query: jest.fn(() => "the-query"),
  where: (...args: any[]) => mockWhere(...args),
  getDocs: (...args: any[]) => mockGetDocs(...args),
}));

import { evaluateCompletion, CHECK_FAILED_MESSAGE } from "./evaluate-completion";
import { createPortalTokenCache } from "../portal-api";

const JOB_PATH = "sources/test-source/jobs/test-job-123";

const makeContext = (request: Record<string, any>): StepContext => ({
  jobPath: JOB_PATH,
  jobDoc: {
    platform_id: "https://learn.concord.org",
    platform_user_id: 27,
    resource_link_id: "845",
    context_id: "class-hash",
    source_key: "test-source",
    jobInfo: {
      version: 1,
      id: "test-job-123",
      status: "running",
      request: { task: "ai4vs-flvs", pilot: "fall-2026-blue", ...request },
      createdAt: Date.now(),
    },
  } as unknown as IJobDocument,
  firebaseJwt: "jwt-token",
  stepResults: {},
  tokenCache: createPortalTokenCache(),
  portalOrigin: "https://learn.concord.org",
});

/** A snapshot of `completed` answered multiple-choice docs plus `untouched` empty interactive states. */
const snapshotOf = (completed: number, untouched: number) => ({
  size: completed + untouched,
  docs: [
    ...Array.from({ length: completed }, () => ({
      data: () => ({ type: "multiple_choice_answer", answer: { choice_ids: ["c1"] } }),
    })),
    ...Array.from({ length: untouched }, () => ({
      data: () => ({ type: "interactive_state", report_state: JSON.stringify({ interactiveState: "{}" }) }),
    })),
  ],
});

describe("evaluateCompletion", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockCleanup.mockResolvedValue(undefined);
    mockGetClientFirestore.mockResolvedValue({ firestore: {}, cleanup: mockCleanup });
    mockCollection.mockReturnValue("answers-ref");
  });

  describe("a misauthored min_completed_questions", () => {
    // The explicit table type is required: jest 24's it.each typings flatten an inline tuple table.
    const MISAUTHORED: Array<[string, Record<string, any>]> = [
      ["absent", {}],
      ["a non-numeric string", { min_completed_questions: "four" }],
      ["zero", { min_completed_questions: "0" }],
      ["a fraction", { min_completed_questions: "2.5" }],
    ];
    it.each(MISAUTHORED)("fails before Firestore with the student-facing message when %s", async (_label, request) => {
      const result = await evaluateCompletion(makeContext(request));

      expect(result).toEqual({ success: false, message: CHECK_FAILED_MESSAGE });
      expect(mockGetClientFirestore).not.toHaveBeenCalled();
      expect(mockGetDocs).not.toHaveBeenCalled();
    });

    it("logs the raw value at error so the fault is diagnosable from the log", async () => {
      await evaluateCompletion(makeContext({ min_completed_questions: "four" }));

      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining(`min_completed_questions is missing or not a positive integer (got "four") for ${JOB_PATH}`)
      );
    });

    it("says so when the parameter is absent", async () => {
      await evaluateCompletion(makeContext({}));

      expect(mockLoggerError).toHaveBeenCalledWith(expect.stringContaining("(got undefined)"));
    });

    it("keeps the raw value out of the student message", async () => {
      const result = await evaluateCompletion(makeContext({ min_completed_questions: "four" }));

      expect(result.message).not.toContain("four");
    });
  });

  describe("counting", () => {
    it("queries the launch's answers by all four identity fields", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 0));

      await evaluateCompletion(makeContext({ min_completed_questions: "4" }));

      expect(mockCollection).toHaveBeenCalledWith({}, "sources/test-source/answers");
      expect(mockWhere).toHaveBeenCalledWith("platform_id", "==", "https://learn.concord.org");
      expect(mockWhere).toHaveBeenCalledWith("resource_link_id", "==", "845");
      expect(mockWhere).toHaveBeenCalledWith("context_id", "==", "class-hash");
      expect(mockWhere).toHaveBeenCalledWith("platform_user_id", "==", 27);
    });

    it("counts only documents that pass answerIsCompleted", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 3));

      const result = await evaluateCompletion(makeContext({ min_completed_questions: "5" }));

      expect(result.success).toBe(false);
      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("4 of 7 answer(s) completed (need 5)")
      );
    });

    it("releases the client after a refusal and after a pass", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 0));

      await evaluateCompletion(makeContext({ min_completed_questions: "5" }));
      await evaluateCompletion(makeContext({ min_completed_questions: "4" }));

      expect(mockCleanup).toHaveBeenCalledTimes(2);
    });
  });

  describe("a short count", () => {
    beforeEach(() => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 3));
    });

    it("is an expected failure carrying the authored template with both variables filled", async () => {
      const result = await evaluateCompletion(makeContext({
        min_completed_questions: "5",
        min_completed_questions_failure_message:
          "You have answered ${completed} of the ${min_completed_questions} questions needed.",
      }));

      expect(result).toEqual({
        success: false,
        expected: true,
        message: "You have answered 4 of the 5 questions needed.",
      });
    });

    it("falls back to the default text when no template is authored", async () => {
      const result = await evaluateCompletion(makeContext({ min_completed_questions: "5" }));

      expect(result).toEqual({
        success: false,
        expected: true,
        message: "You have completed 4 of 5 required questions. Please answer more questions in this activity.",
      });
    });

    it("logs nothing at error", async () => {
      await evaluateCompletion(makeContext({ min_completed_questions: "5" }));

      expect(mockLoggerError).not.toHaveBeenCalled();
    });
  });

  describe("enough answers", () => {
    it("passes with the line send-email renders", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(4, 3));

      const result = await evaluateCompletion(makeContext({ min_completed_questions: "4" }));

      expect(result).toEqual({ success: true, message: "4 of 4 questions completed" });
    });
  });
});
```

The `it.each` over the four misauthored shapes is the case that fails if the combined check is
loosened; the "keeps the raw value out of the student message" case fails if someone later folds
the log detail into the message; the four `where` assertions fail if a filter is dropped; and the
template case fails if either substitution is dropped or the two are swapped.

---

### Harness: seed answers for the gated stages, add the refused scenario, record locks and sends

**Summary**: R7 in full. The two fall stage scenarios seed answers and pass the gate; one new
scenario is refused; and the stub records `update_student_metadata` and `send_class_teachers` the way
it records `add_to_class`, so `run.js` can assert that a refused run reached neither. The README's
stage table and the scenario comments that say those stages need no answers are updated in the same
commit.

**Files affected**:
- `functions/harness/im-done-local/config.js`: one `FALL_CONTEXTS` entry; `RECORD_FILES` map, with `LAST_ENROLL_FILE` derived from it
- `functions/harness/im-done-local/stub-portal.js`: the enrol record block generalizes to the map
- `functions/harness/im-done-local/run.js`: delete all three records before the submit; assert `noLock` / `noEmail` on a failure scenario
- `functions/harness/im-done-local/scenarios.js`: `seedAnswers` and the explicit threshold on the two stage scenarios; `fall-blue-refused`
- `functions/harness/im-done-local/.gitignore`: the two new record files
- `functions/harness/im-done-local/README.md`: stage table, read-back bullet, scenario list, two scenario counts

**Estimated diff size**: ~120 lines

`config.js`. The context entry, in `FALL_CONTEXTS`:

```js
  "fall-orange-control": { resource_link_id: "im-done-fall-orange", context_id: "im-done-fall-orange-ctx" },
  "fall-blue-refused": { resource_link_id: "im-done-fall-blue-refused", context_id: "im-done-fall-blue-refused-ctx" },
```

The record files, replacing the `LAST_ENROLL_FILE` definition; the old name stays exported because
`run.js`'s enrolment read-back uses it:

```js
// Written by stub-portal.js on every call to the named route, read by run.js after a run. The stub
// and the driver are separate processes, so a file is the channel available, as .scenario already is.
const RECORD_FILES = {
  enroll: `${__dirname}/.last-enroll.json`,
  lock: `${__dirname}/.last-lock.json`,
  send: `${__dirname}/.last-send.json`,
};
const LAST_ENROLL_FILE = RECORD_FILES.enroll;
```

and `RECORD_FILES` added to `module.exports`.

`stub-portal.js`. `RECORD_FILES` replaces `LAST_ENROLL_FILE` in the `require("./config")`
destructure, and the record block becomes:

```js
    // Record the portal writes run.js asserts on: the enrolment's class, which is the one observation
    // of the class the pipeline actually resolved, and whether a lock or a send reached the stub at
    // all. Written on every call to the route, including the failure behaviours, so a stale file from
    // an earlier scenario can never be mistaken for this run's.
    //
    // Non-secret by construction: the same masked fields as the request log below, never the
    // Authorization header or the forwarded token.
    const recordFile = RECORD_FILES[route];
    if (recordFile) {
      fs.writeFileSync(recordFile, JSON.stringify({ scenario: name, status: result.status, ...logFields(route, body, url) }));
    }
```

`logFields("enroll", ...)` yields `{ user_id, clazz_id }`, which is what `readEnrolledClassId` reads,
so the enrolment record's shape is unchanged. The `lock` route's `network` behavior returns before
this block, which is right: a dropped connection still reached the route, but no scenario declares
`noLock` under that behavior.

`run.js`. `RECORD_FILES` joins the `require("./config")` destructure. The pre-submit cleanup:

```js
  // Drop the records left by the previous scenario, so a stale one cannot satisfy this run.
  for (const file of Object.values(RECORD_FILES)) {
    fs.rmSync(file, { force: true });
  }
```

and after the enrolment block, before `pass` is computed:

```js
  // A failure scenario may declare that the run stopped BEFORE the portal writes. Every record was
  // deleted before the submit, so a file's absence is evidence that the route was never reached.
  // Opt-in, because the lock and send failure scenarios reach those routes on purpose.
  let stopOk = true;
  if (expect.status === "failure") {
    for (const [flag, route] of [["noLock", "lock"], ["noEmail", "send"]]) {
      if (!expect[flag]) {
        continue;
      }
      const reached = fs.existsSync(RECORD_FILES[route]);
      if (reached) {
        stopOk = false;
      }
      console.log(`${route}: ${reached ? "REACHED the stub" : "(not reached, as expected)"}`);
    }
  }

  const pass = statusOk && messageOk && classOk && enrollOk && stopOk;
```

`scenarios.js`. The two stage scenarios, with their comments rewritten where the change makes them
false:

```js
  // The curriculum stage: three steps, each already covered in isolation, so what this adds is the
  // stage. It is the one stage where send-email takes its FALLBACK offering read (no
  // resolve-origin-class publishes a clazz id), and the one whose notification is distinguishable
  // from a pre-test one only by the authored email_subject R14 requires. Launching from a -gator
  // class is deliberate: the curriculum lock applies to both arms, and nothing in this stage reads
  // the arm at all.
  "fall-blue-curriculum": {
    describe: "The whole fall curriculum stage: complete, lock the curriculum and notify, with no assignment and no enrolment.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-blue-curriculum"],
    request: { pilot: "fall-2026-blue", min_completed_questions: 4, email_subject: "AI4VS: Student completed curriculum" },
    originClassWord: FALL_FT_TREATMENT_CLASS.word,
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      noAssignment: true, noEnrollment: true,
    },
  },
  // The gate refusing, which the scenario above can only ever pass. The seed is four answers, so a
  // threshold of five must stop the run at the first step: the authored message, no lock, no email.
  // Blue is enough; the step is shared by every stage that runs it.
  "fall-blue-refused": {
    describe: "The fall curriculum stage refused: four seeded answers against a threshold of five, stopping before the lock and the notification.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-blue-refused"],
    request: {
      pilot: "fall-2026-blue",
      min_completed_questions: 5,
      min_completed_questions_failure_message: "You have answered ${completed} of the ${min_completed_questions} questions needed.",
      email_subject: "AI4VS: Student completed curriculum",
    },
    originClassWord: FALL_FT_TREATMENT_CLASS.word,
    expect: {
      status: "failure", failsAt: "evaluate-completion",
      messageIncludes: "You have answered 4 of the 5 questions needed.",
      noLock: true, noEmail: true,
    },
  },
  // The only stage where two offering-state steps coexist, so the only place the entry-name
  // uniqueness rule actually bites, and the only end-to-end exercise of the teacher email rendering
  // a lock line beside an open line. It makes no assignment and no enrolment, which is why neither
  // of the driver's read-backs may be implied by success.
  "fall-orange-control": {
    describe: "The whole fall post-test stage for a CONTROL student: complete, resolve, lock the post-test, open the curriculum, notify.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-orange-control"],
    request: { pilot: "fall-2026-orange", min_completed_questions: 4, email_subject: "AI4VS: Student completed post-test" },
    originClassWord: STUDY_CONTROL_CLASS.word,
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      noAssignment: true, noEnrollment: true,
    },
  },
```

`validateScenarios` needs no change: the comment above it names "the two fall stages that seed none"
as the reason a `seed.js`-local guard would not do; with every fall stage now seeding, that sentence
is edited to "which is not every scenario", since the guard's reasoning (it must see every declared
context, not only the seeding ones) still holds.

`.gitignore`, two lines after `.last-enroll.json`:

```
.last-lock.json
.last-send.json
```

`README.md`. Two counts first: the intro's "as part of a stage by the three fall pipeline scenarios
below" and the fall section's "Four scenarios run a whole fall pipeline" both become "five" (the
success bucket's "the four whole-pipeline fall stages" stays, since the refused scenario has its own
bucket). The read-back bullet gains one sentence after "cannot satisfy the run":

```markdown
  The stub records each `update_student_metadata` and `send_class_teachers` body the
  same way (`.last-lock.json`, `.last-send.json`), so a **failure** scenario can
  declare `expect.noLock` and `expect.noEmail` and have `run.js` assert that the
  run stopped before either route was reached; those two are opt-in, since the
  lock and send failure scenarios reach the routes on purpose.
```

The scenario list gains a bucket:

```markdown
- **refused**: `fall-blue-refused`, the completion gate stopping a fall stage
  before the lock and the notification.
```

The stage table:

```markdown
| `fall-blue-curriculum` | curriculum (`fall-2026-blue`) | complete → lock the curriculum → notify, with no assignment and no enrollment, and `send-email` taking its **fallback** offering read |
| `fall-blue-refused` | curriculum (`fall-2026-blue`) | the gate refusing: four seeded answers against a threshold of five, the authored message, and neither the lock nor the send reaching the stub |
| `fall-orange-control` | post-test (`fall-2026-orange`) | complete → resolve → lock the post-test → open the curriculum → notify, with no assignment at all |
```

---

### Verify on staging, then deploy to production

**Summary**: R9. Not a code commit; recorded here so the plan is complete and the order is
unambiguous. Every step below was checked against the portal source and the status tool on the
`ai4vs-status-tool` branch on 2026-09-14.

**Files affected**: none in this repo.

**Estimated diff size**: 0

1. From the merged master commit, in `functions/`: `npm run buildinfo`, then
   `firebase deploy --only functions:taskWorker,functions:submitTask --project report-service-dev`.
2. Pick a **control** student from `phase2-check-before-relock.txt` (one in a `-shark` class, e.g.
   `ft-2026-bingler-shark`). Unlock that student's Blue (762) and Orange (763) rows only, through
   the `ai4vs-setup` admin session:
   `admin.put("/api/v1/offerings/<id>/update_student_metadata", { user_id: <id>, locked: false })`
   for each of the two offerings. Never `PUT /api/v1/offerings/<id>` with `locked`: it rewrites
   every student's row.
3. Blue first, then Orange. On each: press with no threshold authored and confirm the
   `CHECK_FAILED_MESSAGE` text, the error line in the function log, no lock and no email; author
   `min_completed_questions` and the sequence-worded failure message on the button, press with too
   few answers and confirm the authored message with the counts filled in, still unlocked, no email;
   answer enough, press again and confirm the lock, the teacher email carrying the
   `evaluate-completion: N of M questions completed` line, and on Orange the Blue row reopened.
4. `node status.js check --env staging` ends with "No problems found." Its Failures table lists the
   misauthored and refused presses above that line; they are expected there and are not counted as
   problems, since the cross check reads the latest success per stage and a success is never
   replaced by a later failure.
5. `npm run buildinfo` again on the same commit, then
   `firebase deploy --only functions:taskWorker,functions:submitTask --project report-service-pro`.
   Verify from the deployed source zip: `build-info.json` names the merged commit, `updateTime` is
   today's, and the compiled `lib/tasks/ai4vs-flvs/index.js` lists `evaluate-completion` first for
   both fall stages.

---

### Author the production Blue and Orange buttons

**Summary**: R11. Not a code commit. Once the production deploy above is live, a Blue or Orange button
authored to the old recipe (`pilot`, `email_subject`, `completion_message`) fails every press with
`CHECK_FAILED_MESSAGE`, so the two production buttons are authored only after this step's first item
is settled and never without the two threshold lines. No production sequence carries a button today,
so there is nothing to retrofit.

**Files affected**: none in this repo. The PI's answer goes in the `im-done-button/decisions-log.md`
oob file (global namespace), newest at top with the date, alongside the 2026-09-02 and 2026-09-10
threshold entries.

**Estimated diff size**: 0

1. Before Blue is authored, put to the PI: the Blue starting number, the rule it replaces (total minus
   2 per activity, 212 on the 2026-09-14 export of sequence 845), and the reason for the departure
   (97 open responses that would nearly all have to be answered; around 20 stateful non-question
   interactives that count). Record her reply in the decisions log. Orange follows her rule as stated
   (total minus 1 per activity) and needs no separate question.
2. On the authoring day, recount both sequences from that day's published export rather than reusing
   the counts in the requirements spec's Technical Notes (Orange 844: 36 + 16; Blue 845: 32 + 32 + 29
   + 34 + 50 + 47); a republished activity changes the total.
3. Author each button with, in addition to the existing three lines:
   `min_completed_questions=<the number from steps 1 and 2>` and
   `min_completed_questions_failure_message=You have answered ${completed} of the ${min_completed_questions} questions needed. Please go back and answer the questions you skipped, then click I'm Done again.`
   Editing a button's params keeps its `ref_id`, so a loose Blue number can be tightened later
   without orphaning assignments.
4. Press each button once on production as the authoring check, from a test student with too few
   answers, and confirm the authored message with the counts filled in and no lock: the same refused
   path R9 verified on staging, on the button students will actually press. Nothing is written by a
   refused press, so the test student needs no cleanup.

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

None. The two implementation choices worth naming were made in the plan rather than asked, because
neither changes the outcome: the two parameter checks collapse into one (both faults take the same
path and the log carries the raw value either way), and the stub's three record files are one map
keyed by route so the stub writes them from one place and `run.js` clears them from one loop.

## Self-Review

Each finding below was checked against the code before it was written, and the plan's code was run
rather than read (2026-09-14): the proposed `evaluate-completion.ts` change and the proposed test
file were applied verbatim, and the test passed 14/14 under this repo's jest 24 / ts-jest / strict
`tsconfig`, with `npm run lint` and `tsc --noEmit` clean (the predeploy runs both, and `tsconfig`
includes test files). Ten mutations of the step were run against the test: dropping `< 1`, folding
the raw value into the student message, dropping the `context_id` filter, deleting the default
message, dropping the `answerIsCompleted` filter, deleting the error log, skipping the check when
the parameter is absent, dropping one template substitution, and swapping the two substitutions all
failed at least one case; dropping the `g` flag from a substitution did not (QA finding below). The
harness changes were applied verbatim and run through the emulator and the stub: `fall-blue-refused`,
`fall-blue-curriculum`, `fall-orange-control`, `lock-forbidden` and `send-forbidden` all passed, and
with `evaluate-completion` moved after the lock in the compiled Blue pipeline, `fall-blue-refused`
failed on `lock: REACHED the stub`, which is the assertion R7 exists to add. Candidates that did not
survive the check are not listed. The working tree was restored to `master` afterward.

### Senior Engineer

#### RESOLVED: REPORT-82 has two more tables that state the old first entries, and the plan amends neither
The plan amends R5a, R5b and the R13 table. Two other places in `specs/REPORT-82-fall-2026-pipeline-stages.md`
state the contract R1 and R2 change directly: the log-prefix table under the logging requirement
(`| Curriculum | lock-curriculum | ...` / `| Post-test | resolve-origin-class | ...`, the "First
entry" column, around line 172) and R10's entry-names table (`| Curriculum | lock-curriculum,
send-email |` / `| Post-test | resolve-origin-class, lock-post-test, open-curriculum, send-email |`,
around line 208). After this change both stages' first entry is `evaluate-completion` and both
entry lists gain it, so both tables are false as written. Suggested resolution: one more amendment
note in commit 1, under the R10 entry-names table, in the same `> **Amended by REPORT-133**` form,
giving the new lists and noting that the log-prefix table's "First entry" column is now
`evaluate-completion` on all three stages.
**Resolution**: Resolved 2026-09-14: commit 1 gains the R10 note, covering both tables.

#### RESOLVED: Two harness README counts go stale with the fifth fall scenario
`functions/harness/im-done-local/README.md` line 25 says the enroll and open steps are covered "as
part of a stage by the three fall pipeline scenarios below" (already off by one) and line 158 opens
the fall section with "Four scenarios run a whole fall pipeline, each with its own `resource_link_id`
and `context_id`". `fall-blue-refused` is a fifth whole-pipeline fall scenario with its own context,
so both lines are wrong after commit 3, and the plan's README edits (stage table, read-back bullet,
scenario list) touch neither. The success bucket's "the four whole-pipeline fall stages" at line 125
stays right, since the refused scenario goes in its own bucket. Suggested resolution: add both lines
to commit 3's README edits ("five" in both places, or drop the number).
**Resolution**: Resolved 2026-09-14: both lines added to commit 3's README edits, as "five".

---

### QA Engineer

#### RESOLVED: Two claims in commit 2 are overstated
(a) The closing paragraph says the template case "fails if either substitution regex is broken".
Verified: it fails when a substitution is dropped or the two values are swapped, but not when the
`g` flag is removed, because the fixture uses each variable once. The `g` flag is not load-bearing
for any authored message either (R11's template uses each variable once), so this is a wording
fix, not a test gap: "fails if either substitution is dropped or the two are swapped".
(b) The estimated diff size is ~170 lines; the test file as written is 200 lines and the step diff
is +12/-10, so ~215.
**Resolution**: Resolved 2026-09-14: both corrected in commit 2.

---

### DevOps Engineer

#### RESOLVED: Step 4 says the refused presses "do not surface" in `status.js check`; they do, in the Failures table
Verified on the `ai4vs-status-tool` branch: `check` renders the pipeline report before the cross
check, and that report includes a "Failures" table listing every job with `status: failure` (when,
user, stage, message). What is true is that they are not counted: `problemCount` sums the portal
problems and the cross-check problems only, and the per-stage cross check keeps the latest success
(a success is never replaced by a later failure). So after R9 the operator will see six failure rows
(three per stage: misauthored, refused, and possibly a stale phase 2 one) above "No problems found."
Suggested resolution: reword step 4 so the rows are expected: "The Failures table lists the
misauthored and refused presses; they are not counted as problems, and the cross check reads the
latest success per stage."
**Resolution**: Resolved 2026-09-14: step 4 reworded.

Verified with no finding: `firebase.json`'s functions `predeploy` runs `npm run lint` and `npm run
build`, both clean with the change applied; `functions/src/index.ts` `require`s `../build-info.json`
at load, so `npm run buildinfo` before each selective deploy is what keeps the upload loadable, not
only what the zip check reads (the plan already runs it); `.firebaserc` aliases `default` to
report-service-dev and `production` to report-service-pro, so the `--project` ids in steps 1 and 5
are right; and the cross check's inverted-Blue expectation for a control student with a successful
Orange matches R9's Blue-then-Orange order and end state (Blue unlocked, Orange locked).

---

### Security Engineer

No findings. The new error line carries the authored value and `jobPath`, both already in the log
elsewhere; the student message no longer echoes the authored value (pinned by the "keeps the raw
value out of the student message" case); the three record files hold `user_id`, `clazz_id`,
`class_id`, `subject`, `locked` and `active` from the same masked `logFields` the stub already
prints, never the Authorization header, and both new files are gitignored.

---

### Performance Engineer

No findings. Blue's count fetches every answer document for the launch through the client SDK,
around 250 on the published sequence (224 questions plus the stateful interactives). Staging
measurements put answer documents at a 1.5 KB median and ~313 KB maximum, with large interactive
states offloaded to attachments, so the worst case is tens of megabytes against `taskWorker`'s
default 256 MiB and 60 s. Green already runs the same read at a smaller size on every pre-test press.

---

### Student / Education Researcher

No findings beyond the requirements spec's two rounds. The only new student-facing text in this plan
is `CHECK_FAILED_MESSAGE`, which names the fault ("checking your answers") and the action ("tell
your teacher") without internal wording.
