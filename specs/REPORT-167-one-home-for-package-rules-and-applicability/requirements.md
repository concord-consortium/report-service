# report-service: one home for the package rules and applicability

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-167
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

report-server becomes the only place that decides whether a package is valid and whether it applies to a class. It gains a validate route that runs every publish check without publishing, an applies route holding the system's only URL glob matcher, and applicability marked on the package list. The `api` function gains a `derive_urls` route so report-server can follow assignment URLs with the existing deriver. cc-data, the dashboard app and the runner then ask one server and get one answer.

## Project Owner Overview

A researcher writes a package on a laptop, tries it with `cc-data package run`, and publishes it. Then the dashboard offers it on a class and a VM runs it. Today each of those places would carry its own copy of the rules and of the matcher deciding which classes a package suits. When copies disagree, a package passes on the laptop and fails on the VM, or the dashboard offers it and the runner refuses it. Either way the failure reads as the author's mistake.

This story moves those decisions into report-server, which already owns the catalog and the publish path. cc-data, the dashboard and the runner ask it rather than each keeping a copy. It also tightens publish to the runner's own limits (at most two hours declared, no symbolic links in the archive), so nothing report-server accepts is something the VM will refuse.

## Background

REPORT-142 built the catalog: `POST /api/v1/packages` (publish, cc-data token), the state-change routes, `GET /api/v1/packages` (the app's list, anonymous or with a scoped access token) and `GET /api/v1/packages/resolve` (rigse's run path). It also built `POST /derive-profile` on the `researcherDashboard` function, which follows Activity Player assignment URLs to their public activity JSON with `deriveProfile` and writes the class's authored URL profile to `classes/{class_hash}`.

The design originally had three copies of a twenty-line glob matcher, in the app (RD-3), the runner (RD-4) and `cc-data package run` (REPORT-146), held together by one fixture. REPORT-146's spec (2026-10-08, Doug) replaced them with one matcher in report-server and created this story (`final-design.md` sections 5.5, 10 and 17, global oob `streams/researcher-dashboard/`). The other stories already code against the outcome:

- **REPORT-146** (cc-data-cli, branch `REPORT-146-cc-data-cli-the-package`, Dependencies section of its requirements). `build` and `run` send the zip to validate and refuse on its coded error. `run` sends the patterns and the scope's assignment URLs to applies with a 5-minute timeout, refuses on "does not apply", and warns on each unread URL and on truncation. **Any 404 from either route is read as "not deployed yet"**: cc-data warns and proceeds.
- **RD-4** (the runner) keeps no matcher. It asks applies with the patterns from the manifest it checksummed and the profile URLs it read, and still does the refusing.
- **RD-3** (the app) keeps no matcher. It gets applicability from the package-list call it already makes, sending the scope's profile URLs.

What the code shows today, which the requirements below build on:

- **Publish** (`ReportServer.Packages.publish/4`) checks, in order: the publisher role when `official=true`; the archive (`Archive.read_manifest/1`: 10 MiB, a readable zip, no unsafe path, 50 MiB declared, one root `manifest.json` of at most 64 KiB); the manifest projection (`Manifest.project/2`); a bucket for the portal (`Store.bucket_for/1`); the origin; the project grants. Inside the transaction it then checks administration of the locked package and that (identity, version) is new. Errors are `{:error, kind, message}`, rendered through `PackageController`'s `@error_codes`.
- **The duration ceiling** is `@max_duration_seconds 8 * 60 * 60` (28,800) in `Manifest`. The runner's is `PACKAGE_MAX_DURATION_SECONDS`, default 7,200 (RD-4 pass 2 R26).
- **Symbolic links are accepted today.** `Archive.list_entries/1` takes the type from `:zip.list_dir/1`. Verified in this story with a throwaway zip made by `zip -y`: OTP 26's `:zip` reports a symlink entry (`lrwxrwxrwx` in `unzip -Z`) as `:regular`. So a symlink passes, and one can even be the entrypoint, since `Manifest.entrypoint/2` accepts any `:regular` entry. The runner refuses an archive holding a link after extracting it (RD-4 pass 2 R31).
- **There is no glob matcher in this repository.** RD-4 pass 2's stage-verification build has the runner's (`runner/server/url-patterns.js`, two-pointer) and the fixture (`fixtures/url-patterns.json`: 27 `matches` cases and 12 `applies` cases), in researcher-dashboard's branch oob `RD-4-pass-2-pull-loop/stage-verification/step3.diff`. Neither was ever committed.
- **The function's identity check** is `run-package.ts`'s `IDENTITY = /^(users|projects)\/[0-9]+\/[a-z0-9][a-z0-9-]{0,62}$/`. It accepts `users/0/x`, `users/007/x` and ids longer than 18 digits, all of which report-server's `Identity` (`[1-9][0-9]{0,17}`) refuses. `packageKey` is `firestore-paths.ts`'s `identity.replace(/\//g, "__")`. The function checks a version only as a non-empty string.
- **report-server already calls the `api` function** through `ReportServer.ReportService` (`bulk_read`, `fetch_attachment_meta`) with the shared bearer from `:report_service`. Controllers reach it through the `:report_service_client` app env, which tests point at `ReportServer.ReportServiceStub`.
- **The `api` function** routes `bulk_read` and `fetch_attachment_meta` behind `bearerTokenAuth` plus `requireHeaderBearer`, with `timeoutSeconds: 300`. `RD_AUTHORING_HOSTS` is a `defineString` param of the functions codebase, set in both `.env.report-service-dev` and `.env.report-service-pro`, so the `api` function can read it as `researcherDashboard` does.
- **Both runner and cc-data tokens are `api_tokens`.** The runner holds a `researcher-dashboard`-labeled token minted by `POST /api/v1/dashboard-tokens`, which `AuthPlug` verifies like a cc-data token. So the `:api_authenticated` pipeline already admits both callers of applies.

## Requirements

### The derive route on the `api` function

- **R1.** `POST /derive_urls` on the `api` function, behind `bearerTokenAuth` and `requireHeaderBearer` exactly as `bulk_read` is, takes `{assignment_urls: [string]}` and answers `{success: true, interactive_urls, unread, truncated}` from `deriveProfile` (`functions/src/researcher-dashboard/derive-profile.ts`), with the `RD_AUTHORING_HOSTS` allowlist parsed by the existing `parseAllowedHosts`. No second copy of the walk.
- **R2.** Its body bounds are `/derive-profile`'s: at most 500 assignment URLs, each a string of at most 2,048 characters (`MAX_URL_LENGTH`), and a body of at most 256 KiB. A body outside them is a 400 naming the problem. With `RD_AUTHORING_HOSTS` empty it answers 503, as `/derive-profile` does.
- **R3.** It writes nothing: no Firestore document, no task, no cache. It takes no scope id and no class hash. The `classes/{class_hash}` profile stays the rigse and app path's alone.
- **R4.** The `api` function's `GET /` method list names it.

### The only glob matcher (report-server)

- **R5.** `ReportServer.Packages.Patterns` (or a module of that role) holds the matcher of `final-design.md` 5.5: a pattern matches the whole URL, `*` matches any run of characters including none and including `/`, and every other character, `?` included, matches only itself. It is the only glob matcher in the system.
- **R6.** Its cost is bounded at the request limits below, so it is a segment matcher rather than the two-pointer one the runner had: it splits the pattern on `*`, checks the first and last literal as prefix and suffix, and finds the middle literals leftmost in order with `:binary.match/2`. Measured in this story (Elixir, throwaway): a two-pointer matcher takes 6.5 ms for one worst-case pair (`*` plus 254 literals against 2,048 characters), so 20 patterns against 1,000 such URLs would take about 130 seconds; the segment matcher takes 50 to 81 ms for the same 20,000 pairs, including inputs built against `:binary.match`'s search. The two agree on all 27 fixture cases and on 200,000 random patterns and URLs over `a`, `b`, `?` and `*`. The applies route matches at most 2,000 URLs (500 assignment, 500 derived and 1,000 scope URLs) of at most 2,048 code points each, so at most 8 KiB each. A test runs the worst-case shapes at that limit, once over URLs of 2,048 ASCII characters and once over URLs of 2,048 four-byte code points (20 patterns of 256 characters against 2,000 URLs each), and requires an answer within 2 seconds, a bound loose enough not to flake on CI and tight enough to fail a quadratic matcher by two orders of magnitude.
- **R7.** Applicability over a set of URLs follows the runner's rules (RD-4 pass 2 R34): every `all` pattern matches at least one URL; when `any` is non-empty, at least one `any` pattern does; no `none` pattern does. A package declaring no patterns applies to every scope. A refusal names the deciding pattern in the runner's words:
  - `no URL in this class matches the required pattern <p>`
  - `no URL in this class matches any of <p1>, <p2>`
  - `a URL in this class matches the excluded pattern <p>`
- **R8.** `url-patterns.json`, all 27 `matches` cases and all 12 `applies` cases as RD-4 pass 2 built them, is committed in this repository as report-server's test file for the matcher, and a test asserts every case.

### The validate route (report-server)

- **R9.** `POST /api/v1/packages/validate` (`:api_authenticated`, so a cc-data token) takes what publish takes: the raw zip as the body with `Content-Type: application/zip` and a declared `Content-Length`, and the optional `origin` and `official` query parameters.
- **R10.** It runs every check publish runs, in publish's order and with publish's codes and messages: content type and length, the publisher role for `official=true`, the archive, the manifest, the origin, the project grants, and administration of the package. Two conditions are reported rather than refused, because they decide whether this zip can be published now, not whether the package is valid: whether the version is already published, and whether the portal has a bucket (R12, Open Question 3). Administration is checked for a new package too, against the maintainer it would get (its origin), since publish inserts the row and then checks `administers?/3` on it: a `projects/<id>` origin the caller holds no grant on is `FORBIDDEN` whether or not the package exists. A refusal is the same coded error publish would answer for that zip, with the same HTTP status.
- **R11.** It stops before writing: no `packages`, `package_versions` or `package_events` row, no S3 object, and no locking read (`FOR UPDATE`). A test asserts that the row counts and the store are unchanged after a validate that passes.
- **R12.** A passing validate answers 200 `{identity, version, checksum, visibility, already_published, publishing_unavailable}`: what a publish of that zip would record now. `visibility` is the existing package's, or `private` for a new one, or `public` when `official=true` is accepted. `already_published` is true when that (identity, version) exists, which the publish would refuse with `ALREADY_EXISTS`; validate does not refuse it, so `cc-data package run` keeps working on a published version (Open Question 2). `publishing_unavailable` is `null`, or, when the portal has no bucket in `PackageBuckets`, publish's own message for that refusal ("publishing is not configured for <server>"); publish still refuses with that 422. So `package run` works on a portal before its bucket is set, as the stream's rule that local work does not wait on `PackageBuckets` requires.
- **R13.** It is a separate route, not a `dry_run` parameter on publish, because publish ignores parameters it does not know and an older server would publish for real.

### The applies route (report-server)

- **R14.** `POST /api/v1/packages/applies` (`:api_authenticated`, so a cc-data token or the runner's dashboard token) takes JSON `{urls: {all, any, none}, assignment_urls, scope_urls}`.
  - `urls` is required and must be a JSON object; an absent or `null` `urls` is 400, since reading it as "no patterns" would answer `applies: true` for a request whose body was never read (a non-JSON body reaches the controller with no parameters). It is checked with publish's pattern rules (`Manifest`): only the three keys, at most 20 patterns in all, each non-empty, at most 256 characters, no whitespace or control characters. A group that is absent or `null` is empty, since Go marshals a nil slice as `null` (checked in this story: `json.Marshal(map[string][]string{"all": nil})` gives `{"all":null}`) and cc-data builds the three groups from possibly nil slices.
  - `assignment_urls` (optional) is an array of strings. Its bounds are R2's and live only in the function: a 400 from `derive_urls` is answered as 400 `BAD_REQUEST` with the function's message, so the caller learns which bound it crossed and the limits are not kept twice.
  - `scope_urls` (optional) is at most 1,000 strings of at most 2,048 code points (`String.codepoints/1`, the unit `Manifest` already counts). Not graphemes, since one grapheme can carry thousands of combining marks and so bounds neither the body nor the matcher's work; and not bytes, since the function counts the same 2,048 in UTF-16 units, which are never fewer than code points, so a URL the deriver keeps always passes here, where a byte count would refuse a non-ASCII one: a profile's 500 assignment URLs plus its 500 interactive URLs.
  - A body outside these is a 400 `BAD_REQUEST` naming the problem.
- **R15.** When `assignment_urls` is non-empty, report-server sends it to `derive_urls` (R1) through `ReportServer.ReportService`, as it sends `bulk_read`. The URLs matched are `assignment_urls`, the derived `interactive_urls` and `scope_urls` together, which is the set the runner matches (the profile's assignment and interactive URLs).
- **R16.** It answers 200 `{applies, reason, interactive_urls, unread, truncated}`: `reason` is R7's message, or `null` when the package applies; the other three are the deriver's, or `[]`, `[]` and `false` when nothing was derived.
- **R17.** **Neither new route ever answers 404**, since cc-data reads a 404 from either as "not deployed" and silently skips the check. A derive call that fails, times out, or gets any answer other than 200 or 400 (a function without the route answers 404) is answered 503 `SERVICE_UNAVAILABLE`. report-server's wait on the deriver stays below cc-data's 5-minute timeout and above the deriver's 240-second budget.
- **R18.** It writes nothing and takes no scope id or class hash.

### Applicability on the package list (report-server)

- **R19.** `POST /api/v1/packages/list` (the `:api_catalog` pipeline, anonymous with `?portal=` or with the access token) takes `{scope_urls}` (required, possibly empty; R14's bounds) and answers `GET /api/v1/packages`'s list with each row marked `applies` (boolean), computed with R7 over the package's current version's `urls`, so the app needs no matcher and no extra call. It keeps the existing row shape otherwise and calls no deriver. A JSON POST is preflighted, so `CatalogCors` answers a preflight that does not ask for `authorization` from any origin, and allows `POST` and `content-type` (Open Question 1).
- **R20.** `GET /api/v1/packages` answers exactly as today, without `applies`.

### The runner's stricter rules at publish (report-server)

- **R21.** `expected_duration_seconds` is at most 7,200 at publish (and so at validate). 7,201 is refused with `UNPROCESSABLE` naming the ceiling. Versions already published above 7,200 stay as they are; the runner refuses them.
- **R22.** An archive holding a symbolic-link entry is refused at publish (and so at validate) with `UNPROCESSABLE` naming the entry. A link is an entry whose central-directory external attributes carry the Unix file type `S_IFLNK` (`0o120000` in the upper 16 bits), which is what `unzip` restores as a link. Verified in this story by reading the central directory of three real archives in Elixir: `zip -y` (Info-ZIP) and Go's `archive/zip` with `SetMode(os.ModeSymlink|0777)` (cc-data's writer) both record a link as `0o120777` and a regular file as `0o1006xx`/`0o100755`, and Python's `zipfile.writestr` records `0o600` with no type bits, so it reads as not a link. The central directory has to be read for this, since `:zip` drops the attributes. A test publishes a real `zip -y` archive with a link and is refused, and the link-as-entrypoint case is refused too.

### One contract fixture

- **R23.** One JSON file of package-contract cases is committed in this repository:
  - **identity**: strings and whether each is a valid identity (`users|projects`, an id `[1-9][0-9]{0,17}`, a name `^[a-z0-9][a-z0-9-]{0,62}$`), including leading-zero and zero ids, a 19-digit id, a 63- and a 64-character name, uppercase, `_`, and too few and too many segments.
  - **version**: strings and whether each is a valid version (`MAJOR.MINOR.PATCH`, an optional `-prerelease` of `[0-9A-Za-z.-]`, at most 64 characters), including leading zeros, build metadata (`+`), and 64 and 65 characters.
  - **package_key**: identity and expected key (`/` as `__`).
  - **limits**: `max_duration_seconds` (7,200, the runner's ceiling) and `max_url_length` (2,048, the deriver's `MAX_URL_LENGTH`), the two numbers report-server takes from other components. `max_url_length` is in characters: code points in report-server, UTF-16 units in the function, which agree in the direction that matters (R14).
- **R24.** report-server's tests assert `Identity.parse/1` against every identity case and the manifest's version check against every version case. The function's tests assert `run-package.ts`'s identity check against every identity case and `packageKey` against every package-key case, and the function's identity check is tightened to agree. The function keeps no version grammar: it receives versions rigse resolved from the catalog. report-server's tests check each limit at its boundary: a manifest declaring `max_duration_seconds` is accepted and one more second is refused, and a scope URL of `max_url_length` code points is accepted and one more is refused. The function's tests assert `MAX_URL_LENGTH` equals `max_url_length`.
- **R25.** A change to either fixture runs both report-server's and the function's test suites in CI.
- **R26.** Two copies stay on purpose and are recorded where the fixture is described: rigse's `RunRequest` identity and version regexes (merged, and they only ever see identities the catalog resolved), and cc-data's name check in `package init` (it runs before report-server has seen anything). The runner and the app assert against this fixture in their own stories. The runner's ceiling is a setting (`PACKAGE_MAX_DURATION_SECONDS`, up to 28,800), so RD-4 asserts that its default equals `limits.max_duration_seconds` and refuses at startup a configured value below it, since a deploy that lowers it would refuse packages report-server accepts. RD-4's `contract:check` fetches the fixture from report-service's `master` at `fixtures/package-contract.json` and fails on any difference, so that path and the `limits` key are a contract with the runner's repository.

### Documentation and release

- **R27.** `server/README.md`'s package-catalog section names the validate and applies routes and the list's applicability, states the 7,200-second ceiling and the symbolic-link rule, and stays true about which routes carry CORS. `PackageJSON`'s moduledoc no longer says the app matches. `functions/README.md` names `derive_urls` on the `api` function, and its `RD_AUTHORING_HOSTS` row says both routes read the allowlist.
- **R28.** Deployed to staging: the `api` function to `report-service-dev` (fix version Functions 1.9.0) before report-server (1.13.0), since applies depends on `derive_urls`. A staging check: validate refuses a 7,201-second manifest and a zip with a link and accepts a good zip; applies refuses a non-matching package for a staging class's assignment URLs with derived interactive URLs in the answer; the list marks applicability.

## Technical Notes

- **Files.** report-server: `lib/report_server/packages.ex`, `packages/archive.ex`, `packages/manifest.ex`, a new matcher module, `report_service.ex`, `lib/report_server_web/router.ex`, `api/v1/package_controller.ex`, `api/v1/package_json.ex`, possibly `api/catalog_cors.ex`, `test/support/report_service_stub.ex`, `README.md`. Functions: `src/index.ts`, a new `src/api/derive-urls.ts` beside `bulk-read.ts`, `src/researcher-dashboard/run-package.ts`. CI: `.github/workflows/report-server.yml` and `firestore-and-query-creator-tests.yml` path filters.
- **Router.** `POST /packages/validate` and `/packages/applies` are one segment after `/packages`, so `POST /packages/:kind/:owner_id/:name/:state` (four) cannot match them. Both go in the `:api_authenticated` scope above the `/api/v1` catch-all.
- **The derive call's timeouts.** The deriver's budget is 240 seconds (`DERIVATION_BUDGET_MS`) under the `api` function's 300-second timeout. The shared ALB's idle timeout is 600 seconds (cloud-formation `fargate/public-network-stack.yml`), so a long call is not cut there.
- **The host allowlist is the only defense on `derive_urls`.** It takes URLs a researcher supplies through report-server, where `/derive-profile` takes only rigse's. `final-design.md` 5.5 accepts this: it fetches only the `activity`/`sequence` URL inside an assignment URL, only from `RD_AUTHORING_HOSTS`, over HTTPS, with no redirect, a 15-second timeout and a 5 MiB cap, and what it reaches is public authoring JSON. The route does not widen who holds the shared bearer.
- **`derive_urls` is reachable by any researcher's token, through applies.** Each call can hold an `api` instance for up to 240 seconds and make up to 500 allowlisted fetches, five at a time. That is accepted for the first release: the caller is an authenticated researcher, every fetch is to public authoring JSON, and `AuthPlug` records the token's use. Rate limiting is out of scope.
- **REPORT-143** (unpushed, `REPORT-143-vm-endpoints-and-watchdog`) also edits `functions/src/researcher-dashboard/`. The overlap is `run-package.ts`, so whichever merges second rebases.

## Out of Scope

- The runner's and the app's calls to these routes (RD-4, RD-3), and their assertions against the contract fixture.
- cc-data's client for these routes (REPORT-146).
- Any change to `/derive-profile`, the `classes/{class_hash}` profile document, or rigse.
- Re-checking versions already published against the new ceiling or the link rule.
- A JWKS endpoint, rate limiting on `derive_urls`, and a version grammar in the function.

## Open Questions

### RESOLVED: How does the package list receive the scope's URLs?
**Context**: The story and `final-design.md` 5.5 say `GET /api/v1/packages` "accepts the scope's URLs". A profile holds up to 500 assignment URLs of 2,048 characters and up to 512 KiB of interactive URLs, which cannot travel in a query string, and a browser `fetch` cannot send a GET body. RD-3, which has not built its list call yet (no `api/v1/packages` call exists in researcher-dashboard on any branch), consumes this contract.
**Options considered**:
- A) A new `POST /api/v1/packages/list` in the `:api_catalog` pipeline (CORS, anonymous with `?portal=` or the access token) taking `{scope_urls}` and answering the GET's shape with `applies` on each row. `GET /api/v1/packages` stays as it is. A JSON POST is preflighted, so `CatalogCors` must answer `OPTIONS` for it with `POST` and the `content-type` header allowed, and must let an anonymous preflight through from any origin as the anonymous GET is; today it refuses every preflight from an origin outside `cors_origins`.
- B) Keep GET and take a short identifier of the profile instead of its URLs. That needs report-server to read the Firestore profile, which the story forbids.
- C) The app calls `POST /api/v1/packages/applies` once per package. N calls per launch, and applies needs a cc-data or dashboard token the app does not hold.

**Recommendation**: A. B is forbidden by the story and C cannot authenticate, so A is the only shape that works; the open part is that it replaces the GET named in RD-3's Jira description and `final-design.md` 5.5, which Doug should see.

**Decision**: A (Doug, 2026-10-08). The GET stays as it is; RD-3 calls the POST.

### RESOLVED: Does validate refuse a version that is already published?
**Context**: R10 says validate runs every publish check, and publish refuses an existing (identity, version) with `ALREADY_EXISTS`. But REPORT-146's `cc-data package run` calls validate before running, with no origin, and exits on any refusal. An author who publishes `0.1.0` and keeps editing and running locally would be refused until they bump the version. `build` wants the refusal (the publish would fail); `run` does not.
**Options considered**:
- A) Refuse with `ALREADY_EXISTS`, as publish would. REPORT-146's `run` then needs to treat that one code as a warning (a change to REPORT-146's spec).
- B) Answer 200 with `already_published: true` added, so `build` can warn and `run` proceeds. REPORT-146 already ignores unknown fields, so `run` works unchanged, and `build` gains a warning only if REPORT-146 reads the flag.
- C) Skip the version check entirely.

**Recommendation**: B. It keeps REPORT-146's `run` working with no change, `build` still learns of the conflict if it reads the flag, and the publish itself still refuses. It changes the answer REPORT-146 codes against only by adding a field.

**Decision**: B (Doug, 2026-10-08). Validate answers 200 with `already_published: true`; publish still refuses the version.

### RESOLVED: Does validate refuse a portal with no bucket?
**Context**: Until `PackageBuckets` names a portal server's bucket, `Store.bucket_for/1` fails and publish answers 422 "publishing is not configured for <server>". REPORT-146's `build` and `run` both call validate first, so a refusal would stop `package run` on staging today and on any portal without a bucket. Raised by REPORT-146's session.
**Options considered**:
- A) Report it: validate answers 200 with a field naming the condition; publish still refuses.
- B) Refuse it, and cc-data treats that one 422 as a warning.

**Decision**: A (Doug, 2026-10-08). B means cc-data matching an error string, which puts a piece of report-server's rules back in cc-data. The field is `publishing_unavailable` (the message or `null`), beside `already_published` rather than merged with it, since REPORT-146 already codes against `already_published` and each field then means one thing.

### RESOLVED: Judgment call: does validate take `official`?
**Context**: REPORT-146 sends only `origin`. Publish also takes `official=true`, which adds the publisher-role check and changes the recorded visibility.
**Options considered**:
- A) Take `official` too, so validate answers for exactly the publish that will follow (the cc-data-studies release path publishes with it).
- B) Take only `origin`.

**Decision**: A. "Every check publish runs" includes the role check, and the visibility in the answer depends on it. cc-data's current client simply never sends it.

### RESOLVED: Judgment call: where do the two fixtures live?
**Context**: `url-patterns.json` is now report-server's test file alone. The contract fixture is read by both report-server's and the function's tests, and other repositories' stories assert against it.
**Options considered**:
- A) Both at the repository root in `fixtures/` (`fixtures/url-patterns.json`, `fixtures/package-contract.json`), with both CI path filters covering `fixtures/**`.
- B) `url-patterns.json` under `server/test/fixtures/`, the contract fixture at the root.

**Decision**: A. One place for every cross-component fixture, matching where RD-4 pass 2 put `url-patterns.json` in its own repository, so a later component that needs the matcher cases finds them beside the contract.

### RESOLVED: Judgment call: what counts as a symbolic link?
**Context**: A zip records file type only in a Unix-made entry's external attributes, which `:zip` does not surface.
**Options considered**:
- A) Refuse any entry whose upper 16 external-attribute bits carry `S_IFLNK`, whatever the "made by" host.
- B) Refuse only when the host byte is Unix (3).

**Decision**: A. It is a superset of what `unzip` restores as a link, and no legitimate archive from another host sets those bits to `S_IFLNK`.

### RESOLVED: Low confidence: are the request bounds right?
**Context**: R14's 1,000 `scope_urls` assumes the runner and the app send a profile's assignment and interactive URLs as they are. The first draft's 200 ms target was a laptop measurement and would flake as a CI assertion.
**Options considered**:
- A) Bound `scope_urls` by count (1,000) and length (2,048 each), and assert the matcher with a generous time bound.
- B) Bound `scope_urls` by bytes (for example 1 MiB) instead of count.

**Decision**: A. The profile's own limits are counts: `deriveProfile` keeps at most 500 interactive URLs (`MAX_INTERACTIVE_URLS`) and `/derive-profile` takes at most 500 assignment URLs, so 1,000 is exactly what a full profile sends, and 1,000 × 2,048 is about 2 MiB, inside `Plug.Parsers`' default 8 MB JSON limit. A count also bounds the matcher's work directly, which a byte cap does only through the length. R6 now asserts the worst case within 2 seconds rather than 200 ms.

## Self-Review

Roles: Senior Engineer, Security Engineer, QA Engineer, the consuming stories (REPORT-146, RD-3, RD-4), DevOps. Each finding was checked against the code before it was recorded, and each is fixed in place.

### Senior Engineer

#### RESOLVED: Validate checked administration only of an existing package
`Packages.publish/4` inserts a new package and then checks `administers?/3` on it, so a `projects/<id>` origin without a grant is refused even for a first publish. R10 now checks the would-be maintainer of a new package.

#### RESOLVED: The assignment-URL bounds disagreed between report-server and the function
R14 allowed 500 URLs of 2,048 characters (about 1 MiB), while `deriveBodyProblem`'s 256 KiB body cap, which R2 reuses, would refuse that with a 400 that R17 turned into a 503. The bounds now live only in the function, and its 400 comes back as a 400.

### Security Engineer

#### RESOLVED: The list's anonymous POST could not pass CORS
`CatalogCors` answers `*` only to a non-`OPTIONS` request without a bearer and refuses every preflight from an origin outside `cors_origins`, and a JSON POST is always preflighted. Open Question 1's option A now states what `CatalogCors` must allow.

#### RESOLVED: `derive_urls` is reachable by any researcher, not only by rigse
Recorded in Technical Notes with why it is accepted for the first release.

### QA Engineer

#### RESOLVED: "No row lock" was not testable
R11 now names what is testable: no `FOR UPDATE` read, and unchanged row counts and store.
