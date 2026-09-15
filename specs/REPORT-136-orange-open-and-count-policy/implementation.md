# Implementation Plan: Orange opens Blue for flex Sharks only, and the completion count ignores CODAP models

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-136
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Five code commits, then the release steps. The two step changes come first because the harness commits depend on them (the seed shape is what makes the gated scenarios pass under the allowlist). The harness is not run in CI, so the intermediate states are fine; the unit tests pass at every commit.

### Program-aware open in `openTargetOffering` (R1 to R6)

**Summary**: Classify the program beside the arm, fail on either being unclassifiable, and return early for a full-time control student with the R2 summary. The unit test moves its write-path tests to a flex control word and adds the new branches.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/open-target-offering.ts`: the classification block, two doc comments, one exported constant
- `functions/src/tasks/ai4vs-flvs/open-target-offering.test.ts`: word constants, the classification describe, the fixture-agreement block
- `functions/src/tasks/ai4vs-flvs/index.ts`: two comments on `PIPELINES`

**Estimated diff size**: ~145 lines

`open-target-offering.ts`, import and constants:

```ts
import { armFromClassWord, classifyFallProgram, FULL_TIME_PROGRAM } from "./fall-programs";
```

```ts
/**
 * The curriculum sequence, opened to flex control students once they finish the post-test.
 * ... (the rest of the TARGET_OFFERING_NAME comment is unchanged)
 */
export const TARGET_OFFERING_NAME = "Blue Sequence for AI in Math (FLVS 26-27)";

/**
 * Rendered into the teacher notification by send-email. Both open with the same phrase so a
 * teacher scanning many emails sees the same "nothing happened" shape; the full-time line says why,
 * because the researcher reads it when deciding whom to open the curriculum for after the exam.
 * Neither names the sequence: a rename should break exactly one string in this file.
 */
export const NOTHING_TO_OPEN_SUMMARY = "No activity to open for this student";
export const FULL_TIME_CONTROL_SUMMARY =
  `${NOTHING_TO_OPEN_SUMMARY} (full-time program; the researcher opens the curriculum after the EOC exam)`;
```

The header comment's list of portal-data failures ("no match, several matches, self-target, a class word carrying neither arm suffix") becomes "... a class word carrying neither arm suffix or neither program prefix". The `openTargetOffering` doc comment's first line becomes "Open the curriculum to a flex control student: unlock it AND make it visible."

The classification block, replacing everything from the `⚠️ The arm check runs before any portal call` comment through the treatment return:

```ts
  // ⚠️ Both classifications run before any portal call. Roughly half the fall cohort is treatment
  // and every full-time control student is a no-op, so a check placed after the class read would
  // have most of the cohort pay a classes/info read to do nothing, while needlessly holding the
  // whole class's per-student metadata on a path with no use for it.
  const arm = armFromClassWord(originClassWord);
  const program = classifyFallProgram(originClassWord);
  if (!arm || !program) {
    // ⚠️ This step's OWN message, like the other portal-data faults. The word is not ours: it is
    // whatever offerings#show returned for the class the student launched from, so a word carrying
    // neither suffix, or neither year-qualified prefix, means the Orange sequence is sitting in a
    // class that is not a study subclass (a registration class, most likely), which is portal-side
    // placement in the same category as "no offering matched the name". The same fault fails the
    // same way on both arms, so a misplaced Gator class is as loud as a misplaced Shark one. And the
    // reassurance is true here: the stage locks the post-test before this step runs, so the
    // student's work IS recorded.
    //
    // Safe to log the offending word: authored, environment-stable, not PII, not a token.
    functions.logger.error(
      `open-target-offering: unclassifiable origin class word for ${jobPath}`,
      { origin_class_word: originClassWord },
    );
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }
  if (arm === "treatment") {
    // Treatment students completed the curriculum and were deliberately locked out of it so they
    // cannot go back and change answers. Success with a summary saying nothing was done, since
    // send-email renders this line.
    functions.logger.info(`open-target-offering: treatment student, nothing to open (${jobPath})`);
    return { success: true, summary: NOTHING_TO_OPEN_SUMMARY };
  }
  if (program === FULL_TIME_PROGRAM) {
    // Full-time students of both arms sit the state EOC exam, and the study compares the arms on
    // it, so the curriculum reaches a full-time control student only when the researcher opens it
    // by hand after the exam. Flex students sit no EOC and get it here.
    functions.logger.info(`open-target-offering: full-time control student, nothing to open (${jobPath})`);
    return { success: true, summary: FULL_TIME_CONTROL_SUMMARY };
  }
```

Everything after (the mint, the class read, the name match, the write) is unchanged.

`index.ts`, two `PIPELINES` comments this makes stale. The table's header ("The only program-dependent behaviour in the study is inside fall-random-assignment, which resolves the program from the origin class word itself, so this table stays keyed by stage and never by program") becomes: "The program-dependent behaviour in the study lives inside two steps, fall-random-assignment and open-target-offering, and both resolve the program from the origin class word itself, so this table stays keyed by stage and never by program." The `open-curriculum` processingMessage comment ("roughly half the cohort is treatment and the step returns immediately for every one of them without a portal call") becomes "treatment students and full-time control students, most of the cohort, return immediately without a portal call".

`open-target-offering.test.ts`:

```ts
import {
  openTargetOffering, TARGET_OFFERING_NAME, NOTHING_TO_OPEN_SUMMARY, FULL_TIME_CONTROL_SUMMARY,
} from "./open-target-offering";
import {
  armFromClassWord, classifyFallProgram, DESTINATION_SUFFIX, FLEX_PROGRAM, FULL_TIME_PROGRAM,
} from "./fall-programs";

/** The one word the open path runs for: a flex control subclass. */
const CONTROL_WORD = "fl-2026-section1-shark";
const FULL_TIME_CONTROL_WORD = "ft-2026-bingler-shark";
const TREATMENT_WORD = "ft-2026-bingler-gator";
const FLEX_TREATMENT_WORD = "fl-2026-section1-gator";
```

`classBody` gets `name: "FL-2026-Section1-Shark"` (its `class_word` already uses `CONTROL_WORD`). Every existing write-path, target-selection, portal-failure and privacy test then runs on the flex word without further edits, since `makeContext` defaults to `CONTROL_WORD`.

The `arm classification` describe becomes `arm and program classification`:

```ts
  describe("arm and program classification", () => {
    it.each([
      ["a full-time treatment student", TREATMENT_WORD],
      ["a flex treatment student", FLEX_TREATMENT_WORD],
    ])("does nothing for %s, before any portal call", async (_label, classWord) => {
      const result = await openTargetOffering(makeContext({ classWord }));

      expect(result).toEqual({ success: true, summary: NOTHING_TO_OPEN_SUMMARY });
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });

    it("does nothing for a full-time control student, saying why, before any portal call", async () => {
      const result = await openTargetOffering(makeContext({ classWord: FULL_TIME_CONTROL_WORD }));

      expect(result).toEqual({ success: true, summary: FULL_TIME_CONTROL_SUMMARY });
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
    });

    // The word comes from the portal, not from us, so an unclassifiable one means the Orange
    // sequence is in a class that is not a study subclass. The same fault on either axis and on
    // either arm takes the same exit.
    it.each([
      ["neither arm suffix", "ft-2026-bingler"],
      ["neither program prefix, on a control word", "fl-spring-2026-origin-shark"],
      ["neither program prefix, on a treatment word", "f-2026-bingler-gator"],
    ])("fails permanently on a class word carrying %s", async (_label, classWord) => {
      const result = await openTargetOffering(makeContext({ classWord }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("tell your teacher");
      expect(result.message).toContain("Your work has been saved");
      expect(mockPortalTokenFetch).not.toHaveBeenCalled();
      expect(mockGetScopedPortalToken).not.toHaveBeenCalled();
      expect(mockLoggerError).toHaveBeenCalledWith(
        expect.stringContaining("unclassifiable"),
        expect.objectContaining({ origin_class_word: classWord }),
      );
    });

    it("fails with the shared tell-teacher message when the handoff is absent", ...unchanged);
  });
```

The `harness fixture agreement` block gains one test beside "serves class words that classify as the arms their scenarios assume":

```ts
    it("serves control words that classify as the programs their scenarios assume", () => {
      expect(classifyFallProgram(harnessConfig.STUDY_CONTROL_CLASS.word)).toBe(FULL_TIME_PROGRAM);
      expect(classifyFallProgram(harnessConfig.FALL_FLEX_CONTROL_CLASS.word)).toBe(FLEX_PROGRAM);
    });
```

Mutation check: deleting the `program === FULL_TIME_PROGRAM` branch fails the full-time test (it would open); deleting `|| !program` fails the two prefix cases; swapping the constant fails the equality on the summary.

---

### Count only multiple-choice and open-response answers in `evaluateCompletion` (R10 to R13)

**Summary**: Filter the snapshot on `question_type` before `answerIsCompleted`, and report the ignored count in the log line. Unit cases for every branch of the filter.

**Files affected**:
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.ts`: one exported constant, the counting lines, the log line
- `functions/src/tasks/ai4vs-flvs/evaluate-completion.test.ts`: the snapshot builder and a `question types` describe

**Estimated diff size**: ~90 lines

`evaluate-completion.ts`:

```ts
/**
 * The question types the gate counts. A learner-state interactive writes an answer document on
 * page view alone (a CODAP model saves within seconds of its page loading), so only the types a
 * student answers deliberately count, whatever the interactive is embedded as. Exported so the test
 * pins the set rather than restating it.
 */
export const COUNTED_QUESTION_TYPES: ReadonlySet<string> = new Set(["multiple_choice", "open_response"]);
```

Replacing the `// Count completed answers` block and the log line:

```ts
    const countable = snapshot.docs.filter((doc) => COUNTED_QUESTION_TYPES.has(doc.data().question_type));
    const completed = countable.filter((doc) => answerIsCompleted(doc.data())).length;
    const ignored = snapshot.size - countable.length;

    functions.logger.info(
      `evaluate-completion: ${completed} of ${snapshot.size} answer(s) completed ` +
      `(need ${minCompleted}; ${ignored} ignored by question type) for user ${platform_user_id} at ${jobPath}`
    );
```

`evaluate-completion.test.ts`: the builder takes documents rather than counts, so each case names its shapes.

```ts
const COMPLETED_STATE = JSON.stringify({ interactiveState: JSON.stringify({ key: "DOC_1", type: "CODAP" }) });

const multipleChoice = () => ({ type: "multiple_choice_answer", question_type: "multiple_choice", answer: { choice_ids: ["c1"] } });
const openResponse = () => ({ type: "open_response_answer", question_type: "open_response", answer: "An answer." });
const untouchedChoice = () => ({ type: "multiple_choice_answer", question_type: "multiple_choice", answer: { choice_ids: [] } });
const codap = () => ({ type: "interactive_state", question_type: "iframe_interactive", report_state: COMPLETED_STATE });
const offloadedCodap = () => ({
  type: "interactive_state", question_type: "iframe_interactive", attachments: { __attachment__: "ref" },
});
const imageQuestion = () => ({ type: "image_question_answer", question_type: "image_question", answer: { image_url: "u" } });
const untyped = () => ({ type: "interactive_state", report_state: COMPLETED_STATE });

const snapshotOf = (...docs: Array<Record<string, any>>) => ({
  size: docs.length,
  docs: docs.map((data) => ({ data: () => data })),
});
```

The existing cases become `snapshotOf(multipleChoice(), multipleChoice(), multipleChoice(), multipleChoice())` for four completed and add three `untouchedChoice()` where they had three untouched; "counts only documents that pass answerIsCompleted" keeps its `4 of 7` assertion with the new suffix `(need 5; 0 ignored by question type)`.

New describe:

```ts
  describe("question types", () => {
    it("exports the two counted types", () => {
      expect([...COUNTED_QUESTION_TYPES].sort()).toEqual(["multiple_choice", "open_response"]);
    });

    it("counts multiple-choice and open-response answers that pass answerIsCompleted", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(multipleChoice(), openResponse(), untouchedChoice()));

      const result = await evaluateCompletion(makeContext({ min_completed_questions: "2" }));

      expect(result).toEqual({ success: true, message: "2 of 2 questions completed" });
    });

    // The explicit table type is required, as for MISAUTHORED above: jest 24's it.each typings
    // flatten an inline tuple table, and ts-jest then refuses the whole suite.
    const EXCLUDED: Array<[string, Record<string, any>]> = [
      ["a CODAP model with saved state", codap()],
      ["a CODAP model with an offloaded state", offloadedCodap()],
      ["an image question", imageQuestion()],
      ["a document with no question_type", untyped()],
    ];
    it.each(EXCLUDED)("does not count %s, although answerIsCompleted accepts it", async (_label, doc) => {
      expect(answerIsCompleted(doc)).toBe(true);
      mockGetDocs.mockResolvedValue(snapshotOf(multipleChoice(), doc));

      const result = await evaluateCompletion(makeContext({ min_completed_questions: "2" }));

      expect(result.success).toBe(false);
      expect(result.message).toContain("1 of 2");
    });

    it("logs the counted, total and ignored numbers", async () => {
      mockGetDocs.mockResolvedValue(snapshotOf(multipleChoice(), openResponse(), codap(), codap(), untouchedChoice()));

      await evaluateCompletion(makeContext({ min_completed_questions: "3" }));

      expect(mockLoggerInfo).toHaveBeenCalledWith(
        expect.stringContaining("2 of 5 answer(s) completed (need 3; 2 ignored by question type)")
      );
    });
  });
```

`answerIsCompleted` is imported from `../answer-utils` for the precondition assertion, which is what makes each excluded case a real test: the document would count without the filter.

---

### Seed the harness answers in the activity player's shapes (R14)

**Summary**: The seeded demographic answers become real multiple-choice documents, and every seeded scenario gains one CODAP-shaped document that must not count. `fall-blue-refused` is thereby the exclusion proof.

**Files affected**:
- `functions/harness/im-done-local/seed.js`: the document shapes and the count message
- `functions/harness/im-done-local/scenarios.js`: the `fall-blue-refused` comment and `describe`
- `functions/harness/im-done-local/README.md`: the refused row and the seed bullet

**Estimated diff size**: ~45 lines

`seed.js`:

```js
const buildReportState = (authoredState, interactiveState) =>
  JSON.stringify({
    authoredState: JSON.stringify(authoredState),
    interactiveState: JSON.stringify(interactiveState),
  });

// The launch-context fields every document under a scenario shares.
const launchFields = (context) => ({
  platform_id: context.platform_id,
  resource_link_id: context.resource_link_id,
  context_id: context.context_id,
  platform_user_id: context.platform_user_id,
});
```

In the loop, the multiple-choice document as the activity player writes it (`type` from the interactive's answerType, `question_type` from the authored questionType, the choice ids under `answer`, and the report state the demographics reader parses):

```js
      await answersCol.doc(docId).set({
        ...launchFields(context),
        type: "multiple_choice_answer",
        question_type: "multiple_choice",
        question_id: `im-done-${answer.key}`,
        answer: { choice_ids: answer.selectedChoiceIds },
        report_state: buildReportState(
          { prompt: answer.prompt, choices: answer.choices },
          { selectedChoiceIds: answer.selectedChoiceIds },
        ),
      });
```

After the answers loop, per scenario:

```js
    // A learner-state interactive that is not a question, shaped like a CODAP model: it saves state
    // on page view, so the gate must not count it, and the four answers above are the whole count.
    // The authored state is an empty object rather than the empty string a real CODAP carries, so
    // readDemographics skips it silently instead of warning on every pre-test run.
    await answersCol.doc(`${context.source_key}-${scenarioName}-ans-codap`).set({
      ...launchFields(context),
      type: "interactive_state",
      question_type: "iframe_interactive",
      question_id: "im-done-codap",
      report_state: buildReportState({}, { key: "DOC_im_done", type: "CODAP" }),
    });
    console.log(`seeded ${ANSWERS.length} answers and 1 uncounted interactive for scenario: ${scenarioName}`);
```

`scenarios.js`, `fall-blue-refused`: the comment becomes "The seed is four answers plus one CODAP-shaped interactive that must not count, so a threshold of five must stop the run at the first step: the authored message, no lock, no email. On code that counts every saved state the five would pass; that is what this scenario refuses." and `describe` names both ("four seeded answers and one uncounted interactive against a threshold of five").

README: the `fall-blue-refused` row and the `seed.js` bullet say the same.

---

### The two Orange scenarios and the `opened` assertion (R7)

**Summary**: Rename the full-time scenario, add the flex one with its class fixture, record the offering id on the lock route, and let a success scenario assert what was opened. Move the direct-step open scenarios to the flex word and add the direct-step full-time case.

**Files affected**:
- `functions/harness/im-done-local/config.js`: `FALL_CONTEXTS`, `blueOfferingId` on the two control fixtures, comments
- `functions/harness/im-done-local/stub-portal.js`: the flex control class's offerings, the offering id in the lock record
- `functions/harness/im-done-local/scenarios.js`: the renamed and new scenarios, `EXPECT_KEYS`
- `functions/harness/im-done-local/run.js`: the `opened` assertion
- `functions/harness/im-done-local/README.md`: the assertion list, the fall table, the scenario counts

**Estimated diff size**: ~150 lines

`config.js`:

```js
// The fall full-time control subclass. It carries the "-shark" arm suffix and the "ft-2026-"
// program prefix, which is the one combination the open step refuses to open for: a full-time
// control student waits for the researcher. Its Blue is present and locked all the same, so a
// scenario can observe that the step left it alone.
const STUDY_CONTROL_CLASS = { id: 30002, word: "ft-2026-bingler-shark", name: "FT-2026-Bingler-Shark", blueOfferingId: 845 };
```

```js
// The flex control subclass is both the flex pre-test's destination and the one class the open
// step opens Blue in, so it holds the post-test and the locked curriculum the way the real study
// class does. Its Blue id differs from the full-time class's, so the open assertion can tell them
// apart.
const FALL_FLEX_CONTROL_CLASS = { id: 30012, word: "fl-2026-section1-shark", name: "FL-2026-Section1-Shark", blueOfferingId: 846 };
```

```js
const FALL_CONTEXTS = {
  "fall-green-fulltime": { resource_link_id: "im-done-fall-green-ft", context_id: "im-done-fall-green-ft-ctx" },
  "fall-green-flex": { resource_link_id: "im-done-fall-green-flex", context_id: "im-done-fall-green-flex-ctx" },
  "fall-blue-curriculum": { resource_link_id: "im-done-fall-blue", context_id: "im-done-fall-blue-ctx" },
  "fall-blue-refused": { resource_link_id: "im-done-fall-blue-refused", context_id: "im-done-fall-blue-refused-ctx" },
  "fall-orange-fulltime": { resource_link_id: "im-done-fall-orange-ft", context_id: "im-done-fall-orange-ft-ctx" },
  "fall-orange-flex": { resource_link_id: "im-done-fall-orange-flex", context_id: "im-done-fall-orange-flex-ctx" },
};
```

The `FALL_CONTEXTS` comment's "stub-portal.js gives the study control class an Orange offering whose id IS CONTEXT.resource_link_id" is corrected to say the id is the scenario's own `resource_link_id`, for both control classes.

`stub-portal.js`:

```js
// Two offerings, mirroring the real study classes: the post-test the student launched from and the
// locked curriculum. (The ⚠️ note about the self-target guard is unchanged.)
const controlClassInfo = (clazz, scenarioName) => classInfoFor(clazz, [
  { id: FALL_CONTEXTS[scenarioName].resource_link_id, name: "Orange Sequence for AI in Math (FLVS 26-27)", locked: false },
  { id: clazz.blueOfferingId, name: TARGET_OFFERING_NAME, locked: true },
]);
const studyControlClassInfo = controlClassInfo(STUDY_CONTROL_CLASS, "fall-orange-fulltime");
const flexControlClassInfo = controlClassInfo(FALL_FLEX_CONTROL_CLASS, "fall-orange-flex");
```

`CLASSES_BY_WORD` maps `FALL_FLEX_CONTROL_CLASS.word` to `flexControlClassInfo`. In `logFields`, the lock route gains the offering id from the path, which is what the open step chose:

```js
    case "lock":
      return { locked: body.locked, active: body.active, user_id: body.user_id, offering_id: url.pathname.split("/")[4] };
```

`scenarios.js`: the three open-path direct-step scenarios (`open-target-happy`, `open-target-lookup-forbidden`, `open-target-write-error`) seed `FALL_FLEX_CONTROL_CLASS.word`, with `open-target-happy`'s `describe` naming it and "classifies ... as a flex control student". New beside `open-target-treatment`:

```js
  "open-target-fulltime": {
    // Needs the class fixture only for the sake of the whole-pipeline scenario: this step's program
    // check short-circuits before the mint and the class read. Watch terminal 2 for the absent PUT.
    describe: "A full-time control student's post-test: the step opens nothing and says why, with no portal call at all.",
    ...OPEN_TARGET_STEP,
    behavior: OK,
    seedOriginClassWord: STUDY_CONTROL_CLASS.word,
    expect: { status: "success", summaryIncludes: "full-time program" },
  },
```

The whole-pipeline pair, replacing `fall-orange-control`:

```js
  // The only stage where two offering-state steps coexist, so the only place the entry-name
  // uniqueness rule actually bites. The flex scenario is the only end-to-end exercise of the teacher
  // email rendering a lock line beside an open line; the full-time one proves the open step left the
  // curriculum alone, which `opened: false` observes through the stub's lock record. Neither makes an
  // assignment or an enrolment, which is why neither of the driver's read-backs may be implied by
  // success.
  "fall-orange-fulltime": {
    describe: "The whole fall post-test stage for a FULL-TIME control student: complete, resolve, lock the post-test, open nothing, notify.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-orange-fulltime"],
    request: { pilot: "fall-2026-orange", min_completed_questions: 4, email_subject: "AI4VS: Student completed post-test" },
    originClassWord: STUDY_CONTROL_CLASS.word,
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      noAssignment: true, noEnrollment: true, opened: false,
    },
  },
  "fall-orange-flex": {
    describe: "The whole fall post-test stage for a FLEX control student: complete, resolve, lock the post-test, open the curriculum, notify.",
    behavior: OK,
    seedAnswers: true,
    context: FALL_CONTEXTS["fall-orange-flex"],
    request: { pilot: "fall-2026-orange", min_completed_questions: 4, email_subject: "AI4VS: Student completed post-test" },
    originClassWord: FALL_FLEX_CONTROL_CLASS.word,
    expect: {
      status: "success", messageIncludes: "teacher has been notified",
      noAssignment: true, noEnrollment: true, opened: FALL_FLEX_CONTROL_CLASS.blueOfferingId,
    },
  },
```

`EXPECT_KEYS` gains `"opened"`. `STUDY_CONTROL_CLASS` is already imported; nothing new.

`run.js`, after the enrolment block:

```js
  // The open step's decision, observed through the stub's record of the last update_student_metadata
  // call. The lock precedes the open, so the last record is the open's write when the open ran and
  // the lock's when it did not; `opened` is therefore either `false` (the record is the lock's own
  // locked:true) or the id of the offering the open was expected to unlock. Opt-in: the stages with
  // no open step have nothing to observe.
  let openOk = true;
  if (expect.status === "success" && expect.opened !== undefined) {
    const last = fs.existsSync(RECORD_FILES.lock)
      ? JSON.parse(fs.readFileSync(RECORD_FILES.lock, "utf8"))
      : undefined;
    if (expect.opened === false) {
      openOk = !!last && last.locked === "true";
      console.log(`opened: ${openOk ? "(nothing after the lock, as expected)" : JSON.stringify(last)}`);
    } else {
      openOk = !!last && last.locked === "false" && String(last.offering_id) === String(expect.opened);
      console.log(`opened: offering ${last && last.offering_id} locked=${last && last.locked} (expected offering ${expect.opened} unlocked)`);
    }
  }
```

and `openOk` joins `pass`.

README: the assertion list becomes "up to five things" with a bullet for `expect.opened`; the Scenarios section's success bullet names `fall-orange-fulltime` / `fall-orange-flex` in place of `fall-orange-control` and adds `open-target-fulltime` beside `open-target-treatment` (both succeed by doing nothing), and the direct-step paragraph's "all four `open-target-*` scenarios" becomes five with `-fulltime` in its list; the fall table gets the two Orange rows and "Five scenarios run a whole fall pipeline" becomes "Six"; the intro's "three of the fall pipeline scenarios" (those that run `enroll-specified-class` or `open-target-offering` as part of a stage) becomes four; the "only end-to-end exercise of the teacher email rendering a lock line beside an open line" moves to `fall-orange-flex`; the "A class word of the right shape" bullet under "Extending it" says the step classifies the arm from the suffix and the program from the prefix before any portal call, that only a flex control word reaches the open, and that a full-time control word reports a passing "nothing to open" while the matching logic never runs. 35 scenarios after this commit.

---

### Amend the prose the change invalidates (R8, R15)

**Summary**: Amendment notes on REPORT-82 R6, R7 and R15e and on REPORT-133's authoring note and R7, in the REPORT-133 amendment form, pointing at this spec's closed file.

**Files affected**:
- `specs/REPORT-82-fall-2026-pipeline-stages.md`: after R6's second paragraph, after R7, and after R15e
- `specs/REPORT-133-blue-orange-completion-gate.md`: after R7 and after the Technical Notes authoring bullet

**Estimated diff size**: ~18 lines

After REPORT-82 R6:

```markdown
> **Amended by REPORT-136 (2026-09):** `openTargetOffering` opens Blue for flex control students
> only; a full-time control student gets success, nothing opened and a summary line saying why, and
> the researcher opens Blue for them after the EOC exam. See
> `specs/REPORT-136-orange-open-and-count-policy.md`.
```

After R7: "the control-only conditional ... classifies the arm from the suffix" gains: "**Amended by REPORT-136 (2026-09):** it classifies the program from the prefix as well, and a word unclassifiable on either axis fails on both arms."

After R15e ("A third end-to-end scenario runs the post-test stage for a control student"): "**Amended by REPORT-136 (2026-09):** now a pair, `fall-orange-fulltime` (opens nothing) and `fall-orange-flex` (opens the curriculum); the flex one is the end-to-end exercise of the lock line beside the open line."

After REPORT-133 R7 (which names `fall-orange-control`): "**Amended by REPORT-136 (2026-09):** `fall-orange-control` is `fall-orange-fulltime`, joined by `fall-orange-flex`; both seed answers and pass the gate."

After the REPORT-133 authoring bullet: "**Amended by REPORT-136 (2026-09):** a learner-state interactive writes its answer document on page view, not on touch (a Blue CODAP saved within seconds of load with no click), and the step now counts only `multiple_choice` and `open_response` answers; Blue's threshold moved to the allowlist count minus 2 per activity."

---

### Staging check (R17)

Non-code. Deploy `taskWorker` and `submitTask` to report-service-dev from the merged commit (`npm run buildinfo` first), then per the phase 2 runbook's per-student unlock and job-document deletion:

1. Student 432 (full-time Shark, `ft-2026-hankamp-shark`): press Blue (offering 1215) and read the log line `2 of 3 answer(s) completed (need 2; 1 ignored by question type)`; then press Orange: job succeeds, Blue 1215 stays locked (read the offering's student row before and after), the teacher email carries `- open-curriculum: No activity to open for this student (full-time program; ...)`.
2. A flex Shark (whichever of 434 to 436 landed in a `-shark` section): press Orange: job succeeds, Blue opened, the email carries `Opened Blue Sequence ...`.
3. `status.js check --env staging` (on the `ai4vs-status-tool` worktree) reports no problems beyond its own not-yet-updated inverted-Blue expectation for full-time Sharks, which R9 leaves to that branch.

---

### Release 1.8.2 and the authoring (R16, R18, R19)

Non-code, after merge:

1. `chore: functions 1.8.2` on master (version bump in `functions/package.json`), tag `report-service-v1.8.2`.
2. `npm run buildinfo`, `firebase deploy --only functions:taskWorker,functions:submitTask --project report-service-pro`; verify from the deployed source zip that `build-info.json` names the merged commit and the compiled `open-target-offering.js` carries `FULL_TIME_CONTROL_SUMMARY` and `evaluate-completion.js` the two counted types.
3. Download the three exports and run `count-questions.py` from the oob tools folder: its gate-counted number must still be 59 for Green and 50 for Orange, and Blue's is the number to author (203 on the 2026-09-15 content, re-derived on the day because Jie is editing Blue). Then edit `min_completed_questions` on Blue 845's button `106611-MwInteractive` in place and read it back with `verify-button.py`.
4. Regenerate the flowchart with `build-flowchart.py` (new Orange branch: flex control opens Blue, full-time control opens nothing; the count rule) and publish with the Artifact tool with `url` set to the existing artifact.
5. Decisions log rows O16 and O17: status to shipped, with the release tag and the Blue number authored.

Rollback: redeploy the same two functions from tag `report-service-v1.8.1` and restore 209 on the Blue button.

## As built (2026-09-15)

The five code commits landed as planned, with these departures from the text above, all from the per-commit review rather than from compile or lint faults:

- `evaluate-completion.test.ts` names the two recurring snapshots (`FOUR_OF_SEVEN`, `FOUR_OF_FOUR`) instead of repeating the seven-document literal in four tests, and the `EXCLUDED` table's comment points at `MISAUTHORED` instead of restating the jest 24 typings rationale.
- `open-target-fulltime`'s comment says "Needs no class fixture", matching `open-target-treatment`, rather than the wording planned above.
- `stub-portal.js`'s `record` comment now names the offering id and `locked` flag the lock record carries for the `opened` assertion.
- `index.ts`'s rewritten `PIPELINES` comment uses American spelling ("behavior").

Checks on the head commit: 524 unit tests pass (27 suites, 8 emulator tests skipped), lint and build clean, and the harness passes 35/35 against the emulator and the stub, with `fall-orange-fulltime` reporting "nothing after the lock", `fall-orange-flex` reporting offering 846 unlocked, and every gated run logging `1 ignored by question type`.

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

### RESOLVED: 1. `expect.opened` carries the offering id, not `true`
**Context**: R7 says `opened` is `true` / `false` with `true` asserting the fixture's Blue id. The driver has no way to know which class a scenario launched from without a second lookup table, so the plan has the scenario declare the id itself (`opened: FALL_FLEX_CONTROL_CLASS.blueOfferingId`) and `false` for "nothing after the lock".
**Options considered**:
- A) As planned: `false` or the expected offering id. One declaration, no lookup. R7 reworded. (Recommended)
- B) `true` / `false`, with `run.js` resolving the class by `scenario.originClassWord` through a word-to-fixture map exported from `config.js`.

**Decision**: A (2026-09-15). The scenario is the one place that knows its class; R7 reworded to match.

### RESOLVED: 2. Where the `NOTHING_TO_OPEN_SUMMARY` constant lives
**Context**: The treatment line was an inline literal, pinned by `toContain` in the test and the harness. Making it a constant so the full-time line can extend it puts two exported strings in the file.
**Options considered**:
- A) Both exported from `open-target-offering.ts`, the test asserting equality. (Recommended)
- B) Keep the treatment literal inline and write the full-time line out in full, two strings that must agree on their opening phrase with nothing checking.

**Decision**: A (2026-09-15). One source for the shared phrase.

## Self-Review

### Cross-reference (2026-09-15)
Every requirement maps to a step: R1 to R6 the open step, R10 to R13 the count step, R14 the seed, R7 the Orange scenarios, R8 and R15 the amendments, R16 to R19 the release steps, R9 noted in the staging step. No orphan steps; the largest commit is the harness pair at ~150 lines; no step depends on a later one.

Second pass, same day, against the code with throwaway jest tests (deleted): `answerIsCompleted` accepts every excluded fixture and rejects the untouched choice; `readDemographics` resolves the seeded shapes plus the `{}`-authored CODAP document with no warning on all three pre-test configurations, and warns on a real empty-string one; the stub's path split yields the offering id. One defect: the inline mixed-type `it.each` table failed ts-jest's diagnostics under jest 24, so the plan declares the table's type as the existing `MISAUTHORED` table does. Two stale comments in `index.ts` and one README paragraph were missing from the plan and are now in their commits.

### Senior Engineer

#### RESOLVED: a redundant unit case
"opens the target for a flex control student" restated what the whole `the write` describe already proves once `CONTROL_WORD` is the flex word. Removed.

### QA Engineer

No finding: each excluded-type case asserts `answerIsCompleted` accepts the document first, so the case fails without the filter; `fall-blue-refused` passes on today's code and refuses on the new; `opened: false` requires the lock's own record, so a run that skipped the lock fails on it too.

### DevOps Engineer

No finding: the release matches the REPORT-133 shape plus the bump and tag the ticket's fix version calls for; rollback and the deploy-then-edit order are stated.

### Third pass (2026-09-15), each finding verified against the code before being written

Verified and holding, so not raised: the inline string-tuple `it.each` table in the open-step test compiles under jest 24's typings (only the mixed-type table needed the explicit type); `COUNTED_QUESTION_TYPES.has(doc.data().question_type)` compiles against `DocumentData`; the counting lines give `2 of 5 ... 2 ignored` on the log test's snapshot; `answerIsCompleted` accepts all four excluded fixtures and rejects the untouched choice; the stub's `url.pathname.split("/")[4]` yields `"846"` and `String("846") === String(846)`; the lock's form body parses to `locked: "true"`; `lookupClassByWord` and `enrollSpecifiedClass` read nothing off the flex fixture's offerings list, so giving it two offerings leaves `fall-green-flex` unchanged; `readDemographics`'s `prompt?.toLowerCase().includes(...)` short-circuits on the `{}`-authored CODAP document; 33 scenarios today. A recount of today's published exports under the allowlist rule gives Blue 209 to 203, Orange 50 to 50, Green unchanged (neither Green nor Orange holds an `iframe_interactive`), and Blue's 20 stateful `MwInteractive` non-questions are the CODAPs, so the requirements' numbers hold.

#### Senior Engineer

##### RESOLVED: the amendments miss two passages that quote the contract being changed
R8 amends REPORT-82 R6 and R7 and R15 amends REPORT-133's authoring bullet, but two other passages describe what this story changes: REPORT-82 **R15e** ("A third end-to-end scenario runs the post-test stage for a control student ... the only end-to-end exercise of the teacher email rendering a lock line beside an open line"), which becomes a pair with the open on the flex one only, and REPORT-133 **R7**, which names `fall-orange-control` as a scenario that seeds answers and passes the gate, a name that will no longer exist. A reader following either closed spec to the harness finds nothing. Resolved (2026-09-15, no decision needed): R8 names R15e, R15 names REPORT-133 R7, and the amendments commit carries both lines.

#### QA Engineer

##### RESOLVED: the harness README's Scenarios section is not in the plan's README edit list
`README.md` lines 130 to 134 list the success scenarios by name (`fall-green-fulltime / fall-green-flex / fall-blue-curriculum / fall-orange-control`, plus `open-target-happy` and `open-target-treatment`), and the direct-step paragraph says "all four `open-target-*` scenarios (`-happy`, `-treatment`, `-lookup-forbidden`, `-write-error`)". After the harness commit the success list names a scenario that no longer exists and omits two new ones (`fall-orange-flex`, `open-target-fulltime`), and "all four" is five. The plan's README paragraph covers the assertion list, the fall table, the intro count, the email-rendering sentence and the "Extending it" bullet, but not this section. Resolved (2026-09-15, no decision needed): added to the harness commit's README edits.

#### DevOps Engineer

##### RESOLVED: `count-questions.py` has no `ALLOW` and does not load Green
The release step says to run the recount "with `count-questions.py` (`ALLOW` narrowed to `multiple_choice` and `open_response` ...)" and the Technical Notes say to "narrow its `ALLOW`", but the script has no such constant: it counts `if qt and ls` with no type filter, and it loads `seq-844.json` and `seq-845.json` only, printing the PI rule for Orange (minus 1) and Blue (minus 2) and nothing for Green. The oob tools README repeats the `ALLOW` instruction. Suggested: edit the script in the oob tools folder now (an `ALLOW` set applied at the `if qt and ls` line, Green 838 loaded with its own rule, minus 2 per activity, which is what 63 to 59 reflects), so release day runs it rather than rediscovering the edit, and reword the release step and the Technical Notes to match. Resolved (2026-09-15, option A): the script now applies `ALLOW`, loads Green with its minus-2 rule and prints both rules per sequence (59 / 59, 50 / 50, 209 / 203 today); the tools README, R16, the Technical Notes and the release step say so.

#### Security Engineer, Education Researcher, Teacher

No finding. The full-time summary line discloses the program to a teacher whose class word already carries `ft-2026-`; REPORT-82's disclosure analysis covers the same email lines. A full-time Shark's student-facing outcome is unchanged (`Done! Your teacher has been notified.`) and the EOC comparison is what the change protects. The teacher of a full-time Shark class reads one extra parenthetical saying why nothing opened.
