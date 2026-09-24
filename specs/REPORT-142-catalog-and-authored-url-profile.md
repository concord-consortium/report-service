# report-service: the catalog and the authored URL profile

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-142

**Status**: **Closed**

## Overview

report-server gains the package catalog: two tables, a publish endpoint that cc-data-cli calls with the researcher's own cc-data token, state-change endpoints with an audit trail, a read endpoint the dashboard app calls anonymously or with its launch token, and a resolve endpoint rigse calls on the run path. The report-service function gains `POST /derive-profile`, which takes the assignment URLs rigse supplies, follows the Activity Player ones to their public activity JSON, and writes the class's authored URL profile to Firestore with the Admin SDK. Together they are what a package declares at publish and what the page matches it against at launch.

A researcher packages an analysis and publishes it with the cc-data login they already have. It lands private to them, and nobody needs AWS access or a maintainer's help. They can later share it with a project or with everyone, and Concord can mark reviewed packages as official. Every such change is recorded with who made it and what it replaced. Rolling back a bad version means pointing the package at the previous version, and nothing is deleted.

When a researcher opens a class, the dashboard lists only the packages that make sense for that class. It decides this by matching each package's declared URL patterns against the activities and interactives the class was assigned. report-service works out that list of URLs server-side from public authoring data, once per class rather than once per browser tab. Until per-researcher storage credentials ship (REPORT-143), only official packages can actually be run.

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

### Verification

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

### As built (2026-09-24)

Implemented in eight reviewed commits on this branch (`0ef193d` to `b3c38b1`), one per step, each put through the `cc-code-review` loop until a pass reported nothing actionable. Where the code departs from the plan above, or settles something the plan left open, it is recorded here; the judgment calls behind the larger ones are RESOLVED questions below.

#### report-server

- **Identity.** An origin id is at most 18 digits (`users/<1..18 digits>`), so it always fits the portal's integer ids and the S3 key stays short. `Identity.parse/1` splits and validates an identity, and the state-change route rebuilds and checks one with it.
- **The manifest.** `Manifest.project/2` takes the archive's file entries as well as the manifest, so the entrypoint is checked in one place, where the plan had `project/1`. Beyond R7:
  - `version` is at most 64 characters and refuses leading zeros, as semver does.
  - `description` is optional, since its column is nullable and R7 gives only its length and one-line rule.
  - Unknown keys inside `urls` are refused, because a misspelt `any` would otherwise make a package apply everywhere. Unknown top-level keys are still ignored.
  - Lengths are counted in code points, as the varchar columns count them, not in graphemes.
- **The archive.** An entry named with a backslash separator or a drive letter counts as absolute too. `build.sh` runs the Go writer itself (Go must be installed) rather than keeping it in comments, so both fixtures rebuild with one command.
- **Publish.**
  - `?origin=` accepts only `projects/<id>`, since a user origin is always the caller's own.
  - A `Content-Length` is required (400 without). Bandit reads a `Transfer-Encoding: chunked` body whole whatever `read_body`'s `:length`, so the 10 MiB cap is enforced on the declared length first.
  - `official=true` from a publisher is honoured on any publish, not only the first, and still requires administering the package (R11's "on publish or afterwards"). It writes audit rows for `official`, `visibility` and any cleared `project_id`, and the pointer decision is taken from the visibility the package had before.
  - The portal is asked for project grants only when the origin or the existing maintainer is a project; a portal that does not answer is 503.
  - The package row is read, then locked with `FOR UPDATE` or inserted. A locking read of an absent row takes a gap lock, and two such reads deadlock both inserts, so a missing row is inserted without one and a unique conflict locks the winner's row.
  - The two S3 puts carry a 5-second connect and 15-second receive timeout, under InnoDB's 50-second lock wait, and the publish transaction has a 120-second timeout. A lock wait timeout (1205) or deadlock (1213) answers 503 asking the caller to retry, for publish and state changes alike.
  - The portal reads go through a `:packages, :portal` seam (`PackagesPortalStub` in tests), and the store through `:packages, :store` (`PackagesMemoryStore`).
  - The 201 body also carries `official`.
- **State changes.**
  - `official` needs the publisher role only, not administering the package, and clearing it leaves the package public.
  - An official package cannot leave `public` (422 "clear official first"), since official implies public.
  - Setting `official` clears any `project_id`, and a `project` visibility change writes two audit rows, `visibility` and `project_id`.
  - `project_id` is bounded to the column's signed 32-bit range (400 beyond it).
  - An unknown state is 404 and a malformed value 400. Authorization is checked on an unlocked read, since the maintainer and grants cannot change within this story.
- **Reading and resolving.**
  - `resolve` needs the launch token (401 without), as R17 describes it being called.
  - The anonymous `?portal=` takes a host or a portal URL, both through `get_server_for_portal_url/1`'s report-host aliases. An unknown portal answers an empty list.
  - A launch token whose `uid` the portal does not know, or whose portal report-server has no database for, is 401.
  - The list is ordered by catalog id; the app orders for display.
  - The role-flag SQL is one `@role_flags` attribute shared by `get_user_info/2` and the new `get_user_roles/3`.
  - `portal_fixture.sql` gains `roles`, `roles_users` and three users, so `get_user_roles/3` and `get_project_names/3` are tested against MySQL.

#### The function

- **The deriver.**
  - `fetchTimeoutMs` is an optional dependency so the timeout test need not wait 15 seconds.
  - `content_urls` and `unread` record each content URL as the assignment named it, not the HTTPS-rewritten one, and both are sorted, so a re-run is identical whatever order the fetches finish in.
  - A timeout is not retried. A network error, before the headers or partway through the body, and a 5xx are retried once, and the body of every non-200 answer is cancelled so its connection is released.
  - The fixtures are trimmed copies of live authoring JSON (activities 100 and 1000, and the first three activities of sequence 100), with the expected URLs computed from them independently in Python. No committed script regenerates them.
- **The route and worker.**
  - `researcherDashboardApp` takes a second deps factory for `/derive-profile` rather than widening `RunPackageDeps`, and `run-package.test.ts` passes one that throws.
  - `enqueueDerivation` sits in `derive-profile-worker.ts` beside `runDerivation`. Under `FUNCTIONS_EMULATOR` it runs the derivation directly, as `submitTask` does.
  - `RD_AUTHORING_HOSTS` is comma-separated, trimmed and lowercased.
  - An empty `assignment_urls` is accepted, so a class with no assignments gets an empty profile.
  - A write proceeds when the stored `requested_at` is not later than the task's, so a retried task rewrites its own derivation. `requested_at` is the function's clock when the request arrives.

- **Configuration.** A blank `PACKAGES_AWS_*` value fails at boot as a missing one does. `RD_AUTHORING_HOSTS` is `authoring.lara.staging.concord.org,authoring.concord.org` for report-service-dev (the staging host checked to answer 200 for activity JSON) and `authoring.concord.org` for pro. The `PORTAL_PUBLIC_KEYS` paragraph in report-server's README now covers the catalog's launch tokens too.
- **Review.** Every finding the `cc-code-review` passes raised was accepted and fixed; none was rejected.
- **Later specs.** RIGSE-368's requirements were amended on its branch (`553a9e381`) for the `/derive-profile` 202 body `{success: true, queued: true}`, its 503 while `RD_AUTHORING_HOSTS` is empty, and the resolve's 401 without a launch token or for a `uid` the portal does not know. rigse's handling was already right: anything but a 202 is a 502.

#### Verification

- **report-server:** the full `mix test` suite passes (1183 tests), and `mix compile --warnings-as-errors` is clean.
- **The function:** the full `npm test` suite passes (656 tests), with `tsc` and `tslint` clean, and a throwaway `tsc` build's `index.js` exports `deriveProfileWorker`.
- **Not run:** no deploy was made and nothing ran against staging, so a live S3 put, a live Cloud Task and a real Firestore write remain unexercised. The staging runner stack's `packages/*` user (RD-1's fourth IAM item) does not exist yet.

#### Checked against both specs

Each of R1 to R27 was compared with the code after the last step, along with the Jira story's "Done when" and each step's test list. Nothing was missing; the departures are the ones listed above.

#### What blocks deployment

- **REPORT-141 merges first.** This branch stacks on it (PR #429, in review), for `PortalTokenPlug`, `PORTAL_PUBLIC_KEYS` and the `researcherDashboard` function.
- **report-server's stack.** cloud-formation's `fargate/report-server.yml` does not yet carry `PACKAGE_BUCKETS`, `PACKAGES_AWS_ACCESS_KEY_ID`, `PACKAGES_AWS_SECRET_ACCESS_KEY`, `PACKAGES_CORS_ORIGINS` or `PACKAGES_UNREVIEWED_RUNS`, nor REPORT-141's `PORTAL_PUBLIC_KEYS`. It lives outside this repository. cloud-formation's `REPORT-142-report-server-catalog-settings` branch (`0f05ec8`, unpushed) adds them as parameters, each defaulting to off; each environment still needs a template update and its values. Unset, report-server boots and the catalog answers, but no portal can publish and no launch token verifies.
- **Migrations.** `bin/report_server eval "ReportServer.Release.migrate"` must run before the new image serves, for the three catalog tables and `users.package_publisher`.
- **RD-1's fourth IAM item.** Publishing in an environment needs that runner stack's `packages/*`-only IAM user, whose keys become `PACKAGES_AWS_*`. It does not exist yet, for staging or production.
- **The app's origin.** `PACKAGES_CORS_ORIGINS` needs the dashboard app's origins, which RD-1 and RD-3 settle. Until they are set, only the anonymous list and rigse's server-to-server resolve work.
- **Portal keys.** Nothing verifies a launch token until each portal's key is in `PORTAL_PUBLIC_KEYS`, which is REPORT-141's blocker too.
- **Firestore rules.** The class profile document is written but no client can read it until REPORT-143 ships the dashboard's read rules. That blocks RD-3's use of it, not this deploy.
- **Cloud Tasks from `researcherDashboard`: checked, not a blocker (2026-09-24).** In both projects `submitTask` and `api` run as the App Engine default service account, which holds `roles/editor` (so `cloudtasks.tasks.create` and `iam.serviceAccounts.actAs`), and `submitTask` already enqueues to `taskWorker` with an OIDC token for that account. `researcherDashboard` sets no service account, so it runs as the same one. The `deriveProfileWorker` queue does not exist yet in either project; Firebase creates it on the worker's first deploy.
- **`PACKAGES_UNREVIEWED_RUNS` stays unset** until REPORT-143's storage broker is live and RD-1's third pass has taken S3 off the execution role.

## Out of Scope

- rigse's `refresh_profile`, the assignment fingerprint, and the run-path resolve call: RIGSE-368.
- The dashboard's Firestore read rules, including the one on `classes/{class_hash}`: REPORT-143.
- cc-data-cli's `package init | run | build | publish` and state commands: REPORT-146.
- The glob matcher's three copies and their shared fixture: RD-3 (app), RD-4 (runner), REPORT-146 (`cc-data package run`).
- Transferring maintenance to another user or project, which the design allows and the story does not ask for an endpoint for.
- Changing `get_allowed_project_ids/2`'s grant semantics.

## Decisions

### Scope catalog rows to a portal
**Context**: One production report-server serves learn.concord.org and the NGSS portal, whose user and project ids overlap. The design's identity is portal ids with no portal.
**Options considered**:
- A) Add `portal_server` to `packages`, with identity unique per portal and every query confined to the caller's portal. The S3 key stays `packages/<identity>/<version>.zip`, because report-server maps each portal to its own runner bucket and refuses two portals sharing one.
- B) Put the portal in the identity or the S3 key.

**Decision**: A. The collision is real (`report-server.yml:215-219`, and `users` is keyed by `(portal_server, portal_user_id)`), and A fixes it without changing any contract other stories consume: the identity, the S3 key, the result document id and the dataset name all stay as `final-design.md` states them. Recorded as R2 and R27.

---

### Derive in a Cloud Task, not after the response
**Context**: The design has the function answer 202 and derive asynchronously. `researcherDashboard` is a first-generation HTTPS function (REPORT-141), and such a function is not guaranteed CPU once it has responded, so work started after `res.send` may never finish.
**Options considered**:
- A) Enqueue a Cloud Task to a v2 `onTaskDispatched` worker, as `submitTask` already does with `CloudTasksClient` and OIDC, running the worker directly under the emulator.
- B) Derive inside the request and answer when done.
- C) A Firestore-triggered function over a request document.

**Decision**: A. It keeps the 202 contract, gives retries for free, and reuses a pattern the repo already deploys. B makes rigse hold a request open for the whole fetch, and C adds a collection to the dashboard tree that REPORT-143's named-collection rules would have to account for. Recorded as R21.

---

### Emit `base_url` plus `url_fragment`
**Context**: The story names `library_interactive.data.base_url`. The live JSON also carries `url_fragment`, an author-set path, query or hash that the Activity Player appends to form the URL it loads.
**Options considered**:
- A) Emit `base_url` followed by `url_fragment` when non-empty.
- B) Emit `base_url` alone.

**Decision**: A. It is the interactive's actual URL, and it is a structural field whose meaning is the same for every interactive, which is the design's line for what the deriver reads. Patterns written with a trailing `*`, as every design example is, match either form. Under B, two interactives differing only by fragment would collapse, which is the fragment case the design measured. Recorded as R23.

---

### The allowlist governs what is fetched, and a refusal is recorded
**Context**: The story says the deriver "refuses any host outside a configured allowlist". A portal can assign any external URL, and assignment URLs themselves are never fetched.
**Options considered**:
- A) Check only the content URLs the deriver would fetch. A non-allowlisted one is recorded in `unread` and never requested, and the rest of the profile is written.
- B) Refuse the whole request when any URL is off the allowlist.

**Decision**: A. The allowlist exists to stop the function being a request-forgery surface, which is about what it fetches; B would deny a profile to any class with one unusual assignment. Redirects are not followed, or a redirect would step around the allowlist. Recorded as R22 and R24.

---

### A resolve endpoint that refuses to run what the gate forbids
**Context**: rigse resolves a package's checksum and catalog id from the catalog before minting anything, and the story requires that no rung but `official` can be run until the storage broker ships, as "a state the catalog will not let a package reach".
**Options considered**:
- A) `GET /api/v1/packages/resolve`, visible under the same rule as the list, answering `runnable` computed from a report-server switch that is off until REPORT-143's broker is live.
- B) Have rigse filter the list response itself.

**Decision**: A. The catalog computes the gate, so no caller has to remember it. The switch is one setting flipped once, in the order the release plan already fixes. Recorded as R17.

---

### How the zip is uploaded
**Options considered**:
- A) The raw body, `Content-Type: application/zip`, with identity-affecting options as query parameters.
- B) `multipart/form-data`.

**Decision**: A. `Plug.Parsers` passes an unknown content type through unread (`endpoint.ex`, `pass: ["*/*"]`), so the controller reads the body with an explicit cap. cc-data-cli has no multipart code (`client.go` only marshals JSON), so either is new there and A is the smaller. Recorded as R5 and R6.

---

### The profile document needs `platform_id`
**Context**: `final-design.md` 9's rule for `classes/{class_hash}` reads `rdSamePlatform(resource.data)`, which compares the token's `platform_id` with the document's.
**Decision**: The deriver writes `platform_id`, the verified `iss`. Without it, REPORT-143's rule would deny every researcher's read of an existing profile. Recorded as R24.

---

### Who provisions report-server's write access to `packages/` in each runner bucket?
**Context**: report-server writes the zip, but the runner bucket belongs to each environment's runner stack (RD-1, researcher-dashboard repo), in its own AWS account. The staging report-server is in a different account from the staging bucket (`final-design.md` 12). No story grants report-server anything on that bucket. RD-1's IAM passes cover the launcher, the broker's role and the execution role, and REPORT-142 lands before RD-1 in the implementation order.
**Options considered**:
- A) RD-1 gains a fourth IAM item: a dedicated IAM user per runner stack, allowed `s3:PutObject` on `packages/*` and nothing else. Its keys are given to report-server as configuration (R27), which works across accounts with no bucket policy. REPORT-142's publish cannot work in an environment until that exists.
- B) A bucket policy on each runner bucket granting report-server's existing IAM user `packages/*`, cross-account for staging. This widens a credential that already reaches the token-service and output buckets.
- C) Fold the grant into this story as a cloud-formation change, which puts a researcher-dashboard stack change in a report-service story.

**Decision**: A (Doug, 2026-09-24). RD-1 gains a fourth IAM item: a dedicated IAM user per runner stack, limited to `s3:PutObject` on `packages/*`. Its keys are report-server's `PACKAGES_AWS_ACCESS_KEY_ID` and `PACKAGES_AWS_SECRET_ACCESS_KEY`, which are required for any portal in `PACKAGE_BUCKETS`, with no fallback to the server credentials. Publishing in an environment waits on that item. Recorded in R27.

---

### How is the publisher role granted?
**Context**: Only a holder of the publisher role may set `official`, which is Concord's endorsement, and the cc-data-studies release pipeline holds it through a service token. report-server has no such role. Its users carry only the portal's three flags, and a portal admin flag on a CI service account would be far too broad.
**Options considered**:
- A) A report-server-side grant, a `package_publisher` flag on report-server's user row, set and cleared only by an operator through a release task (`bin/report_server eval`). No portal role implies it.
- B) Every portal site admin holds it implicitly, and the release pipeline's service user is made a site admin.
- C) A configured list of `portal_server:portal_user_id` holders in report-server's environment.

**Decision**: A, and every portal site admin also holds the role (Doug, 2026-09-24). So the role is the report-server `package_publisher` flag, set only by an operator through a release task, **or** `portal_is_admin`. The release pipeline's service user gets the flag rather than being made a site admin. Recorded as R11.

---

### The resolve needs the launch token
**Context**: R17 gives the resolve "the same bearer and visibility rule as R15", and R14 gives the list an anonymous answer. Whether an anonymous resolve should answer official packages was left open.
**Options considered**:
- A) The resolve always needs the launch token, and answers 401 without it.
- B) An anonymous resolve with `?portal=` answers official packages, as the list does.

**Decision**: A. rigse is the resolve's only caller and always presents the app's launch token (RIGSE-368 R17), and the resolve's answer is a run decision rather than a listing. B would add an unauthenticated route nobody calls. Recorded in the implementation spec's "As built" section.

---

### A launch token for a user the portal does not know
**Options considered**:
- A) 401, as for an unknown portal.
- B) Treat the caller as holding no roles or grants, and answer official and public packages.

**Decision**: A. A validly signed token naming a user the portal has no row for is a mismatch between rigse and its own database, not an ordinary researcher, and refusing it is the conservative answer. RIGSE-368's requirements were amended to list it.

---

### A zip's declared size does not bound what extracting it costs
**Context**: A probe patched a 20 MB manifest's declared size to 100 bytes in both zip headers. `:zip.list_dir/1` then reported 100, but `:zip.unzip(bin, [:memory, ...])` still returned all 20,000,008 bytes from a 19,582-byte upload, about a thousandfold. At that ratio a 10 MiB upload could make report-server inflate gigabytes.

**Decision**: Fixed: R6 inflates the manifest with a bound on actual output.

---

### The host allowlist needed an exact comparison
**Context**: "Host in an allowlist" admits a suffix or string match, which `https://authoring.concord.org.evil.example/` or `https://authoring.concord.org@evil.example/` could pass.

**Decision**: Fixed: R22 compares the parsed hostname exactly.

---

### Two concurrent publishes of one version could leave S3 holding the loser's bytes
**Context**: If S3 is written before the insert, both requests pass the existence check and both write the object. The unique index then rejects the second row, but its bytes have already replaced the first's. The catalog's checksum no longer matches the object, and every run of that version fails its checksum. Checked on the port-3406 MySQL (InnoDB): with one transaction holding an uncommitted insert of a key, a second insert of that key blocked 3.4 s until the first committed, then failed with `1062 Duplicate entry`.

**Decision**: Fixed: R9 inserts, writes S3, then commits.

---

### The catalog read would inherit a five-minute portal timeout
**Context**: R15 reads role flags and grants from the portal on every bearer request, and `PortalDbs` defaults to a 300,000 ms query timeout (`portal_dbs.ex:9`). `filter_options.ex:198` already passes a short one for the same kind of call.

**Decision**: Fixed: R15.

---

### One bucket per report-server would collide the two production portals
**Context**: The production task serves learn.concord.org and the NGSS portal (`report-server.yml:215-219`), and R2 makes their identities overlap. With one configured bucket, both would write `packages/users/136/...` into it.

**Decision**: Fixed: R27 maps each portal to its own bucket and refuses a shared one.

---

### The derivation request could exceed Cloud Tasks' task size
**Context**: R20 allowed 500 URLs of 2,048 characters, about 1 MB before JSON overhead. R21 carries the request in a Cloud Task, whose maximum size is 1 MiB (Cloud Tasks quotas page, checked 2026-09-24).

**Decision**: Fixed: R20 caps the body at 256 KiB.

---

### Rigse could not learn `clue_prepull` from the resolve
**Context**: RIGSE-368 mints the CLUE class token only when a package declares `clue_prepull` (`final-design.md` 13), and the resolve is the only place rigse learns about a package version. The resolve answered no `clue_prepull`, although it is a column of the `package_versions` row it already joins; the list carries it, but only for each package's current version, and rigse must also run a non-current one.

**Decision**: Fixed: R17's answer includes `clue_prepull` from the resolved version (Doug, 2026-09-24).

---

### A publish must declare its Content-Length
**Context**: The plan capped the upload with `read_body(conn, length: 10 MiB)`. Review found that Bandit reads a `Transfer-Encoding: chunked` body whole whatever `:length` says (`deps/bandit/lib/bandit/http1/socket.ex`), so a chunked upload of any size would be held in memory before the cap applied.
**Options considered**:
- A) Require `Content-Length`, refuse a declared length over 10 MiB before reading, and keep `read_body`'s `:length` as the backstop.
- B) Read the body in chunks with a running total, accepting chunked uploads.

**Decision**: A. cc-data-cli's Go client sends a `Content-Length` for a `bytes.Reader` body, so no real caller is refused, and A is one header check where B is a read loop. Built in the publish step.

---

### `official=true` on a later publish
**Context**: R9 describes `official=true` only as a first publish creating the package official and public. R11 says a publisher may set `official` "on publish or afterwards", and the plan made it a no-op on an existing package.
**Options considered**:
- A) Honour it on any publish, with the same audit rows as the state change, still requiring the caller to administer the package.
- B) Refuse it on an existing package, pointing at the state change.
- C) Accept and ignore it.

**Decision**: A. It matches R11, and the cc-data-studies release pipeline can publish a new official version in one call. C answered 201 while dropping the flag, which review caught. The pointer decision is taken from the visibility before the change, so a private package made official on this publish still moves its pointer.

---

### What setting and clearing `official` touch
**Options considered**:
- A) `official` is the publisher role's alone, needs no administration of the package, implies `public` and clears any `project_id`. Clearing it leaves the package public, and an official package cannot leave `public` (422).
- B) Require the publisher to administer the package too, and restore the previous visibility on clearing.

**Decision**: A. R11 says holding the role "does not make anyone a maintainer" and R12 gives `official` to "the publisher role only", so B would stop Concord endorsing a researcher's package without taking it over. Restoring a previous visibility would need it stored somewhere other than the audit trail, and leaving it public is the conservative reading of an endorsement being withdrawn.

---

### Locking the package row, and lock conflicts
**Context**: Publish holds the package's row lock across two S3 puts. The plan's `find_or_insert_package` did not say how a missing row is created under concurrency.
**Options considered**:
- A) Read without a lock. Lock an existing row with `FOR UPDATE`, or insert a missing one and, on a unique conflict, lock the winner's row. Bound the S3 puts under InnoDB's 50-second lock wait, and answer a lock wait timeout or a deadlock with a retryable 503.
- B) `SELECT ... FOR UPDATE` first, then insert when absent.
- C) `INSERT ... ON DUPLICATE KEY` then lock.

**Decision**: A. Under REPEATABLE READ, B's locking read of an absent row takes a gap lock, and two concurrent first publishes then deadlock on their inserts. C burns an auto-increment id on every publish of an existing package, and `on_conflict: :nothing` hides errors other than the duplicate. The 503 tells a client the conflict is transient rather than surfacing a 500.

---

### How strict the manifest is beyond R7
**Options considered**:
- A) Refuse unknown keys inside `urls`, cap `version` at 64 characters with no leading zeros, make `description` optional, and count lengths in code points.
- B) Apply R7 literally.

**Decision**: A. A misspelt `urls` group would otherwise leave a package offered on every class. A version is an S3 key segment and `s3_key` is a varchar(255). Leading zeros would let `1.0.6` and `01.0.6` be two versions. The description column is nullable. MySQL's varchar counts code points, and a grapheme count let a 200-grapheme title of combining characters overflow its column. Unknown top-level keys are still ignored, as R7 says.

---

### The deriver's retry and timeout policy
**Options considered**:
- A) Retry a network error (before the headers or partway through the body) or a 5xx once. Never retry a timeout, and cancel the body of every non-200 answer.
- B) Retry every failure once.

**Decision**: A. A timeout already spent 15 seconds, and retrying it doubles the worst case of a derivation that Cloud Tasks will retry whole anyway. A dropped connection is the transient case a retry is for. An unread body holds its undici connection until garbage collection.

---

### The app's deps for `/derive-profile`
**Options considered**:
- A) `researcherDashboardApp(deps, deriveDeps)`, a second factory.
- B) Widen `RunPackageDeps` to carry the enqueue seam.

**Decision**: A. The two routes share only the auth middleware's keys, which the first factory already provides. B would make every `/run-package` test construct derive-profile deps it never uses.

---

### An `optional` mode on REPORT-141's `PortalTokenPlug` rather than a second plug
**Options considered**:
- A) Add `optional: true`: no header passes, and a bad header is 401.
- B) A separate `OptionalPortalTokenPlug`.

**Decision**: A. The verification is the same code, and the one behavior that differs, a missing header, is one clause. A second plug would be a second place to get R15's "never downgrade a bad bearer to anonymous" wrong.

---

### S3 writes inside the database transaction
**Options considered**:
- A) Insert, put both objects, then commit.
- B) Put first, then insert.
- C) Conditional `PutObject` with `If-None-Match: *`.

**Decision**: A. The requirements' Self-Review showed B lets a concurrent twin overwrite the winner's object. C would need the `aws` library's support for a header this repo has never sent, and would still leave a row-less object on insert failure. A holds a database transaction open across two small PUTs of at most 10 MiB, which is acceptable for an operation a researcher performs by hand.

---

### Fake `fetch` rather than Node's global in tests
**Decision**: `fetchImpl` is injected. Jest 24's default jsdom environment has no global `fetch`, and a live network call would make the suite depend on the authoring server. The stage 4 JSON, trimmed, is the fixture, so the tests read what the service really returns.

---

### The worker module could not be imported under the repo's Jest
**Context**: The plan put `onTaskDispatched` and `writeProfile` in one module. A scratch test importing `firebase-functions/v2/tasks` failed with `Cannot find module 'firebase-functions/v2/tasks'` under Jest 24, which predates subpath exports (the repo maps only `firebase-functions/params`, `package.json` `moduleNameMapper`). A second scratch test showed `@google-cloud/tasks` and `import * as admin from "firebase-admin"` load. So every test of the worker would have failed to run.

**Decision**: Fixed: the wrapper moves to `derive-profile-task.ts`, which only `index.ts` imports.

---

### The concurrent-publish test could not show the lock it claimed to
**Context**: `ConnCase`'s sandbox in shared mode gives both processes one connection, so the second publish waits on the connection, not the unique index. The test still catches an implementation that writes S3 before the insert, but not the InnoDB behavior.

**Decision**: Fixed: the test is described as asserting the outcome, and the lock itself rests on the direct MySQL check.

---

### `:json` is not the repo's migration type for JSON columns
**Context**: Every JSON column in `server/priv/repo/migrations` is declared `:map` (for example `create_export_scratch.exs:14`, whose comment says it compiles to a MySQL `json` column), with a `:map` schema field. Fixed in the first step.
