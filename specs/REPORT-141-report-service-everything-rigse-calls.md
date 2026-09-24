# report-service: everything rigse calls

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-141

**Status**: **Closed**

## Overview

report-server and the report-service function learn to verify rigse's RS256 portal tokens, report-server gains the endpoint that exchanges rigse's signed assertion for a researcher's own short-lived API token, and the function gains `POST /run-package`, which queues a researcher's packages and launches or wakes their MicroVM without waiting for it. Together they are the whole surface rigse calls for the Researcher Dashboard, authenticated by short-lived signed assertions instead of the function app's shared bearer.

When a researcher asks the Researcher Dashboard to run analyses, the portal hands the work to report-service, which records the request, starts or wakes that researcher's private analysis machine, and answers straight away rather than making the researcher wait for the machine. The machine pulls data as the researcher themselves, using a credential report-server issues for that one machine and that expires on its own.

This story replaces a single all-powerful shared password between the portal and report-service with short-lived, single-purpose signed credentials that only the portal can create, and it makes sure a credential from the staging portal can never be used against production. It is the second step of the dashboard's first release, directly after the portal's signing key (RIGSE-367), and the catalog (REPORT-142) and the dashboard API (RIGSE-368) are built on it.

## Requirements

### Verifying rigse's key (both deployables)

- R1. report-server and the function each hold rigse's public keys as configured values, one entry per key giving its `kid`, the PEM public key, and the issuer (portal site URL) it may sign for. Staging and production portals are configured with different keys. No JWKS or other fetched key.
- R2. A token is verified only against the key its `kid` names, and only if the token's `iss` is the issuer that key is configured for. A token whose `kid` is absent or unknown is refused, never checked against a default; a token whose `iss` is not its key's issuer is refused.
- R3. The algorithm is pinned to RS256 and never taken from the token. An HS256 token signed with a configured public key as the HMAC secret is refused, as are `alg: none` and any token not signed by the named key.
- R4. The expected audience is fixed by the endpoint; a missing `aud`, a different one, or an `aud` that is not a single string is refused. `exp` is required and enforced. Both are checked explicitly rather than left to the JWT library, since neither library chosen here refuses a missing `exp` or an `aud` array by itself (see Verification).
- R5. report-server can verify an `aud: researcher-dashboard` token as a bearer and expose its verified claims to the endpoint that accepts it, so REPORT-142's catalog read can use it. No report-server route accepts it in this story.

### The mint path (report-server)

- R6. `POST /api/v1/dashboard-tokens` accepts only an `aud: report-server` assertion in the `Authorization: Bearer` header, verified per R1 to R4, and reads the user entirely from the verified claims; nothing in the request body is read.
- R7. The portal is taken from the verified `iss`, mapped with `get_server_for_portal_url/1`, and must be one report-server has a database connection for; the `portal_server` claim must agree with it. A token for an unknown portal is refused.
- R8. Each assertion's `jti` is accepted once: a second presentation of the same `jti` before it expires is refused, including after a report-server restart and across more than one task. An assertion with no `jti` is refused. Used `jti`s are recorded in report-server's database with the assertion's expiry and pruned once expired.
- R9. On success the endpoint finds or creates the user from the claims (updating the stored role flags and identity, as a portal login does), revokes that user's live dashboard-labeled tokens, mints a new dashboard-labeled token, and returns the raw token once.
- R10. `api_tokens` gains a nullable `expires_at`. Dashboard-labeled tokens get `expires_at` nine hours after minting; every other token keeps `NULL`. `verify_api_token/1` refuses a token whose `expires_at` has passed and keeps accepting tokens whose `expires_at` is `NULL`, so cc-data's CLI tokens are unaffected. The token listings and lookups that treat a token as live (`list_active_api_tokens`, `list_all_active_api_tokens`, `get_user_api_token`, `get_active_api_token`) apply the same expiry, so an expired dashboard token is not shown or managed as active.

### Queueing work (the function)

- R11. `POST /run-package` is served by a new HTTPS function for the dashboard's function surface, separate from `api`. It accepts only an `aud: report-service-functions` assertion as its bearer, verified per R1 to R4, and is not reachable with the shared `AUTH_BEARER_TOKEN`. The launcher's AWS credentials are secrets of this function alone. `api` and its shared bearer are unchanged.
- R12. The researcher is the assertion's `uid` and the portal is its `iss`: `platform_user_id` is `uid`, `platform_id` is `iss`, and the `{portal}` path segment is `iss`'s host with dots replaced by underscores. Nothing in the body can name a different researcher or portal.
- R13. The body is `final-design.md` section 10's `/run-package` shape: `packages` (each with `identity`, `version`, `checksum` and numeric `catalog_id`, resolved by rigse; the checksum is the catalog's `sha256:<lowercase hex>`, which the runner compares against), `scope` (`kind`, `collection`, `id`, `classes: [{class_hash, class_id}]`, `assignments: [{offering_id, runnable_id, name, url}]`), `class_tokens` (FirebaseApp name to token), `session_token`, `firebase_project` and `report_server_assertion`. The function re-resolves nothing. `report_server_assertion` must verify as an `aud: report-server` token (R1 to R4) naming the same `uid` and `iss` as the request's own assertion, or the request is refused before anything is written; the function only verifies it and relays it, and holds no signing key. An assignment's `url` is the portal's stored URL and can be an empty string, and its `name` can be null (RIGSE-368 R8), so both are accepted as they come.
- R14. The whole batch is validated before anything is written, so every refusal leaves Firestore unchanged: a malformed body is a 4xx; a queue that would exceed its cap (a configured number of outstanding packages per researcher, default 20) is a 409 naming the reason. A failure after the work is accepted and recorded (report-server's mint or the MicroVM API failing on the launch or resume) is answered with its reason and keeps the queued work, which the next request or the VM itself picks up (Doug, 2026-09-23).
- R15. The queue is keyed by class and package, because a researcher can queue work from more than one class dashboard before the VM takes it (Doug, 2026-09-23). On acceptance, in one atomic write: packages not already queued **for that class** are appended to `researcher_dashboard/{portal}/work/{platform_user_id}`, each entry carrying its `class_hash`, checksum and catalog id, and the request's scope block and class tokens are stored under that class (`scopes.{class_hash}`), so a second class's request never overwrites the first's; a result document is written `queued` with `queued_at` for each appended package at `classes/{class_hash}/researchers/{platform_user_id}/results/{package_key}`, where `package_key` is the identity with `/` replaced by `__`; and the outstanding entries are mirrored onto `runners/{platform_user_id}`'s `queue` as `{class_hash, package_key}` pairs. This changes the shape `final-design.md` 6.1 and 10 give `work/` and `queue`, which REPORT-143's `/work`, RD-4's runner and RD-3's page consume.
- R16. After queueing, the function ensures one VM, by the recorded VM's state from `GetMicrovm`: none recorded, not found, `TERMINATING` or `TERMINATED` launches with `RunMicrovm`; `SUSPENDED` resumes with `ResumeMicrovm`; `PENDING` or `RUNNING` does nothing, since the VM asks for work at the end of `/run` and when it next asks to idle; `SUSPENDING` does nothing here: REPORT-143's per-minute watchdog resumes any `SUSPENDED` VM whose `work/` document has packages outstanding, so work queued during a suspend waits at most about a minute rather than until the researcher's next request (Doug, 2026-09-23). Two concurrent requests for the same researcher launch at most one VM.
- R17. Only on the launch branch, the function exchanges `report_server_assertion` at report-server's mint endpoint (R6) for the researcher's token. It never mints on the resume or reuse branch, since minting revokes the token the live VM holds.
- R18. At launch, `runHookPayload` is `final-design.md` section 10's shape exactly: `session_token`, `platform_user_id`, `platform_id`, `portal`, `firebase_project`, `bucket`, `report_server_token`, `report_server_url`, `function_url`. No AWS credential and no `secret_name`. `idlePolicy` is omitted.
- R19. At launch, the function records the VM at `vms/{platform_user_id}` and writes `runners/{platform_user_id}` as `state: starting` with `platform_id`, `queue` and `microvm_id`, with the Admin SDK.
- R20. The function answers 202 with the queue state once the work is recorded and the launch or resume has been requested. It never dispatches into the VM, mints a MicroVM auth token, waits for a VM to reach a state, or holds the request open. An upstream failure (report-server's mint refusing, the MicroVM API failing) is answered with its reason rather than a bare status.

### Configuration

- R21. Every new setting is documented and configured for both environments before the code that reads it deploys: the portal key entries for report-server (`config/runtime.exs`) and for the function; the function's launcher credentials as function secrets; and the runner image, execution role, bucket, report-server URL, the function's own URL (`function_url`) and the queue cap as function params in `functions/.env.report-service-{dev,pro}`. A Firebase deploy of a function that declares a secret not yet set in the project fails, so the secrets are set first. *(partial: the settings, their defaults, the README deploy order and the staging runner values are in place; no portal signing key exists yet, so `PORTAL_PUBLIC_KEYS` is empty in both projects, production has no runner stack, and report-server's variable belongs in cloud-formation. See Not Yet Implemented)*

## Technical Notes

- **Files on master this story touches**: `functions/src/index.ts`, `functions/package.json`, new `functions/src/researcher-dashboard/*`, `functions/.env.report-service-{dev,pro}`; `server/mix.exs`, `server/config/runtime.exs`, `server/lib/report_server/accounts.ex`, `server/lib/report_server/accounts/api_token.ex`, a migration under `server/priv/repo/migrations/`, `server/lib/report_server_web/router.ex`, new modules under `server/lib/report_server_web/api/`, and tests beside each.
- **The spike as reference** (`~/projects/spike/report-service`, branch `RIGSE-365-researcher-dashboard-rules`): `functions/src/researcher-dashboard/run-package.ts` and `microvm.ts` hold the dependency-injected shape (`RunPackageDeps`, a `MicrovmApi` interface faked in tests because the repo's jest cannot resolve `firebase-functions`), the mint call, and `vmUrl`; its dispatch, `waitUntilRunning`, `CreateMicrovmAuthToken` and `idlePolicy` are exactly what this story must not carry. `server/lib/report_server_web/api/{portal_assertion,service_auth_plug}.ex`, `api/v1/dashboard_token_controller.ex` and `Accounts.mint_dashboard_token/1` hold the mint flow, HS256 there.
- **JWT libraries.** report-server adds `joken` (which brings `jose`, the Erlang library, and uses the existing `jason`); the function adds `jsonwebtoken` 9 and `@types/jsonwebtoken`. See Verification for why not `jose` in the function.
- **SDK.** `@aws-sdk/client-lambda-microvms` 3.1138.0 exports `RunMicrovm`, `ResumeMicrovm`, `SuspendMicrovm`, `GetMicrovm`, `TerminateMicrovm`; `idlePolicy` is optional on `RunMicrovm`. `HTTP_INGRESS` cannot be disabled (verified 2026-09-23); what closes the port is `lambda:CreateMicrovmAuthToken` leaving the launcher's policy (RD-1), which is why the function must never need it.
- **The function's AWS credential** is the runner stack's launcher user (spike: `RD_AWS_KEY` / `RD_AWS_SECRET_KEY` as function secrets). Firebase secrets are declared per function, so any route on the same function receives them in its environment.
- **report-server's portal mapping.** `get_server_for_portal_url` rewrites two report hosts to their portals and otherwise returns the host; `has_db_connection?/1` reads `<HOST>_DB` from the environment.
- **Where rigse's side is specified**: RIGSE-367 (token shapes, claims, key contract) and RIGSE-368 (the caller of `/run-package`, which also sends the scope and resolves packages).

- **What `RUNNING does nothing` relies on.** A running VM that has drained its queue calls `/idle` after its idle period, and `/idle` checks for queued work before suspending (REPORT-143, `final-design.md` 7.2(b)); a VM mid-queue calls `/work` again as it drains (RD-4). So work appended to a running VM's queue is taken without the function calling into the VM.

### Verification

Stage 4 ran throwaway probes, never committed, against both runtimes with two freshly generated keypairs standing in for a staging and a production portal. The verifier under test chose the key by `kid`, required the key's configured issuer, pinned RS256, and checked `aud` and `exp` itself.

| Case | report-server: Joken 2.7.0 / JOSE 1.11.12, OTP 26 | function: `jose` 6 on Node 22 | function: `jsonwebtoken` 9 under the repo's Jest |
|---|---|---|---|
| staging token, staging key | accepted | accepted | accepted |
| **staging key, claiming the production `iss`** | refused only by the issuer binding (`:wrong_iss`) | refused by the issuer option | (issuer option) |
| production key under the staging `kid` | refused (signature) | refused (signature) | |
| unknown `kid` | refused | refused | |
| HS256 signed with the public PEM | refused (signature) | refused (alg not allowed) | refused, even with HS256 in the allowed list |
| `alg: none` | refused | refused | refused |
| wrong `aud` | refused | refused | |
| `aud` array containing the expected value | refused only by the explicit string check | **accepted by the library**, refused by the explicit check | **accepted by the library** |
| expired | refused only by the explicit `exp` check: **`Joken.verify/2` does not check `exp`** | refused | |
| no `exp` | refused only by the explicit check | refused (`requiredClaims`) | **accepted by the library** |

**The function's JWT library is `jsonwebtoken` 9, because `jose` cannot run under this repo's tests.** `functions/` compiles to CommonJS with TypeScript 4.9 and tests with Jest 24 (`package.json`, default jsdom environment). Installed with `--no-save` and exercised by a scratch test: `jose` 6 fails to load (`Cannot use import statement outside a module`, it is ESM-only), `jose` 5 fails to resolve (Jest 24 predates package `exports`), and `jose` 4 fails with `TextEncoder is not defined` under jsdom and, under `@jest-environment node`, with `payload must be an instance of Uint8Array` across Jest's module realms. `jsonwebtoken` 9 with `@types/jsonwebtoken` loads, signs and verifies, and its refusals are in the table. The package runs on Node 22 at deploy time either way; the constraint is only that the verifier must be testable where it lives.

The first row pair is the one R2 exists for: with the key chosen by `kid` alone, a token signed by the staging key and claiming production's `iss` verifies, and only the issuer binding refuses it.

### As built (2026-09-24)

The seven planned steps landed one commit each (`50c303a` to `ee6a7a4`), each reviewed until a pass found nothing to act on, followed by an as-built docs commit (`2383050`) and a fix to the shared Firestore fake so it passes `Timestamp`s through (`e5fa456`). Every requirement has code and tests behind it. The departures from the implementation plan's text:

**report-server**
- The test keys are installed from `test/test_helper.exs` (`PortalTokenFixture.install!/0`), not `config/test.exs`: `runtime.exs` runs after `test.exs` and would overwrite it, and `test/support` is not compiled when `test.exs` is evaluated.
- `PortalKeys` logs and ignores an entry it cannot trust: a missing field, an unreadable PEM, or a `kid` listed twice, where it trusts neither entry because which issuer the `kid` is bound to would be a guess. Unset or malformed, it trusts no key and every assertion is refused.
- The live-token predicate is `live_api_tokens/0`, a base query, rather than `live/1`. `revoke_dashboard_tokens/1` uses it too, so an already-expired dashboard token is left unrevoked, which is harmless.
- The mint endpoint stores a role flag as true only when its claim is literally `true` (not `!!`). It requires `login`, `first_name`, `last_name` and `email` as non-empty strings and `portal_user_id` as a positive integer, answering 400 naming the claim, because `create_user` would store a missing field as NULL and `update_user`'s changeset would fail on it. A `jti` over 255 characters is refused as not authenticated, and `used_portal_assertions` also has an index on `expires_at` for the prune.

**The function**
- `parsePortalKeys` throws on a malformed `PORTAL_PUBLIC_KEYS` (including an empty field or a repeated `kid`), which the auth middleware answers as 500 naming the setting. It is the only configuration of a function whose every route needs it, so failing loudly is right there, where report-server has other routes that must keep working. `verifyPortalToken` re-checks `iss` itself, since jsonwebtoken skips its issuer check for a falsy issuer.
- `/run-package` validates more than the plan listed: `scope.collection` must be `"classes"`, `scope.id` must be the class's `class_hash`, `class_hash` must be 48 lowercase hex (rigse's `SecureRandom.hex(24)`, and what REPORT-142's `/derive-profile` validates), every class token must be a non-empty string, and a package named twice in one batch is a 400.
- The work document is written with `mergeFields` rather than `{merge: true}`, so a later request for a class replaces that class's `scopes.{class_hash}` whole and a stale class token cannot survive, while other classes' entries are kept.
- The 202 body is `{success: true, queue, appended, vm}`, with `queue` as the `{class_hash, package_key}` pairs R15 puts on the runner document, and `vm` one of `launched`, `launching` (another request holds the launch claim, where the plan said `running`), `resumed`, `running` or `suspending`.
- `launching_until` is epoch milliseconds, cleared with `null`, and the launch records are written in a transaction rather than a batch, since the `Db` slice the module uses has no batch. The claim is cleared only when no VM can exist: a failure before `RunMicrovm`, a definite 4xx from it, or the oversized payload. A timeout or 5xx from `RunMicrovm`, or a failure to record a launched VM, leaves it to lapse.
- Each upstream call is made once with a 10-second timeout (the mint including its body, and the SDK client with `maxAttempts: 1` and `throwOnRequestTimeout`), so the four calls a launch makes fit inside the function's 60 seconds. A throttled call is answered 502 with the work kept rather than retried. The mint's timeout stops waiting but does not abort the socket: `ensure-vm.test.ts` runs in Jest 24's jsdom environment, whose `AbortSignal` has no `timeout()`, and the node environment has no `AbortSignal` at all.
- The payload-size check runs after the mint, since the minted token is part of the payload. On the launch branch no live VM holds the revoked token, and rigse signs a fresh assertion per call.
- A Firestore failure inside the VM step (reading `vms/` or the claim) is a generic 500. Two concurrent requests against a `SUSPENDED` VM both call `ResumeMicrovm`, and the loser's error is answered 502 with its work already queued.
- Every dashboard string param defaults to `""` (`RD_QUEUE_CAP` defaults to 20), and `/run-package` answers 503 naming the unset launch settings (image, role, bucket, report-server URL) before writing anything. Both `.env` files list every param, empty where it has no value yet, because firebase-tools prompts for (or, non-interactively, fails on) a declared param a file leaves out, whatever its default.
- `microvm.test.ts` replaces the SDK module with `jest.mock`, because Jest 24 cannot resolve the SDK's `node:` builtins. The Firestore fake is shared at `functions/src/test/researcher-dashboard-fake-db.ts`. It runs transactions one at a time, models `merge` and `mergeFields`, and copies only maps and arrays, so a `Timestamp` written through it reads back as a `Timestamp`. `package-lock.json` was regenerated with Node 22's npm 10, the package's engine.

Checks on the head commit: report-server 1062 tests pass (7 skipped) and compiles with `--warnings-as-errors`; the functions' 609 tests pass (31 suites, 8 emulator tests skipped), with `tsc` and `tslint` clean.

## Out of Scope

- `/derive-profile` and the catalog: REPORT-142. The `researcher-dashboard` token verification is built here (R5) and first used there.
- `/work`, `/idle`, `/storage-credentials`, the watchdog and the Firestore rules for the dashboard tree: REPORT-143.
- Revoking a dashboard token: the runner uses the existing `DELETE /api/v1/tokens/current` (RD-4).
- report-server's `get_user_info` expiry and client predicates, which the design calls a pre-existing fix deserving its own pull request.
- Moving student feedback metadata off the shared bearer (RIGSE-367 R23).
- IAM changes on the launcher user: RD-1.

## Not Yet Implemented

- No rigse signing key exists for either portal, so `PORTAL_PUBLIC_KEYS` is `'[]'` in both functions `.env` files and every assertion is refused until entries from `rake portal_signing_key:public` are added.
- report-server reads `PORTAL_PUBLIC_KEYS` from its task environment, which comes from cloud-formation's `fargate/report-server.yml` in another repository. The variable has to be added to that stack.
- There is no production runner stack yet, so production's image, role and bucket are empty and `/run-package` answers 503 there. `RD_AWS_KEY` and `RD_AWS_SECRET_KEY` must still be set in both projects before the first deploy, as the functions README says.

## Decisions

### Bind each configured key to an issuer
**Context**: The story says keys are "keyed by `kid`". One report-server serves the staging portal and both production portals (`report-server.yml:215-219`).
**Options considered**:
- A) Configure `{kid, pem, issuer}` and require the token's `iss` to be its key's issuer.
- B) Configure `{kid, pem}` only and trust `iss` once the signature verifies.

**Decision**: A. Under B, a report-server holding the staging key accepts a staging-signed token that claims a production `iss`, and the minted token reads production data for whichever production user the claims name. Binding costs one field per key and one comparison. Recorded as R1 and R2.

---

### The researcher comes from the assertion, not the body
**Context**: The spike's `run_package` took `platform_user_id`, `platform_id` and `portal` from the body under the shared bearer.
**Options considered**:
- A) Take them from the verified `report-service-functions` assertion (`uid`, `iss`).
- B) Keep them in the body and trust the caller.

**Decision**: A. The assertion names the researcher already, and a body field is what a caller holding any valid assertion could change to queue work into, and launch a VM for, someone else. Recorded as R12.

---

### Reuse a live VM whatever its image version
**Context**: The spike relaunched when a remembered VM ran an older image version than the current one, leaving the old VM running.
**Options considered**:
- A) Reuse a `RUNNING` or `SUSPENDED` VM whatever its version; a new version is picked up at the next launch.
- B) Relaunch on a version change, as the spike did.

**Decision**: A. Under the queue model, relaunching leaves the old VM holding the researcher's queue claim and token until its eight-hour cap, and two VMs for one researcher is what R16 forbids. The maximum VM life bounds how long an old image can serve. Recorded as R16.

---

### Where does the `jti` nonce live?
**Context**: The story says "a short-lived nonce cache". report-server runs one task today and does not cluster, and a restart empties memory.
**Options considered**:
- A) A database table with a unique `jti` and its expiry, pruned of expired rows.
- B) An in-memory (ETS) cache on the node.

**Decision**: A. Checked: report-server runs `DesiredCount: 1` with no `DNS_CLUSTER_QUERY` (`report-server.yml:51`), so an ETS cache is per node and emptied by every deploy or restart, and a restart inside an assertion's two-minute window would reopen exactly the replay the story closes. A table with a unique index on `jti` makes the insert itself the check, holds across restarts and any future task count, and needs no process to own it; rows are pruned by expiry on each insert. Recorded as R8.

---

### What is the queue's cap?
**Context**: `final-design.md` 6.1 names "a queue at its cap" as a 409 without a number.
**Options considered**:
- A) A configured cap, defaulting to 20 packages outstanding per researcher.
- B) No cap in this story.

**Decision**: A, as a configured value defaulting to 20. The design names the 409 but no number, and RIGSE-368's contract depends only on the 409 and its reason, not the value, so a configured default lets operations tune it without a release. Twenty is several full batches of the packages a class is offered and far below anything that strains one VM's eight-hour window, which the runner enforces separately (RD-4). Recorded in R14.

---

### Is `/run-package` a route on the existing `api` function or a function of its own?
**Context**: The existing app applies the shared bearer to every route and every route receives every declared secret, including the launcher's AWS keys once they are declared.
**Options considered**:
- A) A separate HTTPS function for the dashboard's function surface, holding the launcher secrets alone and no shared-bearer middleware; REPORT-142 and REPORT-143 add their routes to it.
- B) A route on `api`, exempted from `bearerTokenAuth` before it runs.

**Decision**: A. Checked: the repo already scopes secrets per function (`auto-importer.ts:461` holds its AWS keys, `chat-tutor.ts:39` its OpenAI key, `submitTask` is its own function), and `api` declares its secrets for every route (`index.ts:71`), so putting the launcher's AWS keys on `api` would put them in the environment of `import_run`, `move_student_work` and every other shared-bearer route. A separate function also has no global `bearerTokenAuth` to exempt a route from, which removes the one place a mistake would let the shared bearer reach `/run-package`. `function_url` in `runHookPayload` points at it, and REPORT-142 and REPORT-143 add their routes there. Recorded as R11.

---

### R16 used a state the API does not have and missed `SUSPENDING`
**Context**: The SDK's `MicrovmState` is `PENDING`, `RUNNING`, `SUSPENDING`, `SUSPENDED`, `TERMINATING`, `TERMINATED` (`@aws-sdk/client-lambda-microvms` 3.1138.0, `models/enums.d.ts:103`). "Starting" is not one, and `SUSPENDING` is exactly the race between `/idle` (queue empty, suspend requested) and a `/run-package` that appends work a moment later: doing nothing leaves the new work stranded on a VM that finishes suspending, and `ResumeMicrovm` cannot be issued until it has.

**Decision**: Fixed: R16 maps every state, and `SUSPENDING` schedules a follow-up resume.


*Superseded*: the follow-up resume became REPORT-143's watchdog, as the decision on work queued against a `SUSPENDING` VM records, and R16 says so.
---

### Nothing tied the relayed `report_server_assertion` to the researcher the request is for
**Context**: R12 took the researcher from the request's own assertion but R13 relayed a second assertion from the body unchecked. A request carrying researcher A's functions assertion and researcher B's report-server assertion would launch A's VM holding B's report-server token, so A's packages would pull B's data into A's S3 prefix. rigse signs both and would have to be wrong for this to happen, but the function can refuse it for one verification, since verifying is not minting.

**Decision**: Fixed: R13 verifies it and requires the same `uid` and `iss`.

---

### Expired dashboard tokens would still be listed and managed as active
**Context**: `list_active_api_tokens`, `list_all_active_api_tokens`, `get_user_api_token` and `get_active_api_token` (`accounts.ex:120-146`) all filter on `is_nil(t.revoked_at)` alone, and the first two drive the CLI token page (`report_live/cli_token.ex`) and the admin all-tokens page (`all_tokens_live/index.ex`). With R10's expiry only in `verify_api_token`, a nine-hour-old dashboard token would verify as dead and display as live.

**Decision**: Fixed: R10 applies the expiry to the listings and lookups too.

---

### Nothing required the new secrets and params to exist before deploy
**Context**: The spike's function declared `RD_AWS_KEY` and `RD_AWS_SECRET_KEY` as secrets and four `RD_*` params in `.env.report-service-dev` only (spike `functions/.env.report-service-dev`); nothing equivalent exists for `-pro`, and a Firebase deploy fails for a function whose declared secret is unset. report-server likewise needs the portal keys in `runtime.exs`.

**Decision**: Fixed: R21.

---

### The `/run-package` validation would refuse every body rigse sends
**Context**: The queueing step validated `checksum` as "a hex string", but REPORT-142's catalog stores and resolves `sha256:<lowercase hex>` (its R9), the runner computes and compares that form (`researcher-dashboard/runner/server/package-fetch.js:20`), and rigse forwards the catalog's value unchanged (RIGSE-368 R17). The validation also left the assignment fields untyped, while rigse sends the portal's stored URL, which master's `valid_url` lets be `""`, and a name that can be null.

**Decision**: Fixed: R13 names the checksum format and the two nullable assignment fields, and the queueing step validates `checksum` against `^sha256:[0-9a-f]{64}$` and accepts them (Doug, 2026-09-24).

---

### How does work queued against a `SUSPENDING` VM get the VM resumed?
**Context**: R16 requires that it does, and `ResumeMicrovm` cannot be issued until the VM reaches `SUSPENDED`, which can take up to the `/suspend` hook's 60-second flush. The function must not wait (R20).
**Options considered**:
- A) The function enqueues a Cloud Task, delayed ~30 seconds, to a follow-up route on `researcherDashboard` that re-runs the ensure step; the repo already uses `@google-cloud/tasks` (`tasks/submit-task.ts`). Needs an authenticated route for Cloud Tasks (an OIDC token from the function's service account) and the queue created per project.
- B) REPORT-143's per-minute watchdog, which already reads sessions and holds the MicroVM API, resumes any `SUSPENDED` VM whose `work/` document has packages outstanding. No new route or queue; up to a minute of latency in a rare race; moves the guarantee into REPORT-143.
- C) Do nothing here; the researcher's next request resumes it.

**Decision**: B (Doug, 2026-09-23). The function does nothing more on `SUSPENDING` than on `RUNNING`; REPORT-143's watchdog gains a clause resuming any `SUSPENDED` VM whose `work/` document has packages outstanding. Recorded in R16.

---

### `jsonwebtoken` rather than hand-rolled `crypto.verify`
**Options considered**:
- A) `jsonwebtoken` 9, which loads under the repo's Jest 24 and whose refusals are in the Verification table.
- B) Verify RS256 directly with Node's `crypto.verify`, no dependency.

**Decision**: A. The library's alg handling was checked (it refuses the confusion token even with HS256 allowed), and the two gaps it has, `exp` and `aud` arrays, are covered by explicit checks. Hand-rolling base64url parsing and signature checks is where a verifier's subtle bugs live.

---

### A launch claim on `vms/{uid}`, not a lock on `work/`
**Options considered**:
- A) The ensure step's own transaction on `vms/{uid}`, setting a short `launching_until` before calling `RunMicrovm`.
- B) Hold the queue transaction open across the launch.

**Decision**: A. A Firestore transaction must not span a network call as slow as `RunMicrovm` and the mint round trip (transactions retry and hold contention), and the queue write is already committed before the VM step, which is what lets a failed launch keep the work for next time.

---

### The dashboard-function step referenced secrets declared only in the last step
**Context**: `researcherDashboard` is declared with `runWith({ secrets: [rdAwsKey, rdAwsSecretKey] })` in the queueing step, but `config.ts`, which defines them, was in the configuration step at the end, so that commit would not compile.

**Decision**: Fixed: `config.ts` moves into the queueing step, and the last step only fills values and documentation.

---

### `firebase-admin/firestore` cannot be imported under the repo's Jest
**Decision**: Checked with a scratch test: `import { FieldValue, Timestamp } from "firebase-admin/firestore"` fails with `Cannot find module` under Jest 24, which predates package subpath exports; `import * as admin from "firebase-admin"` with `admin.firestore.FieldValue` and `admin.firestore.Timestamp` passes, and is what `src/chat/drain.test.ts` already does. Fixed throughout the plan.

---

### `function_url` could not be known before the first deploy
**Decision**: The plan had the operator deploy, read the function's URL, set `RD_FUNCTION_URL` and redeploy. A first-generation HTTPS function's URL is fixed by region, project and name, and `GCLOUD_PROJECT` is set at runtime, so it defaults to the derived URL, with the param kept as an override. Fixed in the queueing and configuration steps.

---

### One scope per researcher's queue runs a second class's packages against the first class's scope
`final-design.md` gives `work/{platform_user_id}` one scope block ("also holds the scope block rigse sent"), de-duplicates appended packages by package key, and mirrors a flat list of package keys onto `runners/{platform_user_id}`'s `queue`; this plan followed it. A researcher who runs packages from two class dashboards before their VM takes the work overwrites the first class's scope and class tokens with the second's, so the first class's queued packages run over the second class's data. A package already queued for class A and then requested for class B is skipped as a duplicate, and `queue` cannot say which class an entry is for. Checked against the design's text and the plan's transaction. The fix is to key queue entries by class and package (for example `scopes: {class_hash: {scope, class_tokens}}` beside `packages: [{class_hash, identity, ...}]`, and `queue` entries naming the class), which changes the `/work` response REPORT-143 returns, what RD-4's runner reads, and the `queue` field RD-3's page renders. Left open because it changes a contract three other stories consume.

**Decision**: key by class (Doug, 2026-09-23). Applied to R15 and the queueing step: entries carry `class_hash`, scope and class tokens live under `scopes.{class_hash}`, de-duplication is by class and package, and `queue` holds `{class_hash, package_key}` pairs. REPORT-143, RD-4 and RD-3 read these shapes.

---

### `export const researcherDashboard` would never be deployed
**Context**: `functions/src/index.ts` ends by assigning `module.exports = { api: wrappedApi, ... }`, which replaces the whole exports object, so an `export const` anywhere in the file is dropped from the compiled module. A throwaway `tsc` build of that shape (`export const researcherDashboard = 1` followed by `module.exports = { api }`) exported only `api`, so Firebase would never have seen the function.

**Decision**: Fixed: `researcherDashboard` is added as a key of that object (Doug, 2026-09-24).
