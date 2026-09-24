# report-service: the catalog and the authored URL profile

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-142
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

report-server gains the package catalog: two tables, a publish endpoint that cc-data-cli calls with the researcher's own cc-data token, state-change endpoints with an audit trail, a read endpoint the dashboard app calls anonymously or with its launch token, and a resolve endpoint rigse calls on the run path. The report-service function gains `POST /derive-profile`, which takes the assignment URLs rigse supplies, follows the Activity Player ones to their public activity JSON, and writes the class's authored URL profile to Firestore with the Admin SDK. Together they are what a package declares at publish and what the page matches it against at launch.

## Project Owner Overview

A researcher packages an analysis and publishes it with the cc-data login they already have. It lands private to them, and nobody needs AWS access or a maintainer's help. They can later share it with a project or with everyone, and Concord can mark reviewed packages as official. Every such change is recorded with who made it and what it replaced. Rolling back a bad version means pointing the package at the previous version, and nothing is deleted.

When a researcher opens a class, the dashboard lists only the packages that make sense for that class. It decides this by matching each package's declared URL patterns against the activities and interactives the class was assigned. report-service works out that list of URLs server-side from public authoring data, once per class rather than once per browser tab. Until per-researcher storage credentials ship (REPORT-143), only official packages can actually be run.

## Background

REPORT-142 is derived from `final-design.md` sections 5.2 to 5.7 and the `manifest.json` and `POST /derive-profile` contracts in section 10. The Jira description is the authoritative scope and is not restated in full here. This spec records how the story lands on master and on REPORT-141, which it stacks on. It also records the decisions the story leaves to implementation.

**What it builds on (REPORT-141, closed at `specs/REPORT-141-report-service-everything-rigse-calls.md`).**
- report-server's `PortalToken.verify/2` and `PortalTokenPlug`. These verify rigse's RS256 tokens by `kid`, bound to an issuer, and expose the claims for a named audience. REPORT-141 R5 builds the `researcher-dashboard` audience for this story's catalog read.
- The function's separate `researcherDashboard` HTTPS function, whose auth middleware verifies an `aud: report-service-functions` assertion. It sets `res.locals.researcher` to `{uid, platformUserId, platformId, portal}` taken from `uid` and `iss`.
- `firestore-paths.ts`, with `portalSegment(iss)`.
- `PORTAL_PUBLIC_KEYS`.

`/derive-profile` is a route on that function. REPORT-141 is implemented on its branch, which this one stacks on, but is not yet merged to master. Every file named below as "from REPORT-141" exists there. Its closed spec's "As built (2026-09-24)" notes, under Technical Notes, record where the code departs from its plan.

**What rigse sends (RIGSE-367).** The launch token carries `aud: researcher-dashboard`, `iss` (the portal's site URL), `uid`, `user_type: "researcher"`, `scope_kind`, `scope_id`, `iat` and `exp`, and lives two hours. It carries no role flags and no project ids, which is why report-server resolves them from the portal on the catalog path. rigse's side of `refresh_profile`, the assignment fingerprint and the run-path resolve are RIGSE-368.

**What master has today.** Nothing of the catalog or the profile, on master or on the spike branch. The spike ran one hard-coded package whose checksum came from the caller.
- **report-server** has `api_tokens`, and `ReportServerWeb.Api.AuthPlug`, which authenticates `/api/v1` by API token and requires `can_access_reports?`, meaning any of the three portal role flags.
- `PortalDbs` connects to each portal's MySQL by `<HOST>_DB`, and holds `get_allowed_project_ids/2` (`portal_dbs.ex:198`).
- It has no CORS anywhere. The error envelope is the flat `{"error": CODE, "message": ...}` of `ErrorHelpers`, which cc-data-cli decodes (`internal/api/client.go:189-215`).
- It writes S3 with its own `SERVER_ACCESS_KEY_ID` user (`aws.ex:146`).
- **The function** has no fetcher of authoring JSON. It already enqueues Cloud Tasks with `CloudTasksClient` and an OIDC token to a v2 `onTaskDispatched` worker, and runs the worker directly under the emulator (`tasks/submit-task.ts:120-160`, `tasks/task-worker.ts:70`).
- **`firestore.rules`** denies every client read and write by default (`match /{document=**}`, line 9) and has no `researcher_dashboard` block. The profile document is therefore unwritable by any client today. REPORT-143 adds the dashboard's read rules.

**One report-server serves more than one portal, so a portal id is not unique within it.** The production report-server task holds `LEARN_CONCORD_ORG_DB` and `NGSS_ASSESSMENT_PORTAL_CONCORD_ORG_DB` (`cloud-formation/fargate/report-server.yml:215-219`), and its `users` table is keyed by `(portal_server, portal_user_id)`. The design's identity `users/<numeric>` uses portal ids, so learn.concord.org's user 136 and the NGSS portal's user 136 would publish into the same identity. Each catalog row is therefore scoped to the portal its ids belong to (R2).

The runner stacks are per environment in separate AWS accounts (Doug, 2026-09-24). Staging's runner bucket is in a different account from the staging report-server (`final-design.md` section 12). So each report-server deployment writes one runner bucket, with a credential scoped to that bucket's `packages/` prefix.

**What the live authoring API returns (checked 2026-09-24, see Verification).**
- `GET https://authoring.concord.org/api/v1/activities/<id>.json` answers 200 without a credential.
- Interactives sit at `pages[].sections[].embeddables[]`, not `pages[].embeddables[]`.
- A `ManagedInteractive` carries `library_interactive.data.base_url` **and** an optional `url_fragment`, which the Activity Player appends to the base URL when it loads the interactive (`activity-player/src/components/activity-page/managed-interactive/managed-interactive.tsx:349`).
- A `MwInteractive` carries `url`, which can be empty.
- `GET .../api/v1/sequences/<id>.json` embeds its activities in full, pages included, so a sequence costs one fetch.
- The Activity Player takes `activity=` and `sequence=` as absolute URLs to that JSON (`activity-player/src/lara-api.ts:21-23`).

**Consumers of the shapes defined here.**
- cc-data-cli's `package publish` and state commands: REPORT-146.
- The dashboard app's list and matcher: RD-3.
- The runner, which reads the manifest from the archive it checksummed and enforces the patterns against the profile: RD-4.
- rigse's `refresh_profile` and run-path resolve: RIGSE-368.
- The Firestore read rule on `classes/{class_hash}`: REPORT-143.

The runner today fetches `scripts/<name>/<version>.zip`, verifies the bytes against the request's `sha256:<hex>` checksum rather than the `.sha256` sidecar, and allows `_` in names. RD-4 moves it to `packages/<identity>/<version>.zip` and the identity grammar.

**Clauses of the Jira story set aside, and why.** None. Every clause names something new on master, and none deletes spike-only code.

## Requirements

### The tables (report-server)

- R1. `packages` holds identity, origin, name, maintainer, visibility, project, official, archived and `current_version`. `package_versions` holds version, checksum, S3 key, `published_at`, `published_by`, title, description, `urls`, `clue_prepull` and `expected_duration_seconds`, with `urls` stored as JSON on the version row. There is no third table for patterns. Audit rows live in their own table (R12).
- R2. Every package belongs to one portal: `packages.portal_server` is the portal host its origin and maintainer ids are drawn from. Identity is unique per portal, not globally. Every read, resolve and state change is confined to the caller's portal. For a cc-data token, that is the token user's `portal_server`. For a launch token, it is the verified `iss` mapped with `PortalDbs.get_server_for_portal_url/1`.
- R3. Identity is `<origin>/<name>`, immutable. Origin is `users/<portal user id>` or `projects/<portal admin project id>`, and name matches `^[a-z0-9][a-z0-9-]{0,62}$`. The catalog id, `packages.id`, is the numeric id the runner names its cc-data dataset `pkg-<catalog id>` by (`final-design.md` 5.3).
- R4. The maintainer is `users/<id>` or `projects/<id>` on the same portal, and initially equals the origin. A caller **administers** a package when either:
  - the maintainer is `users/<their portal user id>`, or
  - the maintainer is `projects/<p>` and `p` is among their allowed project ids (`get_allowed_project_ids/2`, where `:all` for a site admin includes every project).
  Changing the maintainer is not an endpoint in this story.

### Publishing (report-server, what cc-data-cli calls)

- R5. `POST /api/v1/packages` takes the package zip as the raw request body (`Content-Type: application/zip`), authenticated by the publisher's cc-data token through the existing `AuthPlug`. It resolves the owner from the token and never from the manifest. Two optional query parameters:
  - `origin=projects/<id>` publishes under a project the caller holds a grant on.
  - `official=true` is accepted only from a holder of the publisher role (R11).
  Without `origin`, the origin is `users/<the token user's portal_user_id>`.
- R6. The archive must pass every check before anything is written; any failure is a 422 naming the reason.
  - It is at most 10 MiB, compressed.
  - It is a zip with exactly one `manifest.json` at its root. The manifest is inflated with a bound that stops at 64 KiB of actual output, because an entry's declared size is not trusted (see Self-Review). Entry offsets and compressed sizes come from the central directory, since a Go-written zip (cc-data-cli's `archive/zip`) leaves them zero in the local header.
  - Its entries declare at most 50 MiB uncompressed in total. This is a declaration check only; the runner, which unpacks everything, bounds actual bytes (RD-4).
  - No entry is absolute or contains a `..` segment.
- R7. The manifest is validated against `final-design.md` section 10's shape.
  - `name`: the R3 grammar.
  - `version`: `MAJOR.MINOR.PATCH` with an optional `-prerelease` of `[0-9A-Za-z.-]`, so it is safe as an S3 key segment.
  - `title`: a non-empty string of at most 200 characters.
  - `description`: at most 500 characters, one line.
  - `urls`: optional `all`, `any` and `none` arrays of strings.
  - `clue_prepull`: optional boolean, default `false`.
  - `entrypoint`: a relative path naming a file in the archive.
  - `expected_duration_seconds`: a positive integer no greater than 28,800.
  A manifest that declares `owner`, `maintainer`, `origin`, `visibility`, `project` or `official` is refused, since those are catalog state and never a zip's assertion about itself. Other unknown keys are ignored.
- R8. Publish bounds the matcher's bulk work. A version declares at most 20 patterns across `all`, `any` and `none` together. Each pattern is a non-empty string of at most 256 characters with no control characters or whitespace. `*` is the only metacharacter, and `?` is literal (`final-design.md` 5.5).
- R9. The checksum is `sha256:<lowercase hex>` of the zip's bytes, the format the runner compares against. report-server writes the zip to `packages/<identity>/<version>.zip` and the checksum string to `packages/<identity>/<version>.sha256`. It projects the manifest into the rows and inserts them in one transaction. An (identity, version) that already exists on that portal is refused with 409 and nothing is written to S3. The rows are inserted before the S3 write and committed after it, in one transaction. A concurrent publish of the same version then waits on the unique index and fails, and never overwrites the first publisher's object. A failed S3 write rolls the rows back. A first publish creates the package `private`, or `official` and `public` when `official=true` is accepted (R11). Whether the package is new or existing, the caller must administer it (R4).
- R10. `current_version` moves on publish when the package is new or `private`. For `project`, `public` and `official` packages it moves only by the maintainer's explicit act (R12). The response is 201 with the identity, version, checksum, catalog id, visibility and `current_version`.
- R11. The **publisher role** is held by every portal site admin (`portal_is_admin`), and by any other report-server user an operator has explicitly granted it. No other portal role implies it. Only a holder may set or clear `official`, on publish or afterwards, and holding it does not make anyone a maintainer.

### State changes (report-server)

- R12. Authenticated by cc-data token, `POST /api/v1/packages/<origin>/<name>/<state>` sets one of:
  - `visibility` (`private`, `project` with a `project_id`, or `public`), by an administrator (R4). `project` requires a project in the caller's allowed project ids.
  - `official` (boolean), by the publisher role only. Setting it also sets `visibility` to `public`, since `official` implies it (`final-design.md` 5.4).
  - `archived` (boolean), by an administrator.
  - `current_version` (an existing version of the package), by an administrator.
  Every change writes, in the same transaction, one audit row naming the package, the field, the previous value, the new value, the acting user and the time. The automatic pointer move of R10 writes one too. A change that sets a field to its current value writes nothing and succeeds.
- R13. Nothing is deleted. Archived packages are not listed (R15) and not runnable (R17), but they still resolve, and their versions and S3 objects stay.

### Reading (report-server, what the app and rigse call)

- R14. `GET /api/v1/packages` answers an anonymous caller with the non-archived `official` packages of the portal named by its required `portal` query parameter.
- R15. `GET /api/v1/packages` presented with an `aud: researcher-dashboard` bearer, verified by REPORT-141's verifier, answers with the non-archived packages of the token's portal that are any of:
  - `official`
  - `public`
  - maintained by the caller (R4)
  - `project`-visible on a project in the caller's allowed project ids
  An invalid or expired bearer is 401, never downgraded to the anonymous answer. The role flags that decide the allowed project ids are read from the portal's database at request time, not from report-server's stored `users` copy. The caller needs no report-server user row. Those portal reads carry a timeout of a few seconds rather than `PortalDbs`' five-minute default, and a portal that does not answer is 503 rather than a hung list.
- R16. Each listed package carries:
  - its catalog id, identity, origin, name, maintainer, visibility, official flag and runnable flag (R17)
  - `project` as `{id, name}` or null, with the name read from the portal
  - `mine`, which is true when the caller administers it
  - its current version's version, checksum, title, description, `urls`, `clue_prepull`, `expected_duration_seconds` and `published_at`
  Both answers are indexed queries on report-server's database: no S3 read and no scan of the table.
- R17. `GET /api/v1/packages/resolve?identity=<identity>&version=<version>`, with the same bearer and visibility rule as R15, answers one version with:
  - its catalog id, identity, version, checksum, `expected_duration_seconds`, `clue_prepull` and `archived`
  - `runnable`, which is true only when the package is not archived and is `official`, or when unreviewed runs are enabled
  A package the caller may not see is 404, the same as one that does not exist. An archived or unrunnable one answers 200 with `runnable: false` and the reason. Unreviewed runs are a report-server setting, off by default, turned on once REPORT-143's storage broker is live. So no rung but `official` can be run until then, whoever calls. rigse presents the launch token the app sent it and checks `runnable` (RIGSE-368).
- R18. CORS on the two read routes.
  - An anonymous `GET` is answered with `Access-Control-Allow-Origin: *`.
  - A bearer request whose `Origin` is in a configured allowlist is answered with that origin echoed and `Vary: Origin`.
  - A bearer request whose `Origin` is not in the allowlist is refused with 403 before any lookup.
  - A request carrying no `Origin`, such as rigse's server-to-server resolve or the CLI, is not a browser and is not origin-checked.
  - An `OPTIONS` preflight is answered for allowlisted origins only, allowing `GET` and the `Authorization` header.
  - Bearer answers carry `Cache-Control: no-store`.
  No other report-server route gains CORS.

### The authored URL profile (the function)

- R19. `POST /derive-profile` is a route on REPORT-141's `researcherDashboard` function, behind its `aud: report-service-functions` auth. The `{portal}` segment and `platform_id` come from the assertion's `iss`, never the body.
- R20. The body is `{class_hash, assignment_fingerprint, assignment_urls}`.
  - `class_hash` is 48 lowercase hex characters.
  - `assignment_fingerprint` is a non-empty opaque string of at most 256 characters.
  - `assignment_urls` is an array of at most 500 strings of at most 2,048 characters each.
  - The whole body is at most 256 KiB, which keeps the queued task under Cloud Tasks' 1 MiB task limit.
  Anything else is 400 and nothing is queued. A valid request is answered 202 once the derivation is queued, and the function holds nothing open while it runs. While the authoring host allowlist (R22) is empty, every request is answered 503 naming it, before validation, and nothing is queued, since the deriver could only refuse every content URL.
- R21. The derivation runs outside the request, because a first-generation HTTPS function is not guaranteed any CPU after it responds. It is retried on failure. It ends in one write of `researcher_dashboard/{portal}/classes/{class_hash}` with the Admin SDK.
- R22. The deriver follows only a URL that names a container: an assignment URL carrying an `activity` or `sequence` query parameter whose value is an absolute URL. That value is the content URL. Every other assignment URL, a CLUE offering URL among them, is taken as it stands and not fetched.
  - A content URL is fetched only if its parsed hostname exactly equals an entry in a configured allowlist of authoring hosts (no suffix match, no userinfo, default port), and only over HTTPS. An `http:` URL on an allowlisted host is fetched as `https:`.
  - A redirect is not followed.
  - A response over 5 MiB, or one not answered within 15 seconds, is a failure for that URL.
  - A content URL outside the allowlist is recorded as refused and never requested.
- R23. From each activity, directly or inside a sequence's `activities`, the deriver emits one interactive URL per interactive embeddable found in `pages[].sections[].embeddables[]` (or `pages[].embeddables[]` if present):
  - For a `ManagedInteractive`: `library_interactive.data.base_url`, followed by `url_fragment` when that is non-empty, which is the URL the Activity Player loads.
  - For a `MwInteractive`: its `url`, skipped when empty.
  URLs are recorded exactly as authored, protocol-relative and fragment included, and de-duplicated. The deriver reads no other field. It does not read authored state, the library interactive's `name`, or CLUE's curriculum JSON, and it holds no table of known interactives, no question-type map and no per-interactive rule.
- R24. The document is written whole, replacing any earlier content. It holds:
  - `platform_id`, which is the `iss`, and which REPORT-143's read rule checks.
  - `assignment_urls`, as given.
  - `interactive_urls`, sorted.
  - `content_urls`, the URLs read successfully.
  - `unread`, a list of `{url, reason}` for content URLs refused or failed.
  - `assignment_fingerprint`.
  - `derived_at` and `requested_at`, both Firestore timestamps.
  - `truncated`, which is true when more than 500 distinct interactive URLs were found and only the first 500 in sorted order were kept.
  A partial fetch still writes, with what was read and the failures in `unread`, so a deleted activity cannot keep a class from ever getting a profile.
- R25. The write is idempotent and ordered by request. The same inputs produce the same document apart from its timestamps. A derivation writes only if the stored document's `requested_at` is not later than its own, checked in a transaction. So two researchers refreshing one class at the same moment converge on the later request, and a slow, older derivation never overwrites a newer one.
- R26. No client can write the profile document: `firestore.rules`' default denial covers the path, and this story adds no rule for it. The deriver never takes a URL from a browser, since only rigse can call it (R19). The rules test asserting that no client can write `classes/{class_hash}` belongs to REPORT-143, which owns the dashboard's rules (Doug, 2026-09-24).

### Configuration

- R27. Every new setting is documented and configured for both environments before the code that reads it deploys.
  - report-server:
    - a map from portal server to the runner bucket that portal's packages are written to, with the dedicated credential (RD-1) that may write `packages/` there. A map that sends two portals to one bucket is refused at boot, since their identities overlap (R2);
    - the CORS origin allowlist;
    - the unreviewed-runs switch, which defaults to off.
  - The function:
    - the authoring host allowlist, as a param in `functions/.env.report-service-{dev,pro}`.
  A publish for a portal with no bucket configured is refused with a reason rather than written anywhere.

## Technical Notes

- **Files on master this story touches**:
  - report-server:
    - migrations for `packages`, `package_versions`, `package_events` and the publisher grant
    - new `ReportServer.Packages` context modules and schemas
    - new controllers under `server/lib/report_server_web/api/v1/`
    - a CORS plug under `server/lib/report_server_web/api/`
    - `router.ex`, `portal_dbs.ex`, `aws.ex`, `config/runtime.exs`, `config/test.exs`
    - tests beside each
  - Function:
    - new `functions/src/researcher-dashboard/derive-profile*.ts`
    - `functions/src/index.ts`
    - `functions/.env.report-service-{dev,pro}`
  - The files REPORT-141 adds, named in its closed spec.
- **`get_allowed_project_ids/2` is used as it stands.** A project admin gets only the projects they administer, not also those they research, and no grant's `expiration_date` is checked (`portal_dbs.ex:198-218`). Both quirks predate this story and govern what the same researcher's runs can read (`final-design.md` 11.2), so the catalog applies the same definition rather than a second one.
- **The catalog's patterns and the runner's grammar differ today.** The runner allows `_` in a name (`runner/server/package-env.js:26`); the catalog does not (R3). RD-4 adopts the identity.
- **Where the other halves are specified**:
  - rigse's `refresh_profile`, the fingerprint, and the run-path resolve that presents the launch token and checks `runnable`: RIGSE-368.
  - The read rule on `classes/{class_hash}`: REPORT-143.
  - cc-data-cli's commands: REPORT-146.
  - The app's matcher and grouping: RD-3.
  - The runner's enforcement: RD-4.

## Verification

Stage 1 ran these probes, which were throwaway and never committed.

- **The authoring API.** Activities 100, 1000, 5000 and 10000 and sequences 100 and 500 were fetched from `authoring.concord.org` with no credential.
  - Every activity nests embeddables at `pages[].sections[].embeddables[]`.
  - Every `ManagedInteractive` had `library_interactive.data.base_url` and a `url_fragment` key, null in all 95 seen.
  - `MwInteractive.url` was protocol-relative in some cases (`//models-resources.concord.org/dataset-sync-wrapper/index.html?...interactive=%2F%2Flab.concord.org...`) and empty in one.
  - Sequence JSON carries `activities[]` with full `pages`.
  - Unknown ids answer 404 with `{"response_type":"ERROR",...}`.
- **Reading the manifest from the upload in memory** with Erlang's `:zip` on OTP 26.
  - `:zip.list_dir/1` gave each entry's uncompressed size from the central directory.
  - A 50 MB `manifest.json` compressed to 48 KB was refused on that size before extraction.
  - A manifest nested under a folder was reported absent, and a non-zip body was refused.
  - `:crypto.hash(:sha256, bin)` produced the same digest as `sha256sum`.
- **The glob matcher's worst case** is a two-pointer `*`-only matcher on Node 22.
  - A 256-character `*a*a*...b` pattern against a 200-character URL took about 0.13 ms.
  - A package at the R8 caps (20 such patterns) against a profile at the R24 cap (500 URLs of 200 characters) took about 0.3 s. That is the bound the caps buy.
  - Real patterns against 500 real-shaped URLs took microseconds per match.
  - The design's measurement of 54 distinct URLs across 35 activities leaves the 500 cap about tenfold headroom.

**Stage 4, the spec's load-bearing assumptions run as throwaway code.**
- **Reading only the manifest, bounded by actual output.** An Elixir reader took the entry's offset and compressed size from `:zip.list_dir/1`'s central directory and inflated it with `:zlib.safeInflate/2`, stopping past 64 KiB.
  - It read the manifest from a `zip -X` archive and from one written by Go's `archive/zip`.
  - The Go archive sets flag `0x8` and leaves the local header's compressed size at 0, which is why the size comes from the central directory.
  - It refused the size-lying entry in 1 ms and refused the 50 MB bomb.
- **The deriver's extraction over live JSON.** A throwaway extractor walked `pages[].sections[].embeddables[]` and a sequence's `activities[]` over four activities and two sequences.
  - 346 interactive instances yielded 38 distinct URLs, 16 of them protocol-relative.
  - Lab interactives distinguished only by fragment stayed distinct (`lab.concord.org/embeddable.html#interactives/itsi/energy-levels/atom-builder.json`).
  - Container detection took an Activity Player URL's `activity=` and `sequence=` values, URL-encoded or not, and left a CLUE URL as it stood.
  - The exact-hostname check refused `authoring.concord.org.evil.example`, `authoring.concord.org@evil.example` and a non-default port.

## Out of Scope

- rigse's `refresh_profile`, the assignment fingerprint, and the run-path resolve call: RIGSE-368.
- The dashboard's Firestore read rules, including the one on `classes/{class_hash}`: REPORT-143.
- cc-data-cli's `package init | run | build | publish` and state commands: REPORT-146.
- The glob matcher's three copies and their shared fixture: RD-3 (app), RD-4 (runner), REPORT-146 (`cc-data package run`).
- Transferring maintenance to another user or project, which the design allows and the story does not ask for an endpoint for.
- Changing `get_allowed_project_ids/2`'s grant semantics.

## Open Questions

### RESOLVED: Judgment call: scope catalog rows to a portal
**Context**: One production report-server serves learn.concord.org and the NGSS portal, whose user and project ids overlap. The design's identity is portal ids with no portal.
**Options considered**:
- A) Add `portal_server` to `packages`, with identity unique per portal and every query confined to the caller's portal. The S3 key stays `packages/<identity>/<version>.zip`, because report-server maps each portal to its own runner bucket and refuses two portals sharing one.
- B) Put the portal in the identity or the S3 key.

**Decision**: A. The collision is real (`report-server.yml:215-219`, and `users` is keyed by `(portal_server, portal_user_id)`), and A fixes it without changing any contract other stories consume: the identity, the S3 key, the result document id and the dataset name all stay as `final-design.md` states them. Recorded as R2 and R27.

### RESOLVED: Judgment call: derive in a Cloud Task, not after the response
**Context**: The design has the function answer 202 and derive asynchronously. `researcherDashboard` is a first-generation HTTPS function (REPORT-141), and such a function is not guaranteed CPU once it has responded, so work started after `res.send` may never finish.
**Options considered**:
- A) Enqueue a Cloud Task to a v2 `onTaskDispatched` worker, as `submitTask` already does with `CloudTasksClient` and OIDC, running the worker directly under the emulator.
- B) Derive inside the request and answer when done.
- C) A Firestore-triggered function over a request document.

**Decision**: A. It keeps the 202 contract, gives retries for free, and reuses a pattern the repo already deploys. B makes rigse hold a request open for the whole fetch, and C adds a collection to the dashboard tree that REPORT-143's named-collection rules would have to account for. Recorded as R21.

### RESOLVED: Judgment call: emit `base_url` plus `url_fragment`
**Context**: The story names `library_interactive.data.base_url`. The live JSON also carries `url_fragment`, an author-set path, query or hash that the Activity Player appends to form the URL it loads.
**Options considered**:
- A) Emit `base_url` followed by `url_fragment` when non-empty.
- B) Emit `base_url` alone.

**Decision**: A. It is the interactive's actual URL, and it is a structural field whose meaning is the same for every interactive, which is the design's line for what the deriver reads. Patterns written with a trailing `*`, as every design example is, match either form. Under B, two interactives differing only by fragment would collapse, which is the fragment case the design measured. Recorded as R23.

### RESOLVED: Judgment call: the allowlist governs what is fetched, and a refusal is recorded
**Context**: The story says the deriver "refuses any host outside a configured allowlist". A portal can assign any external URL, and assignment URLs themselves are never fetched.
**Options considered**:
- A) Check only the content URLs the deriver would fetch. A non-allowlisted one is recorded in `unread` and never requested, and the rest of the profile is written.
- B) Refuse the whole request when any URL is off the allowlist.

**Decision**: A. The allowlist exists to stop the function being a request-forgery surface, which is about what it fetches; B would deny a profile to any class with one unusual assignment. Redirects are not followed, or a redirect would step around the allowlist. Recorded as R22 and R24.

### RESOLVED: Judgment call: a resolve endpoint that refuses to run what the gate forbids
**Context**: rigse resolves a package's checksum and catalog id from the catalog before minting anything, and the story requires that no rung but `official` can be run until the storage broker ships, as "a state the catalog will not let a package reach".
**Options considered**:
- A) `GET /api/v1/packages/resolve`, visible under the same rule as the list, answering `runnable` computed from a report-server switch that is off until REPORT-143's broker is live.
- B) Have rigse filter the list response itself.

**Decision**: A. The catalog computes the gate, so no caller has to remember it. The switch is one setting flipped once, in the order the release plan already fixes. Recorded as R17.

### RESOLVED: Low confidence: how the zip is uploaded
**Options considered**:
- A) The raw body, `Content-Type: application/zip`, with identity-affecting options as query parameters.
- B) `multipart/form-data`.

**Decision**: A. `Plug.Parsers` passes an unknown content type through unread (`endpoint.ex`, `pass: ["*/*"]`), so the controller reads the body with an explicit cap. cc-data-cli has no multipart code (`client.go` only marshals JSON), so either is new there and A is the smaller. Recorded as R5 and R6.

### RESOLVED: Low confidence: the profile document needs `platform_id`
**Context**: `final-design.md` 9's rule for `classes/{class_hash}` reads `rdSamePlatform(resource.data)`, which compares the token's `platform_id` with the document's.
**Decision**: The deriver writes `platform_id`, the verified `iss`. Without it, REPORT-143's rule would deny every researcher's read of an existing profile. Recorded as R24.

### RESOLVED: Who provisions report-server's write access to `packages/` in each runner bucket?
**Context**: report-server writes the zip, but the runner bucket belongs to each environment's runner stack (RD-1, researcher-dashboard repo), in its own AWS account. The staging report-server is in a different account from the staging bucket (`final-design.md` 12). No story grants report-server anything on that bucket. RD-1's IAM passes cover the launcher, the broker's role and the execution role, and REPORT-142 lands before RD-1 in the implementation order.
**Options considered**:
- A) RD-1 gains a fourth IAM item: a dedicated IAM user per runner stack, allowed `s3:PutObject` on `packages/*` and nothing else. Its keys are given to report-server as configuration (R27), which works across accounts with no bucket policy. REPORT-142's publish cannot work in an environment until that exists.
- B) A bucket policy on each runner bucket granting report-server's existing IAM user `packages/*`, cross-account for staging. This widens a credential that already reaches the token-service and output buckets.
- C) Fold the grant into this story as a cloud-formation change, which puts a researcher-dashboard stack change in a report-service story.

**Decision**: A (Doug, 2026-09-24). RD-1 gains a fourth IAM item: a dedicated IAM user per runner stack, limited to `s3:PutObject` on `packages/*`. Its keys are report-server's `PACKAGES_AWS_ACCESS_KEY_ID` and `PACKAGES_AWS_SECRET_ACCESS_KEY`, which are required for any portal in `PACKAGE_BUCKETS`, with no fallback to the server credentials. Publishing in an environment waits on that item. Recorded in R27.

### RESOLVED: How is the publisher role granted?
**Context**: Only a holder of the publisher role may set `official`, which is Concord's endorsement, and the cc-data-studies release pipeline holds it through a service token. report-server has no such role. Its users carry only the portal's three flags, and a portal admin flag on a CI service account would be far too broad.
**Options considered**:
- A) A report-server-side grant, a `package_publisher` flag on report-server's user row, set and cleared only by an operator through a release task (`bin/report_server eval`). No portal role implies it.
- B) Every portal site admin holds it implicitly, and the release pipeline's service user is made a site admin.
- C) A configured list of `portal_server:portal_user_id` holders in report-server's environment.

**Decision**: A, and every portal site admin also holds the role (Doug, 2026-09-24). So the role is the report-server `package_publisher` flag, set only by an operator through a release task, **or** `portal_is_admin`. The release pipeline's service user gets the flag rather than being made a site admin. Recorded as R11.

### RESOLVED: Judgment call: the resolve needs the launch token
**Context**: R17 gives the resolve "the same bearer and visibility rule as R15", and R14 gives the list an anonymous answer. Whether an anonymous resolve should answer official packages was left open.
**Options considered**:
- A) The resolve always needs the launch token, and answers 401 without it.
- B) An anonymous resolve with `?portal=` answers official packages, as the list does.

**Decision**: A. rigse is the resolve's only caller and always presents the app's launch token (RIGSE-368 R17), and the resolve's answer is a run decision rather than a listing. B would add an unauthenticated route nobody calls. Recorded in the implementation spec's "As built" section.

### RESOLVED: Judgment call: a launch token for a user the portal does not know
**Options considered**:
- A) 401, as for an unknown portal.
- B) Treat the caller as holding no roles or grants, and answer official and public packages.

**Decision**: A. A validly signed token naming a user the portal has no row for is a mismatch between rigse and its own database, not an ordinary researcher, and refusing it is the conservative answer. RIGSE-368's requirements were amended to list it.

## Self-Review

Roles: Security Engineer, Senior Engineer (Elixir and Firebase functions), QA Engineer, DevOps Engineer, and the engineer integrating RIGSE-368 and RD-3 against these contracts. Each finding was checked by running code or reading the repo before being recorded. Two concerns were dropped after checking:
- The anonymous answer's `Access-Control-Allow-Origin: *` exposes nothing. The `/api/v1` pipeline uses no cookies or session.
- A browser cannot dodge the origin check by omitting `Origin`. A cross-origin `fetch` always sends it.

### Security Engineer

#### RESOLVED: A zip's declared size does not bound what extracting it costs
A probe patched a 20 MB manifest's declared size to 100 bytes in both zip headers. `:zip.list_dir/1` then reported 100, but `:zip.unzip(bin, [:memory, ...])` still returned all 20,000,008 bytes from a 19,582-byte upload, about a thousandfold. At that ratio a 10 MiB upload could make report-server inflate gigabytes. Fixed: R6 inflates the manifest with a bound on actual output.

#### RESOLVED: The host allowlist needed an exact comparison
"Host in an allowlist" admits a suffix or string match, which `https://authoring.concord.org.evil.example/` or `https://authoring.concord.org@evil.example/` could pass. Fixed: R22 compares the parsed hostname exactly.

### Senior Engineer

#### RESOLVED: Two concurrent publishes of one version could leave S3 holding the loser's bytes
If S3 is written before the insert, both requests pass the existence check and both write the object. The unique index then rejects the second row, but its bytes have already replaced the first's. The catalog's checksum no longer matches the object, and every run of that version fails its checksum. Checked on the port-3406 MySQL (InnoDB): with one transaction holding an uncommitted insert of a key, a second insert of that key blocked 3.4 s until the first committed, then failed with `1062 Duplicate entry`. Fixed: R9 inserts, writes S3, then commits.

#### RESOLVED: The catalog read would inherit a five-minute portal timeout
R15 reads role flags and grants from the portal on every bearer request, and `PortalDbs` defaults to a 300,000 ms query timeout (`portal_dbs.ex:9`). `filter_options.ex:198` already passes a short one for the same kind of call. Fixed: R15.

### DevOps Engineer

#### RESOLVED: One bucket per report-server would collide the two production portals
The production task serves learn.concord.org and the NGSS portal (`report-server.yml:215-219`), and R2 makes their identities overlap. With one configured bucket, both would write `packages/users/136/...` into it. Fixed: R27 maps each portal to its own bucket and refuses a shared one.

#### RESOLVED: The derivation request could exceed Cloud Tasks' task size
R20 allowed 500 URLs of 2,048 characters, about 1 MB before JSON overhead. R21 carries the request in a Cloud Task, whose maximum size is 1 MiB (Cloud Tasks quotas page, checked 2026-09-24). Fixed: R20 caps the body at 256 KiB.

### Integrator of RIGSE-368 (found while speccing RIGSE-368)

#### RESOLVED: rigse could not learn `clue_prepull` from the resolve
RIGSE-368 mints the CLUE class token only when a package declares `clue_prepull` (`final-design.md` 13), and the resolve is the only place rigse learns about a package version. The resolve answered no `clue_prepull`, although it is a column of the `package_versions` row it already joins; the list carries it, but only for each package's current version, and rigse must also run a non-current one. Fixed: R17's answer includes `clue_prepull` from the resolved version (Doug, 2026-09-24).
