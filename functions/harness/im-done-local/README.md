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
the stub, for steps no wired pipeline reaches yet (today: the fall
`enroll-specified-class` step); it needs the stub only, no emulator and no
`seed.js`, but it **does** need a prior `npm run build`, since it imports the
compiled step from `lib/` (it exits with a "run `npm run build`" message when
that file is missing).

## What it does and does not prove

`run.js` **asserts** three things per scenario and fails the run if any diverge:

- the final job status (`success` / `failure`),
- the student message bucket (a substring of the classifier's message), and
- on the happy path, the class the student landed in, read back from the
  persisted assignment doc. Note this doc is written by `random-assignment`
  *before* the `add_to_class` call, so it proves the strata-to-class mapping and
  that some enroll succeeded, not that that exact `clazz_id` reached the portal.

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

- **reload**: `mint-expired`.
- **tell-your-teacher**: `mint-no-shared-teacher` / `mint-unauthorized` /
  `mint-unauthenticated` / `mint-signature` / `mint-bad-token-type` /
  `enroll-forbidden` / `lock-forbidden` / `offering-forbidden` /
  `offering-notfound` / `send-forbidden` / `send-no-teacher-email` /
  `enroll-unknown-word` / `enroll-lookup-forbidden`.
- **generic**: `mint-network` / `enroll-nonsuccess` / `lock-server-error` /
  `lock-network` / `offering-no-clazz` / `offering-server-error` /
  `send-delivery` / `send-nonsuccess`.

The direct-step scenarios (`driver: "run-step"`) are `enroll-happy`,
`enroll-unknown-word` (the destination word matches no class, a `400` from
`classes#info` as in rigse), and `enroll-lookup-forbidden`.

See `scenarios.js` for the full table and the exact response each maps to; every
endpoint behavior the stub implements has a scenario that reaches it.

## Extending it for the fall stories (REPORT-80/82)

The fall pipelines add report-service **steps** that call **existing** portal
endpoints, so the stub already serves the class-resolution reads
(`GET /api/v1/classes/info`, keyed on the `class_word` query param and returning
the `get_info` shape with each offering's `url` and `external_url`;
`GET /api/v1/classes/:id`). To cover a new step: add its endpoint behavior to
`stub-portal.js` only if it hits an endpoint not already stubbed, add a scenario
to `scenarios.js` (with `driver: "run-step"` while no pipeline reaches the step),
and point `config.js` at the new pilot/context/class. No portal plumbing changes
are needed for endpoints the stub already has.

## Files

- `config.js` — ports, identifiers, the origin and destination classes the stub
  serves, and the demographic answers (a `Female|White|High|Mod1` student,
  assigned to `FL-spring-2026-SHARK`).
- `scenarios.js` — the named scenarios and their expected outcomes.
- `stub-portal.js` — the stub portal (RIGSE-shaped responses, scenario-driven).
- `seed.js` — seeds the emulator Firestore answers and mints a learner token.
- `run.js` / `run-all.js` — drive one scenario / all scenarios.
- `run-step.js` — drive one compiled step against the stub, twice.
