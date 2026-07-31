# Local "I'm Done" pipeline harness

Runs the `ai4vs-flvs` pipeline end to end on the Firebase emulator against a
**stub portal**, with no real portal, no OIDC identity, and no deployed
functions. It exercises the parts the unit tests cannot: the emulator actually
calling out, `portalOidcFetch` parsing real portal response bodies, thrown-fetch
handling, the per-run token cache, and the student message that surfaces for
each failure.

The stub's response bodies mirror the RIGSE-352 controllers (`oidc_mint`,
`students#add_to_class`, `offerings#show` / `#update_student_metadata`,
`emails#send_class_teachers`), so the classifier is driven by the same wire
shapes it will see in production. A named scenario picks each endpoint's
behavior, so you can watch the pipeline stop at the right step with the right
message.

Two drivers run scenarios. `run.js` submits a whole pipeline through the
emulator's `submitTask`. `run-step.js` calls one compiled step directly against
the stub, selected per scenario; it needs the stub only, no emulator and no
`seed.js`, but it **does** need a prior `npm run build`, since it imports the
compiled step from `lib/` (it exits with a "run `npm run build`" message when
that file is missing). The fall `enroll-specified-class` and
`open-target-offering` steps are covered both ways: in isolation by the
direct-step scenarios, with the failure branches a whole run cannot easily reach,
and as part of a stage by the three fall pipeline scenarios below.

## What it does and does not prove

`run.js` **asserts** up to four things per scenario and fails the run if any
diverge:

- the final job status (`success` / `failure`),
- the student message bucket (a substring of the classifier's message),
- the **arm** stored in the persisted assignment document, which every success
  scenario must declare: either `expect.assignedArm` (`treatment` / `control`) or
  `expect.noAssignment`, which asserts that no arm was stored rather than
  skipping the read-back. It is the arm and not a class word because the arm is
  what the document holds; an earlier version composed a word from the arm and
  the scenario's `originClassWord` and compared it against a word composed the
  same way, which passed while naming a class that need not exist (spring's
  composed `fl-spring-2026-origin-shark` never has: spring appends no suffix and
  enrolls by authored class id).
- the class **id** the pipeline actually enrolled into, also required of every
  success scenario: either `expect.enrolledClassId` or `expect.noEnrollment`,
  which asserts that no `add_to_class` reached the stub. This is the one check
  that observes a decision the pipeline made rather than restating a harness
  value: the stub records each `add_to_class` body to `.last-enroll.json` and
  `run.js` reads it back, having deleted it before submitting so a stale record
  cannot satisfy the run. It matters because every subclass word has a
  `classes/info` fixture on purpose, so a pipeline that appended the wrong suffix
  would resolve a real class, enroll successfully, and otherwise pass.

Both declarations are mandatory rather than opt-in, because an omitted one is
silent: the scenario reports PASS while checking nothing beyond its completion
text.

`run-step.js` runs its step **twice** against one `StepContext` and asserts, on
both runs, the step's success and a substring of its `summary` (on success) or
its student `message` (on failure). For the enroll step the summary names the
class the destination word resolved to, and the stub serves a destination class
whose name and id differ from the origin's, so a wrong-class resolution fails
the run rather than passing on the stub's unconditional `{ success: true }`.
Running twice with one token cache also covers re-invocation: the second run
re-resolves the same word and re-uses both cached tokens (watch terminal 2 for
the absent second mint). What it cannot prove is the portal's server-side
enrollment no-op, which is byte-identical on the wire to a first enrollment.

Everything else the harness exercises is **shown in the logs for manual
inspection**, not asserted, and is covered at the unit level instead: the
request construction (endpoints, bodies, encodings) and the masked
`Authorization: Bearer <len=N>` per call in terminal 2; the mint/cache dedup
(the stub's `mintCounter` decorates each minted token, so two distinct scopes
mean two mints) also in terminal 2; the `platform_id` gate's reject path (no
scenario points at an untrusted host — that path is covered by
`ai4vs-flvs/index.test.ts`); and the never-log-a-token guarantee (about
report-service's own logging, covered by `portal-api.test.ts`; the stub masks
its own logs but captures nothing from terminal 1). When a scenario expects a
`failsAt` step, that too is printed, not asserted.

What none of it proves: the real portal contract (a stub cannot mint a real
signed JWT or enforce real authorization). For that, deploy to staging and run a
real LTI launch; the deployed functions run as the Compute SA and mint a
matching-`sub` OIDC token natively.

## Setup

1. Add the harness env to `functions/.env.local` (gitignored; loaded by the
   emulator). Copy from `env.local.example`:

   ```
   TRUSTED_PORTAL_HOSTS=learn.portal.staging.concord.org,localhost,127.0.0.1
   PORTAL_OIDC_TOKEN=stub-oidc-token
   ```

2. Build once so the emulator serves the current code: `npm run build`.

## Run (three terminals, from `functions/`)

```
# 1) the emulator (functions + firestore + auth)
npm run emulator

# 2) the stub portal
node harness/im-done-local/stub-portal.js

# 3) seed the answers + mint a learner token, then drive a scenario
node harness/im-done-local/seed.js
node harness/im-done-local/run.js               # happy path
node harness/im-done-local/run.js mint-expired  # a failure scenario
node harness/im-done-local/run-step.js enroll-happy  # one step, stub only
node harness/im-done-local/run-all.js           # every scenario, with a summary
```

`run.js` submits the job, polls the job document, prints the outcome, and checks
it against the scenario's expectation. Watch terminal 2 to see each portal call
(secrets masked) and terminal 1 for the pipeline logs. `run-step.js` prints each
run's `StepResult` and the step's own logs in terminal 3, since it runs the step
in-process rather than in the emulator. `run-all.js` sends each scenario to the
driver its entry names, so it needs the emulator, the seed, **and** a build.

## Scenarios

`happy` plus a failure per bucket:

- **success**: `happy`, the four whole-pipeline fall stages
  `fall-green-fulltime` / `fall-green-flex` / `fall-blue-curriculum` /
  `fall-orange-control` (below), plus the direct-step `enroll-happy`,
  `open-target-happy` and `open-target-treatment` (the last of these succeeds by
  doing nothing, which is the treatment arm's correct behavior).
- **reload**: `mint-expired`.
- **tell-your-teacher**: `mint-no-shared-teacher` / `mint-unauthorized` /
  `mint-unauthenticated` / `mint-signature` / `mint-bad-token-type` /
  `enroll-forbidden` / `lock-forbidden` / `offering-forbidden` /
  `offering-notfound` / `send-forbidden` / `send-no-teacher-email` /
  `enroll-unknown-word` / `enroll-lookup-forbidden` /
  `open-target-lookup-forbidden`.
- **generic**: `mint-network` / `enroll-nonsuccess` / `lock-server-error` /
  `lock-network` / `offering-no-clazz` / `offering-server-error` /
  `send-delivery` / `send-nonsuccess` / `open-target-write-error`.

`open-target-write-error` is worth a note: it expects the open step's **own**
message ("Your work has been saved…") rather than the shared tell-your-teacher
one. The step keeps its own message for portal-data failures as well as portal
errors, because it never promises a retry, so the two differ only in the
reassurance clause, and the preceding lock has already recorded the work.

The direct-step scenarios (`driver: "run-step"`) are `enroll-happy`,
`enroll-unknown-word` (the destination word matches no class, a `400` from
`classes#info` as in rigse), `enroll-lookup-forbidden`, and all four
`open-target-*` scenarios (`-happy`, `-treatment`, `-lookup-forbidden`,
`-write-error`).

See `scenarios.js` for the full table and the exact response each maps to; every
endpoint behavior the stub implements has a scenario that reaches it.

## The fall stages

Four scenarios run a whole fall pipeline, each with its own `resource_link_id`
and `context_id` so they do not share a launch context with `happy` or with each
other. `scenarios.js` checks that at require time, so a mistyped `FALL_CONTEXTS`
key throws with the scenario's name instead of silently falling back to the
shared context and colliding with `happy`:

| Scenario | Stage | What it proves |
|---|---|---|
| `fall-green-fulltime` | pre-test (`fall-2026-green`) | complete → resolve → randomize → enroll → lock → notify, landing in `ft-2026-bingler-gator` |
| `fall-green-flex` | pre-test (`fall-2026-green`) | the **same** seeded answers landing in the **opposite** arm, `fl-2026-section1-shark` |
| `fall-blue-curriculum` | curriculum (`fall-2026-blue`) | lock the curriculum → notify, with no assignment and no enrollment, and `send-email` taking its **fallback** offering read |
| `fall-orange-control` | post-test (`fall-2026-orange`) | resolve → lock the post-test → open the curriculum → notify, with no assignment at all |

The pre-test pair is the point of the pair: identical demographics can only reach
opposite arms if the program resolved from the origin class word actually
selected a different strata table. `fall-orange-control` is the only stage where
two offering-state steps coexist, so it is the only end-to-end exercise of the
teacher email rendering a lock line beside an open line.
`fall-blue-curriculum` is the only stage where no step publishes an
`originClazzId`, so it is the only end-to-end run of `send-email`'s retained
offering read on a fall pipeline; it launches from a `-gator` class deliberately,
since the curriculum lock applies to both arms and nothing in that stage reads
the arm.

### An assigned arm is sticky, and re-running does not reset it

This is correct behavior (a student who holds an arm keeps it, which is what
makes the pipeline safe to re-run), but from outside it means editing `ANSWERS`
and re-running yields the **old** arm with nothing on screen explaining why. To
start over, delete the assignment document under
`sources/<source_key>/jobs-task-data/<docId>`. There are **two formulas**, and
which one applies depends on the scenario's `assignmentScope`:

- **`fall-green-fulltime`** uses the per-class document, hashed over its own
  `resource_link_id` and `context_id`, so deleting it resets that scenario only.
- **`fall-green-flex`** uses the pooled document, keyed on the *program*
  (`fall-2026-flex`), so deleting it resets **every** flex scenario at once,
  including any added later. The flex document is per program, not per scenario.

Deliberately not automated: a driver that cleared the assignment on every run
would destroy the one property the idempotency requirement exists to
demonstrate.

## Extending it for the fall stories (REPORT-80/82)

The fall pipelines add report-service **steps** that call **existing** portal
endpoints, so the stub already serves the class-resolution reads
(`GET /api/v1/classes/info`, keyed on the `class_word` query param and returning
the `get_info` shape with each offering's `url` and `external_url`;
`GET /api/v1/classes/:id`). To cover a new step: add its endpoint behavior to
`stub-portal.js` only if it hits an endpoint not already stubbed, add a scenario
to `scenarios.js` (with `driver: "run-step"` while no pipeline reaches the step,
or as a whole-pipeline scenario once one does), and point `config.js` at the new
pilot/context/class. No **stub** changes are needed for endpoints the stub
already has.

A whole-pipeline scenario for a new stage declares more than a spring one does:
its own `context` (a launch context of its own, so its answers and its assignment
document do not collide with another scenario's), a `request` carrying the
stage's `pilot` and any authored parameters, `seedAnswers` if the stage reads
answers at all, `originClassWord` for the identity the stub should serve through
`offerings#show`, and `assignmentScope: "pooled"` if the stage randomizes into
the pooled document rather than the per-class one. A success scenario must also
declare both read-backs: `expect.assignedArm` or `expect.noAssignment`, and
`expect.enrolledClassId` or `expect.noEnrollment`. `run.js` fails a success
scenario that omits either, since omitting one otherwise reports PASS while
checking nothing.

The **driver** is a separate question, and it may need work even when the stub
does not. `run-step.js` is not single-step: a `run-step` scenario names
`stepModule`, `stepExport` and `stepName`, defaulting to the enroll step. Two
further things a new step may need, neither of which the stub can provide:

- **A seeded handoff.** A step that reads its input from `stepResults` rather
  than from a request param (as `enroll-specified-class` does) fails its
  absent-handoff check before reaching anything the scenario tests. Set
  `seedOriginClassWord` on the scenario.
- **A class word of the right shape.** `open-target-offering` classifies the
  study arm from the word's `-gator` / `-shark` suffix before any portal call, so
  a scenario seeded with `fl-spring-2026-origin` or `ft-fall-2026-a` fails on
  that check and reports a passing tell-your-teacher while the logic it exists
  to prove never runs.

The driver also writes each run's result into `context.stepResults` under the
scenario's step name, the way `index.ts` does, so the second run is a real
re-entry with accumulated state rather than a repeat of the first run's inputs.
That includes the runner's guard: a result is recorded only if the step
succeeded, since `index.ts` returns early on failure and would never leave a
failed step's key behind for a later step to read.

## Files

- `config.js` — ports, identifiers, the classes the stub serves (the spring
  origin and destination, the fall `STUDY_CONTROL_CLASS`, the fall subclasses the
  pre-test stage enrolls into, and the two registration classes a fall pre-test
  launches from, which are served through `offerings#show` only), the fall
  scenarios' launch contexts, `TARGET_OFFERING_NAME` and `FLEX_PROGRAM` (which
  unit tests pin to their source constants, along with the subclass fixture words
  against the pipeline's arm suffixes), and the demographic answers (a
  `Female|White|High|Mod1` student, assigned to `FL-spring-2026-SHARK` under
  spring's table).
- `scenarios.js` — the named scenarios and their expected outcomes, validated at
  require time so a malformed or duplicated launch context throws by name.
- `stub-portal.js` — the stub portal (RIGSE-shaped responses, scenario-driven).
- `seed.js` — clears the answers collection, re-seeds it for every scenario
  declaring `seedAnswers` (under that scenario's own launch context), and mints
  a learner token. One run holds every scenario's answers at once.
- `run.js` / `run-all.js` — drive one scenario / all scenarios.
- `run-step.js` — drive one compiled step against the stub, twice.
