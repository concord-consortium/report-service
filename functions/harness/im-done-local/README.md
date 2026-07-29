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

## What it does and does not prove

`run.js` **asserts** three things per scenario and fails the run if any diverge:

- the final job status (`success` / `failure`),
- the student message bucket (a substring of the classifier's message), and
- on the happy path, the class the student landed in, read back from the
  persisted assignment doc. Note this doc is written by `random-assignment`
  *before* the `add_to_class` call, so it proves the strata-to-class mapping and
  that some enroll succeeded, not that that exact `clazz_id` reached the portal.

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
node harness/im-done-local/run-all.js           # every scenario, with a summary
```

`run.js` submits the job, polls the job document, prints the outcome, and checks
it against the scenario's expectation. Watch terminal 2 to see each portal call
(secrets masked) and terminal 1 for the pipeline logs.

## Scenarios

`happy` plus a failure per bucket:

- **reload**: `mint-expired`.
- **tell-your-teacher**: `mint-no-shared-teacher` / `mint-unauthorized` /
  `mint-unauthenticated` / `mint-signature` / `mint-bad-token-type` /
  `enroll-forbidden` / `lock-forbidden` / `offering-forbidden` /
  `offering-notfound` / `send-forbidden` / `send-no-teacher-email`.
- **generic**: `mint-network` / `enroll-nonsuccess` / `lock-server-error` /
  `lock-network` / `offering-no-clazz` / `offering-server-error` /
  `send-delivery` / `send-nonsuccess`.

See `scenarios.js` for the full table and the exact response each maps to; every
endpoint behavior the stub implements has a scenario that reaches it.

## Extending it for the fall stories (REPORT-79/80/82)

The fall pipelines add report-service **steps** that call **existing** portal
endpoints, so the stub already serves the class-resolution reads
(`GET /api/v1/classes/info`, `GET /api/v1/classes/:id`, both returning the
`get_info` shape). To cover a new step: add its endpoint behavior to
`stub-portal.js` only if it hits an endpoint not already stubbed, add a scenario
to `scenarios.js`, and point `config.js` at the new pilot/context. No portal
plumbing changes are needed for endpoints the stub already has.

## Files

- `config.js` — ports, identifiers, the demographic answers (a
  `Female|White|High|Mod1` student, assigned to `FL-spring-2026-SHARK`).
- `scenarios.js` — the named scenarios and their expected outcomes.
- `stub-portal.js` — the stub portal (RIGSE-shaped responses, scenario-driven).
- `seed.js` — seeds the emulator Firestore answers and mints a learner token.
- `run.js` / `run-all.js` — drive one scenario / all scenarios.
