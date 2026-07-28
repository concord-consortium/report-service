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

- **Does**: report-service's request construction (endpoints, bodies,
  encodings, `Authorization: Bearer <minted>`), the mint/cache dedup, the
  `platform_id` gate, the classifier buckets end to end, and that no token value
  is ever logged.
- **Does not**: validate the real portal contract (a stub cannot mint a real
  signed JWT or enforce real authorization). For that, deploy to staging and run
  a real LTI launch; the deployed functions run as the Compute SA and mint a
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

`happy` plus a failure per bucket: `mint-expired` (reload), `mint-no-shared-teacher`
/ `mint-unauthorized` / `mint-unauthenticated` / `enroll-forbidden` /
`lock-forbidden` / `offering-forbidden` / `offering-notfound` / `send-forbidden`
(tell-your-teacher), and `mint-network` / `enroll-nonsuccess` / `lock-server-error`
/ `offering-no-clazz` / `send-delivery` (generic). See `scenarios.js` for the
full table and the exact response each maps to.

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
