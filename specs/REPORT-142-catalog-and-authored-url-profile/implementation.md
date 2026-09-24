# Implementation Plan: report-service: the catalog and the authored URL profile

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-142
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Eight steps, one commit each, on top of REPORT-141's implementation.

- report-server's five steps come first: the tables, the archive reader, publish, state changes, then reading with CORS.
- The function's two steps follow: the deriver's pure logic, then the route, task and write.
- A configuration step closes.

Each step is testable on its own:
- report-server's with `mix test` against the port-3406 MySQL, with the four placeholder environment variables.
- The function's with Jest 24 on Node 22, with `fetch`, Firestore and the task client injected as fakes, as REPORT-141 injects Firestore and `ensureVm` in `run-package.test.ts` and `fetchImpl` in `ensure-vm.test.ts`.

**What REPORT-141 built, as this plan uses it (checked against its implementation, 2026-09-24).**
- `researcherDashboardApp(deps: () => RunPackageDeps)` in `app.ts` applies `requireHeaderBearer` and `portalAssertionAuth` to every route. It takes one deps factory today, so adding `/derive-profile` widens that parameter to carry this route's deps (the `enqueue` seam) too.
- Errors go through the repo's `res.error(status, message)`, which answers `{success: false, error}`. `/run-package` answers 503 naming any unset launch setting before it writes anything.
- The Firestore fake is shared at `functions/src/test/researcher-dashboard-fake-db.ts`. It runs transactions one at a time, models `merge` and `mergeFields`, and copies only maps and arrays, so a `Timestamp` such as `requested_at` reads back as a `Timestamp`. The ordered-write tests below use it rather than a fake of their own. The `Db`, `DocRef` and `Transaction` interfaces it implements are in `run-package.ts`.
- `run-package.test.ts` drives the real express app over HTTP on an ephemeral port, under `@jest-environment node` and with `express.json()` in front, since Firebase parses the body first. The `node` test environment has no `AbortSignal` or `AbortController` (jsdom has its own), and Jest 24 cannot load a package that imports `node:` builtins, such as the AWS SDK v3 clients, so such a module is replaced with `jest.mock`.
- Every dashboard string param in `config.ts` defaults to `""`, and `RD_QUEUE_CAP` to 20. The secrets `RD_AWS_KEY` and `RD_AWS_SECRET_KEY` are the exception: they have no default and are never in a `.env` file. Every non-secret param is still listed in both `.env.report-service-*` files, because firebase-tools prompts for (or, non-interactively, fails on) a declared param a file leaves out, whatever its default.
- `/run-package` validates `class_hash` as `^[0-9a-f]{48}$`, the same rule R20 gives `/derive-profile`.
- report-server's `PortalTokenPlug.init/1` returns the audience string (`Keyword.fetch!(opts, :audience)`), so the `optional: true` mode below changes what `init/1` returns. The plug halts through `ErrorHelpers.not_authenticated/1`.

### report-server: the catalog tables and the `Packages` context

**Summary**: Adds `packages`, `package_versions`, `package_events` and the publisher grant, with schemas and the identity grammar. Nothing is routed yet. Covers R1 to R4 and R11's storage.

**Files affected**:
- `server/priv/repo/migrations/20260925120000_create_packages.exs` — new
- `server/priv/repo/migrations/20260925120100_add_package_publisher_to_users.exs` — new
- `server/lib/report_server/packages.ex` — new context
- `server/lib/report_server/packages/package.ex`, `package_version.ex`, `package_event.ex` — new schemas
- `server/lib/report_server/packages/identity.ex` — new
- `server/lib/report_server/accounts/user.ex` — `field :package_publisher, :boolean, default: false`, not cast from portal info
- `server/lib/report_server/release.ex` — `grant_package_publisher/2`, `revoke_package_publisher/2`
- `server/test/report_server/packages/identity_test.exs`, `packages_test.exs` — new

**Estimated diff size**: ~380 lines

```elixir
  def change do
    create table(:packages) do
      add :portal_server, :string, null: false
      add :identity, :string, null: false          # "<origin>/<name>", immutable
      add :origin, :string, null: false            # "users/136" | "projects/20"
      add :name, :string, null: false
      add :maintainer, :string, null: false        # same grammar as origin
      add :visibility, :string, null: false, default: "private"   # private | project | public
      add :project_id, :integer                    # the portal admin project, when visibility is project
      add :official, :boolean, null: false, default: false
      add :archived, :boolean, null: false, default: false
      add :current_version, :string
      timestamps(type: :utc_datetime)
    end
    # Unique per portal (R2). The indexes below serve every read without a scan (R16).
    create unique_index(:packages, [:portal_server, :identity])
    create index(:packages, [:portal_server, :official, :archived])
    create index(:packages, [:portal_server, :visibility, :archived])
    create index(:packages, [:portal_server, :maintainer])

    create table(:package_versions) do
      add :package_id, references(:packages, on_delete: :restrict), null: false
      add :version, :string, null: false
      add :checksum, :string, null: false          # "sha256:<hex>"
      add :s3_key, :string, null: false
      add :published_at, :utc_datetime, null: false
      add :published_by, references(:users, on_delete: :restrict), null: false
      add :title, :string, null: false
      add :description, :string, size: 500
      add :urls, :map, null: false                 # a MySQL json column, as export_scratch.endpoint_set is; {"all": [], "any": [], "none": []}
      add :clue_prepull, :boolean, null: false, default: false
      add :expected_duration_seconds, :integer, null: false
    end
    create unique_index(:package_versions, [:package_id, :version])

    create table(:package_events) do
      add :package_id, references(:packages, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :field, :string, null: false             # visibility | project_id | official | archived | current_version
      add :previous_value, :string
      add :new_value, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end
    create index(:package_events, [:package_id])
  end
```

`Identity`:

```elixir
  @name ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @origin ~r/\A(users|projects)\/([1-9][0-9]*)\z/

  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)
  def parse_origin(origin) ...          # {:ok, {:users | :projects, id}} | :error
  def identity(origin, name), do: "#{origin}/#{name}"
  def s3_key(identity, version, ext), do: "packages/#{identity}/#{version}.#{ext}"
```

`Packages.administers?(package, portal_user_id, allowed_project_ids)` is R4's single definition. It is true when the maintainer is `users/<portal_user_id>`, or when the maintainer is `projects/<p>` and `p` is in the allowed ids (`:all` included). Both endpoints and the list's `mine` flag call it.

The publisher grant (R11) is a column set only by the release task, and never by `find_or_create_user`'s changeset. `Packages.publisher?(user)` is `user.package_publisher or user.portal_is_admin`, so every site admin holds the role as well. On the cc-data token path, the stored flags are the ones a portal login last refreshed.

**Tests**:
- The grammar: underscore, uppercase, 64 characters and a leading hyphen are refused; `users/0` and `groups/1` are refused as origins.
- `administers?` for a user maintainer, a project maintainer with and without a grant, and `:all`.
- `publisher?` is true for the flag, true for a site admin without the flag, and false for a project admin or researcher.
- The unique index refuses a second identity on one portal and accepts it on another.

---

### report-server: read the archive and project the manifest

**Summary**: `Packages.Archive` validates an upload and reads only its manifest, with the bound on actual output that stage 3 found necessary. `Packages.Manifest` validates the section 10 shape and projects it into version attributes. There is a fixture archive and a test that catches drift. Covers R6 to R8, and the story's "a test over a fixture manifest catches drift".

**Files affected**:
- `server/lib/report_server/packages/archive.ex` — new
- `server/lib/report_server/packages/manifest.ex` — new
- `server/test/support/fixtures/packages/class-counts-1.0.6.zip` — new, built by a committed script
- `server/test/support/fixtures/packages/build.sh` — new: builds the fixture reproducibly (`zip -X`, sorted, fixed mtime)
- `server/test/report_server/packages/archive_test.exs`, `manifest_test.exs` — new

**Estimated diff size**: ~360 lines

`Archive.read_manifest/1` is the stage 4 probe made permanent:
- Entries come from `:zip.list_dir/1`'s central directory, with offset and compressed size taken from there, since Go's `archive/zip` leaves the local header's sizes zero.
- Exactly one entry named `manifest.json` must exist.
- No entry may be absolute or contain `..`.
- The declared uncompressed total must be at most 50 MiB.
- The manifest's deflate stream is fed through `:zlib.safeInflate/2` and abandoned once output passes 64 KiB.
- Stored (method 0) entries are length-checked, and any other method is refused.
- `entrypoint` must name an entry in the list.

```elixir
  @spec read_manifest(binary()) :: {:ok, map(), [String.t()]} | {:error, String.t()}
```

`Manifest.project/1` returns the `package_versions` attributes from a decoded manifest, or `{:error, message}`, applying R7 and R8 in full. The drift test decodes the fixture with `Archive` and `Manifest` and asserts every projected field against the JSON literal inside the fixture's `manifest.json`. A field added to the manifest contract without a projection change fails it.

**Tests**:
- Accepted: the fixture, and a Go-written archive (committed as a fixture beside it, produced by a four-line Go program kept in `build.sh`'s comments).
- Refused, each with its message:
  - a non-zip
  - no manifest, a nested manifest, and two manifests
  - a manifest declaring 100 bytes that inflates to 20 MB (the stage 3 case, generated in the test)
  - a 50 MB bomb
  - a `../x` entry
  - an entrypoint not in the archive
  - each R7 field malformed
  - an `owner` or `official` key
  - 21 patterns, a 257-character pattern, and a pattern with a space

---

### report-server: `POST /api/v1/packages`

**Summary**: The publish endpoint. It reads the raw body with a cap, validates, computes the checksum, resolves origin and maintainer, and inserts the rows. It writes both S3 objects inside the same transaction, before the commit. Covers R5, R9, R10 and R27's bucket map.

**Files affected**:
- `server/lib/report_server/packages/store.ex` — new: `put(portal_server, key, body)` behaviour; `S3Store` and a test `MemoryStore`
- `server/lib/report_server/packages.ex` — `publish/4`
- `server/lib/report_server_web/api/v1/package_controller.ex` — new, `create/2`
- `server/lib/report_server_web/api/error_helpers.ex` — `"FORBIDDEN" => 403`, `"ALREADY_EXISTS" => 409`
- `server/lib/report_server_web/router.ex` — `post "/packages"` in the existing `:api_authenticated` scope
- `server/config/runtime.exs`, `config/test.exs` — `:packages` config
- `server/test/report_server_web/api/v1/package_controller_create_test.exs` — new

**Estimated diff size**: ~420 lines

The controller reads the body with `Plug.Conn.read_body(conn, length: 10 * 1024 * 1024)`. A `{:more, _, _}` answers 422 "archive exceeds 10 MiB". A content type other than `application/zip` is 400. `Plug.Parsers` passes `application/zip` through unread, which stage 5 checked with a throwaway route: a Go-written zip arrived byte-identical.

```elixir
  def publish(user = %User{}, body, origin_param, official?) do
    with {:ok, manifest, _entries} <- Archive.read_manifest(body),
         {:ok, attrs} <- Manifest.project(manifest),
         {:ok, bucket} <- Store.bucket_for(user.portal_server),          # R27: no bucket, no publish
         {:ok, origin} <- resolve_origin(user, origin_param),            # users/<id>, or projects/<p> with a grant
         :ok <- check_official(user, official?) do                       # R11
      identity = Identity.identity(origin, attrs.name)
      checksum = "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

      Repo.transaction(fn ->
        package = find_or_insert_package(user.portal_server, identity, origin, official?)   # new: private, or official+public
        unless administers?(package, user) do Repo.rollback(:forbidden) end
        version = insert_version!(package, attrs, checksum, user)        # unique index: a concurrent twin waits here, then fails
        package = maybe_move_pointer(package, version, user)             # new or private: move, with an audit row (R10, R12)
        # Written before commit, so the loser of a race never reaches S3 (Self-Review, requirements).
        :ok = Store.put(bucket, Identity.s3_key(identity, attrs.version, "zip"), body) |> ok_or_rollback()
        :ok = Store.put(bucket, Identity.s3_key(identity, attrs.version, "sha256"), checksum) |> ok_or_rollback()
        {package, version}
      end)
    end
  end
```

An existing (identity, version) is found by the insert's unique constraint and answered 409 `ALREADY_EXISTS`. That covers both the sequential case and the concurrent twin that waited. Store failures roll back and answer 503 naming S3.

`S3Store.put/3` uses `AWS.S3.put_object` with a client built from the packages credentials in `us-east-1`. Those credentials are `PACKAGES_AWS_ACCESS_KEY_ID` and `PACKAGES_AWS_SECRET_ACCESS_KEY`, the dedicated `packages/*`-only user RD-1 creates per runner stack. `runtime.exs` raises if `PACKAGE_BUCKETS` names a portal and either key is missing. There is no fallback to the server credentials.

`PACKAGE_BUCKETS` is JSON `{"learn.concord.org": "<bucket>"}`, parsed at boot. A value repeated across portals raises in `runtime.exs` (R27).

Tests run with `MemoryStore`, which records puts and can be told to fail. The Go fixture's publish checks that the stored `.sha256` equals the checksum and the zip equals the body.

**Tests**:
- Publishing:
  - 201 with a private package, a version row, the pointer moved, and two stored objects.
  - The second publish of the same version is 409 and stores nothing.
  - Two concurrent publishes of one version (two `Task`s, sandbox in shared mode): exactly one 201, and the stored bytes are the winner's. Under the sandbox the two share one connection and serialize on it rather than on the unique index, so this asserts the outcome only; the InnoDB wait that makes it hold in production was verified against the port-3406 MySQL (requirements, Self-Review).
  - A new version of a private package moves the pointer and writes an audit row naming the previous version.
  - A new version of a `public` package does not move it.
- Origin and role:
  - `origin=projects/20` with a grant publishes under it; without one, 403.
  - `official=true` without the role is 403; with it, the package is official and public and the pointer moves.
  - Another user's package is 403.
- Refusals:
  - A portal with no bucket is 422 naming it.
  - An S3 failure rolls back, with no rows.
  - A body over 10 MiB is 422.
  - A non-zip content type is 400.
  - An anonymous or `NOT_AUTHENTICATED` token is 401.

---

### report-server: state changes and their audit rows

**Summary**: `POST /api/v1/packages/:kind/:owner_id/:name/:state` for `visibility`, `official`, `archived` and `current_version`. Each change is one transaction with its `package_events` row. Covers R12 and R13.

**Files affected**:
- `server/lib/report_server/packages.ex` — `change_state/4`
- `server/lib/report_server_web/api/v1/package_controller.ex` — `update_state/2`
- `server/lib/report_server_web/router.ex` — the route in `:api_authenticated`
- `server/test/report_server_web/api/v1/package_controller_state_test.exs` — new

**Estimated diff size**: ~300 lines

The path rebuilds the identity from `kind` (`users` | `projects`), `owner_id` and `name`, and looks it up on the caller's portal. An unknown identity is 404. The JSON body is:
- `{"visibility": "project", "project_id": 20}`
- `{"official": true}`
- `{"archived": true}`
- `{"current_version": "1.0.6"}`

```elixir
  defp apply_change(package, field, new_value, user) do
    previous = Map.fetch!(package, field)
    if previous == new_value do
      {:ok, package}                                   # R12: no-op, no audit row
    else
      Repo.transaction(fn ->
        package = package |> Package.state_changeset(%{field => new_value}) |> Repo.update!()
        Repo.insert!(%PackageEvent{package_id: package.id, user_id: user.id, field: to_string(field),
                                   previous_value: to_audit(previous), new_value: to_audit(new_value)})
        package
      end)
    end
  end
```

Authorization per R12:
- `official` requires `Packages.publisher?(user)`, and setting it true also sets visibility `public` (two audit rows).
- The other states require `administers?`.
- `visibility: project` requires `project_id` in the caller's allowed ids, and leaving `project` clears `project_id`.
- `current_version` must name an existing version of this package.

**Tests**:
- Each state moves and writes exactly one row naming the previous value.
- Rolling `current_version` back leaves every version row and store object in place.
- Setting a value to itself writes nothing.
- A non-maintainer is 403.
- A maintainer setting `official` is 403, and the role holder sets it.
- `project` without a grant is 403.
- An unknown version is 422.
- Another portal's package is 404.
- Archiving keeps the version resolvable (checked in the next step's tests).

---

### report-server: reading, resolving, and CORS

**Summary**: `GET /api/v1/packages` and `GET /api/v1/packages/resolve`, anonymous or with a `researcher-dashboard` launch token. The caller's flags and grants are read from the portal with a short timeout, and a new CORS plug sits on these two routes only. Covers R14 to R18 and R27's CORS and unreviewed-runs settings.

**Files affected**:
- `server/lib/report_server_web/api/portal_token_plug.ex` (from REPORT-141) — an `optional: true` option: no `Authorization` header passes through unauthenticated, while a present but invalid one is still 401
- `server/lib/report_server_web/api/catalog_cors.ex` — new
- `server/lib/report_server/portal_dbs.ex` — `get_user_roles/3` (flags for a portal user id), `get_project_names/3`
- `server/lib/report_server/packages.ex` — `list_visible/2`, `resolve/3`
- `server/lib/report_server_web/api/v1/package_controller.ex` — `index/2`, `resolve/2`, `preflight/2`
- `server/lib/report_server_web/api/v1/package_json.ex` — new
- `server/lib/report_server_web/router.ex` — a `:api_catalog` pipeline and scope above the catch-all
- `server/test/report_server_web/api/v1/package_controller_read_test.exs`, `catalog_cors_test.exs` — new

**Estimated diff size**: ~450 lines

```elixir
  pipeline :api_catalog do
    plug :force_json
    plug ReportServerWeb.Api.CatalogCors
    plug ReportServerWeb.Api.PortalTokenPlug, audience: "researcher-dashboard", optional: true
  end

  scope "/api/v1", ReportServerWeb.Api.V1 do
    pipe_through :api_catalog
    get "/packages", PackageController, :index
    get "/packages/resolve", PackageController, :resolve
    options "/packages", PackageController, :preflight
    options "/packages/resolve", PackageController, :preflight
  end
```

The scope sits above the existing `:api_authenticated` scope, so `GET /packages` never reaches `AuthPlug`. `POST /packages` in `:api_authenticated` is unaffected, since Phoenix matches on method.

`CatalogCors` is the probe's shape, with the allowlist read from `:packages, :cors_origins`:
- No `Origin`: passes untouched.
- `Origin` and no `Authorization` on a non-`OPTIONS` request: `Access-Control-Allow-Origin: *`.
- An allowlisted origin: echoed, with `Vary: Origin`, `Access-Control-Allow-Headers: authorization` and `Access-Control-Allow-Methods: GET`.
- Anything else: 403 and halt.

The controller sets `Cache-Control: no-store` whenever `:portal_claims` is assigned. Stage 5's throwaway route measured the answers: anonymous with any `Origin` got `*`; an allowlisted preflight got 204 with the origin echoed; an unlisted preflight and an unlisted bearer request got 403; `OPTIONS` on another `/api/v1` route still reached the 404 catch-all.

The caller, when a bearer is present:

```elixir
  defp caller(%{"iss" => iss, "uid" => uid}) do
    server = PortalDbs.get_server_for_portal_url(iss)
    with true <- PortalDbs.has_db_connection?(server) || {:error, :unknown_portal},
         {:ok, flags} <- PortalDbs.get_user_roles(server, uid, timeout: @portal_timeout_ms),   # R15: fresh, not the stored copy
         user = %User{portal_server: server, portal_user_id: uid,
                      portal_is_admin: flags.is_admin, portal_is_project_admin: flags.is_project_admin,
                      portal_is_project_researcher: flags.is_project_researcher},
         ids when is_list(ids) or ids in [:all, :none] <- PortalDbs.get_allowed_project_ids(user, timeout: @portal_timeout_ms) do
      {:ok, %{server: server, uid: uid, allowed: ids}}
    end
  end
```

`@portal_timeout_ms` is 5,000, matching `filter_options.ex:21`. A portal error or timeout answers 503 `SERVICE_UNAVAILABLE`, and an unknown portal answers 401.

`get_user_roles/3` is `get_user_info`'s role subqueries keyed on `u.id = ?` rather than an access grant. The `User` struct is transient and never inserted.

`list_visible/2` is one query:

```elixir
    from p in Package,
      where: p.portal_server == ^server and not p.archived,
      where: p.official or p.visibility == "public" or p.maintainer == ^"users/#{uid}"
             or (p.visibility == "project" and p.project_id in ^project_ids)      # :all -> any project row
             or (fragment("? LIKE 'projects/%'", p.maintainer) and p.maintainer in ^maintainer_projects),
      join: v in PackageVersion, on: v.package_id == p.id and v.version == p.current_version,
      select: {p, v}
```

The anonymous form keeps only `p.official`, on the `portal` query parameter's server. An unknown portal answers an empty list. Project names come from one `get_project_names/3` call for the distinct `project_id`s, and a failure there leaves names null rather than failing the list.

`resolve/3` applies the same visibility predicate without the `archived` filter, joins the named version, and computes:

```elixir
  runnable = not p.archived and (p.official or Application.get_env(:report_server, :packages)[:unreviewed_runs])
  reason = cond do p.archived -> "archived"; not runnable -> "not official, and unreviewed runs are not enabled"; true -> nil end
```

The response per package (R16), which RD-3 renders and RIGSE-368 reads:

```json
{ "catalog_id": 12, "identity": "projects/20/class-counts", "origin": "projects/20", "name": "class-counts",
  "maintainer": "projects/20", "visibility": "public", "official": true, "runnable": true, "mine": false,
  "project": null,
  "current_version": { "version": "1.0.6", "checksum": "sha256:...", "title": "Class counts", "description": "...",
                       "urls": {"all": [], "any": ["*collaborative-learning/*unit=dataflow*"], "none": []},
                       "clue_prepull": true, "expected_duration_seconds": 120, "published_at": "..." } }
```

`resolve` answers `{catalog_id, identity, version, checksum, expected_duration_seconds, clue_prepull, archived, runnable, reason}`, with `clue_prepull` from the resolved version's row, which RIGSE-368 reads to decide whether to mint the CLUE class token.

**Tests** (portal reads are faked through a `PortalDbs` seam configured in `test.exs`, as `endpoint_set.ex`'s `allowed_project_ids_source()` already does):
- The list:
  - Anonymous: official rows only, on the named portal only.
  - With a launch token: adds public, own, project-granted and project-maintained rows, and excludes another portal's rows, archived rows, and a `project` row on an ungranted project.
  - A site admin (`:all`) sees every project row.
  - An expired or wrong-audience bearer is 401, not the anonymous answer.
  - A portal timeout is 503.
- Resolve:
  - An invisible package is 404.
  - An archived one is `runnable: false, reason: "archived"`.
  - A private own package is `runnable: false` until `unreviewed_runs` is set, then `true`.
  - An official one is `runnable: true`.
  - A non-current version resolves, with that version's own `clue_prepull` rather than the current version's.
- CORS: the probe's cases, plus `Cache-Control: no-store` on bearer answers.

---

### function: the deriver's extraction, container rule and fetch

**Summary**: Pure, injectable logic for R22 to R24: which assignment URLs are containers, the host allowlist, a bounded fetch, interactive URL extraction, and assembling the document. There is no route yet. Covers R22 to R24.

**Files affected**:
- `functions/src/researcher-dashboard/derive-profile.ts` — new
- `functions/src/researcher-dashboard/derive-profile.test.ts` — new
- `functions/src/researcher-dashboard/fixtures/` — new: trimmed copies of the stage 4 activity and sequence JSON (two activities, one sequence), plus a generated 35-activity class

**Estimated diff size**: ~380 lines

```ts
export interface ProfileDeps {
  fetchImpl: (url: string, init: { redirect: "manual"; signal: AbortSignal }) => Promise<Response>
  allowedHosts: Set<string>
  now: () => number
}

// R22: a container names its content in `activity` or `sequence`, as an absolute URL.
export function contentUrlOf(assignmentUrl: string): string | undefined {
  let u: URL
  try { u = new URL(assignmentUrl) } catch { return undefined }
  const c = u.searchParams.get("activity") ?? u.searchParams.get("sequence")
  return c && /^https?:\/\//.test(c) ? c : undefined
}

// Exact hostname, no userinfo, default port; http is fetched as https (R22).
export function allowedContentUrl(contentUrl: string, allowed: Set<string>): string | undefined { ... }

// R23. Reads nothing but the embeddable type, the base URL, its fragment and the legacy url.
export function interactiveUrls(activity: any): string[] {
  const out: string[] = []
  for (const page of activity?.pages ?? []) {
    const embeddables = [...(page.embeddables ?? []), ...(page.sections ?? []).flatMap((s: any) => s.embeddables ?? [])]
    for (const e of embeddables) {
      if (e?.type === "ManagedInteractive") {
        const base = e.library_interactive?.data?.base_url
        if (typeof base === "string" && base) out.push(base + (typeof e.url_fragment === "string" ? e.url_fragment : ""))
      } else if (e?.type === "MwInteractive" && typeof e.url === "string" && e.url) {
        out.push(e.url)
      }
    }
  }
  return out
}

export async function deriveProfile(deps: ProfileDeps, assignmentUrls: string[]): Promise<Derived> { ... }
```

`deriveProfile` works through the content URLs:
- De-duplicates them.
- Fetches with at most 5 in flight, each under a 15-second `AbortController` and `redirect: "manual"`, so a 3xx is a failure (`"redirect not followed"`). `derive-profile.test.ts` stays on Jest's default jsdom environment, because the node environment has no `AbortController`.
- Reads the body through its stream reader and abandons it past 5 MiB.
- Retries a network error or 5xx once.

A sequence's `activities[]` and a bare activity both go through `interactiveUrls`. The result is:
- `interactive_urls`: distinct and sorted, cut to 500 with `truncated` set.
- `content_urls`: read successfully.
- `unread`: `{url, reason}` for refused, failed, non-JSON and oversize URLs.

Each `fetchImpl` in tests is a fake, since Jest 24's jsdom environment has no `fetch`. At deploy, `deps.fetchImpl` is Node 22's global `fetch`.

**Tests**:
- Extraction:
  - The fixtures yield exactly the stage 4 URLs, protocol-relative and fragment-only Lab URLs intact, and nothing from `Embeddable::Xhtml` or `Labbook`.
  - A `url_fragment` is appended, and an empty `MwInteractive.url` is skipped.
  - A pre-sections activity (`pages[].embeddables[]`) is read.
- Containers: a CLUE URL is taken as it stands and never fetched; an encoded and an unencoded `activity=` are followed; `sequence=` is followed.
- The host check: `authoring.concord.org.evil.example`, userinfo and a port are refused and recorded, never requested.
- Fetch failures: a 302 is recorded as not followed; a timeout, a 404 and an oversize body are recorded; a 503 then 200 is retried and read.
- Scale: 35 activities are fetched with at most 5 in flight; 600 distinct URLs truncate to 500.
- Re-running on the same inputs gives an identical result apart from timestamps.

---

### function: `POST /derive-profile`, the task, and the ordered write

**Summary**: The route on `researcherDashboard` validates and enqueues. A v2 `onTaskDispatched` worker, `deriveProfileWorker`, runs the derivation and writes the class document in a transaction that refuses to overwrite a newer request. Covers R19 to R21, R24 to R26.

**Files affected**:
- `functions/src/researcher-dashboard/app.ts` (from REPORT-141) — `app.post("/derive-profile", ...)`, with the app's deps parameter widened to carry this route's
- `functions/src/researcher-dashboard/derive-profile-route.ts` — new: validation and enqueue
- `functions/src/researcher-dashboard/derive-profile-worker.ts` — new: `runDerivation` and `writeProfile`, importing nothing from `firebase-functions`
- `functions/src/researcher-dashboard/derive-profile-task.ts` — new: only the `onTaskDispatched` wrapper, which no test imports, because Jest 24 cannot resolve `firebase-functions/v2/tasks`
- `functions/src/researcher-dashboard/config.ts` (from REPORT-141) — `defineString("RD_AUTHORING_HOSTS", { default: "" })`, following the file's convention, and listed in both `.env` files (configuration step)
- `functions/src/index.ts` — `deriveProfileWorker` added to the `module.exports` object
- `functions/src/researcher-dashboard/derive-profile-route.test.ts`, `derive-profile-worker.test.ts` — new

**Estimated diff size**: ~400 lines

The route:
- Validation per R20: `class_hash` against `^[0-9a-f]{48}$`, the fingerprint length, and the URL count and lengths. `JSON.stringify(req.body).length <= 256 * 1024` is checked first.
- The failure answer is 400 naming the field, with nothing enqueued.
- A valid request takes `requested_at = Date.now()`.
- It enqueues `{portal, platform_id, class_hash, assignment_fingerprint, assignment_urls, requested_at}` with `CloudTasksClient.createTask`, to `https://us-central1-${project}.cloudfunctions.net/deriveProfileWorker` with an OIDC token for `${project}@appspot.gserviceaccount.com`. That is `submitTask`'s pattern (`tasks/submit-task.ts:134-150`), behind a `deps.enqueue` seam.
- Under `FUNCTIONS_EMULATOR` it calls the worker body directly, as `submitTask` does.
- When the parsed `RD_AUTHORING_HOSTS` allowlist is empty, it answers 503 `researcherDashboard is not configured: RD_AUTHORING_HOSTS unset` before validating or enqueuing anything, as `/run-package` does for its launch settings. Otherwise every content URL would be refused and an empty profile written with a 202.
- It answers 202 `{success: true, queued: true}` with `res.status(202).json(...)`, as `/run-package` does. An enqueue failure is 502 with its reason.

The worker:

```ts
// derive-profile-task.ts
export const deriveProfileWorker = onTaskDispatched(
  { retryConfig: { maxAttempts: 3, minBackoffSeconds: 10 }, rateLimits: { maxConcurrentDispatches: 10 },
    timeoutSeconds: 300, memory: "512MiB" },
  async req => runDerivation(defaultDeps(), req.data as DeriveTask))
)

// derive-profile-worker.ts
export async function writeProfile(db, task: DeriveTask, derived: Derived) {
  const ref = db.doc(`researcher_dashboard/${task.portal}/classes/${task.class_hash}`)
  const requestedAt = admin.firestore.Timestamp.fromMillis(task.requested_at)
  await db.runTransaction(async tx => {
    const current = (await tx.get(ref)).data()
    // R25: a newer request's derivation already landed, or will; never overwrite it with older inputs.
    if (current?.requested_at && current.requested_at.toMillis() > task.requested_at) return
    tx.set(ref, {                                     // whole document, no merge (R24)
      platform_id: task.platform_id,
      assignment_urls: task.assignment_urls,
      interactive_urls: derived.interactive_urls,
      content_urls: derived.content_urls,
      unread: derived.unread,
      truncated: derived.truncated,
      assignment_fingerprint: task.assignment_fingerprint,
      requested_at: requestedAt,
      derived_at: admin.firestore.FieldValue.serverTimestamp(),
    })
  })
}
```

`import * as admin from "firebase-admin"`, not the `firebase-admin/firestore` subpath, which Jest 24 cannot resolve (REPORT-141 stage 7). The document's field names are the contract RD-3's app and RD-4's runner read, and REPORT-143's rule checks `platform_id`.

**`index.ts` ends in `module.exports = { ... }`.** An `export const` elsewhere in the file is dropped from the compiled module. A throwaway `tsc` build of that shape exported only the `module.exports` keys. So `deriveProfileWorker` is added as a key there, beside `researcherDashboard`, which REPORT-141 added there.

**Tests** (fakes for `enqueue`, `db` and the deriver):
- The route:
  - A valid body is 202 and enqueues exactly the task, with `portal` and `platform_id` from the assertion even when the body names others.
  - Each malformed field is 400 with nothing enqueued, and so is a body over 256 KiB.
  - A `report-service-functions` bearer for another audience is 401, via REPORT-141's middleware.
  - An enqueue failure is 502.
  - An empty `RD_AUTHORING_HOSTS` is 503 naming it, with nothing enqueued.
- The write:
  - It sets exactly the R24 fields with no merge.
  - A task older than the stored `requested_at` writes nothing.
  - Two tasks for one class, run through the fake's serialized transaction in either order, leave the later request's document.
- Stub assertions: nothing in these modules parses `authored_state`, reads `library_interactive.data.name`, or fetches CLUE curriculum JSON.

---

### configuration and deploy order

**Summary**: The new settings in both deployables, documented, with the order they must exist in. Covers R27.

**Files affected**:
- `functions/.env.report-service-dev`: `RD_AUTHORING_HOSTS=authoring.lara.staging.concord.org,authoring.concord.org`
- `functions/.env.report-service-pro`: `RD_AUTHORING_HOSTS=authoring.concord.org`
- `server/config/runtime.exs`:
  - `PACKAGE_BUCKETS` (JSON, portal server to bucket)
  - `PACKAGES_AWS_ACCESS_KEY_ID` / `PACKAGES_AWS_SECRET_ACCESS_KEY` (required whenever `PACKAGE_BUCKETS` is set; from RD-1's per-stack `packages/*` user)
  - `PACKAGES_CORS_ORIGINS` (comma-separated)
  - `PACKAGES_UNREVIEWED_RUNS` (`"true"` to enable; default off)
- `server/README.md`: the four variables, and the publisher grant task
- `functions/README.md`: `RD_AUTHORING_HOSTS` and `deriveProfileWorker`

**Estimated diff size**: ~90 lines

The READMEs state the deploy order.
- report-server's migrations and config deploy before cc-data-cli's `package publish` (REPORT-146) is used.
- `PACKAGE_BUCKETS` names each environment's runner bucket (the staging stack's `researcher-dashboard-runner-staging`, and production's once RD-1 creates it). A portal left out of it cannot publish.
- `PACKAGES_UNREVIEWED_RUNS` stays unset until REPORT-143's broker is live and RD-1's third pass has taken S3 off the execution role.
- `deriveProfileWorker` is deployed with `researcherDashboard`. Firebase creates its task queue on the first deploy of an `onTaskDispatched` function, as it did for `taskWorker`.

## As built (2026-09-24)

Implemented in eight reviewed commits on this branch (`0ef193d` to `b3c38b1`), one per step, each put through the `cc-code-review` loop until a pass reported nothing actionable. Where the code departs from the plan above, or settles something the plan left open, it is recorded here; the judgment calls behind the larger ones are RESOLVED questions below.

### report-server

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

### The function

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

### Verification

- **report-server:** the full `mix test` suite passes (1183 tests), and `mix compile --warnings-as-errors` is clean.
- **The function:** the full `npm test` suite passes (656 tests), with `tsc` and `tslint` clean, and a throwaway `tsc` build's `index.js` exports `deriveProfileWorker`.
- **Not run:** no deploy was made and nothing ran against staging, so a live S3 put, a live Cloud Task and a real Firestore write remain unexercised. The staging runner stack's `packages/*` user (RD-1's fourth IAM item) does not exist yet.

### Checked against both specs

Each of R1 to R27 was compared with the code after the last step, along with the Jira story's "Done when" and each step's test list. Nothing was missing; the departures are the ones listed above.

### What blocks deployment

- **REPORT-141 merges first.** This branch stacks on it (PR #429, in review), for `PortalTokenPlug`, `PORTAL_PUBLIC_KEYS` and the `researcherDashboard` function.
- **report-server's stack.** cloud-formation's `fargate/report-server.yml` does not yet carry `PACKAGE_BUCKETS`, `PACKAGES_AWS_ACCESS_KEY_ID`, `PACKAGES_AWS_SECRET_ACCESS_KEY`, `PACKAGES_CORS_ORIGINS` or `PACKAGES_UNREVIEWED_RUNS`, nor REPORT-141's `PORTAL_PUBLIC_KEYS`. It lives outside this repository. Unset, report-server boots and the catalog answers, but no portal can publish and no launch token verifies.
- **Migrations.** `bin/report_server eval "ReportServer.Release.migrate"` must run before the new image serves, for the three catalog tables and `users.package_publisher`.
- **RD-1's fourth IAM item.** Publishing in an environment needs that runner stack's `packages/*`-only IAM user, whose keys become `PACKAGES_AWS_*`. It does not exist yet, for staging or production.
- **The app's origin.** `PACKAGES_CORS_ORIGINS` needs the dashboard app's origins, which RD-1 and RD-3 settle. Until they are set, only the anonymous list and rigse's server-to-server resolve work.
- **Portal keys.** Nothing verifies a launch token until each portal's key is in `PORTAL_PUBLIC_KEYS`, which is REPORT-141's blocker too.
- **Firestore rules.** The class profile document is written but no client can read it until REPORT-143 ships the dashboard's read rules. That blocks RD-3's use of it, not this deploy.
- **Cloud Tasks from `researcherDashboard`.** The function enqueues to the `deriveProfileWorker` queue with an OIDC token for the App Engine default service account, as `api`'s `submitTask` does. Whether `researcherDashboard`'s runtime service account holds `cloudtasks.tasks.create` and `iam.serviceAccounts.actAs` on that account was not checked. If it runs as the default account, as `api` does, it should.
- **`PACKAGES_UNREVIEWED_RUNS` stays unset** until REPORT-143's storage broker is live and RD-1's third pass has taken S3 off the execution role.

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

### RESOLVED: Judgment call: a publish must declare its Content-Length
**Context**: The plan capped the upload with `read_body(conn, length: 10 MiB)`. Review found that Bandit reads a `Transfer-Encoding: chunked` body whole whatever `:length` says (`deps/bandit/lib/bandit/http1/socket.ex`), so a chunked upload of any size would be held in memory before the cap applied.
**Options considered**:
- A) Require `Content-Length`, refuse a declared length over 10 MiB before reading, and keep `read_body`'s `:length` as the backstop.
- B) Read the body in chunks with a running total, accepting chunked uploads.

**Decision**: A. cc-data-cli's Go client sends a `Content-Length` for a `bytes.Reader` body, so no real caller is refused, and A is one header check where B is a read loop. Built in the publish step.

### RESOLVED: Judgment call: `official=true` on a later publish
**Context**: R9 describes `official=true` only as a first publish creating the package official and public. R11 says a publisher may set `official` "on publish or afterwards", and the plan made it a no-op on an existing package.
**Options considered**:
- A) Honour it on any publish, with the same audit rows as the state change, still requiring the caller to administer the package.
- B) Refuse it on an existing package, pointing at the state change.
- C) Accept and ignore it.

**Decision**: A. It matches R11, and the cc-data-studies release pipeline can publish a new official version in one call. C answered 201 while dropping the flag, which review caught. The pointer decision is taken from the visibility before the change, so a private package made official on this publish still moves its pointer.

### RESOLVED: Judgment call: what setting and clearing `official` touch
**Options considered**:
- A) `official` is the publisher role's alone, needs no administration of the package, implies `public` and clears any `project_id`. Clearing it leaves the package public, and an official package cannot leave `public` (422).
- B) Require the publisher to administer the package too, and restore the previous visibility on clearing.

**Decision**: A. R11 says holding the role "does not make anyone a maintainer" and R12 gives `official` to "the publisher role only", so B would stop Concord endorsing a researcher's package without taking it over. Restoring a previous visibility would need it stored somewhere other than the audit trail, and leaving it public is the conservative reading of an endorsement being withdrawn.

### RESOLVED: Judgment call: locking the package row, and lock conflicts
**Context**: Publish holds the package's row lock across two S3 puts. The plan's `find_or_insert_package` did not say how a missing row is created under concurrency.
**Options considered**:
- A) Read without a lock. Lock an existing row with `FOR UPDATE`, or insert a missing one and, on a unique conflict, lock the winner's row. Bound the S3 puts under InnoDB's 50-second lock wait, and answer a lock wait timeout or a deadlock with a retryable 503.
- B) `SELECT ... FOR UPDATE` first, then insert when absent.
- C) `INSERT ... ON DUPLICATE KEY` then lock.

**Decision**: A. Under REPEATABLE READ, B's locking read of an absent row takes a gap lock, and two concurrent first publishes then deadlock on their inserts. C burns an auto-increment id on every publish of an existing package, and `on_conflict: :nothing` hides errors other than the duplicate. The 503 tells a client the conflict is transient rather than surfacing a 500.

### RESOLVED: Judgment call: how strict the manifest is beyond R7
**Options considered**:
- A) Refuse unknown keys inside `urls`, cap `version` at 64 characters with no leading zeros, make `description` optional, and count lengths in code points.
- B) Apply R7 literally.

**Decision**: A. A misspelt `urls` group would otherwise leave a package offered on every class. A version is an S3 key segment and `s3_key` is a varchar(255). Leading zeros would let `1.0.6` and `01.0.6` be two versions. The description column is nullable. MySQL's varchar counts code points, and a grapheme count let a 200-grapheme title of combining characters overflow its column. Unknown top-level keys are still ignored, as R7 says.

### RESOLVED: Judgment call: the deriver's retry and timeout policy
**Options considered**:
- A) Retry a network error (before the headers or partway through the body) or a 5xx once. Never retry a timeout, and cancel the body of every non-200 answer.
- B) Retry every failure once.

**Decision**: A. A timeout already spent 15 seconds, and retrying it doubles the worst case of a derivation that Cloud Tasks will retry whole anyway. A dropped connection is the transient case a retry is for. An unread body holds its undici connection until garbage collection.

### RESOLVED: Judgment call: the app's deps for `/derive-profile`
**Options considered**:
- A) `researcherDashboardApp(deps, deriveDeps)`, a second factory.
- B) Widen `RunPackageDeps` to carry the enqueue seam.

**Decision**: A. The two routes share only the auth middleware's keys, which the first factory already provides. B would make every `/run-package` test construct derive-profile deps it never uses.

### RESOLVED: Judgment call: an `optional` mode on REPORT-141's `PortalTokenPlug` rather than a second plug
**Options considered**:
- A) Add `optional: true`: no header passes, and a bad header is 401.
- B) A separate `OptionalPortalTokenPlug`.

**Decision**: A. The verification is the same code, and the one behavior that differs, a missing header, is one clause. A second plug would be a second place to get R15's "never downgrade a bad bearer to anonymous" wrong.

### RESOLVED: Judgment call: S3 writes inside the database transaction
**Options considered**:
- A) Insert, put both objects, then commit.
- B) Put first, then insert.
- C) Conditional `PutObject` with `If-None-Match: *`.

**Decision**: A. The requirements' Self-Review showed B lets a concurrent twin overwrite the winner's object. C would need the `aws` library's support for a header this repo has never sent, and would still leave a row-less object on insert failure. A holds a database transaction open across two small PUTs of at most 10 MiB, which is acceptable for an operation a researcher performs by hand.

### RESOLVED: Judgment call: fake `fetch` rather than Node's global in tests
**Decision**: `fetchImpl` is injected. Jest 24's default jsdom environment has no global `fetch`, and a live network call would make the suite depend on the authoring server. The stage 4 JSON, trimmed, is the fixture, so the tests read what the service really returns.

## Self-Review

Roles:
- whoever reviews the commits
- whoever runs the tests
- the Security Engineer
- the Senior Engineer (Elixir and Firebase functions)
- the operator deploying it

The riskiest pieces were run before this plan was written:
- the bounded manifest reader over Go, `zip -X`, lying and bomb archives;
- the extractor over live authoring JSON;
- a throwaway route, CORS plug and preflight in report-server's real test environment;
- the MySQL unique-index wait;
- the `module.exports` shape under `tsc`.


### Engineer running the tests

#### RESOLVED: The worker module could not be imported under the repo's Jest
The plan put `onTaskDispatched` and `writeProfile` in one module. A scratch test importing `firebase-functions/v2/tasks` failed with `Cannot find module 'firebase-functions/v2/tasks'` under Jest 24, which predates subpath exports (the repo maps only `firebase-functions/params`, `package.json` `moduleNameMapper`). A second scratch test showed `@google-cloud/tasks` and `import * as admin from "firebase-admin"` load. So every test of the worker would have failed to run. Fixed: the wrapper moves to `derive-profile-task.ts`, which only `index.ts` imports.

#### RESOLVED: The concurrent-publish test could not show the lock it claimed to
`ConnCase`'s sandbox in shared mode gives both processes one connection, so the second publish waits on the connection, not the unique index. The test still catches an implementation that writes S3 before the insert, but not the InnoDB behavior. Fixed: the test is described as asserting the outcome, and the lock itself rests on the direct MySQL check.

### Senior Engineer

#### RESOLVED: `:json` is not the repo's migration type for JSON columns
Every JSON column in `server/priv/repo/migrations` is declared `:map` (for example `create_export_scratch.exs:14`, whose comment says it compiles to a MySQL `json` column), with a `:map` schema field. Fixed in the first step.
