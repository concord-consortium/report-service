# report-service: one home for the package rules and applicability

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-167

**Status**: **Closed**

## Overview

report-server becomes the only place that decides whether a package is valid and whether it applies to a class. It gains a validate route that runs every publish check without publishing, an applies route holding the system's only URL glob matcher, and applicability marked on the package list. The `api` function gains a `derive_urls` route so report-server can follow assignment URLs with the existing deriver. cc-data, the dashboard app and the runner then ask one server and get one answer, and publish adopts the runner's own limits (at most 7,200 declared seconds, no symbolic links), so nothing report-server accepts is refused on a VM.

## Requirements

### The derive route on the `api` function

- **R1.** `POST /derive_urls` on the `api` function, behind `bearerTokenAuth` and `requireHeaderBearer` as `bulk_read` is, takes `{assignment_urls: [string]}` and answers `{success: true, interactive_urls, unread, truncated}` from `deriveProfile`, with the `RD_AUTHORING_HOSTS` allowlist parsed by `parseAllowedHosts`. No second copy of the walk.
- **R2.** Its body bounds are `/derive-profile`'s: at most 500 assignment URLs, each at most 2,048 characters (`MAX_URL_LENGTH`), and a body of at most 256 KiB; outside them is a 400 naming the problem. With `RD_AUTHORING_HOSTS` empty it answers 503.
- **R3.** It writes nothing and takes no scope id or class hash; the `classes/{class_hash}` profile stays the rigse and app path's alone.
- **R4.** The `api` function's `GET /` method list names it.

### The only glob matcher (report-server)

- **R5.** `ReportServer.Packages.Patterns` holds the matcher: a pattern matches the whole URL, `*` matches any run of characters including none and including `/`, and every other character, `?` included, matches only itself. It is the only glob matcher in the system.
- **R6.** It is a segment matcher (split on `*`, first and last literal as prefix and suffix, middle literals leftmost in order with `:binary.match/2`), linear in the URL, where the runner's two-pointer matcher is quadratic (about 130 seconds for 20 worst-case patterns against 1,000 URLs). The applies route matches at most 2,000 URLs of at most 2,048 code points; a test runs the worst shapes there over ASCII and four-byte code points and requires an answer within 2 seconds.
- **R7.** Applicability follows the runner's rules: every `all` pattern matches some URL; when `any` is non-empty, at least one `any` pattern does; no `none` pattern does. A package declaring no patterns applies to every scope. Refusals use the runner's words: `no URL in this class matches the required pattern <p>`, `no URL in this class matches any of <p1>, <p2>`, `a URL in this class matches the excluded pattern <p>`.
- **R8.** `fixtures/url-patterns.json` (27 `matches` and 12 `applies` cases, from RD-4 pass 2) is committed, and a test asserts every case.

### The validate route (report-server)

- **R9.** `POST /api/v1/packages/validate` (`:api_authenticated`) takes what publish takes: the raw zip with `Content-Type: application/zip` and a declared `Content-Length`, and the optional `origin` and `official` query parameters.
- **R10.** It runs every check publish runs, in publish's order and with publish's codes and messages: content type and length, the publisher role for `official=true`, the archive, the manifest, the origin, the project grants, and administration of the package (for a new package, against the maintainer it would get). Two conditions that decide only whether the zip can be published now are reported rather than refused: the version is already published, and the portal has no bucket.
- **R11.** It writes nothing: no `packages`, `package_versions` or `package_events` row, no S3 object, no `FOR UPDATE` read.
- **R12.** A passing validate answers 200 `{identity, version, checksum, visibility, already_published, publishing_unavailable}`. `visibility` is the existing package's, `private` for a new one, or `public` when `official=true` is accepted. `already_published` is true when publish would refuse with `ALREADY_EXISTS`. `publishing_unavailable` is `null`, or publish's message when the portal has no bucket ("publishing is not configured for <server>"). Publish still refuses both.
- **R13.** It is a separate route, not a `dry_run` parameter, because publish ignores unknown parameters and an older server would publish for real.

### The applies route (report-server)

- **R14.** `POST /api/v1/packages/applies` (`:api_authenticated`, so a cc-data token or the runner's dashboard token) takes JSON `{urls: {all, any, none}, assignment_urls, scope_urls}`.
  - `urls` is required and must be an object; absent or `null` is 400. It is checked with publish's pattern rules (only the three keys, at most 20 patterns, each non-empty, at most 256 characters, no whitespace or control characters). A group that is absent or `null` is empty, since Go marshals a nil slice as `null`.
  - `assignment_urls` (optional): its bounds are R2's and live only in the function; a 400 from `derive_urls` is answered as 400 `BAD_REQUEST` with the function's message.
  - `scope_urls` (optional): at most 1,000 strings of at most 2,048 code points.
  - Any other body problem is 400 `BAD_REQUEST` naming it.
- **R15.** Non-empty `assignment_urls` go to `derive_urls` through `ReportServer.ReportService`. The URLs matched are `assignment_urls`, the derived `interactive_urls` and `scope_urls` together, which is the set the runner matches.
- **R16.** It answers 200 `{applies, reason, interactive_urls, unread, truncated}`; `reason` is R7's message or `null`, and the other three are the deriver's or `[]`, `[]` and `false`.
- **R17.** Neither new route ever answers 404, since cc-data reads a 404 as "not deployed" and skips the check. A derive call that fails, times out, or answers anything but 200 or 400 is 503 `SERVICE_UNAVAILABLE`. report-server waits 270 seconds: past the deriver's 240-second budget, inside cc-data's 5 minutes.
- **R18.** It writes nothing and takes no scope id or class hash.

### Applicability on the package list (report-server)

- **R19.** `POST /api/v1/packages/list` (`:api_catalog`, anonymous with `?portal=` or with the access token) takes `{scope_urls}` (required, possibly empty; R14's bounds) and answers `GET /api/v1/packages`'s rows with `applies` added, computed with R7 over each package's current version's `urls`. It calls no deriver. `CatalogCors` answers a preflight that does not ask for `authorization` from any origin, and allows `POST` and `content-type`.
- **R20.** `GET /api/v1/packages` answers exactly as before, without `applies`.

### The runner's stricter rules at publish (report-server)

- **R21.** `expected_duration_seconds` is at most 7,200 at publish (and so at validate); 7,201 is `UNPROCESSABLE`. Versions already published above it stay; the runner refuses them.
- **R22.** An archive holding a symbolic-link entry is refused with `UNPROCESSABLE` naming the entry. A link is an entry whose central-directory external attributes carry `S_IFLNK` (`0o120000` in the upper 16 bits), which Info-ZIP's `zip -y` and Go's `archive/zip` both write and `unzip` restores as a link. `:zip` reports a link as a regular file, so the central directory is read directly.

### One contract fixture

- **R23.** `fixtures/package-contract.json` holds `identity` cases, `version` cases, `package_key` cases (`/` as `__`), and `limits`: `max_duration_seconds` (7,200, the runner's ceiling) and `max_url_length` (2,048, the deriver's `MAX_URL_LENGTH`, counted in code points by report-server and UTF-16 units by the function).
- **R24.** report-server's tests assert `Identity.parse/1` and the manifest's version check against every case and each limit at its boundary; the function's tests assert its identity check, `packageKey` and `MAX_URL_LENGTH`. The function's identity check is tightened to the catalog's grammar; it keeps no version grammar.
- **R25.** A change to `fixtures/` runs both report-server's and the function's suites in CI.
- **R26.** Two copies stay on purpose: rigse's `RunRequest` regexes and cc-data's `package init` name check. The runner and the app assert against the fixture in their own stories; RD-4 asserts its `PACKAGE_MAX_DURATION_SECONDS` default against `limits.max_duration_seconds` and refuses at startup a configured value below it. RD-4's `contract:check` fetches the fixture from `master` at this path, so the path and the `limits` key are a contract.

### Documentation and release

- **R27.** `server/README.md`'s catalog section names validate, applies and the list's applicability, states the ceiling and the link rule, and says which routes carry CORS. `functions/README.md` names `derive_urls`, and its `RD_AUTHORING_HOSTS` row says both routes read the allowlist.
- **R28.** Deployed to staging, the `api` function to `report-service-dev` (Functions 1.9.0) before report-server (1.13.0), with a staging check of validate, applies and the list. *(Not yet done: see Not Yet Implemented.)*

## Technical Notes

- **Router.** `/packages/validate` and `/packages/applies` are one segment after `/packages`, so `POST /packages/:kind/:owner_id/:name/:state` cannot match them; both sit in `:api_authenticated` above the `/api/v1` catch-all.
- **Timeouts.** The deriver's budget is 240 seconds under the `api` function's 300; each fetch's timer is capped by the budget left. report-server waits 270 seconds with `retry: false`. The ALB's idle timeout is 600 seconds.
- **The host allowlist is the only defense on `derive_urls`**, which takes researcher-supplied URLs through applies. It fetches only the `activity`/`sequence` URL inside an assignment URL, from `RD_AUTHORING_HOSTS`, over HTTPS, with no redirect, a 15-second timeout and a 5 MiB cap, and reaches only public authoring JSON.
- **Any researcher's token reaches `derive_urls` through applies**, holding an `api` instance up to 240 seconds and making up to 500 allowlisted fetches. Accepted for the first release; rate limiting is out of scope.
- **Publish's error order moved slightly**: the bucket lookup is carried through the shared `prepare/4`, so a zip failing both the bucket and a later check (origin, grants) gets the later check's error. Nothing relied on the old order.
- **`ReportService.get_request/0`** reads `:report_service_req_options`, so a test can route requests through `Req.Test`.

## Out of Scope

- The runner's and the app's calls to these routes (RD-4, RD-3), and their assertions against the contract fixture.
- cc-data's client for these routes (REPORT-146).
- Any change to `/derive-profile`, the `classes/{class_hash}` profile document, or rigse.
- Re-checking versions already published against the new ceiling or the link rule.
- A JWKS endpoint, rate limiting on `derive_urls`, and a version grammar in the function.

## Not Yet Implemented

- **The staging release (R28)**, tracker step 2.3, after the PR merges: first confirm `report-service-qa`'s `ReportServiceUrl` names `report-service-dev`'s `api` function; then deploy `api` (`derive_urls`) to `report-service-dev`, then report-server 1.13.0 to staging, in that order, since reversed, applies answers 503 and `cc-data package run` fails for any patterned package. Then the staging check. Production follows the same order.

## Decisions

### Requirements

**How the package list receives the scope's URLs.** A) a new `POST /api/v1/packages/list` with `{scope_urls}`; B) a GET taking a profile id (needs a Firestore read the story forbids); C) the app calling applies per package (N calls, and no token the app holds). **A** (Doug): a profile's URLs cannot travel in a GET. The GET stays unchanged.

**Whether validate refuses an already-published version.** A) refuse with `ALREADY_EXISTS`; B) answer 200 with `already_published`; C) skip the check. **B** (Doug): `cc-data package run` keeps working on a published version, and publish still refuses it.

**Whether validate refuses a portal with no bucket.** A) report it in a field; B) refuse, with cc-data treating that one 422 as a warning. **A** (Doug, raised by REPORT-146): B means cc-data matching an error string, putting a piece of report-server's rules back in cc-data, and `package run` would fail on every portal before its bucket is set. The field is `publishing_unavailable`, beside `already_published` rather than merged with it, since REPORT-146 already reads `already_published`.

**Whether validate takes `official`.** A) yes; B) only `origin`. **A**: "every check publish runs" includes the publisher-role check, and the answer's visibility depends on it.

**Where the fixtures live.** A) both at the repository root in `fixtures/`; B) the matcher's under `server/test/fixtures/`. **A**: one place for every cross-component fixture, as RD-4 put `url-patterns.json` in its repository.

**What counts as a symbolic link.** A) any entry whose upper attribute bits carry `S_IFLNK`, whatever the host; B) only when the host byte is Unix. **A**: a superset of what `unzip` restores as a link, and no legitimate archive sets those bits otherwise.

**How scope URLs are bounded.** A) by count (1,000) and per-URL length; B) by total bytes. **A**: a profile's own limits are counts (500 assignment, 500 interactive URLs), and a count bounds the matcher's work directly. The length is in code points (Doug): graphemes let one "character" carry thousands of combining marks (a 7.8 MB body passed a grapheme bound), and bytes would refuse a non-ASCII URL the function, which counts UTF-16 units, keeps.

**Whether `urls` is required on applies, and `scope_urls` on the list.** Reading a missing `urls` as "no patterns" answered `applies: true` for a body never read (a `text/plain` body, or a misspelled key), on the answer the runner acts on. Both keys are now required; `null` groups inside `urls` stay empty.

**Whether limits shared with other components are asserted.** A) a `limits` block in the contract fixture, asserted by both suites, with RD-4 checking its setting at startup; B) the URL length only; C) nothing. **A** (Doug): the runner's ceiling is a deploy-time setting, so only its own startup check catches a lowered value, and the fixture gives that check one number.

**Validate's administration check for a new package.** Publish inserts the row and then checks `administers?/3`, so validate checks the maintainer a new package would get: an ungranted `projects/<id>` origin is `FORBIDDEN` whether or not the package exists.

**Where the assignment-URL bounds live.** A copy in report-server disagreed with the function's 256 KiB body cap. They live only in the function, and its 400 comes back as a 400.

**CORS for the anonymous list's POST.** A JSON POST is preflighted, and `CatalogCors` refused every preflight outside `cors_origins`. A preflight that does not ask for `authorization` precedes a request with no bearer, which every origin may already make, so it is answered to any origin; one asking for `authorization` still needs an allowlisted origin.

### Implementation

**Validate as a shared `prepare/4`, or a rolled-back publish.** A) extract publish's pre-transaction checks and repeat its two in-transaction checks as plain reads; B) run publish in a transaction that always rolls back. **A**: B takes the `FOR UPDATE` lock, can insert and roll back a row, and would wait behind a concurrent publish.

**Reading the central directory, or replacing `:zip`.** A) keep `:zip` for listing and read only the external attributes; B) parse the archive ourselves. **A**: `:zip` already decides what a readable archive is, and only the file type is missing. `:zip` accepts an Info-ZIP archive comment, so the backward search for the end record is covered by a commented fixture.

**Where the scope-URL bound lives.** A) the controller, shared by applies and the list; B) `Patterns`. **A**: it is a request bound, not a property of patterns.

**Testing `ReportService.derive_urls/1`.** No test exercised `ReportService`'s HTTP calls and `get_request/0` built a bare `Req`, so it now reads `:report_service_req_options`, letting the test put `Req.Test` in front of it.

**The release's pre-check.** Staging report-server reaches the function through its stack's `ReportServiceUrl`, which this repository cannot see, so the release reads it before deploying.
