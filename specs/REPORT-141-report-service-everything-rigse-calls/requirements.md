# report-service: everything rigse calls

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-141
**Repo**: https://github.com/concord-consortium/report-service
**Status**: **In Development**

## Overview

report-server and the report-service function learn to verify rigse's RS256 portal tokens, report-server gains the endpoint that exchanges rigse's signed assertion for a researcher's own short-lived API token, and the function gains `POST /run-package`, which queues a researcher's packages and launches or wakes their MicroVM without waiting for it. Together they are the whole surface rigse calls for the Researcher Dashboard, authenticated by short-lived signed assertions instead of the function app's shared bearer.

## Project Owner Overview

When a researcher asks the Researcher Dashboard to run analyses, the portal hands the work to report-service, which records the request, starts or wakes that researcher's private analysis machine, and answers straight away rather than making the researcher wait for the machine. The machine pulls data as the researcher themselves, using a credential report-server issues for that one machine and that expires on its own.

This story replaces a single all-powerful shared password between the portal and report-service with short-lived, single-purpose signed credentials that only the portal can create, and it makes sure a credential from the staging portal can never be used against production. It is the second step of the dashboard's first release, directly after the portal's signing key (RIGSE-367), and the catalog (REPORT-142) and the dashboard API (RIGSE-368) are built on it.

## Background

REPORT-141 is derived from `final-design.md` sections 6.1, 10, 11.1 and 11.2; the Jira description is the authoritative scope and is not restated in full here. This spec records how it lands on master and the contract it takes from RIGSE-367, whose spec (`rigse/specs/RIGSE-367-the-portal-signing-key-and-the-scoped-launch-token/`) fixes the token shapes.

**What rigse sends (RIGSE-367).** rigse signs RS256 tokens with a per-environment key, `kid` in the header, `iss` equal to the portal's site URL, exactly one string `aud`, and verifiers configured with the public key PEM under its `kid` (RIGSE-367 R5). Three audiences:

| `aud` | Claims | Life | Verified here by |
|---|---|---|---|
| `researcher-dashboard` | `iss`, `uid`, `user_type: "researcher"`, `scope_kind`, `scope_id`, `iat`, `exp` | 2 hours | report-server (used by REPORT-142's catalog read) |
| `report-server` | the above plus `jti`, `portal_user_id`, `portal_server`, `login`, `first_name`, `last_name`, `email`, `is_admin`, `is_project_admin`, `is_project_researcher` | 2 minutes | report-server's mint endpoint |
| `report-service-functions` | `iss`, `uid`, `iat`, `exp` | 2 minutes | the function's `/run-package` |

The `jwt` gem rigse uses was found to accept an HS256 token signed with an RS256 public key's PEM when handed the PEM string and a list containing HS256, and to accept an `aud` array containing the expected value (RIGSE-367 Verification); the same classes of mistake are possible in any JWT library and are the reason for R3 and R4 below.

**What master has today.** Nothing of the dashboard. On report-service master:

- **The function app** (`functions/src/index.ts`) is one express app behind `api.use(bearerTokenAuth)` (`index.ts:85`), which requires the shared `AUTH_BEARER_TOKEN` secret on every route but `/`; `requireHeaderBearer` additionally refuses a bearer in the query or body on `bulk_read` and `fetch_attachment_meta`. There is no JWT library in `functions/package.json`, no MicroVM SDK, and no `researcher_dashboard/` code.
- **report-server** (`server/`) has `api_tokens` (`accounts/api_token.ex`: `token_hash`, `label`, `last_used_at`, `revoked_at`, `revoked_by_user_id`), `create_api_token/2` and `verify_api_token/1`, which filters on `is_nil(t.revoked_at)` only (`accounts.ex:94-104`). `ReportServerWeb.Api.AuthPlug` authenticates `/api/v1` by API token. `DELETE /api/v1/tokens/current` already lets a token holder revoke its own token (`router.ex:79-86`), which is what the runner's `/terminate` uses (RD-4), so this story adds no revoke endpoint. There is no JWT library in `mix.exs` and no mint endpoint.
- **Users** are found or created from `PortalUserInfo` (`accounts.ex:16`, `find_or_create_user/1`) keyed by `portal_server` (the portal host) and `portal_user_id`; the `User` changeset requires every portal field. `PortalDbs.get_server_for_portal_url/1` maps a portal URL to that host, and `has_db_connection?/1` says whether report-server knows the portal.

**One report-server serves several portals, staging and production together.** `cloud-formation/fargate/report-server.yml:215-219` gives the task `LEARN_PORTAL_STAGING_CONCORD_ORG_DB`, `LEARN_CONCORD_ORG_DB` and `NGSS_ASSESSMENT_PORTAL_CONCORD_ORG_DB`. So one report-server holds more than one portal's public key, and a verifier that picks a key by `kid` alone would accept a token signed with the staging key that claims `iss: https://learn.concord.org/`: the story's own Done-when, "a staging-signed token is refused in production", fails. Each configured key must be bound to the issuer it may sign for (R2). The function is configured per project with one portal (`TRUSTED_PORTAL_HOSTS` in `functions/.env.report-service-{dev,pro}`), but takes a list, so the same binding applies there.

**report-server runs as one task and does not cluster.** `DesiredCount` defaults to 1 (`report-server.yml:51`) and `DNS_CLUSTER_QUERY` is not set, so there is no shared memory between tasks if the count is ever raised, and a node restart empties an in-memory cache. That shapes where the `jti` nonce lives (see Open Questions).

**Clauses of the Jira story set aside, and why.** Per the sprint's branching rule, a clause that deletes or renames something existing only on a spike branch is ignored. Each was checked against master:

| Jira clause | On master? | Treatment |
|---|---|---|
| `secret_name` deleted along with the Secrets Manager secret behind it | No: absent from report-service on master and on the spike branch (whose test asserts it is absent); it survives only in the runner's `Makefile` sample payload and a runner test, which are RD-4's | Set aside; `runHookPayload` is built without it from the start. |
| The spike's `PORTAL_SERVICE_SECRET` and its HS256 `PortalAssertion` | No (spike only) | Set aside; the mint endpoint verifies RS256 from the start. |
| "rigse holds no bearer for the function app" (Done-when) | rigse holds `REPORT_SERVICE_BEARER_TOKEN` on master for student feedback metadata | Restated as RIGSE-367 decided (its R23, option A): no dashboard path uses the shared bearer. `/run-package` accepts only the assertion. |

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

- R21. Every new setting is documented and configured for both environments before the code that reads it deploys: the portal key entries for report-server (`config/runtime.exs`) and for the function; the function's launcher credentials as function secrets; and the runner image, execution role, bucket, report-server URL, the function's own URL (`function_url`) and the queue cap as function params in `functions/.env.report-service-{dev,pro}`. A Firebase deploy of a function that declares a secret not yet set in the project fails, so the secrets are set first.

## Technical Notes

- **Files on master this story touches**: `functions/src/index.ts`, `functions/package.json`, new `functions/src/researcher-dashboard/*`, `functions/.env.report-service-{dev,pro}`; `server/mix.exs`, `server/config/runtime.exs`, `server/lib/report_server/accounts.ex`, `server/lib/report_server/accounts/api_token.ex`, a migration under `server/priv/repo/migrations/`, `server/lib/report_server_web/router.ex`, new modules under `server/lib/report_server_web/api/`, and tests beside each.
- **The spike as reference** (`~/projects/spike/report-service`, branch `RIGSE-365-researcher-dashboard-rules`): `functions/src/researcher-dashboard/run-package.ts` and `microvm.ts` hold the dependency-injected shape (`RunPackageDeps`, a `MicrovmApi` interface faked in tests because the repo's jest cannot resolve `firebase-functions`), the mint call, and `vmUrl`; its dispatch, `waitUntilRunning`, `CreateMicrovmAuthToken` and `idlePolicy` are exactly what this story must not carry. `server/lib/report_server_web/api/{portal_assertion,service_auth_plug}.ex`, `api/v1/dashboard_token_controller.ex` and `Accounts.mint_dashboard_token/1` hold the mint flow, HS256 there.
- **JWT libraries.** report-server adds `joken` (which brings `jose`, the Erlang library, and uses the existing `jason`); the function adds `jsonwebtoken` 9 and `@types/jsonwebtoken`. See Verification for why not `jose` in the function.
- **SDK.** `@aws-sdk/client-lambda-microvms` 3.1138.0 exports `RunMicrovm`, `ResumeMicrovm`, `SuspendMicrovm`, `GetMicrovm`, `TerminateMicrovm`; `idlePolicy` is optional on `RunMicrovm`. `HTTP_INGRESS` cannot be disabled (verified 2026-09-23); what closes the port is `lambda:CreateMicrovmAuthToken` leaving the launcher's policy (RD-1), which is why the function must never need it.
- **The function's AWS credential** is the runner stack's launcher user (spike: `RD_AWS_KEY` / `RD_AWS_SECRET_KEY` as function secrets). Firebase secrets are declared per function, so any route on the same function receives them in its environment.
- **report-server's portal mapping.** `get_server_for_portal_url` rewrites two report hosts to their portals and otherwise returns the host; `has_db_connection?/1` reads `<HOST>_DB` from the environment.
- **Where rigse's side is specified**: RIGSE-367 (token shapes, claims, key contract) and RIGSE-368 (the caller of `/run-package`, which also sends the scope and resolves packages).

- **What `RUNNING does nothing` relies on.** A running VM that has drained its queue calls `/idle` after its idle period, and `/idle` checks for queued work before suspending (REPORT-143, `final-design.md` 7.2(b)); a VM mid-queue calls `/work` again as it drains (RD-4). So work appended to a running VM's queue is taken without the function calling into the VM.

## Verification

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

## Out of Scope

- `/derive-profile` and the catalog: REPORT-142. The `researcher-dashboard` token verification is built here (R5) and first used there.
- `/work`, `/idle`, `/storage-credentials`, the watchdog and the Firestore rules for the dashboard tree: REPORT-143.
- Revoking a dashboard token: the runner uses the existing `DELETE /api/v1/tokens/current` (RD-4).
- report-server's `get_user_info` expiry and client predicates, which the design calls a pre-existing fix deserving its own pull request.
- Moving student feedback metadata off the shared bearer (RIGSE-367 R23).
- IAM changes on the launcher user: RD-1.

## Open Questions

### RESOLVED: Judgment call: bind each configured key to an issuer
**Context**: The story says keys are "keyed by `kid`". One report-server serves the staging portal and both production portals (`report-server.yml:215-219`).
**Options considered**:
- A) Configure `{kid, pem, issuer}` and require the token's `iss` to be its key's issuer.
- B) Configure `{kid, pem}` only and trust `iss` once the signature verifies.

**Decision**: A. Under B, a report-server holding the staging key accepts a staging-signed token that claims a production `iss`, and the minted token reads production data for whichever production user the claims name. Binding costs one field per key and one comparison. Recorded as R1 and R2.

### RESOLVED: Judgment call: the researcher comes from the assertion, not the body
**Context**: The spike's `run_package` took `platform_user_id`, `platform_id` and `portal` from the body under the shared bearer.
**Options considered**:
- A) Take them from the verified `report-service-functions` assertion (`uid`, `iss`).
- B) Keep them in the body and trust the caller.

**Decision**: A. The assertion names the researcher already, and a body field is what a caller holding any valid assertion could change to queue work into, and launch a VM for, someone else. Recorded as R12.

### RESOLVED: Judgment call: reuse a live VM whatever its image version
**Context**: The spike relaunched when a remembered VM ran an older image version than the current one, leaving the old VM running.
**Options considered**:
- A) Reuse a `RUNNING` or `SUSPENDED` VM whatever its version; a new version is picked up at the next launch.
- B) Relaunch on a version change, as the spike did.

**Decision**: A. Under the queue model, relaunching leaves the old VM holding the researcher's queue claim and token until its eight-hour cap, and two VMs for one researcher is what R16 forbids. The maximum VM life bounds how long an old image can serve. Recorded as R16.

### RESOLVED: Low confidence: where does the `jti` nonce live?
**Context**: The story says "a short-lived nonce cache". report-server runs one task today and does not cluster, and a restart empties memory.
**Options considered**:
- A) A database table with a unique `jti` and its expiry, pruned of expired rows.
- B) An in-memory (ETS) cache on the node.

**Decision**: A. Checked: report-server runs `DesiredCount: 1` with no `DNS_CLUSTER_QUERY` (`report-server.yml:51`), so an ETS cache is per node and emptied by every deploy or restart, and a restart inside an assertion's two-minute window would reopen exactly the replay the story closes. A table with a unique index on `jti` makes the insert itself the check, holds across restarts and any future task count, and needs no process to own it; rows are pruned by expiry on each insert. Recorded as R8.

### RESOLVED: Low confidence: what is the queue's cap?
**Context**: `final-design.md` 6.1 names "a queue at its cap" as a 409 without a number.
**Options considered**:
- A) A configured cap, defaulting to 20 packages outstanding per researcher.
- B) No cap in this story.

**Decision**: A, as a configured value defaulting to 20. The design names the 409 but no number, and RIGSE-368's contract depends only on the 409 and its reason, not the value, so a configured default lets operations tune it without a release. Twenty is several full batches of the packages a class is offered and far below anything that strains one VM's eight-hour window, which the runner enforces separately (RD-4). Recorded in R14.

### RESOLVED: Low confidence: is `/run-package` a route on the existing `api` function or a function of its own?
**Context**: The existing app applies the shared bearer to every route and every route receives every declared secret, including the launcher's AWS keys once they are declared.
**Options considered**:
- A) A separate HTTPS function for the dashboard's function surface, holding the launcher secrets alone and no shared-bearer middleware; REPORT-142 and REPORT-143 add their routes to it.
- B) A route on `api`, exempted from `bearerTokenAuth` before it runs.

**Decision**: A. Checked: the repo already scopes secrets per function (`auto-importer.ts:461` holds its AWS keys, `chat-tutor.ts:39` its OpenAI key, `submitTask` is its own function), and `api` declares its secrets for every route (`index.ts:71`), so putting the launcher's AWS keys on `api` would put them in the environment of `import_run`, `move_student_work` and every other shared-bearer route. A separate function also has no global `bearerTokenAuth` to exempt a route from, which removes the one place a mistake would let the shared bearer reach `/run-package`. `function_url` in `runHookPayload` points at it, and REPORT-142 and REPORT-143 add their routes there. Recorded as R11.

## Self-Review

Roles: Security Engineer, Senior Engineer (Elixir and Firebase functions), QA Engineer, DevOps Engineer, Product Manager. Each finding was checked against the code before being recorded. Dropped after checking: a replayed `report-service-functions` assertion, which inside its two minutes can only re-append packages already queued (skipped) and ensure a VM that already exists, so it needs no nonce; the mint response carrying a raw token, which is the endpoint's purpose and is returned once over TLS as the CLI token flow already does; and the Product Manager's review, which found nothing to change.

### Senior Engineer

#### RESOLVED: R16 used a state the API does not have and missed `SUSPENDING`
The SDK's `MicrovmState` is `PENDING`, `RUNNING`, `SUSPENDING`, `SUSPENDED`, `TERMINATING`, `TERMINATED` (`@aws-sdk/client-lambda-microvms` 3.1138.0, `models/enums.d.ts:103`). "Starting" is not one, and `SUSPENDING` is exactly the race between `/idle` (queue empty, suspend requested) and a `/run-package` that appends work a moment later: doing nothing leaves the new work stranded on a VM that finishes suspending, and `ResumeMicrovm` cannot be issued until it has. Fixed: R16 maps every state, and `SUSPENDING` schedules a follow-up resume.

### Security Engineer

#### RESOLVED: Nothing tied the relayed `report_server_assertion` to the researcher the request is for
R12 took the researcher from the request's own assertion but R13 relayed a second assertion from the body unchecked. A request carrying researcher A's functions assertion and researcher B's report-server assertion would launch A's VM holding B's report-server token, so A's packages would pull B's data into A's S3 prefix. rigse signs both and would have to be wrong for this to happen, but the function can refuse it for one verification, since verifying is not minting. Fixed: R13 verifies it and requires the same `uid` and `iss`.

### QA Engineer

#### RESOLVED: Expired dashboard tokens would still be listed and managed as active
`list_active_api_tokens`, `list_all_active_api_tokens`, `get_user_api_token` and `get_active_api_token` (`accounts.ex:120-146`) all filter on `is_nil(t.revoked_at)` alone, and the first two drive the CLI token page (`report_live/cli_token.ex`) and the admin all-tokens page (`all_tokens_live/index.ex`). With R10's expiry only in `verify_api_token`, a nine-hour-old dashboard token would verify as dead and display as live. Fixed: R10 applies the expiry to the listings and lookups too.

### DevOps Engineer

#### RESOLVED: Nothing required the new secrets and params to exist before deploy
The spike's function declared `RD_AWS_KEY` and `RD_AWS_SECRET_KEY` as secrets and four `RD_*` params in `.env.report-service-dev` only (spike `functions/.env.report-service-dev`); nothing equivalent exists for `-pro`, and a Firebase deploy fails for a function whose declared secret is unset. report-server likewise needs the portal keys in `runtime.exs`. Fixed: R21.

### Integrator of RIGSE-368 (found while speccing RIGSE-368)

#### RESOLVED: The `/run-package` validation would refuse every body rigse sends
The queueing step validated `checksum` as "a hex string", but REPORT-142's catalog stores and resolves `sha256:<lowercase hex>` (its R9), the runner computes and compares that form (`researcher-dashboard/runner/server/package-fetch.js:20`), and rigse forwards the catalog's value unchanged (RIGSE-368 R17). The validation also left the assignment fields untyped, while rigse sends the portal's stored URL, which master's `valid_url` lets be `""`, and a name that can be null. Fixed: R13 names the checksum format and the two nullable assignment fields, and the queueing step validates `checksum` against `^sha256:[0-9a-f]{64}$` and accepts them (Doug, 2026-09-24).

