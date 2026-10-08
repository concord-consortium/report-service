# Implementation Plan: report-service: one home for the package rules and applicability

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-167
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

**The throwaway build.** Every step below was built as throwaway code in a scratch worktree of `master` at `067a1c4`, never in this one. The whole build is the branch oob file `stage-verification/stage5-throwaway-build.patch` (report-service, `REPORT-167-report-service-one-home-for`), 28 files; its tests are grouped into fewer files than the steps name. On it the server suite ran 1,261 tests (1,236 on `master`) with two failures: `catalog_cors_test.exs`'s pin of the old preflight headers, which the list step updates, and `report_run_duplicate_test.exs`, a LiveView test this work does not touch, which passed on each of three reruns alone. The functions suite ran 678 tests (674 on `master`), all passing (`npm test`, Node 22), and `npm run lint` was clean. Two mutations were each caught: the function's old identity regex fails the contract test, and a two-pointer matcher fails the matcher's time bound. The code below is the shape of each step, not its whole text.

## Implementation Plan

### The package-contract fixture

**Summary**: R23 to R26. One fixture of identity, version and package-key cases, asserted by report-server and by the function, with the function's identity check tightened to the catalog's grammar. It comes first because it touches nothing else, and later steps add no grammar.

**Files affected**:
- `fixtures/package-contract.json`: new. `about` (what it is, who asserts it, that RD-4's `contract:check` fetches it from `master` at this path, and the two copies left on purpose: rigse's `RunRequest` and cc-data's `package init`), then `identity` (19 cases), `version` (14) and `package_key` (2), as in the patch, and `limits` holding `max_url_length: 2048`. Later steps add `limits.max_duration_seconds` and the report-server assertions on both, each with the value it checks, so no step asserts a limit before it exists. The `about` text is where R26's record lives.
- `server/lib/report_server/packages/manifest.ex`: `valid_version?/1` made public from `version/1`'s condition, so the test asserts the grammar the projection uses.
- `server/test/report_server/packages/contract_test.exs`: new. Reads the fixture from `Path.expand("../../../../fixtures/package-contract.json", __DIR__)`, asserts the case lists are non-empty, then `Identity.parse/1` against every identity case and `Manifest.valid_version?/1` against every version case, naming the failing value.
- `functions/src/researcher-dashboard/run-package.ts`: `IDENTITY` exported and tightened to `/^(users|projects)\/[1-9][0-9]{0,17}\/[a-z0-9][a-z0-9-]{0,62}$/`, with a comment naming the fixture.
- `functions/src/researcher-dashboard/package-contract.test.ts`: new. Reads the fixture with `fs` from `path.resolve(__dirname, "../../../fixtures/package-contract.json")`, asserts non-empty lists, `IDENTITY` against every identity case, `packageKey` against every package-key case, and `MAX_URL_LENGTH` (`derive-profile.ts`) equal to `limits.max_url_length`.
- `.github/workflows/report-server.yml` and `firestore-and-query-creator-tests.yml`: `'fixtures/**'` added to each `paths` filter (R25).

**Estimated diff size**: ~170 lines

The function sees only identities rigse resolved from the catalog, so the tightening refuses nothing it receives today. Mutation checked: the old `[0-9]+` regex fails the identity test on `users/0/counts`, `users/007/counts` and the 19-digit id.

---

### The runner's stricter rules at publish

**Summary**: R21 and R22. The duration ceiling drops to 7,200, and an archive holding a symbolic link is refused. Both live in the code publish already runs, so validate (a later step) inherits them.

**Files affected**:
- `server/lib/report_server/packages/manifest.ex`: `@max_duration_seconds 2 * 60 * 60`, with a comment that it is the runner's own ceiling.
- `server/lib/report_server/packages/archive.ex`: `check_links/1` after `check_paths/1`, reading the central directory; the moduledoc gains why.
- `server/test/support/fixtures/packages/build.sh`: builds `symlink-entry.zip` (a link to `/etc/passwd` beside a valid package) and `symlink-entrypoint.zip` (the manifest's `entrypoint` is a link to `run.py`) with `zip -X -y`, `symlink-entry-go.zip`, Go-written with a third entry from `SetMode(os.ModeSymlink | 0777)`, and `symlink-entry-commented.zip`, `symlink-entry.zip`'s entries given an archive comment with `zip -z`, all with fixed mtimes (`touch -h` for the links). Checked in the throwaway build: two runs of the extended script produce identical hashes for all five zips that existed then (the commented one is new since), and the two existing fixtures come out unchanged.
- `server/test/support/fixtures/packages/*.zip`: the three new fixtures.
- `server/test/report_server/packages/archive_test.exs`: each of the four link fixtures is refused naming its entry; both existing fixtures still read.
- `server/test/report_server/packages/manifest_test.exs`: the `28_801` case becomes `7_201`, and 7,200 is accepted.
- `fixtures/package-contract.json`: `limits.max_duration_seconds: 7200`, and `contract_test.exs` gains a boundary test: a manifest declaring it projects, and one more second is refused.
- `server/test/report_server_web/api/v1/package_controller_create_test.exs`: publish refuses `symlink-entrypoint.zip` with 422 and stores nothing; publish refuses 7,201 seconds.
- `server/README.md`: the catalog section states the 7,200-second ceiling and the link rule (R27).

**Estimated diff size**: ~170 lines plus three small binary fixtures

```elixir
@central_header_signature 0x02014B50
@end_of_central_directory_signature 0x06054B50
@file_type_mask 0o170000
@symlink_type 0o120000

defp check_links(bin) do
  with {:ok, modes} <- central_modes(bin) do
    case Enum.find(modes, fn {_name, mode} -> Bitwise.band(mode, @file_type_mask) == @symlink_type end) do
      nil -> :ok
      {name, _mode} -> {:error, "the archive entry #{inspect(name)} is a symbolic link"}
    end
  end
end

# each entry's name and the Unix mode in the upper half of its external attributes
defp central_modes(bin) do
  # the record is 22 bytes followed by a comment of at most 65,535
  last = byte_size(bin) - 22

  with {:ok, eocd} <- find_end_of_central_directory(bin, last, max(last - 65_535, 0)),
       <<_::binary-size(eocd), @end_of_central_directory_signature::little-32, _disks::binary-size(6),
         count::little-16, size::little-32, offset::little-32, _::binary>> <- bin,
       true <- offset + size <= eocd || :error do
    central_entries(binary_part(bin, offset, size), count, [])
  else
    _ -> {:error, "the archive is not a readable zip"}
  end
end
```

`central_entries/3` walks `count` headers: signature, 24 bytes to the name length, the name, extra and comment lengths, 4 bytes, the 32-bit external attributes (shifted right 16), the offset, then the name, skipping extra and comment. A header that does not parse is "not a readable zip". It runs after `:zip.list_dir/1` has accepted the archive, so the central directory is already known to be well formed; a Zip64 directory, which `:zip` would have to accept first, is beyond a 10 MiB archive.

Checked in the throwaway build: Info-ZIP's `zip -y` and Go's `archive/zip` both record a link as `0o120777`, and Python's `zipfile.writestr` writes `0o600` with no type bits, so it is not a link. An archive comment is reachable: `:zip.list_dir/1` refuses an archive `:zip.create/3` wrote with a comment but accepts an Info-ZIP one given a comment with `zip -z` (OTP 26), so the backward search for the end record is live code, and `symlink-entry-commented.zip` covers it. The throwaway `central_modes/1` refused that archive's link entry by name.

---

### The matcher

**Summary**: R5 to R8. `ReportServer.Packages.Patterns` holds the only glob matcher and the applicability rule, and takes over `Manifest`'s pattern validation so the applies route checks a request's patterns with exactly the code publish uses.

**Files affected**:
- `server/lib/report_server/packages/patterns.ex`: new. `matches?/2`, `applies/2`, `validate/1`.
- `server/lib/report_server/packages/manifest.ex`: `urls/1` calls `Patterns.validate/1` and prefixes its message with `manifest.json: `; the pattern helpers and their three attributes move to `Patterns`.
- `fixtures/url-patterns.json`: new. RD-4 pass 2's fixture with its 27 `matches` and 12 `applies` cases unchanged, and `about` rewritten to name report-server's matcher as the only one.
- `server/test/report_server/packages/patterns_test.exs`: new.

**Estimated diff size**: ~230 lines

```elixir
def matches?(pattern, url) when is_binary(pattern) and is_binary(url) do
  case :binary.split(pattern, "*", [:global]) do
    [literal] ->
      literal == url

    [first | rest] ->
      {middle, [last]} = Enum.split(rest, -1)
      first_size = byte_size(first)
      last_size = byte_size(last)
      size = byte_size(url)

      size >= first_size + last_size and
        binary_part(url, 0, first_size) == first and
        binary_part(url, size - last_size, last_size) == last and
        in_order?(middle, binary_part(url, first_size, size - first_size - last_size))
  end
end

defp in_order?([], _rest), do: true
defp in_order?(["" | literals], rest), do: in_order?(literals, rest)

defp in_order?([literal | literals], rest) do
  case :binary.match(rest, literal) do
    {at, length} -> in_order?(literals, binary_part(rest, at + length, byte_size(rest) - at - length))
    :nomatch -> false
  end
end

def applies(urls, scope_urls) do
  matched? = fn pattern -> Enum.any?(scope_urls, &matches?(pattern, &1)) end
  any = Map.get(urls, "any", [])

  cond do
    pattern = Enum.find(Map.get(urls, "all", []), &(not matched?.(&1))) ->
      {:error, "no URL in this class matches the required pattern #{pattern}"}

    any != [] and not Enum.any?(any, matched?) ->
      {:error, "no URL in this class matches any of #{Enum.join(any, ", ")}"}

    pattern = Enum.find(Map.get(urls, "none", []), matched?) ->
      {:error, "a URL in this class matches the excluded pattern #{pattern}"}

    true ->
      :ok
  end
end
```

The name is `matches?`, not `match?`, which would collide with `Kernel.match?/2`. Matching is on bytes, which for a `*`-only glob over UTF-8 gives the same answer as matching on characters, since `*` absorbs whole runs and a literal can only match at a character boundary.

Tests (`patterns_test.exs`):
- **Every `matches` case**: asserts there are 27, then each, naming the pattern and URL.
- **Every `applies` case**: asserts there are 12, then each.
- **The three refusals' wording**, exactly.
- **The worst cases at the limits**: `*` plus 254 literals, `*a` repeated to `*b`, and `*b` plus 253 literals then `*`, each 20 times against 2,000 URLs of 2,048 `a`s (the applies route's maximum), and the same shapes built from a four-byte code point against 2,000 URLs of 2,048 such code points, within 2 seconds each. Measured with the throwaway build's matcher: at most 134 ms over ASCII and 335 ms over four-byte code points. Mutation checked: a two-pointer matcher fails it.
- `manifest_test.exs` keeps its pattern cases unchanged and passes, which is the check that the move changed no message.

---

### `derive_urls` on the `api` function

**Summary**: R1 to R4. The route report-server's applies calls. It reuses `deriveProfile` and `/derive-profile`'s bounds, and writes nothing.

**Files affected**:
- `functions/src/researcher-dashboard/derive-profile-route.ts`: the assignment-URL checks move out of `deriveBodyProblem` into an exported `assignmentUrlsProblem`, which `deriveBodyProblem` calls.
- `functions/src/api/derive-urls.ts`: new, `makeDeriveUrls(deps)`.
- `functions/src/index.ts`: `api.post("/derive_urls", requireHeaderBearer, makeDeriveUrls(...))` with `fetch` and `parseAllowedHosts(rdAuthoringHosts.value())`, read per request as `researcherDashboard` reads it; `GET /`'s method list gains the route.
- `functions/src/api/derive-urls.test.ts`: new.
- `functions/README.md`: the `RD_AUTHORING_HOSTS` row says both `derive-profile` and the `api` function's `derive_urls` read it, and a line under the Researcher Dashboard section says `derive_urls` is on `api`, behind the shared bearer, for report-server's applies route, writes nothing, and takes researcher-supplied URLs, so the allowlist is its only defense (R27).

**Estimated diff size**: ~120 lines

```ts
export type DeriveUrlsDeps = Pick<ProfileDeps, "fetchImpl" | "allowedHosts" | "budgetMs" | "now">

export function makeDeriveUrls(deps: () => DeriveUrlsDeps) {
  return async (req: express.Request, res: express.Response) => {
    const d = deps()
    if (d.allowedHosts.size === 0) {
      return res.error(503, "derive_urls is not configured: RD_AUTHORING_HOSTS unset")
    }
    const body = req.body
    if (typeof body !== "object" || body === null || Array.isArray(body)) return res.error(400, "the body must be a JSON object")
    if (Buffer.byteLength(JSON.stringify(body)) > MAX_BODY_BYTES) return res.error(400, "the body exceeds 256 KiB")
    const problem = assignmentUrlsProblem(body.assignment_urls)
    if (problem) return res.error(400, problem)

    const { interactive_urls, unread, truncated } = await deriveProfile(d, body.assignment_urls)
    return res.success({ interactive_urls, unread, truncated })
  }
}
```

`deriveProfile` never throws for a URL it cannot read (it records it in `unread`), so the handler needs no catch beyond what express gives an unexpected throw. The `api` function's `timeoutSeconds: 300` already covers the deriver's 240-second budget, and `RD_AUTHORING_HOSTS` is already in both projects' `.env`, so the deploy needs no new param.

Tests (`derive-urls.test.ts`, with a stub `fetchImpl` whose body is a `Buffer` reader, since jest's environment has no `TextEncoder`): an allowed and a disallowed host derive the allowed one's interactive URL and record the other as `host not allowed`, with one fetch made; an empty allowlist is 503; 501 URLs, a 2,049-character URL and a 256 KiB-plus body are each 400. `derive-profile-route.test.ts` passes unchanged, which checks the extraction.

---

### The validate route

**Summary**: R9 to R13. publish's pre-transaction checks move into `prepare/4`, which publish and validate share, and validate adds the two checks publish makes inside its transaction as plain reads. `prepare/4` carries the bucket lookup's result in the plan instead of stopping on it: publish refuses on it straight after `prepare/4` with the same 422, and validate reports it as `publishing_unavailable`. So a zip that fails both the bucket and a later check (the origin, the grants) now gets the later check's error from publish, which no caller relies on; the server suite's 347 package and API tests passed unchanged on the throwaway build.

**Files affected**:
- `server/lib/report_server/packages.ex`: `prepare/4` (private), `publish/4` calls it, `validate/4` new.
- `server/lib/report_server_web/api/v1/package_controller.ex`: `validate/2`.
- `server/lib/report_server_web/router.ex`: `post "/packages/validate", PackageController, :validate` in the `:api_authenticated` scope.
- `server/test/report_server_web/api/v1/package_controller_validate_test.exs`: new.
- `server/README.md`: the catalog section names validate (R27).

**Estimated diff size**: ~200 lines

```elixir
def validate(%User{} = user, body, origin_param, official?) do
  with {:ok, plan} <- prepare(user, body, origin_param, official?) do
    package = package_query(user.portal_server, plan.identity) |> Repo.one()
    would_be = package || %Package{maintainer: plan.origin, visibility: "private"}

    if administers?(would_be, user.portal_user_id, plan.allowed) do
      published? =
        !!package and Repo.exists?(from v in PackageVersion, where: v.package_id == ^package.id and v.version == ^plan.attrs.version)

      visibility = if official?, do: "public", else: would_be.visibility
      {:ok, %{identity: plan.identity, version: plan.attrs.version, checksum: plan.checksum, visibility: visibility, already_published: published?,
        publishing_unavailable: with({:error, message} <- plan.bucket, do: message, else: (_ -> nil))}}
    else
      {:error, :forbidden, "you do not administer #{plan.identity}"}
    end
  end
end
```

The controller's `validate/2` is `create/2` with `Packages.validate/4` in place of `Packages.publish/4` and a 200 `json(conn, validated)`, sharing `zip_content_type/1`, `read_archive/1` and `official_param/1`, so content type, length and the 10 MiB cap answer exactly as publish's do.

Tests (`package_controller_validate_test.exs`):
- **Writes nothing**: a passing validate leaves the `packages`, `package_versions` and `package_events` counts and `PackagesMemoryStore.objects()` exactly as before, and answers `{identity, version, checksum, visibility: "private", already_published: false, publishing_unavailable: nil}` with the checksum publish would record.
- **Publish's refusal for the same zip**: for 7,201 seconds, a bad name, the link fixture and a wrong content type, validate and publish answer the same status and the same body.
- **A new package under an ungranted project** is 403, and 200 once the grant is stubbed.
- **An already-published version** is `already_published: true`, and the next version `false`.
- **A portal with no bucket** (`:packages, :buckets` emptied for the test): validate is 200 with `publishing_unavailable: "publishing is not configured for <server>"`, the same zip's publish is 422 with that message, a 7,201-second manifest is still 422 and an ungranted project still 403. Checked in the throwaway build.
- **`official=true`** without the publisher role is 403, and with it answers `visibility: "public"`.

---

### The applies route

**Summary**: R14 to R18. report-server's applicability answer for cc-data and the runner, deriving assignment URLs through `derive_urls`.

**Files affected**:
- `server/lib/report_server/report_service.ex`: `derive_urls/1` and `@derive_receive_timeout 270_000`, and `get_request/0` builds its `Req` from `Application.get_env(:report_server, :report_service_req_options, [])`, so a test can route it through `Req.Test` (no test of `ReportService`'s HTTP calls exists today, and nothing else sets the key).
- `server/test/report_server/report_service_test.exs`: new, the `derive_urls/1` tests below.
- `server/test/support/report_service_stub.ex`: `derive_urls/1`.
- `server/lib/report_server_web/api/v1/package_controller.ex`: `applies/2`, `:unavailable` in `@error_codes`, and the body helpers.
- `server/lib/report_server_web/router.ex`: `post "/packages/applies", PackageController, :applies` in the `:api_authenticated` scope.
- `server/test/report_server_web/api/v1/package_controller_applies_test.exs`: new.
- `server/README.md`: the catalog section names applies (R27).

**Estimated diff size**: ~220 lines

```elixir
# report_service.ex
def derive_urls(assignment_urls) do
  {url, token} = get_endpoint("derive_urls")

  result =
    get_request()
    |> Req.post(url: url, auth: {:bearer, token}, json: %{assignment_urls: assignment_urls},
      receive_timeout: @derive_receive_timeout, retry: false, debug: false)

  case result do
    {:ok, %{status: 200, body: %{"success" => true} = body}} -> {:ok, Map.take(body, ["interactive_urls", "unread", "truncated"])}
    {:ok, %{status: 400, body: %{"error" => error}}} when is_binary(error) -> {:error, {:bad_request, error}}
    _ -> {:error, :unavailable}
  end
end

# package_controller.ex
def applies(conn, params) do
  with {:ok, urls} <- applies_patterns(params["urls"]),
       {:ok, assignment_urls} <- string_list(params, "assignment_urls"),
       {:ok, scope_urls} <- scope_urls(params),
       {:ok, derived} <- derive(assignment_urls) do
    verdict = Patterns.applies(urls, assignment_urls ++ derived["interactive_urls"] ++ scope_urls)

    json(conn, %{
      applies: verdict == :ok,
      reason: with({:error, reason} <- verdict, do: reason, else: (_ -> nil)),
      interactive_urls: derived["interactive_urls"],
      unread: derived["unread"],
      truncated: derived["truncated"]
    })
  else
    {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
  end
end
```

- `applies_patterns/1` refuses a `urls` that is not a map (absent or `null` included) with `:bad_request`, drops `null` groups and calls `Patterns.validate/1`, a refusal becoming `:bad_request`. validate cannot answer 404 either: every error kind `prepare/4` returns maps to a code other than `NOT_FOUND`.
- `scope_urls/1` takes at most 1,000 strings of at most 2,048 code points (`length(String.codepoints(url))`; `@max_scope_urls`, `@max_url_length`). The list step reuses it, and requires the key first.
- `derive([])` answers empty without a call. Otherwise a `{:bad_request, message}` from the function becomes 400 with its message, and anything else 503 "report-service could not derive the assignments' interactive URLs; retry". The function's bounds are the only copy (R14).
- `retry: false` keeps `Req` from repeating a 240-second derivation on a transient error. 270 seconds sits past the deriver's 240-second budget and inside cc-data's 5 minutes.

Tests (`package_controller_applies_test.exs`, with `ReportServiceStub` installed through `:report_service_client` as `bulk_export_controller_test.exs` does, stopping any running stub agent before starting one):
- **Scope URLs as given**: no derive call (the stub flunks if called), `null` groups accepted, `{applies: true, reason: nil, interactive_urls: [], unread: [], truncated: false}`.
- **Assignment URLs derived**: the stub's interactive URLs, unread and truncation are passed through, a pattern matching only a derived interactive URL applies, one matching only the assignment URL itself applies, and a refusal carries R7's wording.
- **Never 404**: a deriver 400 is 400 `BAD_REQUEST`, and `:unavailable` is 503 `SERVICE_UNAVAILABLE`.
- **Bad bodies**: an absent `urls`, a `text/plain` body, an unknown group, 21 patterns, 1,001 scope URLs, a scope URL of 2,049 code points and a one-grapheme scope URL of 3,901 code points (a letter and 3,900 combining marks) are each 400, and a scope URL of 2,048 four-byte code points is accepted. Checked in the throwaway build: the absent `urls` and the `text/plain` body each answered 200 `applies: true` before the check and 400 after.
- **The contract's URL limit**: a scope URL of `limits.max_url_length` code points, read from the fixture, is 200 and one more is 400. Checked in the throwaway build: these three limit assertions pass, and a fixture saying 7,201 and 2,047 fails all three.
- **Authentication**: no token is 401; a `researcher-dashboard`-labeled token (minted with `Accounts.mint_dashboard_token/1`) is accepted, which is the runner's case.
- **`ReportService.derive_urls/1` itself** (`report_service_test.exs`, `async: false`, putting `plug: {Req.Test, __MODULE__}` in `:report_service_req_options` and deleting it on exit): 200 maps to `{:ok, ...}` with only the three keys, 400 to `{:bad_request, message}`, and 404, 500 and 503 to `:unavailable`; the request goes to `.../derive_urls` with the bearer and `{"assignment_urls": [...]}`. Built and passing in the throwaway build (Req 0.4.14).
- **The runner's token**: built and passing in the throwaway build, a token from `Accounts.mint_dashboard_token/1` for a project researcher gets 200 from applies.

---

### Applicability on the package list

**Summary**: R19 and R20. `POST /api/v1/packages/list` answers the GET's list with `applies` on each row; the GET is unchanged.

**Files affected**:
- `server/lib/report_server_web/router.ex`: `post "/packages/list"` and `options "/packages/list"` in the `:api_catalog` scope.
- `server/lib/report_server_web/api/v1/package_controller.ex`: `index/2` and `list/2` share `list_packages/3`, passing `nil` or the checked scope URLs.
- `server/lib/report_server_web/api/v1/package_json.ex`: `index/2`, which adds `applies` per row only when given URLs, and the moduledoc's "lists and matches" becomes "lists, with applicability from `POST /api/v1/packages/list`," since the app keeps no matcher.
- `server/lib/report_server_web/api/catalog_cors.ex`: methods `GET, POST`, headers `authorization, content-type`, and a preflight that does not ask for `authorization` answered `*` from any origin.
- `server/test/report_server_web/api/catalog_cors_test.exs`: the preflight test's header pins and its `FORBIDDEN` case updated (below).
- `server/test/report_server_web/api/v1/package_controller_read_test.exs`: the list cases.
- `server/README.md`: the list's applicability, and which routes carry CORS (R27).

**Estimated diff size**: ~180 lines

```elixir
# catalog_cors.ex, between the anonymous non-OPTIONS clause and the allowlisted origin
conn.method == "OPTIONS" and not requests_authorization?(conn) ->
  conn
  |> put_resp_header("access-control-allow-origin", "*")
  |> put_resp_header("access-control-allow-headers", "content-type")
  |> put_resp_header("access-control-allow-methods", "GET, POST")
```

A preflight that does not ask for `authorization` precedes a request without a bearer, which every origin may already make. A request with a bearer still needs a preflight asking for it, which is still answered only for `cors_origins`. So `catalog_cors_test.exs`'s `FORBIDDEN` case gains `access-control-request-headers: authorization`, which is what it was testing, and its header pins become `authorization, content-type` and `GET, POST`.

Tests:
- **Read test**: with two official packages patterned `*open-response*` and `*drawing*`, `POST /api/v1/packages/list?portal=...` with one open-response URL marks them `true` and `false`; the same read with the access token marks the token's visible list; `GET` rows carry no `applies` key; a package with no patterns is `true` on an empty `scope_urls`; an absent `scope_urls` and 1,001 scope URLs are each 400.
- **CORS test**: an anonymous preflight from an unlisted origin is 204 with `*`; one asking for `authorization` from it is 403; one from an allowlisted origin echoes the origin with the new headers.

## Release

- **Before the deploy**, read `ReportServiceUrl` on the `report-service-qa` stack and confirm it names `report-service-dev`'s `api` function, since staging report-server reaches `derive_urls` through it (production's default is `report-service-pro`'s, in `config/runtime.exs`).
- **Order** (R28): deploy the `api` function (`firebase deploy --only functions:api`, Functions 1.9.0) to `report-service-dev`, then report-server 1.13.0 to staging. Before the function is deployed, applies with assignment URLs answers 503, never 404.
- **Staging check**: with a staging cc-data token, validate a good zip (200), a 7,201-second manifest and `symlink-entrypoint.zip` (422 each); applies with a staging class's Activity Player assignment URLs answers with derived interactive URLs and refuses a pattern none of them matches; `POST /api/v1/packages/list?portal=learn.portal.staging.concord.org` with scope URLs marks `applies`. Post the deploy to the stream channel.
- **Production** follows the same order, against `report-service-pro`.

## Open Questions

### RESOLVED: Judgment call: one shared `prepare/4`, or validate as a rolled-back publish?
**Options considered**:
- A) Extract publish's pre-transaction checks into `prepare/4` and repeat its two in-transaction checks as plain reads.
- B) Run publish inside a transaction that always rolls back, with a store that writes nothing.

**Decision**: A. B takes the `FOR UPDATE` lock and can insert and roll back a package row, which R11 rules out, and it would make validate wait behind a concurrent publish. A repeats two short checks, each a read.

### RESOLVED: Judgment call: read the central directory, or replace `:zip`?
**Options considered**:
- A) Keep `:zip.list_dir/1` for listing and read only the external attributes from the central directory.
- B) Parse the whole archive ourselves and drop `:zip`.

**Decision**: A. `:zip` already decides what a readable archive is, and only the file type is missing from what it reports.

### RESOLVED: Judgment call: where does the scope-URL bound live?
**Options considered**:
- A) In the controller (`@max_scope_urls`, `@max_url_length`), shared by applies and the list.
- B) In `Patterns`, beside the pattern caps.

**Decision**: A. It is a request bound, not a property of patterns, and both routes that take scope URLs are in one controller.

## Self-Review

Roles: the commit reviewer, the test writer, the operator, Security Engineer. Each finding was checked by building it in the throwaway tree, and each is fixed in place.

### Test writer

#### RESOLVED: `ReportService.derive_urls/1` could not be tested as written
No test exercises `ReportService`'s HTTP calls today, and `get_request/0` builds a bare `Req.new()`, so there was no way to put `Req.Test` in front of it. The applies step now adds `:report_service_req_options`, and the `derive_urls/1` tests were built on it and pass.

#### RESOLVED: The link fixtures' rebuild was asserted, not shown
The extended `build.sh` was run twice: identical hashes for all five zips, the two existing ones unchanged, and all three link fixtures refused. The Go link fixture is now named.

#### RESOLVED: The runner's token on applies was assumed
A `researcher-dashboard` token from `Accounts.mint_dashboard_token/1` gets 200 from applies in the throwaway build; the applies step names the test.

### Operator

#### RESOLVED: Staging's derive target was not checked
Staging report-server reaches the function through its stack's `ReportServiceUrl`, a parameter this repository cannot see. The release section now reads it before the deploy.

### Commit reviewer

#### RESOLVED: `functions/README.md` would describe the allowlist wrongly
Its `RD_AUTHORING_HOSTS` row says only `derive-profile` reads it. The `derive_urls` step updates the row and adds the route, and R27 names the file.

Each step was checked for forward dependencies: the list step reuses `scope_urls/1` from the applies step before it, and the validate step's link-fixture test uses the stricter-rules step's fixture, also earlier. No other step uses a later one.

### Round two

Roles: Senior Engineer, Performance and Security Engineer, QA Engineer, the consuming stories (REPORT-146, RD-4), the commit reviewer. Each finding was reproduced in a scratch worktree of `067a1c4` with the stage-5 throwaway patch applied, with throwaway probe tests where the claim was about behavior.

### Senior Engineer

#### RESOLVED: applies answers `applies: true` for a request it never read
An absent `urls` and a non-JSON body each answered 200 `applies: true` in the throwaway build. R14 now requires `urls` as an object and R19 requires `scope_urls`; with the fix, both cases answer 400.

#### RESOLVED: R10's list of checks is garbled
Fixed in R10.

#### RESOLVED: `Patterns.groups/0` has no caller
Dropped from the matcher step.

### Performance and Security Engineer

#### RESOLVED: the scope-URL bound counts graphemes, so it does not bound bytes
A 7.8 MB body of one-grapheme URLs passed `String.length/1`. R14 now bounds scope URLs in code points (Doug, 2026-10-08, after RD-4's session noted in #28 that a byte bound refuses a non-ASCII URL the function keeps, since the function counts UTF-16 units), and R6's timing test runs at applies' real maximum of 2,000 URLs, ASCII and four-byte (335 ms worst case, measured).

### QA Engineer

#### RESOLVED: the link check's archive-comment path is live and untested
`:zip` accepts an Info-ZIP archive with a comment, so the reason given for skipping it was wrong. The stricter-rules step now adds `symlink-entry-commented.zip` and corrects the sentence.

#### RESOLVED: "Never 404" in the validate tests names no test
Moved from the validate tests into the applies step's prose.

### Consuming stories (REPORT-146, RD-4)

#### RESOLVED: the runner's limits are kept twice with nothing asserting they agree
A (Doug, 2026-10-08): `fixtures/package-contract.json` gains `limits` (R23, R24). report-server checks both limits at their boundaries, the function checks `MAX_URL_LENGTH`, and R26 has RD-4 check its default and refuse at startup a configured ceiling below the fixture's.

#### RESOLVED: REPORT-146 does not read `already_published`, and its contract still says validate refuses as publish does
Posted to `stream/researcher-dashboard/general` (#8, 2026-10-08) for REPORT-146's session: `ValidatedPackage` gains `already_published`, `build` warns on it and `run` ignores it. REPORT-146's spec owns the change.

### Commit reviewer

#### RESOLVED: `PackageJSON`'s moduledoc says the app matches
Named in the list step and R27.