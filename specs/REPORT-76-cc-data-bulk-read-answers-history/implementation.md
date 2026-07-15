# Implementation Plan: cc-data Bulk-Read Function for Answers + Interactive History (Paged, Resumable)

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-76
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## How to read this plan

Each `###` heading is one logically-coherent, independently-reviewable commit (~500 lines or fewer). Steps are ordered so each builds only on those above it — no forward dependencies. New files are given in full; edits to existing files are shown as before/after against the **verbatim current source** (line numbers are from the files as they exist today). Test bodies are summarized as scenario lists, but every required **stub/harness/seam** is given in full because those gate the whole test strategy.

**Decisions this plan pins that the requirements left to implementer discretion** (all mechanical, none change observable contract — each is noted inline and collected in Open Questions):
- Composite `page_token` wire format: `base64url(JSON)` of `{"s": scratch_id, "i": endpoint_index, "c": inner_cursor}` (plaintext, unsigned — integrity is capability + ownership re-check + bounds validation, per requirements).
- One Node route `POST /bulk_read` with `collection: "answers" | "history"` in the body (the two Elixir routes `/answers` and `/history` both call it); avoids duplicating the walker.
- Default caps: `limit` default **500** / max **500**; `endpoint_limit` **250**; `read_limit` **5000**. All tunable; `limit` only lowers the returned-item cap (server max == default, per requirements' "only lowers ~500"; a higher max has no response-byte guard against the 10 MB gen1 cap — F-ext-3).
- History Firestore batch size **300** per metadata query; `getAll` state-doc chunk size **300**.
- New Elixir namespace `ReportServer.Exports` (context) + `ReportServer.Exports.ExportScratch` (schema), mirroring the `Accounts` / `Accounts.AuthGrant` split.
- New controller `ReportServerWeb.Api.V1.BulkExportController` (sibling to `ReportController`), new params module `ReportServerWeb.Api.V1.BulkParams` (STORY-3-specific limit/token parsing, leaving STORY 1's `Params` untouched).

**Validation milestone**: the requirements mandate an early end-to-end vertical slice (one learner → one page → cursor → resume) before building out audit/sweep/UI. That slice is reached at the end of **"Bulk controller — validation-milestone vertical slice (`/answers`)"** below; the steps before it are its prerequisites, and everything after it is build-out.

---

## Implementation Plan

### Persistence foundation — migrations + `export_scratch` schema/context + audit-log changeset extensions

**Summary**: Everything downstream needs the two tables and the retyped audit changeset. This is the DB + Ecto layer with no HTTP surface, independently testable via Repo.

**Files affected**:
- `server/priv/repo/migrations/20260714120000_create_export_scratch.exs` — new
- `server/priv/repo/migrations/20260714120100_add_export_id_to_data_access_log.exs` — new
- `server/lib/report_server/exports/export_scratch.ex` — new (schema)
- `server/lib/report_server/exports.ex` — new (context)
- `server/lib/report_server/types/ecto_json_array.ex` — new (custom `Ecto.Type`, `type/0 == :map`, list-shaped cast/load/dump; required for MyXQL to round-trip a JSON array — see F-ext3-1; mirrors `EctoReportFilter`)
- `server/lib/report_server/audit_log/data_access_log_entry.ex` — edit (retype `endpoint_set`, add `export_id`, extend allow-lists)
- `server/lib/report_server/audit_log.ex` — edit (make `dump_filter/1` public for reuse — one-liner; **`create_scratch_with_intent/2` lives in `Exports`, NOT here** — F-ext2-2)
- `server/test/report_server/exports_test.exs` — new (unit tests for mint/two-step lookup/bump/sweep/data_type guard)

**Estimated diff size**: ~320 lines.

#### Migration — `export_scratch`

Next timestamp sorts after the latest existing migration (`20260713090000`). MySQL: an Ecto `:map` column compiles to `json`, which holds a top-level JSON **array** at the DB layer. The migration column stays `:map`; the *schema field* uses the custom `ReportServer.Types.EctoJsonArray` type (below) — **NOT a bare `{:array, :map}`**. Under `Ecto.Adapters.MyXQL` a bare `{:array, _}` schema field does not round-trip: the adapter only prepends `json_decode` for `:map`/`{:map, _}` loaders (`myxql.ex:153-158`), so a `{:array, _}` field READS the raw JSON string back and fails to load (writes work — MyXQL JSON-encodes a list — but reads crash). See "Why a custom Ecto type" below (F-ext3-1).

```elixir
# server/priv/repo/migrations/20260714120000_create_export_scratch.exs
defmodule ReportServer.Repo.Migrations.CreateExportScratch do
  use Ecto.Migration

  def change do
    create table(:export_scratch) do
      # unguessable capability, minted per export (NOT the PK); the client-held page_token references it
      add :scratch_id, :string, null: false
      add :report_run_id, references(:report_runs, on_delete: :nothing), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      # "answers_bulk" | "history_bulk" — binds the scratch to its route (cross-route replay guard)
      add :data_type, :string, null: false
      # per-learner authorized snapshot: [{remote_endpoint, source, lti_tuple?}, ...]
      # ~tens of KB typical, ~1.9 MB worst case (10k learners) — ~34x under max_allowed_packet.
      # :map compiles to a MySQL `json` column, which holds the top-level array. (The SCHEMA field uses the
      # EctoJsonArray custom type — see below — so the array round-trips under MyXQL; the migration is :map.)
      add :endpoint_set, :map, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # single unique index resolves the ownership-guarded lookup to <=1 row (auth_grants/api_tokens precedent)
    create unique_index(:export_scratch, [:scratch_id])
    # plain index for the sweep's range delete (DELETE WHERE expires_at < now)
    create index(:export_scratch, [:expires_at])
  end
end
```

#### Migration — `data_access_log.export_id`

```elixir
# server/priv/repo/migrations/20260714120100_add_export_id_to_data_access_log.exs
defmodule ReportServer.Repo.Migrations.AddExportIdToDataAccessLog do
  use Ecto.Migration

  def change do
    alter table(:data_access_log) do
      # nullable; correlates all rows of one bulk export (= scratch_id). Null on STORY 1 CSV/job rows.
      add :export_id, :string
    end

    create index(:data_access_log, [:export_id])
  end
end
```

**No migration is needed to retype `endpoint_set`** — STORY 1 already created it as `:map` → a MySQL `json` column, and the `EctoJsonArray` custom type also dumps to `json`. Only the *schema field declaration* changes (below); STORY 1's rows wrote `null`, which remains valid.

#### Why a custom Ecto type (`EctoJsonArray`) — MyXQL does not round-trip bare `{:array, _}` (F-ext3-1)

Under `Ecto.Adapters.MyXQL`, a schema field typed `{:array, :map}`/`{:array, :string}` over a MySQL `json` column **fails on read**. The adapter prepends the JSON decoder only for `:map`/`{:map, _}` types:
```elixir
# deps/ecto_sql/lib/ecto/adapters/myxql.ex:153-158 (verbatim)
def loaders({:map, _}, type), do: [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
def loaders(:map, type),      do: [&json_decode/1, type]
...
def loaders(_, type),         do: [type]     # <-- {:array, _} lands here: NO json_decode
```
MySQL returns a `json` column as a raw string, so a `{:array, _}` field hands that binary straight to Ecto's array loader → hard load error. (Writes happen to work — MyXQL JSON-encodes a list on the wire — and the DDL is fine because the *migration* column is `:map`, never `{:array, _}`, so `ecto_to_db({:array, _})`'s "Array type is not supported by MySQL" rejection at `connection.ex:1530` is never reached. It's specifically the READ that breaks: `fetch_for_page` on page-N resume and the audit-log admin display.)

Fix: a custom `Ecto.Type` with `type/0 == :map` (so it DOES get `json_decode` on load) whose `cast/load/dump` carry a top-level **list**, mirroring the repo's existing `ReportServer.Types.EctoReportFilter`. Keeping the stored value a top-level JSON array means the audit `JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))` pathless filter is unchanged.

```elixir
# server/lib/report_server/types/ecto_json_array.ex — NEW
# A top-level JSON array stored in a MySQL `json` column. type/0 is :map so MyXQL's loader prepends
# json_decode (myxql.ex:154); dump returns a plain list which MyXQL JSON-encodes on the wire. Used for
# ExportScratch.endpoint_set (array of maps) AND data_access_log.endpoint_set (array of strings).
defmodule ReportServer.Types.EctoJsonArray do
  use Ecto.Type

  def type, do: :map   # dispatches MyXQL's :map loader (json_decode) — a bare {:array,_} would not decode

  def cast(list) when is_list(list), do: {:ok, list}
  def cast(_), do: :error

  def load(list) when is_list(list), do: {:ok, list}   # json_decode already turned the raw string into a list
  def load(_), do: :error

  def dump(list) when is_list(list), do: {:ok, list}   # MyXQL JSON-encodes the list -> top-level json array
  def dump(_), do: :error
end
```
(`nil` is short-circuited by Ecto before `cast/load/dump`, so a STORY-1 `null` `endpoint_set` still loads as `nil`.)

#### `ExportScratch` schema

```elixir
# server/lib/report_server/exports/export_scratch.ex
defmodule ReportServer.Exports.ExportScratch do
  use Ecto.Schema

  import Ecto.Changeset

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportRun

  schema "export_scratch" do
    field :scratch_id, :string
    field :data_type, :string
    # array of per-learner objects: %{"remote_endpoint" => ..., "source" => ..., "lti_tuple" => %{...} | nil}
    # custom type (NOT bare {:array, :map}) — see "Why a custom Ecto type" above (MyXQL round-trip). (F-ext3-1)
    field :endpoint_set, ReportServer.Types.EctoJsonArray
    field :expires_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_id
    belongs_to :report_run, ReportRun, foreign_key: :report_run_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(scratch, attrs) do
    scratch
    |> cast(attrs, [:scratch_id, :data_type, :endpoint_set, :expires_at, :user_id, :report_run_id])
    |> validate_required([:scratch_id, :data_type, :endpoint_set, :expires_at, :user_id, :report_run_id])
    |> validate_inclusion(:data_type, ["answers_bulk", "history_bulk"])
    |> unique_constraint(:scratch_id)
  end
end
```

#### `Exports` context

Implements the mint idiom (reusing `Accounts`'s `strong_rand_bytes` capability), the **two-step read-time lookup** (404 vs 410), the **absolute** sliding-TTL bump, the ownership+route-scoped inline delete, the tuple-cache merge, and the sweep query. The page-1 atomic `scratch + intent-row` write lives here too (`create_scratch_with_intent/2`).

```elixir
# server/lib/report_server/exports.ex
defmodule ReportServer.Exports do
  @moduledoc """
  Server-side scratch store for STORY-3 bulk exports: the once-derived authorized endpoint snapshot,
  keyed by an unguessable `scratch_id` capability, with a two-step (404 vs 410) read-time expiry lookup,
  an absolute sliding TTL, and a periodic + boot sweep (see `ReportServer.Exports.SweepServer`).
  """
  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias ReportServer.Repo
  alias ReportServer.Exports.ExportScratch
  alias ReportServer.AuditLog.DataAccessLogEntry

  @ttl_seconds 60 * 60  # 1 hour of inactivity

  @doc "Mint an unguessable capability (NOT the table PK), reusing the auth_grants/api_token idiom."
  def mint_scratch_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  def ttl_expires_at, do: DateTime.utc_now(:second) |> DateTime.add(@ttl_seconds)

  @doc """
  Page-1 atomicity: insert the scratch row and its intent audit row both-or-neither.
  Returns {:ok, %{scratch: %ExportScratch{}, intent: %DataAccessLogEntry{}}} | {:error, step, changeset, _}.
  """
  def create_scratch_with_intent(scratch_attrs, intent_attrs) do
    Multi.new()
    |> Multi.insert(:scratch, ExportScratch.changeset(%ExportScratch{}, scratch_attrs))
    |> Multi.insert(:intent, DataAccessLogEntry.changeset(%DataAccessLogEntry{}, intent_attrs))
    |> Repo.transaction()
  end

  @doc """
  Two-step read-time lookup for a page load. Ownership+route identity match with NO expiry predicate:
    * no row                       -> :not_found  (forged / cross-user / cross-run / cross-route / swept)
    * matched but expires_at <= now -> delete (scoped) and return :expired (-> 410 EXPIRED_CURSOR)
    * matched and active            -> bump TTL absolutely and return {:ok, scratch}
  """
  def fetch_for_page(scratch_id, user_id, report_run_id, data_type) do
    now = DateTime.utc_now(:second)

    query =
      from s in ExportScratch,
        where:
          s.scratch_id == ^scratch_id and s.user_id == ^user_id and
            s.report_run_id == ^report_run_id and s.data_type == ^data_type

    case Repo.one(query) do
      nil ->
        :not_found

      %ExportScratch{expires_at: expires_at} = scratch ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, bump_ttl(scratch)}
        else
          delete_scoped(scratch_id, user_id, report_run_id, data_type)
          :expired
        end
    end
  end

  # absolute SET (never expires_at + delta) so concurrent same-token retries converge and stay idempotent
  defp bump_ttl(%ExportScratch{} = scratch) do
    new_expires_at = ttl_expires_at()

    {_n, _} =
      from(s in ExportScratch, where: s.scratch_id == ^scratch.scratch_id)
      |> Repo.update_all(set: [expires_at: new_expires_at])

    %ExportScratch{scratch | expires_at: new_expires_at}
  end

  defp delete_scoped(scratch_id, user_id, report_run_id, data_type) do
    from(s in ExportScratch,
      where:
        s.scratch_id == ^scratch_id and s.user_id == ^user_id and
          s.report_run_id == ^report_run_id and s.data_type == ^data_type
    )
    |> Repo.delete_all()
  end

  @doc """
  Merge Node's freshly-derived LTI tuples into the cached snapshot (tuple cache), so the per-learner
  `answers ... limit 1` derivation runs once per export. `touched` is [%{"remote_endpoint" => e,
  "lti_tuple" => t}, ...]. Idempotent; persists the updated endpoint_set.
  """
  def merge_touched_endpoints(%ExportScratch{} = scratch, touched) when is_list(touched) do
    by_endpoint = Map.new(touched, fn t -> {t["remote_endpoint"], t["lti_tuple"]} end)

    if map_size(by_endpoint) == 0 do
      scratch
    else
      updated =
        Enum.map(scratch.endpoint_set, fn ep ->
          case Map.get(by_endpoint, ep["remote_endpoint"]) do
            nil -> ep
            tuple -> Map.put(ep, "lti_tuple", tuple)
          end
        end)

      # fail-OPEN, and ONLY here: the tuple cache is a pure optimization (Node re-derives a nil lti_tuple
      # via the `answers ... limit 1` read), so a cache-write failure must never fail an already-successful
      # page. Every AUDIT write stays fail-closed. (F1/F2, Round 3.)
      case scratch |> Ecto.Changeset.change(endpoint_set: updated) |> Repo.update() do
        {:ok, updated_scratch} ->
          updated_scratch

        {:error, _changeset} ->
          Logger.warning("Exports.merge_touched_endpoints: tuple-cache update failed; will re-derive next page")
          scratch
      end
    end
  end

  def merge_touched_endpoints(scratch, _), do: scratch

  @doc "Storage-reclaim sweep (periodic + boot). Correctness never depends on it — expired rows are already invisible."
  def sweep_expired do
    now = DateTime.utc_now(:second)
    {count, _} = from(s in ExportScratch, where: s.expires_at < ^now) |> Repo.delete_all()
    count
  end
end
```

> **Concurrency note (F3, Round 3).** There is intentionally no optimistic-lock/version column and no
> natural-key uniqueness on `(user_id, report_run_id, data_type)` — only the `scratch_id` unique index.
> Two consequences, both accepted:
> (1) **Concurrent same-token pages** each read the row and overwrite the whole `endpoint_set` — a
> last-writer-wins race, but *safe*: the only mutated field is the nil-fill tuple cache, which Node
> re-derives on demand, so a lost write costs at most a redundant derive. The absolute-`SET` `bump_ttl`
> is likewise idempotent under the same race.
> (2) **Concurrent (not sequential) page-1s** for one `(user, report_run)` mint independent `scratch_id`s
> and write independent `export_scoped` intent rows — i.e. one logical export can surface as two
> `export_id`s. This matches the at-least-once philosophy; the retry-distinguishability guarantee is
> per-`export_id`. Strict page-1 dedup (a natural-key unique index + upsert) is explicitly out of scope.

#### `DataAccessLogEntry` — retype + extend (before/after)

```elixir
# server/lib/report_server/audit_log/data_access_log_entry.ex

# --- schema fields (lines 16-17) ---
# BEFORE
      field :cursor, :string
      field :endpoint_set, :map
# AFTER
      field :cursor, :string
      # custom type, NOT {:array, :string} — MyXQL won't json-decode a bare {:array,_} on load (see the
      # "Why a custom Ecto type" note in the export_scratch migration section). Stores a top-level JSON array
      # of remote_endpoint strings, so the pathless JSON_CONTAINS filter is unchanged. (F-ext3-1)
      field :endpoint_set, ReportServer.Types.EctoJsonArray
      field :export_id, :string                # correlates all rows of one bulk export (= scratch_id); null on STORY 1 rows

# --- changeset (lines 28-35) — NOTE: the live changeset ends with two foreign_key_constraint/1 calls
#     (lines 34-35); they MUST be preserved in the AFTER (only the cast/validate_inclusion lines change) ---
# BEFORE
      |> cast(attrs, [:event, :source, :data_type, :user_id, :report_run_id, :report_filter,
                      :report_slug, :job_id, :cursor, :endpoint_set])
      |> validate_required([:event, :source, :data_type, :user_id, :report_run_id])
      |> validate_inclusion(:event, ["download_url_issued"])
      |> validate_inclusion(:source, ["web", "api"])
      |> validate_inclusion(:data_type, ["run_csv", "job_result"])
      |> foreign_key_constraint(:user_id)
      |> foreign_key_constraint(:report_run_id)
# AFTER
      |> cast(attrs, [:event, :source, :data_type, :user_id, :report_run_id, :report_filter,
                      :report_slug, :job_id, :cursor, :endpoint_set, :export_id])
      |> validate_required([:event, :source, :data_type, :user_id, :report_run_id])
      |> validate_inclusion(:event, ["download_url_issued", "export_scoped", "bulk_read"])
      |> validate_inclusion(:source, ["web", "api"])
      |> validate_inclusion(:data_type, ["run_csv", "job_result", "answers_bulk", "history_bulk", "export_scoped"])
      |> foreign_key_constraint(:user_id)
      |> foreign_key_constraint(:report_run_id)
```

Blast-radius (verified in requirements Round-4): the negative changeset tests at `audit_log_test.exs:136-142` assert `"nope"` is rejected — still true under the widened lists; `cast` ignores callers omitting `export_id`; STORY 1 rows keep `null` endpoint_set / `null` export_id.

#### `AuditLog` — expose the filter dump for reuse

`AuditLog.dump_filter/1` is currently private (`audit_log.ex:56-57`). The bulk controller builds intent + access attrs and needs the same `%ReportFilter{} -> map | nil` shape. Make it public (one-line change), and add nothing else here — `create_entry/1` already exists for the per-page access row, and `create_scratch_with_intent/2` (in `Exports`) covers the atomic page-1 write.

```elixir
# server/lib/report_server/audit_log.ex (lines 56-57)
# BEFORE
  defp dump_filter(nil), do: nil
  defp dump_filter(report_filter), do: Map.from_struct(report_filter)
# AFTER
  def dump_filter(nil), do: nil
  def dump_filter(report_filter), do: Map.from_struct(report_filter)
```

#### Tests (`exports_test.exs`)

Uses the local Repo sandbox (`ReportServer.DataCase`). Scenarios:
- `mint_scratch_id/0` returns 43-char url-safe base64 (32 bytes, no padding), unique across calls.
- `create_scratch_with_intent/2` commits both rows; a failing intent changeset (bad `event`) rolls back the scratch (assert neither row exists).
- `fetch_for_page/4`: active row → `{:ok, scratch}` with bumped `expires_at`; wrong `user_id`/`report_run_id`/`data_type`/`scratch_id` → `:not_found`; expired row → `:expired` **and** row deleted; a second `fetch_for_page` after expiry → `:not_found` (delete happened).
- bump is absolute (two rapid fetches converge to `now+1h`, not `+2h`).
- `merge_touched_endpoints/2` adds `lti_tuple` to the matching endpoint only, idempotent, persists.
- `sweep_expired/0` deletes only `expires_at < now`, returns count.
- **`endpoint_set` DB round-trip (F-ext3-1 regression guard)**: insert a scratch with a non-trivial `endpoint_set` (list of maps incl. a nested `lti_tuple`), then **`Repo.get`/`fetch_for_page` it back and assert the loaded value equals the written list** — a bare `{:array, _}` field would raise a load error here under MyXQL, so this proves the `EctoJsonArray` custom type round-trips. (Mirror the same round-trip assertion for `data_access_log.endpoint_set` — a list of strings — in `audit_log_test.exs`.)

---

### Elixir↔Node seams + test stubs (`ReportService.bulk_read/1`, `LearnerData.fetch/3 allow_empty`, source derivation)

**Summary**: Two swappable seams the controller and its tests require — neither exists today (no Mox/Bypass in the project). Mirrors STORY 1's `Application.get_env(:report_server, :athena_db, ...)` idiom. Also adds `LearnerData`'s `allow_empty` option and the shared source-derivation helper.

**Files affected**:
- `server/lib/report_server/report_service.ex` — edit (add `bulk_read/1` with the required `receive_timeout`)
- `server/lib/report_server/reports/athena/learner_data.ex` — edit (thread `opts` → `allow_empty`; add a private `maybe_ensure_not_empty/2` that calls the existing public `ReportUtils.ensure_not_empty/2`)
- `server/lib/report_server/reports/source_key.ex` — new (the `answersSourceKey`/hostname/offline-remap derivation, reused by the controller)
- `server/test/support/report_service_stub.ex` — new
- `server/test/support/learner_data_stub.ex` — new

**Estimated diff size**: ~200 lines.

#### `ReportService.bulk_read/1`

The internal Elixir→Node wire contract is **POST with a JSON body** (the first read route needing a body). Sets `receive_timeout: 310_000` — comfortably above the ~300 s Node ceiling (Req's default is 15 000 ms, which would abort every legitimately-slow page).

```elixir
# server/lib/report_server/report_service.ex — add:

  @bulk_receive_timeout 310_000  # ms; must exceed the ~300s Node/Cloud-Function ceiling (Req default is 15_000)

  @doc """
  Bulk Firestore read (STORY 3). `req` is the internal wire request:
    %{collection: "answers"|"history", source_endpoints: [...], inner_cursor: nil|map,
      limit: int, endpoint_limit: int, read_limit: int}
  Returns {:ok, body_without_success_key} | {:error, reason}. Node stays stateless; Elixir owns cursor assembly.
  """
  def bulk_read(req) do
    {url, token} = get_endpoint("bulk_read")

    result =
      get_request()
      |> Req.post(
        url: url,
        auth: {:bearer, token},
        json: req,
        receive_timeout: @bulk_receive_timeout,
        debug: false
      )

    case result do
      {:ok, %{status: 200, body: %{"success" => true} = body}} ->
        {:ok, Map.delete(body, "success")}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status}} ->
        {:error, "unexpected bulk_read status #{status}"}

      {:error, error} ->
        {:error, error}
    end
  end
```

Seam accessor (used by the controller): `Application.get_env(:report_server, :report_service_client, ReportServer.ReportService)`. **Fully-qualify the default** — the controller does not `alias ReportService`, so an unqualified `ReportService` default would resolve to the nonexistent `Elixir.ReportService` and fail in production where the env is unset (F-ext-1).

#### `ReportServiceStub`

```elixir
# server/test/support/report_service_stub.ex
# Mirrors ReportServer.AthenaDBStub exactly (named Agent set via Application.put_env, async: false tests).
defmodule ReportServer.ReportServiceStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def bulk_read(req), do: apply_stub(:bulk_read, [req])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
```

Set in a test via `ReportServiceStub.start(%{bulk_read: fn req -> {:ok, %{"items" => ..., ...}} end})` +
`Application.put_env(:report_server, :report_service_client, ReportServer.ReportServiceStub)`, exactly as STORY 1
does for `:athena_db` (`report_controller_test.exs:68`). Tests are `async: false` (they mutate app env). This is
the project's established seam pattern — a named Agent, robust across processes — not the process dictionary.

#### `LearnerData.fetch/3` — `allow_empty` option

The default report path must keep erroring on an empty learner set (`ensure_not_empty`); STORY 3 needs `{:ok, []}`. Add an optional `opts` arg threaded into `map_learner_data`, defaulting to `allow_empty: false` so the 4 existing callers are byte-identical.

```elixir
# server/lib/report_server/reports/athena/learner_data.ex

# BEFORE (line 24)
  def fetch(%ReportFilter{cohort: cohort, ...}, user = %User{}) do
    ...
         {:ok, learner_data} <- map_learner_data(result, user) do
# AFTER  (add opts, thread to map_learner_data)
  def fetch(%ReportFilter{cohort: cohort, ...}, user = %User{}, opts \\ []) do
    ...
         {:ok, learner_data} <- map_learner_data(result, user, opts) do

# map_learner_data/3 — gate ensure_not_empty on allow_empty
# BEFORE (line 148)
  defp map_learner_data(result = %MyXQL.Result{}, user = %User{}) do
    rows = PortalDbs.map_columns_on_rows(result)
    ...
    with {:ok, rows} <- ensure_not_empty(rows, "No learners were found matching the filters you selected."),
# AFTER
  defp map_learner_data(result = %MyXQL.Result{}, user = %User{}, opts) do
    rows = PortalDbs.map_columns_on_rows(result)
    ...
    with {:ok, rows} <- maybe_ensure_not_empty(rows, Keyword.get(opts, :allow_empty, false)),
```

Add the private helper (empty rows fold cleanly — `get_teacher_map([], ...)` / `get_permission_form_map([], ...)` already have `{:ok, %{}}` clauses at lines 223/260):

```elixir
  defp maybe_ensure_not_empty(rows, true), do: {:ok, rows}
  defp maybe_ensure_not_empty(rows, false),
    do: ensure_not_empty(rows, "No learners were found matching the filters you selected.")
```

Seam accessor (controller): `Application.get_env(:report_server, :learner_data, ReportServer.Reports.Athena.LearnerData)`.

#### `LearnerDataStub`

The portal MySQL is un-sandboxable (not an Ecto repo; keyed off a `"{server}_DB"` env var absent in CI), so the derivation is stubbed at the module boundary.

```elixir
# server/test/support/learner_data_stub.ex
# Named-Agent seam (mirrors AthenaDBStub). Portal MySQL is not sandboxable, so fetch/3 and
# get_allowed_project_ids/1 are both stubbed here.
defmodule ReportServer.LearnerDataStub do
  def start(responses), do: Agent.start_link(fn -> responses end, name: __MODULE__)

  def fetch(report_filter, user, opts \\ []), do: apply_stub(:fetch, [report_filter, user, opts])
  def get_allowed_project_ids(user), do: apply_stub(:get_allowed_project_ids, [user])

  defp apply_stub(name, args) do
    Agent.get(__MODULE__, &Map.fetch!(&1, name)) |> apply(args)
  end
end
```

The controller reads two accessors so both are swappable in tests:
`Application.get_env(:report_server, :learner_data, ReportServer.Reports.Athena.LearnerData)` (for `fetch/3`) and
`Application.get_env(:report_server, :allowed_project_ids_source, ReportServer.PortalDbs)` (for
`get_allowed_project_ids/1`). Point both at `LearnerDataStub` in a test to drive the empty-`[]`-short-circuit,
`:all`, non-empty, and empty-rows scenarios without a live portal DB.

#### `SourceKey` derivation

Mirrors the report's own SQL `COALESCE(url_extract_parameter(runnable_url, 'answersSourceKey'), hostname(runnable_url))` + the offline remap (`shared_queries.ex:431-436`). **Not hostname-only** — an `answersSourceKey` override run would otherwise query the wrong `source`.

```elixir
# server/lib/report_server/reports/source_key.ex
defmodule ReportServer.Reports.SourceKey do
  @moduledoc "Derives the Firestore `source` for a run from its runnable_url, matching the report's own SQL."

  @offline "activity-player-offline.concord.org"
  @online "activity-player.concord.org"

  def from_runnable_url(runnable_url) when is_binary(runnable_url) do
    uri = URI.parse(runnable_url)

    (answers_source_key(uri.query) || uri.host)
    |> remap_offline()
  end

  defp answers_source_key(nil), do: nil
  defp answers_source_key(query) do
    case URI.decode_query(query) |> Map.get("answersSourceKey") do
      nil -> nil
      "" -> nil
      key -> key
    end
  end

  defp remap_offline(@offline), do: @online
  defp remap_offline(source), do: source
end
```

Tests (`source_key_test.exs`): hostname-only URL → host; `?answersSourceKey=foo` → `"foo"`; offline host → online remap; override + offline query mix. (Verified in this session's probes that `URI`/`URI.decode_query` behave as assumed.)

> **Source-derivation fidelity (URL-only by design).** The report's own SQL (`shared_queries.ex:428-436`)
> resolves an answer's source as `COALESCE(learners_and_answers.source_key['question_id'], IF(url_derived =
> 'activity-player-offline.concord.org', 'activity-player.concord.org', url_derived))` — i.e. it **prefers the
> `source_key` recorded on the actual answer** and uses the runnable-URL derivation only "with no answer".
> `SourceKey.from_runnable_url/1` implements **only that URL-derived fallback**. This is deliberate: at derive
> time Elixir has the portal row (`ea.url`) but not the answer's Firestore/Athena `source_key`, so reading the
> authoritative key per learner would cost an extra Athena/Firestore round-trip per export. **Divergence class
> not covered**: a run whose answers were written under a `source_key` that differs from its *current*
> `runnable_url` derivation (rehosted/migrated activity, or a per-question source_key) — the walker would query
> the wrong `sources/{source}` and **silently** return zero items for that learner (no error). In the common
> case they coincide (activity-player writes answers under the same key it derives from the URL). Future hook,
> out of scope for STORY 3: the history reader already reads one real answer doc to derive the LTI tuple
> (`readHistoryEndpoint`), so it could cross-check `answer.source_key` against the requested `source` there and
> surface a mismatch signal instead of returning empty. The validation milestone (below) must confirm on real
> data that the URL-derived `source` matches where a known learner's answers actually live.

---

### Node emulator test harness + faithful seed helper

**Summary**: the repo has the emulator *binary* configured (Firestore port 9090, in the **repo-root** `firebase.json` — NOT `functions/firebase.json`) but **no automated test harness** — jest is `^24`, `test` is plain `jest`, all existing tests are pure in-memory, and there is **no `emulators:exec` usage and no emulator-backed test** today. (`FIRESTORE_EMULATOR_HOST` is already *referenced* once, at `firebase-client.ts:54` — `process.env.FIRESTORE_EMULATOR_HOST || "localhost:9090"` — but nothing in the test path sets it.) Standing this up is a prerequisite for every emulator-backed test below. Verified-working approach: wrap jest in `firebase emulators:exec`. **Must fail closed** when `FIRESTORE_EMULATOR_HOST` is unset (an unguarded admin-SDK test connects to the real `report-service-dev` project).

**Hermetic CI (finding from Phase-3 review)**: `firebase-tools` is currently only a **global**-install script (`firebase:tools:install`), not a pinned dependency, so a bare `firebase emulators:exec` in `test:emulator` would silently fail to launch on any CI runner without the global binary — and every emulator-backed assertion would then not run behind a green `npm test`. Pin `firebase-tools` in `functions/devDependencies` and invoke it via `npx` (resolves to `node_modules/.bin`) so the harness is self-contained.

**Files affected**:
- `functions/package.json` — edit (add `firebase-tools` to `devDependencies`; add `test:emulator` script; add `\.emulator\.test\.` to `jest.testPathIgnorePatterns` so plain `npm test` skips the emulator suites — see finding Q1)
- `functions/src/test/emulator-setup.ts` — new (fail-closed guard)
- `functions/src/test/seed-helpers.ts` — new (faithful activity-player write shapes)

**Estimated diff size**: ~180 lines.

```jsonc
// functions/package.json
// add to "devDependencies" (pinned; makes the emulator harness hermetic — no reliance on a global install)
"firebase-tools": "^13.0.0",
// add to "scripts" (npx resolves the pinned binary from node_modules/.bin).
// NOTE the trailing `--testPathIgnorePatterns "/node_modules/"`: it OVERRIDES the config ignore below so
// the emulator suites are re-included here. Without it, jest ANDs the config's ignore (which now excludes
// `\.emulator\.test\.`) with `--testPathPattern`, and this script finds ZERO tests (verified).
"test:emulator": "npx firebase emulators:exec --only firestore --project report-service-dev 'jest --testPathPattern emulator --testPathIgnorePatterns \"/node_modules/\"'",
// add the emulator pattern to the EXISTING jest.testPathIgnorePatterns so plain `npm test` skips it:
// "jest": { ..., "testPathIgnorePatterns": ["/node_modules/", "\\.emulator\\.test\\."] }
```

**Why both halves are required (finding Q1, verified):** the live jest config uses
`testRegex: "(/__tests__/.*|(\\.|/)(test|spec))\\.(jsx?|tsx?)$"`, which matches `*.emulator.test.ts`, and
`testPathIgnorePatterns` is only `["/node_modules/"]`. So a bare `npm test` (`"test": "jest"`) would
discover the emulator suites, and their top-level `import "./emulator-setup"` throws fail-closed when
`FIRESTORE_EMULATOR_HOST` is unset — turning every default `npm test` (dev box, or any CI job running the
default script) RED. Adding `"\\.emulator\\.test\\."` to `testPathIgnorePatterns` makes `npm test` skip
them; the `test:emulator` script then re-includes them by OVERRIDING the ignore list on the CLI (a probe
confirmed `testPathIgnorePatterns` is ANDed and is NOT lifted by `--testPathPattern` alone). `emulators:exec`
sets `FIRESTORE_EMULATOR_HOST` in the child env; the admin SDK auto-detects it. (Pin the exact
`firebase-tools` major to whatever the team already installs globally; `^13` is a placeholder to confirm
against the current CLI version.)

```ts
// functions/src/test/emulator-setup.ts
// Import this at the top of every *.emulator.test.ts. Fails CLOSED so a test can never touch a real project.
import admin from "firebase-admin";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    "FIRESTORE_EMULATOR_HOST is unset — refusing to run emulator tests against a real Firestore project. " +
    "Run via `npm run test:emulator` (firebase emulators:exec)."
  );
}

if (admin.apps.length === 0) {
  admin.initializeApp({ projectId: "report-service-dev" });
}

export const db = admin.firestore();

export async function clearFirestore() {
  // emulator-only: delete all docs under /sources used by a test run
  const sources = await db.collection("sources").listDocuments();
  await Promise.all(sources.map((s) => db.recursiveDelete(s)));
}
```

Seed helper — copies the **exact field set** from activity-player `createAnswerDoc` (`firebase-db.ts:542-590`) and `createInteractiveStateHistoryEntry` (`:596+`), not a hand-picked subset. Shape-fidelity fixtures use `serverTimestamp`; ordering/tie/precision fixtures pass explicit `Timestamp(seconds, nanoseconds)` (a test cannot pin a `serverTimestamp` to force a tie or a sub-µs gap).

```ts
// functions/src/test/seed-helpers.ts
import admin from "firebase-admin";
import { db } from "./emulator-setup";

const { Timestamp, FieldValue } = admin.firestore;

interface SeedAnswerOpts {
  source: string;
  remote_endpoint: string;
  question_id: string;
  answer_id: string;
  platform_id: string;
  platform_user_id: string;
  resource_link_id: string;
  context_id?: string;
  interactiveState?: unknown;   // will be double-JSON-encoded into report_state
  extra?: Record<string, unknown>;
}

// Faithful answer doc (matches createAnswerDoc). report_state is DOUBLE-encoded.
export function answerDoc(o: SeedAnswerOpts) {
  return {
    id: o.answer_id,
    question_id: o.question_id,
    type: "interactive_state",
    source_key: o.source,
    tool_id: "activity-player",
    resource_url: `https://example.com/${o.resource_link_id}`,
    context_id: o.context_id ?? "class-hash-1",
    run_key: "",
    remote_endpoint: o.remote_endpoint,
    platform_id: o.platform_id,
    platform_user_id: o.platform_user_id,
    resource_link_id: o.resource_link_id,
    created: new Date().toUTCString(),
    interactive_state_history_id: "",
    report_state: JSON.stringify({
      interactiveState: JSON.stringify(o.interactiveState ?? { foo: "bar" }),
    }),
    ...(o.extra ?? {}),
  };
}

export async function seedAnswer(o: SeedAnswerOpts) {
  await db.doc(`sources/${o.source}/answers/${o.answer_id}`).set(answerDoc(o));
}

// One history snapshot: metadata doc (sortable created_at Timestamp) + state doc (full answer-doc copy w/ remote_endpoint).
export async function seedHistory(o: SeedAnswerOpts & {
  history_id: string;
  created_at?: { seconds: number; nanoseconds: number };  // omit -> serverTimestamp (shape fixtures)
}) {
  const created_at = o.created_at
    ? new Timestamp(o.created_at.seconds, o.created_at.nanoseconds)  // ordering/tie/precision fixtures
    : FieldValue.serverTimestamp();                                  // shape-fidelity fixtures

  await db.doc(`sources/${o.source}/interactive_state_histories/${o.history_id}`).set({
    id: o.history_id,
    answer_id: o.answer_id,
    question_id: o.question_id,
    state_type: "full",
    created_at,
    platform_id: o.platform_id,
    platform_user_id: o.platform_user_id,
    resource_link_id: o.resource_link_id,
    context_id: o.context_id ?? "class-hash-1",
  });

  // state doc = full copy of the answer doc at that instant (carries remote_endpoint)
  await db.doc(`sources/${o.source}/interactive_state_history_states/${o.history_id}`).set(answerDoc(o));
}
```

---

### Node bulk read — cursor/timestamp helpers, header-only guard, `/answers` + `/history` walker, route registration + timeout

**Summary**: The authorization-blind Firestore reader. One `POST /bulk_read` route (collection in body), gated by the shared bearer middleware **plus** a per-route header-only guard. Walks the ordered endpoint slice under three caps (`limit`/`endpoint_limit`/`read_limit`), returns items + `stop_endpoint_offset` + inner cursor + a **proven** `endpoint_exhausted` + `touched_endpoints`. Raises the shared `api` function timeout 60 → ~300 s.

**Files affected**:
- `functions/src/api/helpers/bulk-cursor.ts` — new (Timestamp reconstruction + strict validation)
- `functions/src/middleware/require-header-bearer.ts` — new (key-existence guard)
- `functions/src/api/bulk-read.ts` — new (the walker + both collection readers)
- `functions/src/index.ts` — edit (register route, raise timeout, doc string)
- tests: `functions/src/api/helpers/bulk-cursor.test.ts` (pure), `functions/src/middleware/require-header-bearer.test.ts` (pure), `functions/src/api/bulk-read.emulator.test.ts` (emulator)

**Estimated diff size**: ~430 lines.

#### Cursor helpers (strict; a bad cursor must never throw a 500 inside Node)

```ts
// functions/src/api/helpers/bulk-cursor.ts
import admin from "firebase-admin";

const { Timestamp } = admin.firestore;

// Answers inner cursor: { docId }. History inner cursor: { seconds, nanoseconds, docId }.
export type AnswersCursor = { docId: string };
export type HistoryCursor = { seconds: number; nanoseconds: number; docId: string };

const isInt = (n: unknown): n is number => typeof n === "number" && Number.isInteger(n);

// Firestore Timestamp valid range (0001-01-01T00:00:00Z .. 9999-12-31T23:59:59Z). `new Timestamp(s, _)` with
// out-of-range seconds throws a RangeError — which is NOT a `badRequest` error, so it would surface as an
// uncaught 500. isInt alone does not bound seconds; an integer-but-out-of-range `seconds` (e.g. a tampered
// page_token) must be rejected as BAD_REQUEST here, before construction. (F-ext7-1)
const TS_MIN_SECONDS = -62_135_596_800;
const TS_MAX_SECONDS = 253_402_300_799;
const isValidTsSeconds = (s: unknown): s is number => isInt(s) && s >= TS_MIN_SECONDS && s <= TS_MAX_SECONDS;

// A Firestore cursor docId must be a PLAIN document id: non-empty and no "/". `startAfter(docId)` /
// `startAfter(ts, docId)` on a documentId ordering throws synchronously otherwise (verified). (AI-1)
const isPlainDocId = (v: unknown): v is string => typeof v === "string" && v.length > 0 && !v.includes("/");

// Returns a Firestore Timestamp or throws a typed error the handler maps to BAD_REQUEST (never an uncaught 500).
export function reconstructTimestamp(c: HistoryCursor) {
  if (!isValidTsSeconds(c.seconds) || !isInt(c.nanoseconds) || c.nanoseconds < 0 || c.nanoseconds > 999_999_999) {
    const e: any = new Error("inner_cursor has invalid Timestamp fields");
    e.badRequest = true;
    throw e;
  }
  return new Timestamp(c.seconds, c.nanoseconds); // safe: seconds+nanoseconds bounds-checked above
}

export function validateHistoryCursor(c: unknown): asserts c is HistoryCursor | null {
  if (c === null || c === undefined) return;
  const o = c as any;
  if (!isValidTsSeconds(o.seconds) || !isInt(o.nanoseconds) || o.nanoseconds < 0 || o.nanoseconds > 999_999_999 ||
      !isPlainDocId(o.docId)) {
    const e: any = new Error("malformed history inner_cursor");
    e.badRequest = true;
    throw e;
  }
}

export function validateAnswersCursor(c: unknown): asserts c is AnswersCursor | null {
  if (c === null || c === undefined) return;
  if (!isPlainDocId((c as any).docId)) {
    const e: any = new Error("malformed answers inner_cursor");
    e.badRequest = true;
    throw e;
  }
}
```

> Elixir already decode-and-validates the inner cursor's numeric fields before forwarding (see the controller step), so these guards are defense-in-depth; but they guarantee that even a hand-crafted internal call gets a clean `BAD_REQUEST`, never the uncaught 500 that `new Timestamp()` would throw. (This session's probe confirmed `new Timestamp(100,1000000000)` and stringified args throw.)

#### Header-only guard (key-existence, not `typeof === "string"`)

```ts
// functions/src/middleware/require-header-bearer.ts
import express from "express";

// The shared bearer-token-auth already ran and authenticated. This per-bulk-route guard rejects any request
// that carried the bearer as a query param or body value — in ANY form (scalar/array/object) via a
// key-existence check (NOT typeof === "string"). SCOPE (F-ext7-3): this ENFORCES header-only usage for this
// route (401 on query/body bearer), which stops a compliant client from putting the token in a URL/body going
// forward and keeps it out of app-level *body* logs. It does NOT retroactively scrub a `?bearer=…` from the
// upstream ALB/proxy *access log*, which records the request URL BEFORE any Express middleware runs — that
// leak, if it occurs, is a proxy-layer concern (don't log query strings) and no in-Express guard can undo it.
export default function requireHeaderBearer(req: express.Request, res: express.Response, next: express.NextFunction) {
  const inQuery = req.query && Object.prototype.hasOwnProperty.call(req.query, "bearer");
  const inBody = req.body && typeof req.body === "object" && Object.prototype.hasOwnProperty.call(req.body, "bearer");
  if (inQuery || inBody) {
    return res.error(401, "This route requires the Authorization: Bearer header; query/body bearer is not accepted.");
  }
  next();
}
```

(This session's qs/Express probe confirmed `?bearer[0]=` → array, `?bearer[x]=` → object, and that `"bearer" in query` catches all forms while `typeof === "string"` misses them.)

#### The walker (`bulk-read.ts`)

```ts
// functions/src/api/bulk-read.ts
import { Request, Response } from "express";
import admin from "firebase-admin";
import { getPath, getCollection, getDoc } from "./helpers/paths";
import {
  reconstructTimestamp, validateHistoryCursor, validateAnswersCursor, HistoryCursor, AnswersCursor,
} from "./helpers/bulk-cursor";

const { FieldPath } = admin.firestore;
const HISTORY_BATCH = 300;   // metadata docs per query
const GETALL_CHUNK = 300;    // state docs per getAll
// NOTE (read-budget accounting): a history batch performs up to 2*batch reads — the metadata query
// PLUS the state-doc getAll — but only the metadata query is sized against the remaining budget. So the
// EFFECTIVE read ceiling per call is read_limit + HISTORY_BATCH (~6% over the 5000 default), bounded and
// non-runaway (the loop re-checks reads>=remReads at the top). read_limit's default carries that headroom;
// a truly hard cap isn't achievable without pre-counting, which Firestore does not offer cheaply.

type LtiTuple = { platform_id: string; platform_user_id: string; resource_link_id: string };
type SourceEndpoint = { remote_endpoint: string; source: string; lti_tuple?: LtiTuple | null };

interface BulkRequest {
  collection: "answers" | "history";
  source_endpoints: SourceEndpoint[];   // ordered slice from the current endpoint index onward
  inner_cursor: AnswersCursor | HistoryCursor | null;
  limit: number;
  endpoint_limit: number;
  read_limit: number;
}

// Result of reading one endpoint under the remaining caps.
interface EndpointRead {
  items: any[];
  innerCursor: AnswersCursor | HistoryCursor | null; // null iff exhausted
  exhausted: boolean;
  reads: number;                                     // raw docs counted toward read_limit
  touched?: { remote_endpoint: string; lti_tuple: LtiTuple } | null;
}

async function chunkedGetAll(refs: FirebaseFirestore.DocumentReference[]) {
  const out: FirebaseFirestore.DocumentSnapshot[] = [];
  for (let i = 0; i < refs.length; i += GETALL_CHUNK) {
    const chunk = refs.slice(i, i + GETALL_CHUNK);
    out.push(...(await admin.firestore().getAll(...chunk)));
  }
  return out;
}

// ---- ANSWERS: ordered by __name__ (doc id); 1 returned item == 1 raw doc read ----
// Exported for direct emulator-test assertions on walker mechanics (cursor/ordering/caps/post-filter) —
// see finding Q2; the handler-level res.success/res.error path is covered separately.
export async function readAnswersEndpoint(ep: SourceEndpoint, start: AnswersCursor | null,
                                   remItems: number, remReads: number): Promise<EndpointRead> {
  const path = await getPath(ep.source, "answers");
  const base = () => getCollection(path).where("remote_endpoint", "==", ep.remote_endpoint).orderBy(FieldPath.documentId());

  const cap = Math.max(0, Math.min(remItems, remReads));
  if (cap === 0) return { items: [], innerCursor: start, exhausted: false, reads: 0 };

  let q = base();
  if (start) q = q.startAfter(start.docId);
  const snap = await q.limit(cap).get();
  const items = snap.docs.map((d) => ({ ...d.data(), id: d.id }));
  const reads = snap.size;
  const lastId = snap.size ? snap.docs[snap.size - 1].id : start?.docId ?? null;

  if (snap.size < cap) {
    return { items, innerCursor: null, exhausted: true, reads };     // short read = natural end
  }
  // exactly `cap` docs -> next-doc unknown; one-doc lookahead (counts toward read_limit, may exceed by 1)
  let la = base();
  if (lastId) la = la.startAfter(lastId);
  const laSnap = await la.limit(1).get();
  if (laSnap.empty) return { items, innerCursor: null, exhausted: true, reads: reads + laSnap.size };
  return { items, innerCursor: { docId: lastId as string }, exhausted: false, reads: reads + laSnap.size };
}

// ---- HISTORY: keyed by LTI tuple; ordered by (created_at, __name__); post-filtered to remote_endpoint ----
// Exported for direct emulator-test assertions (see finding Q2).
export async function readHistoryEndpoint(ep: SourceEndpoint, start: HistoryCursor | null,
                                   remItems: number, remReads: number): Promise<EndpointRead> {
  // derive/cache the LTI tuple (the `answers ... limit 1` read does NOT count toward read_limit)
  let tuple = ep.lti_tuple ?? null;
  let touched: EndpointRead["touched"] = null;
  if (!tuple) {
    const ansPath = await getPath(ep.source, "answers");
    const ansSnap = await getCollection(ansPath).where("remote_endpoint", "==", ep.remote_endpoint).limit(1).get();
    if (ansSnap.empty) return { items: [], innerCursor: null, exhausted: true, reads: 0, touched: null }; // no answers -> no history
    const a = ansSnap.docs[0].data();
    tuple = { platform_id: a.platform_id, platform_user_id: a.platform_user_id, resource_link_id: a.resource_link_id };
    touched = { remote_endpoint: ep.remote_endpoint, lti_tuple: tuple };
  }

  const metaPath = await getPath(ep.source, "interactive_state_histories");
  const statePathPrefix = await getPath(ep.source, "interactive_state_history_states");
  const metaBase = () => getCollection(metaPath)
    .where("platform_id", "==", tuple!.platform_id)
    .where("platform_user_id", "==", tuple!.platform_user_id)
    .where("resource_link_id", "==", tuple!.resource_link_id)
    .orderBy("created_at").orderBy(FieldPath.documentId());

  const items: any[] = [];
  let reads = 0;
  let cursor: HistoryCursor | null = start;
  let exhausted = false;
  let hitItemCap = false;   // broke mid-batch on the item cap -> a next metadata doc provably exists in-stream

  while (true) {
    if (items.length >= remItems || reads >= remReads) { exhausted = false; break; }
    const batch = Math.max(1, Math.min(HISTORY_BATCH, remReads - reads));
    let q = metaBase();
    if (cursor) q = q.startAfter(reconstructTimestamp(cursor), cursor.docId);
    const metaSnap = await q.limit(batch).get();
    reads += metaSnap.size;
    if (metaSnap.size === 0) { exhausted = true; break; }

    const stateRefs = metaSnap.docs.map((d) => getDoc(`${statePathPrefix}/${d.id}`));
    const stateDocs = await chunkedGetAll(stateRefs);
    reads += stateDocs.length;

    // Push in metadata order, advancing the cursor to the LAST CONSUMED doc, and STOP exactly at the item
    // cap (mid-batch if needed) so `limit` is respected precisely — same contract as the answers path.
    for (let i = 0; i < metaSnap.size; i++) {
      if (items.length >= remItems) { hitItemCap = true; break; } // stop AT the item cap; doc i is untouched
      const metaDoc = metaSnap.docs[i];
      const meta = metaDoc.data() as any;
      // advance the cursor for EVERY consumed doc (even a filtered/missing state doc): resuming after it is
      // safe because it produced no item, and it keeps the cursor monotonic with the metadata stream.
      cursor = { seconds: meta.created_at.seconds, nanoseconds: meta.created_at.nanoseconds, docId: metaDoc.id };
      const state = stateDocs[i];
      if (!state.exists) continue;
      const sd = state.data() as any;
      if (sd.remote_endpoint !== ep.remote_endpoint) continue;    // filter to the authorized endpoint (1:many tuple)
      items.push({
        ...sd,
        history_id: metaDoc.id,
        created_at: meta.created_at.toDate().toISOString(),        // MUST convert (raw Timestamp -> {_seconds,...})
        answer_id: meta.answer_id,
        question_id: meta.question_id,
      });
    }

    if (hitItemCap) { exhausted = false; break; }                 // more docs remain after the cursor in this batch
    if (metaSnap.size < batch) { exhausted = true; break; }        // short read = natural end (whole batch consumed)
    // full batch, all consumed, caps not yet hit -> loop; caps re-checked at top
  }

  // Stopped on a read/endpoint cap with next-doc unknown -> definitive lookahead (never guess `true`).
  // Skip it when we broke mid-batch on the item cap: a next metadata doc was already read this batch,
  // so the endpoint is provably NOT exhausted and no extra read is warranted.
  if (!exhausted && !hitItemCap && cursor) {
    const laSnap = await metaBase().startAfter(reconstructTimestamp(cursor), cursor.docId).limit(1).get();
    reads += laSnap.size;
    if (laSnap.empty) exhausted = true;
  }

  return { items, innerCursor: exhausted ? null : cursor, exhausted, reads, touched };
}

> **`report_state` is opaque passthrough — and can carry S3-attachment references in more than one form
> (live-verified, 2026-07-15; org-wide writer audit).** The item push spreads the state doc verbatim (`...sd`),
> so `report_state` is returned exactly as stored: a **double-JSON-encoded** string that the walker never parses,
> reshapes, or validates. Its decoded inner `interactiveState` comes in these shapes the consumer must tolerate:
> - **Inline state** — the actual payload (e.g. `{"answerType":"open_response_answer","answerText":"…"}`, a
>   bar-chart `barValues` array, or a CODAP/DG document inline when small enough).
> - **Whole-state offloaded to an attachment** — a pointer `{"__attachment__":"file-{ts}.json"|"file.json",
>   "contentType":"application/json"}`, written by **`cloud-file-manager`** (`interactive-api-provider.ts`,
>   `kDynamicAttachmentSizeThreshold` = 400 KiB; commits CFM-18 `41cd3cd`/`ddc46e9`) when serialized state
>   ≥ 400 KiB. NB: CFM is used **only by CODAP and SageModeler** (verified org-wide: the only importer of
>   `@concord-consortium/cloud-file-manager` is `codap`; CFM was meant to be generic but was never adopted
>   elsewhere), so `__attachment__` appears in practice only for CODAP/SageModeler answers.
> - **Inline state that references a *media* attachment** — e.g. open-response audio: the inner state stays
>   small but carries `{"answerType":"open_response_answer","answerText":"…","audioFile":"audio{ts}.mp3"}`,
>   where `audioFile` names an `audio/mpeg` S3 attachment holding the recording. Written by
>   `question-interactives/packages/open-response` (`runtime.tsx` `writeAttachment(...)`). Open-response-specific;
>   the other 25 question types keep state inline and write no attachments. `answerText` may be empty while
>   `audioFile` is the entire response.
>
> The set of attachment-reference fields is small but technically **open** (`__attachment__`, `audioFile`; a
> future interactive could add another) — which is exactly why the walker keeps `report_state` opaque/verbatim
> rather than trying to enumerate and resolve them. In every case **the walker returns the reference untouched
> and does NOT resolve it**: the bytes live in **S3, not Firestore**, reachable only via the AP/LARA attachments
> service (`getAttachmentUrl({name})`) scoped to the answer's `remote_endpoint`. A bulk-read consumer that needs
> the actual content (offloaded state JSON, or audio) must resolve the attachment name itself against that
> service; `portal-report/js/components/report/iframe-answer-report-item-attachment.tsx` is the existing report
> UI's attachment resolver and the reference implementation. (See the Open Question "Server-side attachment
> resolution endpoint" for whether report-service should expose this.) A single learner+resource history stream
> also legitimately mixes multiple `question_id`s and `type`s (`open_response_answer`, `interactive_state`)
> interleaved by `created_at` — the reader filters ONLY by `remote_endpoint`, never by question or type, so all
> of them flow through. (Observed: 22 snapshots for one staging learner across 3 questions over 10 days.)

#### Fourth cap — response-byte budget (`RESPONSE_BYTE_BUDGET`, F-ext-3 hardening)

**Why item-count and read caps are not enough.** `limit` bounds returned *items*, `read_limit` bounds Firestore
*reads* — **neither bounds response BYTES**, and the gen1 Cloud Function response cap is ~10 MB. A live probe
(2026-07-15, staging `report-service-dev`, `functions/byte-envelope.js`) measured real serialized item sizes:
answers median ~1.5 KB / p95 ~12 KB / **max ~313 KB**; history state docs median ~1.7 KB / **p95 ~52 KB**. The
mean page is comfortable (~2–4 MB at 500 items), but item size is highly variable and large interactive states
**cluster by activity** — a class doing a CODAP activity returns many 50–300 KB items in a row. At the tail,
~10 near-max items already reach 10 MB, so a 500-item page can blow the cap. (Dev data only — pro likely larger.)

**The per-item ceiling that makes a byte budget safe.** No single item can exceed the **Firestore 1 MiB document
limit**, which Firestore enforces on every write (oversized docs simply fail to save). Large state/media never
inflates `report_state`: CODAP/SageModeler offload whole state to an `__attachment__` at 400 KiB (CFM-18), and
open-response offloads audio to `audioFile` — both leave only a tiny reference inline (see the passthrough note
above). So a **soft budget of ~8 MB** (`RESPONSE_BYTE_BUDGET = 8 * 1024 * 1024`, leaving headroom under 10 MB for
the JSON envelope: the `items` wrapper, `stop_endpoint_offset`, cursor, `touched_endpoints`, and UTF-8 expansion)
**always admits at least one item** (max item < 1 MiB ≪ 8 MB) → **forward progress is guaranteed, no single-item
deadlock**; a pathological all-max page still yields ~8 items.

**Integration (page-level, threaded like `remItems`/`remReads`).** The budget is a Node constant (tied to the
fixed platform cap, not a per-request tunable) tracked across the whole endpoint walk in `bulkRead`, and passed
as `remBytes` into both readers alongside `remItems`/`remReads`. Each reader, **before pushing an item**,
measures `Buffer.byteLength(JSON.stringify(item), "utf8")` and stops **if at least one item has already been
pushed this page AND adding this item would exceed `remBytes`** — setting the inner cursor to the last *included*
item and treating it exactly like the existing mid-batch item-cap stop (`exhausted:false`, next-doc provably
exists). The first item of a page is always included (progress backstop; unreachable in practice since max item
< budget). `bulkRead` decrements `remBytes` by each returned item's size as endpoints are consumed.

```ts
// helper (bulk-read.ts): serialized UTF-8 size of one emitted item
const itemBytes = (item: any) => Buffer.byteLength(JSON.stringify(item), "utf8");

// ANSWERS reader: after `snap` is fetched, replace the bulk `.map` with a byte-aware include loop that trims to
// the budget and reports the last-included doc as the cursor (mirrors the history mid-batch stop):
const items: any[] = [];
let bytes = 0, trimmed = false, lastIncludedId = start?.docId ?? null;
for (const d of snap.docs) {
  const item = { ...d.data(), id: d.id };
  const sz = itemBytes(item);
  if (items.length >= 1 && bytes + sz > remBytes) { trimmed = true; break; }  // stop AT the budget
  items.push(item); bytes += sz; lastIncludedId = d.id;
}
// if `trimmed`, the page ended on the byte cap mid-fetch: innerCursor = { docId: lastIncludedId },
// exhausted:false (a next doc provably exists — it's the one we didn't include), no lookahead needed.

// HISTORY reader: in the existing per-doc push loop, add the same guard alongside the item-cap check:
//   if (items.length >= 1 && bytes + itemBytes(nextItem) > remBytes) { hitByteCap = true; break; }
// treat hitByteCap identically to hitItemCap (cursor at last consumed, exhausted:false, skip lookahead).
```

**Test (emulator).** Seed several large `report_state`s (~300–900 KB each): a page returns **fewer than
`limit`** items with total serialized size **≤ budget + one-item overshoot**, the inner cursor points at the last
*included* item, and the next page resumes with **no gap/dup**; separately, a single item seeded **larger than
the budget** still returns **exactly that one item** (progress guarantee). Pure-unit: `itemBytes` counts UTF-8
bytes (a multi-byte `report_state` is not undercounted — same class of bug as CFM-18 `ddc46e9`).

export default async function bulkRead(req: Request, res: Response) {
  try {
    const body = req.body as BulkRequest;
    const { collection, source_endpoints, inner_cursor, limit, endpoint_limit, read_limit } = body;

    if (collection !== "answers" && collection !== "history") return res.error(400, "invalid collection");
    if (!Array.isArray(source_endpoints)) return res.error(400, "source_endpoints must be an array");
    // All three caps must be positive integers. read_limit>=1 guards forward progress; limit>=1 and
    // endpoint_limit>=1 do too — this route is authorization-blind and internet-reachable behind the shared
    // static bearer, so a malformed DIRECT bearer call (or a future Elixir regression) must not slip a
    // limit:0 / non-integer through and get a same-position no-progress page (readAnswersEndpoint returns
    // {items:[], innerCursor: start, exhausted:false} when cap===0). Reject at the boundary. (F-ext5-2)
    // Each cap must be an integer in [1, max]. `>= 1` guards forward progress (limit:0 -> no-progress page).
    // The upper bound bounds worst-case work for a malformed/leaked-bearer DIRECT call (Elixir sends far
    // smaller fixed values); generous headroom over Elixir's 500/250/5000 so real tuning is never rejected.
    // (F-ext5-2 lower bound; AI-3 upper bound.)
    const CAP_MAX: Record<string, number> = { limit: 2000, endpoint_limit: 10000, read_limit: 100000 };
    for (const [name, v] of [["limit", limit], ["endpoint_limit", endpoint_limit], ["read_limit", read_limit]] as const) {
      if (!Number.isInteger(v) || v < 1) return res.error(400, `${name} must be an integer >= 1`);
      if (v > CAP_MAX[name]) return res.error(400, `${name} must be <= ${CAP_MAX[name]}`);
    }

    // Validate every endpoint OBJECT, not just that the outer value is an array. Elixir always builds these
    // from the scratch, but a direct bearer call could send `[{}]`, whose undefined `source`/`remote_endpoint`
    // would reach `where("remote_endpoint","==",undefined)` and throw inside Firestore -> uncaught 500. Reject
    // as BAD_REQUEST here (defense-in-depth, same posture as the caps/cursor guards). (F-ext7-2)
    // `source` ALSO must not contain "/": it is a path segment in getPath("/sources/<source>/<type>"), and a
    // slash breaks the collection-path arity -> getCollection(...) throws synchronously -> uncaught 500
    // (verified). remote_endpoint is only a query VALUE, so a slash there is harmless. (AI-2)
    const isNonEmptyStr = (v: unknown): v is string => typeof v === "string" && v.length > 0;
    for (const ep of source_endpoints) {
      if (!ep || typeof ep !== "object") return res.error(400, "each source_endpoint must be an object");
      if (!isNonEmptyStr((ep as any).source) || (ep as any).source.includes("/")) {
        return res.error(400, "source_endpoint.source must be a non-empty string with no '/'");
      }
      if (!isNonEmptyStr((ep as any).remote_endpoint)) {
        return res.error(400, "source_endpoint.remote_endpoint must be a non-empty string");
      }
      const t = (ep as any).lti_tuple;
      if (t !== undefined && t !== null) {
        if (typeof t !== "object" ||
            !isNonEmptyStr(t.platform_id) || !isNonEmptyStr(t.platform_user_id) || !isNonEmptyStr(t.resource_link_id)) {
          return res.error(400, "source_endpoint.lti_tuple must be null/absent or {platform_id, platform_user_id, resource_link_id} strings");
        }
      }
    }

    if (collection === "answers") validateAnswersCursor(inner_cursor);
    else validateHistoryCursor(inner_cursor);

    const items: any[] = [];
    const touched: NonNullable<EndpointRead["touched"]>[] = [];
    let reads = 0;
    let endpointsWalked = 0;
    let stopOffset = 0;
    let stopCursor: EndpointRead["innerCursor"] = null;
    let stopExhausted = true;

    for (let offset = 0; offset < source_endpoints.length; offset++) {
      const ep = source_endpoints[offset];
      const start = offset === 0 ? inner_cursor : null;
      const remItems = limit - items.length;
      const remReads = read_limit - reads;

      const r = collection === "answers"
        ? await readAnswersEndpoint(ep, start as AnswersCursor | null, remItems, remReads)
        : await readHistoryEndpoint(ep, start as HistoryCursor | null, remItems, remReads);

      items.push(...r.items);
      reads += r.reads;
      if (r.touched) touched.push(r.touched);
      endpointsWalked++;
      stopOffset = offset;
      stopCursor = r.innerCursor;
      stopExhausted = r.exhausted;

      if (!r.exhausted) break;                    // hit a cap mid-endpoint -> resume same endpoint
      if (items.length >= limit) break;           // item cap, endpoint exhausted -> advance +1
      if (reads >= read_limit) break;             // read cap
      if (endpointsWalked >= endpoint_limit) break; // endpoint cap (empty-mid-export page lands here)
    }

    return res.success({
      items,
      stop_endpoint_offset: stopOffset,
      inner_cursor: stopCursor,
      endpoint_exhausted: stopExhausted,
      touched_endpoints: touched,
    });
  } catch (e: any) {
    if (e && e.badRequest) return res.error(400, e.message);
    console.error(e);
    return res.error(500, e?.toString?.() ?? "bulk_read failed");
  }
}
```

#### Register the route + raise the timeout (`index.ts`)

```ts
// functions/src/index.ts

// --- imports (after line 16) ---
import bulkRead from "./api/bulk-read"
import requireHeaderBearer from "./middleware/require-header-bearer"

// --- route registration (after line 58, alongside the other api.get/api.post routes) ---
api.post("/bulk_read", requireHeaderBearer, bulkRead)

// --- add a doc line to the methods object (lines 41-49) ---
"POST bulk_read": "STORY 3: bulk answers/history read for a report run's authorized endpoints (Elixir-only, header bearer required)",

// --- raise the shared function timeout (lines 64-65) ---
// BEFORE
const wrappedApi = functions
  .runWith({ secrets: [bearerToken] })
// AFTER
const wrappedApi = functions
  .runWith({ secrets: [bearerToken], timeoutSeconds: 300 })   // STORY 3: headroom for a slow bulk page; ceiling, not a cost floor
```

> Deploy-review note (out of Node scope): raising `timeoutSeconds` lifts the max duration for **every** co-located route (`import_run`, `move_student_work`, `get-answer`, …). It's a ceiling, not a cost floor. Also sanity-check the ALB/proxy idle timeout against ~300 s.

#### Tests

- `bulk-cursor.test.ts` (pure): `reconstructTimestamp` throws `badRequest` for out-of-range/stringified fields, succeeds for valid; validators accept null and reject wrong shapes; **out-of-range `seconds` (F-ext7-1): `253_402_300_800` (too high) and `-62_135_596_801` (too low) throw `badRequest` from both `reconstructTimestamp` and `validateHistoryCursor` — NOT the RangeError that `new Timestamp` would raise; the in-range endpoints `253_402_300_799` / `-62_135_596_800` pass**; **non-plain `docId` (AI-1): `validateAnswersCursor`/`validateHistoryCursor` throw `badRequest` for `docId: "a/b"` (slash) and `docId: ""` (empty), and accept a plain id — guards the synchronous `startAfter(...)` throw on a documentId ordering.**
- `bulk-read.test.ts` (pure boundary guard, F-ext5-2 + F-ext7-2 + AI-2/AI-3): call `bulkRead` with a mock `req`/`res` (no Firestore) and assert **400** for: `limit`/`endpoint_limit`/`read_limit` each `0`, negative, non-integer, **or above its max (`limit>2000`, `endpoint_limit>10000`, `read_limit>100000` — AI-3)**; a non-array `source_endpoints`; a malformed endpoint object — `[{}]`, `[{source:"s"}]` (missing `remote_endpoint`), `[{source:"",remote_endpoint:"e"}]` (empty string), `[{source:"s",remote_endpoint:"e",lti_tuple:{platform_id:"p"}}]` (incomplete tuple), **and `[{source:"a/b",remote_endpoint:"e"}]` (source with "/" — AI-2)**. A fully well-formed request passes the guard. So a malformed direct internal-bearer call can never get a no-progress page, unbounded work, or a Firestore-`undefined`/path-arity 500. (Returns before any Firestore access, so no emulator needed.)
- `require-header-bearer.test.ts` (pure, **guard in isolation**): mock `req` with `query.bearer` scalar/array/object, `body.bearer`, and header-only — assert the guard returns 401 for the first four and `next()` for header-only. Annotate that this tests the guard ALONE; the real pipeline runs `bearerTokenAuth` first (see next bullet). (No supertest needed.)
- `require-header-bearer.test.ts` (**two-middleware integration**, F4/Round 3): compose the two exported middleware fns over a mock `req`/`res` in sequence — `bearerTokenAuth` then `requireHeaderBearer` (set the server token via the `AUTH_BEARER_TOKEN` seam) — to prove the 400-vs-401 layering the requirement enumerates: array/object query bearer **alone** → **400** from `bearerTokenAuth` (not a string, no header; guard never runs); array/object query bearer **+ valid `Authorization` header** → **401** from the guard; header-only valid → reaches the handler. (Chains the raw middleware fns directly; still no supertest.)
- `bulk-read.emulator.test.ts` (emulator, via `test:emulator`): seed with the helpers, then assert — answers pagination + `__name__` order + cursor resume; history `orderBy(created_at, __name__)` + ties across a page boundary (full-precision cursor drops nothing, a millis-rounded-up cursor skips → must fail); duplicate-learner `remote_endpoint` post-filter; empty-mid-export (`endpoint_limit`, 0 items, non-null resume); huge-filtered-history (`read_limit`, 0 items, mid-learner cursor); **`limit` smaller than a batch's matches (history)** → page returns EXACTLY `limit` items (not `limit`+batch), inner cursor points at the last returned item, and the next page resumes at item `limit`+1 with no gap/dup (F1 mid-batch item-cap guard); "cap hit exactly after exhausting the endpoint" → lookahead proves `endpoint_exhausted: true`; `touched_endpoints` returned on first touch only; `created_at` is ISO on the wire; double-encoded `report_state` passes through untouched. **Caveat asserted in a comment**: emulator green does not prove the dev/prod composite index (see the index step).

---

### Bulk controller — validation-milestone vertical slice (`/answers`, derive-once, scratch, one page, cursor round-trip)

**Summary**: The end-to-end mechanic proven before build-out. Adds the STORY-3 params module, the controller with the `/answers` action only, the derive-once + scratch + Node-proxy + cursor-reassembly path, and the two routes. **This is the validation milestone**: one learner → one page → cursor → resume, measurable on real data. `Cache-Control: no-store` (`put_no_store/1`) and the `EXPIRED_CURSOR` → 410 error code are added **in THIS step** — both are part of the resumability contract this milestone validates (F-ext2-1/F-ext2-3). Only `/history` and the per-page audit **access** row land in the next step (the page-1 **intent** row is already written here, atomically with the scratch).

**Files affected**:
- `server/lib/report_server_web/api/v1/bulk_params.ex` — new (STORY-3 limit/token parse + encode + validate)
- `server/lib/report_server_web/api/v1/bulk_export_controller.ex` — new (`answers/2` + shared serve path; `history/2` stubbed to `not_found` until next step)
- `server/lib/report_server_web/api/error_helpers.ex` — edit (add `EXPIRED_CURSOR` → 410 — the slice's `:expired` path calls `render_error(conn, "EXPIRED_CURSOR", …)`, and `render_error/4` `Map.fetch!`es `@statuses`, so the code MUST be registered in this same step or the slice raises instead of returning 410 — F-ext2-1)
- `server/lib/report_server_web/router.ex` — edit (two routes)
- `server/test/report_server_web/api/v1/bulk_export_controller_test.exs` — new (slice scenarios)

**Estimated diff size**: ~360 lines.

#### `BulkParams`

STORY-3-specific limit clamp (default 500 / max 500 — server cap == default, so `limit` only lowers; NOT STORY 1's 50/200) and the composite token. Elixir decodes and validates the inner cursor's numeric fields so Node never 500s.

```elixir
# server/lib/report_server_web/api/v1/bulk_params.ex
defmodule ReportServerWeb.Api.V1.BulkParams do
  @default_limit 500
  # server max == default: `limit` can only LOWER the page cap (requirements: "only lowers", @max_limit >= 500).
  # Kept at 500 (not 2000) because a page's JSON has NO response-byte guard — `read_limit` bounds doc *reads*,
  # not response *bytes* — and 500 large `report_state` docs is what keeps a page a few MB under the 10 MB gen1
  # response cap. Raising this later requires a response-size check (see the validation milestone). (F-ext-3)
  @max_limit 500

  # Firestore Timestamp valid range (0001-01-01T00:00:00Z .. 9999-12-31T23:59:59Z). A history cursor whose
  # `seconds` is an integer but out of this range passes `is_integer/1` yet makes Node's `new Timestamp(s,_)`
  # throw a RangeError -> uncaught 500. Bound it here so a tampered page_token 400s at the Elixir edge. (F-ext7-1)
  @ts_min_seconds -62_135_596_800
  @ts_max_seconds 253_402_300_799

  # limit only LOWERS the ~500 cap (a caller may request a smaller page; never raise above the server max)
  def parse_limit(params) do
    case Map.fetch(params, "limit") do
      :error -> {:ok, @default_limit}
      {:ok, v} when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n |> max(1) |> min(@max_limit)}
          _ -> {:error, :bad_request, "limit must be an integer"}
        end
      {:ok, _} -> {:error, :bad_request, "limit must be an integer"}
    end
  end

  # {:ok, nil} | {:ok, %{scratch_id, endpoint_index, inner_cursor}} | {:error, :bad_request, msg}
  # inner_cursor is validated per-collection by the controller (numeric Timestamp fields for history).
  def parse_page_token(params) do
    case Map.fetch(params, "page_token") do
      :error -> {:ok, nil}
      {:ok, token} when is_binary(token) ->
        with {:ok, json} <- Base.url_decode64(token, padding: false),
             {:ok, %{"s" => s, "i" => i} = decoded} when is_binary(s) and is_integer(i) and i >= 0 <-
               Jason.decode(json) do
          {:ok, %{scratch_id: s, endpoint_index: i, inner_cursor: Map.get(decoded, "c")}}
        else
          _ -> {:error, :bad_request, "page_token is not valid"}
        end
      {:ok, _} -> {:error, :bad_request, "page_token is not valid"}
    end
  end

  def encode_page_token(scratch_id, endpoint_index, inner_cursor) do
    %{"s" => scratch_id, "i" => endpoint_index, "c" => inner_cursor}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # inner-cursor shape/range validation. Elixir is the gate that produces the client-facing 400 (a Node 4xx
  # is collapsed to 500 by serve_page), so it must reject everything Firestore would throw on.
  def validate_inner_cursor(nil, _collection), do: :ok
  def validate_inner_cursor(%{"docId" => d}, "answers"), do: check_doc_id(d)
  def validate_inner_cursor(%{"seconds" => s, "nanoseconds" => n, "docId" => d}, "history")
      when is_integer(s) and s >= @ts_min_seconds and s <= @ts_max_seconds and
           is_integer(n) and n >= 0 and n <= 999_999_999,
      do: check_doc_id(d)
  def validate_inner_cursor(_, _), do: {:error, "inner_cursor is malformed for this route"}

  # A Firestore cursor docId must be a PLAIN document id: a non-empty binary with no "/". Otherwise Node's
  # `startAfter(...)` on a documentId ordering throws SYNCHRONOUSLY (verified: "a/b" and "" both throw) ->
  # uncaught 500. `is_binary(d)`/`d != ""` alone is not enough — the "/" must be rejected too. (AI-1)
  defp check_doc_id(d) when is_binary(d) and d != "" do
    if String.contains?(d, "/"),
      do: {:error, "inner_cursor docId must be a plain document id (no '/')"},
      else: :ok
  end
  defp check_doc_id(_), do: {:error, "inner_cursor docId must be a non-empty plain document id"}
end
```

#### `BulkExportController` (slice: `/answers` path)

```elixir
# server/lib/report_server_web/api/v1/bulk_export_controller.ex
defmodule ReportServerWeb.Api.V1.BulkExportController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.{AuditLog, Exports, PortalDbs, Reports}
  alias ReportServer.Reports.{ReportFilter, SourceKey}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{BulkParams, Params}

  # STORY-3 page bounds (see requirements "Bounded work per call")
  @endpoint_limit 250
  @read_limit 5000

  def answers(conn, params), do: serve(conn, params, "answers_bulk", "answers")

  # /history lands in the next step; until then it 404s (never a 500)
  def history(conn, _params), do: ErrorHelpers.not_found(conn)

  defp serve(conn, %{"id" => id_param} = params, data_type, collection) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),                   # reuse STORY 1's parser: 0 < id <= @max_bigint; malformed/out-of-range :id -> 404 (parse first!)
         {:ok, report_run} <- Reports.get_api_report_run(user, id),# ownership -> 404
         {:ok, limit} <- BulkParams.parse_limit(params),
         {:ok, token} <- BulkParams.parse_page_token(params) do
      conn = put_no_store(conn)

      case token do
        nil ->
          first_page(conn, user, report_run, data_type, collection, limit)

        %{scratch_id: sid, endpoint_index: idx, inner_cursor: inner} ->
          next_page(conn, user, report_run, id, data_type, collection, limit, sid, idx, inner)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, :bad_request, msg} -> ErrorHelpers.bad_request(conn, msg)
    end
  end

  # :id parsing REUSES ReportServerWeb.Api.V1.Params.parse_id/1 (STORY 1) directly — do NOT re-implement it
  # locally: the shared parser enforces `0 < id <= @max_bigint`, so an out-of-bigint-range :id returns
  # {:error, :not_found} (→ 404) instead of being bound into get_api_report_run's Ecto query and blowing up
  # the MySQL bigint column with an out-of-range value (→ 500). Same {:ok, id} | {:error, :not_found} shape
  # the serve/4 `with` chain expects. (F-ext-2)

  # ---- page 1: derive-once, mint scratch + intent row atomically, serve from index 0 / null cursor ----
  defp first_page(conn, user, report_run, data_type, collection, limit) do
    case derive_endpoint_set(user, report_run) do
      {:ok, []} ->
        # empty export (empty permission set OR no matching learners): terminal empty page. No data is served
        # and there is nothing to resume, so no scratch is minted — but STORY 3 STILL records the intent row
        # ("this export was scoped to zero endpoints") for IRB/audit completeness, fail-closed like every other
        # audit write. export_id is minted (same capability generator) so the row is correlatable.
        export_id = Exports.mint_scratch_id()
        intent_attrs = audit_attrs(user, report_run, "export_scoped", "export_scoped", export_id, nil, [])

        case AuditLog.create_entry(intent_attrs) do
          {:ok, _entry} -> json(conn, %{items: [], next_page_token: nil})
          {:error, _reason} -> ErrorHelpers.server_error(conn)
        end

      {:ok, endpoints} ->
        scratch_id = Exports.mint_scratch_id()

        scratch_attrs = %{
          scratch_id: scratch_id,
          report_run_id: report_run.id,
          user_id: user.id,
          data_type: data_type,
          endpoint_set: endpoints,
          expires_at: Exports.ttl_expires_at()
        }

        intent_attrs =
          audit_attrs(user, report_run, "export_scoped", "export_scoped", scratch_id, nil,
            Enum.map(endpoints, & &1["remote_endpoint"]))

        case Exports.create_scratch_with_intent(scratch_attrs, intent_attrs) do
          {:ok, %{scratch: scratch}} ->
            serve_page(conn, user, report_run, scratch, collection, data_type, 0, nil, limit, nil)

          {:error, _step, _changeset, _} ->
            ErrorHelpers.server_error(conn)
        end

      {:error, _reason} ->
        ErrorHelpers.server_error(conn)
    end
  end

  # ---- page N: two-step scratch lookup (404 vs 410), bounds-check index + inner cursor, serve ----
  defp next_page(conn, user, report_run, id, data_type, collection, limit, scratch_id, idx, inner) do
    case Exports.fetch_for_page(scratch_id, user.id, id, data_type) do
      :not_found ->
        ErrorHelpers.not_found(conn)

      :expired ->
        ErrorHelpers.render_error(conn, "EXPIRED_CURSOR",
          "The export cursor has expired; restart the export from a null page_token.")

      {:ok, scratch} ->
        cond do
          idx < 0 or idx >= length(scratch.endpoint_set) ->
            ErrorHelpers.bad_request(conn, "page_token endpoint index out of range")

          BulkParams.validate_inner_cursor(inner, collection) != :ok ->
            ErrorHelpers.bad_request(conn, "inner_cursor is malformed for this route")

          true ->
            raw_token = raw_page_token(conn)
            serve_page(conn, user, report_run, scratch, collection, data_type, idx, inner, limit, raw_token)
        end
    end
  end

  # ---- shared: slice from index, call Node, reassemble cursor, (audit in next step), return envelope ----
  defp serve_page(conn, _user, _report_run, scratch, collection, _data_type, index, inner, limit, _raw_token) do
    endpoints = scratch.endpoint_set
    slice = Enum.drop(endpoints, index)

    req = %{
      collection: collection,
      source_endpoints: slice,
      inner_cursor: inner,
      limit: limit,
      endpoint_limit: @endpoint_limit,
      read_limit: @read_limit
    }

    case report_service().bulk_read(req) do
      {:ok, %{"items" => items, "stop_endpoint_offset" => off, "inner_cursor" => next_inner,
              "endpoint_exhausted" => exhausted, "touched_endpoints" => touched}} ->
        Exports.merge_touched_endpoints(scratch, touched)

        {next_index, next_cursor} =
          if exhausted, do: {index + off + 1, nil}, else: {index + off, next_inner}

        next_token =
          if next_index >= length(endpoints),
            do: nil,
            else: BulkParams.encode_page_token(scratch.scratch_id, next_index, next_cursor)

        # NOTE: per-page audit access row is added in the next step (fail-closed, before returning)
        json(conn, %{items: items, next_page_token: next_token})

      {:error, _reason} ->
        # Node read failure: no audit row, no cursor advance; CLI retries the same token idempotently.
        # NOTE: this also collapses a Node 4xx (e.g. the defense-in-depth BAD_REQUEST from a hand-crafted
        # inner_cursor) into a client 500. Acceptable because Elixir pre-validates the cursor
        # (BulkParams.validate_inner_cursor + numeric-field checks) so Node should never 4xx in practice;
        # if truthful mapping is later wanted, thread the Node error shape through and map a reported
        # BAD_REQUEST back to ErrorHelpers.bad_request/2.
        ErrorHelpers.server_error(conn)
    end
  end

  # ---- derive-once: permission short-circuit, nil-filter normalize, live LearnerData.fetch, source per learner ----
  defp derive_endpoint_set(user, report_run) do
    case allowed_project_ids_source().get_allowed_project_ids(user) do
      :none -> {:ok, []}   # defensive/unreachable (all role flags false -> AuthPlug 401s before here)
      [] -> {:ok, []}      # empty-permission short-circuit BEFORE any SQL (ReportUtils.list_to_in([]) -> "()", so a caller's "... IN #{...}" -> "IN ()" syntax error -> 500)
      {:error, _reason} = err ->
        # Portal permission query FAILED (get_project_ids -> query -> {:error,_}, portal_dbs.ex:149-159).
        # Return it so first_page maps it to a controlled SERVER_ERROR. Without this branch the `_allowed`
        # catch-all would swallow the tuple, LearnerData.fetch would re-derive the same failing permission
        # lookup, and ReportUtils.list_to_in({:error,_}) would raise Protocol.UndefinedError (Enum.map on a
        # tuple) — an uncaught crash instead of the planned 500. (F-ext5-1)
        err
      _allowed ->
        filter = report_run.report_filter || %ReportFilter{}   # nil is a live state; fetch(nil,...) would FunctionClauseError

        case learner_data().fetch(filter, user, allow_empty: true) do
          {:ok, learner_groups} -> {:ok, to_endpoints(learner_groups)}
          {:error, _msg} = err -> err
        end
    end
  end

  # LearnerData.fetch returns groups (grouped by runnable_url); each group's learners carry
  # run_remote_endpoint + runnable_url. Ordered, stable snapshot; source per learner.
  defp to_endpoints(learner_groups) do
    learner_groups
    |> Enum.flat_map(fn group -> Map.get(group, :learners, []) end)
    |> Enum.map(fn l ->
      %{"remote_endpoint" => l.run_remote_endpoint, "source" => derive_source(l.runnable_url)}
    end)
    # Drop any learner whose DERIVED source is not a usable non-empty string — this is what actually keeps a
    # malformed `source` out of the persisted scratch/audit set (Node's getPath(nil|"", …) would build
    # "/sources//…" and silently return no data). Filtering on the derived source (not just the input url)
    # subsumes the earlier input-only guard: SourceKey.from_runnable_url/1 returns `nil` for a non-binary or
    # hostless url ("foo", "/path") and `""` for a bare "https://" (all verified), and `derive_source/1`
    # returns nil for a non-binary url instead of raising. `run_remote_endpoint` is always a non-nil binary
    # (learner_data.ex:162,179). (F1 Round 3, corrected by F-ext6-1: guard the derived source, not the input.)
    # source must be a non-empty binary AND a single Firestore path segment (no "/") — a slash would make
    # Node's getCollection("/sources/<source>/answers") throw on path arity (AI-2). is_binary short-circuits,
    # so String.contains?/2 only runs on a binary. An `answersSourceKey` param with a "/" is the only way a
    # derived source could contain one; dropping it keeps a malformed source out of the scratch/audit set.
    |> Enum.filter(fn ep ->
      is_binary(ep["source"]) and ep["source"] != "" and not String.contains?(ep["source"], "/")
    end)
  end

  # Total wrapper: a non-binary runnable_url yields nil (then filtered) rather than a FunctionClauseError from
  # SourceKey.from_runnable_url/1's is_binary/1-only head. (F1 Round 3 / F-ext6-1)
  defp derive_source(url) when is_binary(url), do: SourceKey.from_runnable_url(url)
  defp derive_source(_), do: nil

  defp audit_attrs(user, report_run, event, data_type, export_id, cursor, endpoint_set) do
    %{
      event: event,
      source: "api",
      data_type: data_type,
      user_id: user.id,
      report_run_id: report_run.id,
      report_slug: report_run.report_slug,
      report_filter: AuditLog.dump_filter(report_run.report_filter),
      cursor: cursor,
      export_id: export_id,
      endpoint_set: endpoint_set
    }
  end

  defp put_no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp raw_page_token(conn), do: conn.query_params["page_token"]

  defp report_service, do: Application.get_env(:report_server, :report_service_client, ReportServer.ReportService)
  defp learner_data, do: Application.get_env(:report_server, :learner_data, ReportServer.Reports.Athena.LearnerData)
  defp allowed_project_ids_source, do: Application.get_env(:report_server, :allowed_project_ids_source, PortalDbs)
end
```

> **Confirmed** (read `group_learners_by_runnable_url/1`, `learner_data.ex:296-338`): it returns
> `[%{runnable_url: _, query_id: _, learners: [row, ...]}, ...]` in first-encountered order, and each `row` is
> the learner map from `map_learner_data/3` carrying `:run_remote_endpoint` and `:runnable_url`. So
> `group.learners` + `l.run_remote_endpoint` / `l.runnable_url` are correct. (Optimization available but not
> required: all learners in a group share one `runnable_url`, so `source` could be derived once per group.)

#### Routes (`router.ex`, before/after)

```elixir
# server/lib/report_server_web/router.ex (scope "/api/v1", lines 55-63)
# BEFORE
    get "/reports/:id/download", ReportController, :download
    get "/reports/:id/jobs", ReportJobController, :index
    get "/reports/:id/jobs/:job_id/download", ReportJobController, :download
# AFTER (add the two bulk routes above the jobs routes; they stay under :api_authenticated and above the match:* fallback)
    get "/reports/:id/download", ReportController, :download
    get "/reports/:id/answers", BulkExportController, :answers
    get "/reports/:id/history", BulkExportController, :history
    get "/reports/:id/jobs", ReportJobController, :index
    get "/reports/:id/jobs/:job_id/download", ReportJobController, :download
```

Route shadowing is clean (`/reports/:id` is 2 segments, `/reports/:id/answers` is 3; the `match :*` fallback is in a separate scope below).

#### `EXPIRED_CURSOR` → 410 (before/after)

The slice's `next_page/…` `:expired` branch calls `ErrorHelpers.render_error(conn, "EXPIRED_CURSOR", …)`, and `render_error/4` does `put_status(Map.fetch!(@statuses, code))` (`error_helpers.ex:23`) — a `Map.fetch!` that **raises `KeyError` → 500** if the code isn't registered. So this edit MUST land in the slice step (not deferred to build-out), or the slice's own `EXPIRED_CURSOR` test would get a 500 instead of 410. 410 (not 409) so `@codes_by_status`'s reverse map has no collision with `NOT_READY` (409).

```elixir
# server/lib/report_server_web/api/error_helpers.ex (lines 5-11)
# BEFORE
  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "SERVER_ERROR" => 500
  }
# AFTER
  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "EXPIRED_CURSOR" => 410,
    "SERVER_ERROR" => 500
  }
```

(`code_for_status/1` auto-derives from `@codes_by_status`; `EXPIRED_CURSOR` is always explicitly `render_error`'d, never raised as an exception, so the reverse-map path never mis-maps a raised 410.)

#### Tests (slice scenarios, using the stubs)

Copy the STORY-1 controller-test setup (`report_controller_test.exs`), set `:report_service_client` → `ReportServiceStub`, `:learner_data` → `LearnerDataStub`, `:allowed_project_ids_source` → stub. Assert:
- **Ownership/existence**: non-owned / non-Athena / non-existent / malformed / **out-of-bigint-range** `:id` → 404 (indistinguishable). The out-of-range case (e.g. `"99999999999999999999999999"`) specifically guards F-ext-2: it must 404 via `Params.parse_id/1`'s `@max_bigint` check, never reach the Ecto query.
- **Production client default (F-ext-1)**: assert the default `report_service` target exists — `Code.ensure_loaded?(ReportServer.ReportService)` and `function_exported?(ReportServer.ReportService, :bulk_read, 1)` — so a mistyped/unqualified default (`Elixir.ReportService`) can never ship green.
- **Nil-`report_filter` run**: owned run with `report_filter == nil` derives normally (not a 500).
- **Empty export (both paths)**: `[]` permission set → 200 `items: []` `next_page_token: null` without calling `LearnerData.fetch`; non-empty perms but zero learners (`allow_empty`) → same. **Both write one `export_scoped` intent row with `endpoint_set: []`** (and no scratch row); an audit-write failure on the empty path → 500 (fail-closed).
- **Portal permission-query failure (F-ext5-1)**: stub `allowed_project_ids_source` to return `{:error, reason}` → `derive_endpoint_set` returns the error → **controlled `SERVER_ERROR` (500)**, `LearnerData.fetch` is NOT called, no scratch/intent row written. (Guards against the swallow-then-`list_to_in`-on-a-tuple raise.) *Out of scope, pre-existing: if `get_allowed_project_ids` succeeds but the SECOND lookup inside `LearnerData.fetch`/`apply_allowed_project_ids_filter` later fails, that raise-window lives in shared code the normal report path also uses — not introduced or fixed by STORY 3.*
- **`answersSourceKey`-override run**: endpoint's `source` is the override key (via `SourceKey`).
- **`teacher-actions`-type run (F5, Round 3)**: an owned `teacher-actions` run whose filter transitively selects learners (stubbed `LearnerData.fetch`) derives a **non-empty** endpoint set and serves a page — asserts the endpoints work for any Athena-type run, not only answer reports (requirements "Elixir bulk endpoints").
- **Malformed-`runnable_url` learner (F1 Round 3 / F-ext6-1 / AI-2)**: a learner whose `runnable_url` is `nil` (non-binary), a binary that derives no usable `source` (`"foo"` → `nil`, `"https://"` → `""`), **or one that derives a `source` containing "/" (e.g. `?answersSourceKey=a/b`)** is dropped by `to_endpoints/1`'s derived-`source` filter and does NOT 500 — the rest of the endpoint set serves normally, and **no endpoint with a `nil`/`""`/slash `source` is ever persisted** to the scratch/audit set.
- **Source derived → Node (stubbed mechanics, F-ext6-2)**: for a run with a known `runnable_url`, assert the endpoint set the controller sends to Node — captured via `ReportServiceStub` (which records the `req.source_endpoints`) — carries the `SourceKey.from_runnable_url`-derived `source`. This is the *hermetic* half: it proves the derived `source` reaches the walker. It does **NOT** prove that `source` matches where real answers live — that requires live Firestore/portal data and is an **env-gated live check in the deploy checklist** (below), NOT a stubbed controller test. (Splitting these avoids a false coverage claim: green stubbed CI must not read as "real-data source fidelity verified.")
- **One learner → one page → cursor → resume**: stub returns a page with a non-null cursor; assert `next_page_token` decodes to `{scratch_id, index, inner_cursor}`; replay it → `fetch_for_page` serves the same page (idempotent); terminal page (`endpoint_exhausted` on last endpoint) → `next_page_token: null`, and replaying the terminal token re-serves it (scratch retained).
- **EXPIRED_CURSOR**: expire the scratch row → 410, and the body carries `error: "EXPIRED_CURSOR"` (this step registers the code in `@statuses`, so `render_error/4`'s `Map.fetch!` resolves 410 rather than raising — F-ext2-1).
- **Cross-route replay**: a `/history`-minted token (once `/history` exists) replayed on `/answers` → 404 via the `data_type` guard, including the `null`-inner-cursor case.
- **Node read failure**: stub returns `{:error, _}` → 500, no cursor advance, retry succeeds.
- **Mid-export token revocation → 401 (pipeline regression guard)**: obtain a valid page-1 token, revoke the caller's API token (`Accounts.revoke_api_token(api_token, revoked_by_user_id)`, `accounts.ex:107`, or clear the local `portal_is_*` flags), then request the next page → **401** from `AuthPlug`, export halts. Asserts the bulk routes inherit STORY 1's per-request `:api_authenticated` check (no STORY-3 code — this is a regression guard that the routes are correctly scoped, and that a revoked token is rejected *before* any page is served). A **pure Portal-side role change** (local `users` row unchanged) is **not** reflected — assert the live check is token-revocation + local-flag, not a Portal round-trip.
- **`Cache-Control: no-store`** present on both success and (where applicable) served responses.

---

### Bulk controller build-out — `/history`, audit rows (intent + per-page, fail-closed), error codes

**Summary**: Completes the data plane: the `/history` action, the per-page fail-closed access audit row (written **before** returning data), and the audit `endpoint_set` = actually-served endpoints. `/history` reuses the entire `serve/4` path — only the action wiring and the audit write are new. (The `EXPIRED_CURSOR` → 410 error code was moved into the vertical-slice step — the slice's `:expired` path already needs it — see F-ext2-1.)

**Files affected**:
- `server/lib/report_server_web/api/v1/bulk_export_controller.ex` — edit (real `history/2`; add the access-row write in `serve_page/…`)
- `server/test/report_server_web/api/v1/bulk_export_controller_test.exs` — extend (history + audit scenarios)

**Estimated diff size**: ~80 lines.

#### `history/2` + per-page audit (before/after)

```elixir
# bulk_export_controller.ex
# BEFORE
  def history(conn, _params), do: ErrorHelpers.not_found(conn)
# AFTER
  def history(conn, params), do: serve(conn, params, "history_bulk", "history")
```

Insert the fail-closed access-row write into `serve_page/…`, replacing the placeholder `json(conn, ...)` success branch:

```elixir
# BEFORE (success branch of serve_page)
        # NOTE: per-page audit access row is added in the next step (fail-closed, before returning)
        json(conn, %{items: items, next_page_token: next_token})
# AFTER
        served = items |> Enum.map(& &1["remote_endpoint"]) |> Enum.uniq()

        access_attrs =
          audit_attrs(user, report_run, "bulk_read", data_type, scratch.scratch_id, raw_token, served)

        case AuditLog.create_entry(access_attrs) do
          {:ok, _entry} -> json(conn, %{items: items, next_page_token: next_token})
          {:error, _reason} -> ErrorHelpers.server_error(conn)   # fail-closed: no data if audit write fails
        end
```

This requires threading `user`, `report_run`, `data_type`, and `raw_token` into `serve_page/…` (they were placeholders `_user`/`_report_run`/`_data_type`/`_raw_token` in the slice step — un-underscore them now). `served` = actually-served endpoints (truthful "what left the server"; `[]` for an empty-mid-export page). The intent row (page 1) is already written atomically with the scratch.

#### Tests (extend)

- **History mechanic**: learner with answers+history → items carry `history_id`, ISO `created_at`, `answer_id`/`question_id`; double-encoded `report_state` untouched.
- **Learner with answers but no history** → `/history` empty for them, coverage "none".
- **Out-of-range history cursor `seconds` → 400, not 500 (F-ext7-1)**: a `/history` `page_token` whose decoded inner cursor has `seconds` = `253_402_300_800` (too high) or `-62_135_596_801` (too low) → `BAD_REQUEST` from `BulkParams.validate_inner_cursor/2` (never forwarded to Node); the in-range boundary values pass. Guards the "a bad cursor must never throw a 500" contract for a tampered token.
- **Non-plain cursor `docId` → 400, not 500 (AI-1)**: a tampered `page_token` (either `/answers` or `/history`) with inner-cursor `docId: "a/b"` (slash) or `docId: ""` (empty) → `BAD_REQUEST` from `validate_inner_cursor/2` before Node; a plain id passes. Guards the synchronous `startAfter(...)` throw.
- **Empty mid-export page** → `items: []` + non-null token (endpoint cap), then continues.
- **Audit rows**: page 1 writes one `export_scoped` intent row (full endpoint set) + one `bulk_read` access row (served set); subsequent pages write only `bulk_read`; `export_id` = scratch_id on all; a retried page is distinguishable via `(user, report_run, data_type, export_id, cursor)`; audit-write failure → 500 with no data.
- (`EXPIRED_CURSOR` → 410 is covered by the vertical-slice step's test — the code now lands there.)

---

### Attachment download endpoint — batch presign (`POST /api/v1/reports/:id/attachments`) + Node metadata helper

**Summary**: Hands the client short-lived **presigned GET URLs** for the S3 attachments referenced (but not
resolved) by `report_state`/`interactive_state` — `__attachment__` (CODAP/SageModeler whole-state offload) and
`audioFile` (open-response audio). Batch (≤500/call). Auth is **durable via `report_run_id`** (re-derives the
`endpoint_set` fresh — survives the scratch's 1-hour TTL, reflects current permissions), **NOT** the
`page_token`. Firestore lives in Node, so a small Node helper returns the **authoritative** per-doc attachment
metadata; Elixir authorizes (`owner ∈ endpoint_set`) and presigns with report-service's **own** server creds (no
token-service brokering — the `report-server-*` IAM already grants `s3:GetObject` on
`<private-bucket>/interactive-attachments/*`). End-to-end validated on staging (2.9 MB CODAP fetch, 2026-07-15).

**Files affected**:
- `functions/src/api/attachment-meta.ts` — new (Node helper: authoritative `{publicPath, remote_endpoint, contentType}` per requested doc+name)
- `functions/src/index.ts` — edit. Register behind the **header-only** bearer guard, shown as literal code (do NOT rely on prose — an implementer omitting the guard would leave the route reachable via a query-string bearer, re-opening the access-log token leak, since the global `bearerTokenAuth` also accepts `?bearer=`; self-review R2-J): `api.post("/fetch_attachment_meta", requireHeaderBearer, fetchAttachmentMeta)` (+ `import fetchAttachmentMeta from "./api/attachment-meta"`).
- `server/lib/report_server/report_service.ex` — edit (add `fetch_attachment_meta/1` seam, mirrors `bulk_read/1`)
- `server/lib/report_server_web/aws.ex` — edit (add `presign_server_get/2` — **server-cred** presign with `attachment`/`inline` disposition + content-type options + `safe_filename/1`; NOT the workgroup-cred `get_presigned_url/3`)
- `server/lib/report_server_web/api/v1/endpoint_set.ex` — **NEW (self-review R2-B).** Extract `derive_endpoint_set/2` + `to_endpoints/1` + `derive_source/1` + the test-seam accessors (`learner_data/0`, `allowed_project_ids_source/0`) out of `BulkExportController` (where the vertical-slice step put them as `defp`) into this shared **public** module. Both `BulkExportController` and `AttachmentController` call `EndpointSet.derive_endpoint_set(user, report_run)` — a `defp` in one controller cannot be called from the other, so the shared module is required (not optional). Update the vertical-slice step's controller to delegate to it.
- `server/lib/report_server_web/api/v1/bulk_params.ex` — edit (add `parse_attachment_items/1` and `parse_disposition/1`, both following the **existing `BulkParams` 3-tuple convention** `{:ok, value}` | `{:error, :bad_request, msg}` — NOT a 2-tuple; a 2-tuple would miss the controller `else` clause and 500 instead of 400; self-review R2-C/D). `parse_attachment_items/1`: array, `≤500`, each item a map with non-empty string `source`/`doc_id`/`name` and **`collection ∈ {"answers","history"}` validated here** (bad collection → clean 400 at the param layer, no Node round-trip — R3-C); `[]`/`0` → `{:error, :bad_request, _}`. `parse_disposition/1`: **`parse_disposition(nil) → {:ok, "attachment"}`** (absent key defaults; JSON `null` also arrives as `nil` → defaults), `"attachment"`/`"inline"` → `{:ok, value}`, anything else → `{:error, :bad_request, _}`.
- `server/lib/report_server_web/api/v1/attachment_controller.ex` — new (the batch endpoint; aliases `Params`, `Reports`, `EndpointSet`, `Aws`, `TokenService`, `AuditLog`, `ErrorHelpers`)
- `server/lib/report_server_web/api/v1/attachment_json.ex` — new (results envelope + `expires_in_seconds`)
- `server/lib/report_server_web/router.ex` — edit (`post "/reports/:id/attachments"` in the same bearer-scoped pipeline as `/reports/:id/answers`)
- `server/lib/report_server/audit_log.ex` / `data_access_log_entry.ex` — edit (`attachment_urls_issued` event + `"attachment"` data_type in the allow-lists)
- tests: `attachment_controller_test.exs` (stubbed, async: false), `attachment-meta.emulator.test.ts`

**Estimated diff size**: ~360 lines.

#### Node metadata helper (`fetch_attachment_meta`)

Authorization-blind like `/bulk_read`; returns only what Elixir needs to authorize + presign. `getAll`-batched.
Never returns bytes. A missing doc / missing attachment name yields a per-item `null` (Elixir maps to `not_found`).

```ts
// functions/src/api/attachment-meta.ts
import { Request, Response } from "express";
import admin from "firebase-admin";
import { getDoc } from "./helpers/paths";

interface MetaReq { items: { collection: "answers" | "history"; source: string; doc_id: string; name: string }[]; }

const subFor = (c: string) => (c === "history" ? "interactive_state_history_states" : "answers");

export default async function fetchAttachmentMeta(req: Request, res: Response) {
  try {
    const { items } = req.body as MetaReq;
    if (!Array.isArray(items)) return res.error(400, "items must be an array");
    if (items.length > 500) return res.error(400, "too many items");     // matches Elixir cap; defense in depth
    // validate each coordinate is a plain, non-empty string; reject "/" in source/doc_id (path-arity guard, AI-2)
    for (const it of items) {
      for (const k of ["collection", "source", "doc_id", "name"] as const) {
        if (typeof it?.[k] !== "string" || it[k].length === 0) return res.error(400, `item.${k} must be a non-empty string`);
      }
      if (it.source.includes("/") || it.doc_id.includes("/")) return res.error(400, "source/doc_id must not contain '/'");
      if (it.collection !== "answers" && it.collection !== "history") return res.error(400, "bad collection");
    }
    const GETALL_CHUNK = 300;   // match bulk-read's chunkedGetAll — getAll/batchGet has a per-call ceiling (self-review #5)
    const refs = items.map((it) => getDoc(`/sources/${it.source}/${subFor(it.collection)}/${it.doc_id}`));
    const snaps: FirebaseFirestore.DocumentSnapshot[] = [];
    for (let i = 0; i < refs.length; i += GETALL_CHUNK) {
      snaps.push(...(await admin.firestore().getAll(...refs.slice(i, i + GETALL_CHUNK))));
    }
    const results = items.map((it, i) => {
      const snap = snaps[i];
      if (!snap?.exists) return { doc_id: it.doc_id, name: it.name, meta: null };
      const d = snap.data() as any;
      const att = d.attachments?.[it.name];
      if (!att?.publicPath) return { doc_id: it.doc_id, name: it.name, meta: null };
      return {
        doc_id: it.doc_id, name: it.name,
        // authz key = the DOC's learner (`remote_endpoint`); NOT `folder.ownerId` — run-with-others legitimately
        // makes them differ and ownerId is a less-reliable field (self-review #4). contentType is returned for
        // the `inline` disposition (response-content-type). A doc with no remote_endpoint is out of scope → deny.
        meta: { publicPath: att.publicPath, contentType: att.contentType ?? null,
                remote_endpoint: d.remote_endpoint ?? null },
      };
    });
    return res.success({ results });
  } catch (e: any) {
    return res.error(500, "fetch_attachment_meta failed");
  }
}
```

`index.ts`: register `POST /fetch_attachment_meta` behind the same `requireHeaderBearer` guard as `/bulk_read`
(it reads Firestore; not internet-exposable unguarded). No timeout bump needed — bounded ≤500 `getAll`.

#### Elixir seam (`ReportService.fetch_attachment_meta/1`)

Mirrors `bulk_read/1` (POST + JSON body, same `report_service_client` accessor + stub). Returns
`{:ok, %{"results" => [...]}} | {:error, reason}`.

#### Controller (`AttachmentController`)

```elixir
# server/lib/report_server_web/api/v1/attachment_controller.ex (shape)
def create(conn, params) do
  user = conn.assigns.current_user
  with {:ok, report_run_id} <- Params.parse_id(params["id"]),                           # STORY 1 parser (max-bigint guard) — NOT a bulk-local one (self-review #2)
       {:ok, disposition} <- BulkParams.parse_disposition(params["disposition"]),       # {:ok, "attachment"|"inline"} | {:error, :bad_request, msg}
       {:ok, items} <- BulkParams.parse_attachment_items(params["attachments"]),        # ≤500; validates collection/source/doc_id/name -> {:error, :bad_request, msg}
       {:ok, report_run} <- Reports.get_api_report_run(user, report_run_id),            # DURABLE ownership -> {:error, :not_found} on not-owned/missing
       {:ok, endpoint_set} <- EndpointSet.derive_endpoint_set(user, report_run),        # SHARED module (extracted from BulkExportController — self-review R2-B)
       {:ok, %{"results" => metas}} <- report_service_client().fetch_attachment_meta(%{items: items}),
       :ok <- validate_meta_count(metas, items) do                                       # Node must return one result per item (self-review R2-H)
    allowed = MapSet.new(endpoint_set, & &1["remote_endpoint"])
    signed = Enum.zip(items, metas) |> Enum.map(&sign_one(&1, allowed, disposition))    # -> [{result_map, signed_endpoint | nil}] (R3-A)
    results = Enum.map(signed, &elem(&1, 0))
    endpoints = signed |> Enum.flat_map(fn {_r, re} -> List.wrap(re) end) |> Enum.uniq() # distinct learners ACTUALLY signed → the audit endpoint_set
    # fail-CLOSED: the audit result GATES the response. `cache-control: no-store` (mirrors the bulk endpoints'
    # put_no_store) so no proxy/cache retains the response body of 10-min credential-free URLs. (self-review R2-E)
    case AuditLog.log_attachment_urls(user, report_run, endpoints) do
      {:ok, _} ->
        conn |> put_resp_header("cache-control", "no-store") |> json(AttachmentJSON.results(results, Aws.presign_ttl_seconds()))
      {:error, _} ->
        ErrorHelpers.server_error(conn)
    end
  else
    {:error, :bad_request, msg} -> ErrorHelpers.bad_request(conn, msg)                  # param errors (3-tuple, BulkParams convention) -> 400 (self-review R2-C/D)
    {:error, :not_found} -> ErrorHelpers.not_found(conn)                                # not-owned / missing run -> 404 (self-review R2-A)
    {:error, _} -> ErrorHelpers.server_error(conn)                                      # Node/derivation/seam failures -> 500 (NOT 400) (self-review R2-A/C)
  end
end

# Node returns exactly one result per requested item, positionally. A length mismatch is a Node-contract
# violation, not a client error -> {:error, _} -> 500 (never silently Enum.zip-truncate). (self-review R2-H)
defp validate_meta_count(metas, items) when length(metas) == length(items), do: :ok
defp validate_meta_count(_metas, _items), do: {:error, :meta_count_mismatch}

# per-item, partial-success: never let one bad item fail the batch.
# Returns {public_result_map, signed_endpoint | nil} — the endpoint is threaded out (only when a URL was actually
# signed) so the audit can record the distinct learners without the result map having to expose remote_endpoint. (R3-A)
defp sign_one({item, %{"meta" => nil}}, _allowed, _disp),
  do: {%{doc_id: item["doc_id"], name: item["name"], error: "not_found"}, nil}
defp sign_one({item, %{"meta" => %{"remote_endpoint" => re, "publicPath" => key, "contentType" => ct}}}, allowed, disposition) do
  # authorize on the DOC's learner (re); re == nil (out-of-scope/anonymous) -> not_authorized. NOT folder.ownerId.
  if re != nil and MapSet.member?(allowed, re) do
    s3_url = "s3://#{TokenService.get_private_bucket()}/#{key}"                            # same s3:// shape transcribe_audio.ex builds
    case Aws.presign_server_get(s3_url, name: item["name"], disposition: disposition, content_type: ct) do
      {:ok, url} -> {%{doc_id: item["doc_id"], name: item["name"], url: url}, re}          # signed → record its endpoint for audit
      {:error, _} -> {%{doc_id: item["doc_id"], name: item["name"], error: "not_found"}, nil}
    end
  else
    {%{doc_id: item["doc_id"], name: item["name"], error: "not_authorized"}, nil}          # IDOR guard: learner not in set (or absent)
  end
end
```

- **`Aws.presign_server_get/2`** (NEW, `aws.ex`) presigns a private-bucket GET with **server creds**, mirroring
  how `transcribe_audio.ex` reaches the private bucket (build `s3://#{TokenService.get_private_bucket()}/#{publicPath}`,
  access with `get_server_credentials/0`) and how STORY 1's `AthenaDB.get_download_url/2` signs (also
  `:aws_credentials`). **Do NOT reuse `Aws.get_presigned_url/3`** — that helper signs with **workgroup**
  (per-user Athena) creds, the wrong trust boundary, and those creds can't read the attachments bucket
  (self-review #3). Shape:
  ```elixir
  # aws.ex
  @presign_ttl_seconds 60 * 10                                  # 600s; presign lifetime lives WITH the presign helper
  def presign_ttl_seconds, do: @presign_ttl_seconds             # the controller reads this for expires_in_seconds (one source)

  def presign_server_get(s3_url, opts) do
    {bucket, key} = get_bucket_and_path(s3_url)                 # reuse existing s3://host/key parser
    client = get_exaws_client(get_server_credentials())          # SERVER creds (:aws_credentials), NOT workgroup
    :s3
    |> ExAws.Config.new(client)
    |> ExAws.S3.presigned_url(:get, bucket, key,
         expires_in: @presign_ttl_seconds,                       # single source of truth (self-review #6, R1/R2)
         query_params: disposition_params(opts))
  end
  # "attachment" (default) forces download; "inline" renders/plays in a browser (the opt-in --inline path)
  defp disposition_params(opts) do
    case Keyword.get(opts, :disposition, "attachment") do
      "inline" -> [{"response-content-disposition", "inline"},
                   {"response-content-type", Keyword.get(opts, :content_type) || "application/octet-stream"}]
      _        -> [{"response-content-disposition", ~s(attachment; filename="#{safe_filename(Keyword.fetch!(opts, :name))}")}]
    end
  end
  # `name` is a real key in the doc's attachments map (LARA-generated, e.g. "file.json"/"audio<ts>.mp3", so
  # writer-constrained — NOT arbitrary client input), but the value still flows into a Content-Disposition, so
  # defense-in-depth: strip CR/LF/quotes/backslashes and control chars, then RFC-6266-quote it. (self-review R2-F)
  defp safe_filename(name) do
    name |> String.replace(~r/[\x00-\x1f"\\]/u, "") |> String.slice(0, 255)
  end
  ```
  (`get_bucket_and_path/1` and `get_exaws_client/1` are already private in `aws.ex`; this helper lives in the
  same module, so no visibility change is needed.)
- **`EndpointSet.derive_endpoint_set(user, report_run)`** is the exact page-1 derivation, now in a **shared
  module** (`ReportServerWeb.Api.V1.EndpointSet`) extracted from `BulkExportController` — a `defp` in one
  controller can't be called from another, so the extraction is required (self-review R2-B). Arg order is
  **`(user, report_run)`** (self-review #1). Attachments reuse it, so a user who lost access since the export is
  denied. No scratch is read or written. It returns `{:ok, [%{"remote_endpoint" => …, "source" => …}, …]}` |
  `{:ok, []}` | `{:error, reason}` — a derivation `{:error, _}` maps to **500** in the controller (never 400).
- **Never trust a client `publicPath`.** The request carries only `{collection, source, doc_id, name}`; the key
  comes solely from the Node re-read's authoritative `meta.publicPath`, and authorization is the `∈ endpoint_set`
  check on the re-read **`remote_endpoint`** (the doc's learner). This is the IDOR guard — the server creds can
  read the whole `interactive-attachments/*` prefix, so the endpoint_set check is the *only* thing gating which
  learner's files a researcher can sign. (Not gated on `folder.ownerId`; see self-review #4 — run-with-others.)

#### Audit (`log_attachment_urls/3`) — one row per call, fail-closed

`log_attachment_urls(user, report_run, endpoints)` builds attrs and calls the existing
`AuditLog.create_entry/1`, **returning its `{:ok, _} | {:error, _}`** so the controller can gate the response on
it (fail-closed — see the `case` above; a failed write → 500, no URLs returned). The `endpoints` are the distinct
`remote_endpoints` **actually signed** (threaded out of `sign_one`, since the public `results` maps intentionally
omit `remote_endpoint` — R3-A). Row: `event: "attachment_urls_issued"`, `data_type: "attachment"`, `source: "api"`,
`endpoint_set: endpoints`, `cursor: nil`, `export_id: nil` (the `report_run_id` FK correlates it). No per-item
count is persisted (no such column, and `endpoint_set` already answers "which learners"; R4).

**Changeset edit (shown, not just described — R3-B).** This step further widens the two `validate_inclusion`
lists the persistence step set, additively:
```elixir
# data_access_log_entry.ex — this step's delta on top of the persistence step's lists
|> validate_inclusion(:event, ["download_url_issued", "export_scoped", "bulk_read", "attachment_urls_issued"])
|> validate_inclusion(:data_type, ["run_csv", "job_result", "answers_bulk", "history_bulk", "export_scoped", "attachment"])
```
`endpoint_set` is already `EctoJsonArray` (list) after the persistence step, so a list-of-strings round-trips; the
existing negative changeset test (`"nope"` rejected) still holds under the widened lists.

#### Tests

- `attachment_controller_test.exs` (stubbed `report_service_client` + `learner_data`, `async: false`): happy path
  → per-item `url`s for authorized learners; **`not_authorized`** for a `remote_endpoint` outside the derived
  `endpoint_set` **and for a `nil` `remote_endpoint`** (out-of-scope/anonymous); **`not_found`** for a `null`
  meta (missing doc or missing name); **partial success** (one bad + one good in the same batch); cap → 400 at
  `>500`; empty/`0` → 400; `report_run` not owned → 404; **bad `disposition`** (not `attachment`/`inline`) → 400;
  **default disposition** presigns with `response-content-disposition: attachment; filename=`, **`disposition:"inline"`**
  presigns with `inline` + `response-content-type` from the meta `contentType` (assert on the generated
  `query_params`); **run-with-others** — a `remote_endpoint` in the set whose `folder.ownerId` *differs* still
  signs (NOT rejected — self-review #4); audit writes **exactly one** row with the distinct authorized endpoints,
  and an audit-write failure → 500 with no URLs leaked; the presigned key equals the Node-supplied `publicPath`
  and a client-supplied `publicPath` is ignored. **Added from the external review (Round 5):**
  **exactly `500` → 200 and `501` → 400** (inclusive-boundary, not just `>500`); **non-string `disposition`**
  (`5`, `["inline"]`) → 400 not 500 (guards the 3-tuple param convention); **`attachments` not an array / omitted /
  item missing a key / empty-string or non-string coordinate** → 400; **`collection:"history"` happy path** (asserts
  the Node call used the `interactive_state_history_states` sub-collection, not `answers`); **`source`/`doc_id` with
  `"/"`** → 400 at the Elixir param layer (not forwarded to Node); **Node meta-count mismatch** (stub returns fewer
  metas than items) → **500** via `validate_meta_count`, never a silently-truncated `results`; **`inline` with
  `contentType: nil`** → `response-content-type: application/octet-stream`; **`name` with a quote/CR-LF/control
  char** → the generated `Content-Disposition` is `safe_filename`-sanitized+quoted (assert the header value);
  **response carries `cache-control: no-store`**; **Node/derivation `{:error, _}` (a `fetch_attachment_meta`
  server error, or a `derive_endpoint_set` failure) → 500, NOT 400**; **duplicate identical items** → both get a
  `url` and the audit endpoint_set lists the learner **once**; **three-way mixed batch** (authorized→url,
  out-of-set→not_authorized, null-meta→not_found) coexist in one 200 with the audit endpoint_set holding only the
  one authorized learner. Plus a spy/mock assertion that `presign_server_get` uses `get_server_credentials/0`
  (NOT the workgroup-cred path) — the only automated guard on the trust-boundary choice.
- `attachment-meta.emulator.test.ts`: seed an answer + a history state doc each with an `attachments` map; helper
  returns authoritative `{publicPath, remote_endpoint, contentType}`; missing name → `meta: null`; a present doc
  whose `attachments[name]` lacks `publicPath` → `meta: null`; `"/"` in `source`/`doc_id` → 400; `>500` items → 400;
  **a query-string/body bearer (no header) on `/fetch_attachment_meta` → 401** (mirrors `require-header-bearer.test.ts`).
- **Not** unit-testable: the real S3 presign→GET (needs live creds + the private bucket) — covered by the
  throwaway staging validation (`functions/validate-attachment.js`, 2.9 MB CODAP fetch); note that in a comment.

---

### Scratch sweep GenServer + supervision wiring

**Summary**: Reclaims abandoned + completed scratch rows (the terminal page is retained for idempotency, so the sweep is the only reclaim for completed exports). Mirrors `StatsServer`: **no DB work in `init/1`** — the boot sweep runs from `handle_continue` so a slow DB at boot can't restart-loop the supervisor.

**Files affected**:
- `server/lib/report_server/exports/sweep_server.ex` — new
- `server/lib/report_server/application.ex` — edit (add child)
- `server/config/runtime.exs` — edit (add `:exports_sweep` `disable:` config, defaulting **disabled in `:test`** — see F-ext4-1)
- `server/test/report_server/exports/sweep_server_test.exs` — new

**Estimated diff size**: ~95 lines.

**Test-sandbox safety (F-ext4-1) — the boot/interval sweep must NOT run under the `:manual` SQL sandbox.**
Unlike `StatsServer` (which it otherwise mirrors), this server's `sweep_expired/0` hits the **local**
`ReportServer.Repo` (`Repo.delete_all`). The sandbox runs in `:manual` mode (`test_helper.exs:2`), so a
supervised process started at app boot owns no connection — a boot or interval sweep would raise
`DBConnection.OwnershipError` and restart-loop the supervisor during `mix test`. (`StatsServer` avoids this
only because it queries `PortalDbs`, not the sandboxed Repo — so it is NOT a precedent for touching the Repo
at boot.) Fix: mirror `StatsServer`'s `disabled?/0` gate (config-driven, **disabled in `:test`**); the
supervised instance then does no DB work in tests, and the sweep tests exercise `Exports.sweep_expired/0`
directly (after the `DataCase` checkout) or start a server instance explicitly and `Sandbox.allow` it.

```elixir
# server/lib/report_server/exports/sweep_server.ex
defmodule ReportServer.Exports.SweepServer do
  @moduledoc """
  Periodic (+ boot) storage-reclaim sweep for export_scratch. Correctness never depends on the interval —
  expired rows are already invisible via the two-step read-time lookup — so this is a reclaim cadence only.
  Mirrors StatsServer: no DB work in init/1; the boot sweep runs from handle_continue, and a `disabled?/0`
  gate keeps it inert under the :test SQL sandbox (it hits the LOCAL Repo, so it must be gated — F-ext4-1).
  """
  use GenServer

  require Logger
  alias ReportServer.Exports

  @sweep_interval 15 * 60 * 1000  # 15 minutes

  # `:name` is injectable so an isolated test can start a SECOND instance under a different name — the
  # supervised singleton owns __MODULE__, so a test can't reuse that name ({:already_started, pid}). (F-ext7-4)
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))

  # config-driven gate (mirrors StatsServer.disabled?/0). Disabled in :test so the supervised instance never
  # touches the :manual SQL sandbox at boot/interval; sweep tests drive Exports.sweep_expired/0 directly.
  def disabled?, do: Keyword.get(Application.get_env(:report_server, :exports_sweep, []), :disable, false)

  @impl true
  def init(state) do
    if disabled?() do
      # start thin and inert — no boot sweep, no interval scheduling (no DB work under the sandbox)
      {:ok, state}
    else
      # return immediately; do the (potentially slow) boot sweep in handle_continue, never on the supervisor start path
      {:ok, state, {:continue, :boot_sweep}}
    end
  end

  @impl true
  def handle_continue(:boot_sweep, state) do
    {:noreply, sweep_and_schedule(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    {:noreply, sweep_and_schedule(state)}
  end

  defp sweep_and_schedule(state) do
    count = Exports.sweep_expired()
    if count > 0, do: Logger.info("Exports.SweepServer reclaimed #{count} expired scratch row(s)")
    Process.send_after(self(), :sweep, @sweep_interval)
    state
  end
end
```

```elixir
# server/lib/report_server/application.ex (children list, line 21)
# BEFORE
        {ReportServer.Dashboard.StatsServer, get_dashboard_servers()},
# AFTER
        {ReportServer.Dashboard.StatsServer, get_dashboard_servers()},
        ReportServer.Exports.SweepServer,   # inert in :test via disabled?/0 (F-ext4-1)
```

```elixir
# server/config/runtime.exs — add alongside the existing :stats_server config (line ~58).
# Disabled in :test so the supervised sweeper does no Repo work under the :manual SQL sandbox; overridable
# by env var elsewhere (mirrors DISABLE_STATS_SERVER).
config :report_server, :exports_sweep,
  disable: System.get_env("DISABLE_EXPORTS_SWEEP") == "true" || config_env() == :test
```

Test: because the supervised instance is `disabled?` in `:test`, it does no boot/interval DB work (no sandbox-ownership crash). The sweep tests seed an expired + an active row **after the `DataCase` sandbox checkout** and call `Exports.sweep_expired/0` directly — this is the primary and sufficient coverage (the GenServer is thin). **A test must NOT try to start another `SweepServer` under the default name — the supervised singleton already owns `__MODULE__`, so `start_link([])` would return `{:error, {:already_started, pid}}`** (F-ext7-4). If a test really wants to exercise the running GenServer, it starts an instance under a DIFFERENT name via the injectable opt (`start_link(name: :sweep_test)`), `Ecto.Adapters.SQL.Sandbox.allow/3`s that pid onto the test's connection, and drives it with a manual `send(pid, :sweep)` (avoiding the boot-sweep/allow race).

---

### Admin audit-log page — `export_id` + `remote_endpoint` filters, query + LiveView + accessibility

**Summary**: Populate-and-query lands together. Extends the STORY-1 audit LiveView (`AuditLogLive.Index`) with two URL-param-driven filters, a case-sensitive `JSON_CONTAINS` search bound as an Ecto `fragment` param, and the full a11y treatment (aria-live result summary, filter-aware empty state, focus move, real labeled form, table caption + `scope="col"`).

**Files affected**:
- `server/lib/report_server/audit_log.ex` — edit (`list_entries_paginated/2` with optional filters)
- `server/lib/report_server_web/live/audit_log_live/index.ex` — edit (read filter params, assign summary/active-filter + a filter-derived refocus token)
- `server/lib/report_server_web/live/audit_log_live/index.html.heex` — edit (form, aria-live, empty-state branch, caption, `scope`, `data-refocus` on the results container)
- `server/assets/js/app.ts` — edit (register the `FocusResults` phx-hook in the existing `Hooks` object, alongside `CopyToClipboard` at `app.ts:32`)
- `server/test/report_server/audit_log_test.exs` — extend (filter query)
- `server/test/report_server_web/live/audit_log_live/index_test.exs` — extend/new (filter + a11y markup)

**Estimated diff size**: ~160 lines.

#### Query (`list_entries_paginated/2`, before/after)

```elixir
# server/lib/report_server/audit_log.ex (lines 51-54)
# BEFORE
  def list_entries_paginated(page) do
    from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at, desc: e.id], preload: [:user])
    |> Pagination.paginate(page)
  end
# AFTER
  def list_entries_paginated(page, filters \\ %{}) do
    from(e in DataAccessLogEntry, order_by: [desc: e.inserted_at, desc: e.id], preload: [:user])
    |> filter_by_export_id(filters[:export_id])
    |> filter_by_remote_endpoint(filters[:remote_endpoint])
    |> Pagination.paginate(page)
  end

  defp filter_by_export_id(query, nil), do: query
  defp filter_by_export_id(query, ""), do: query
  defp filter_by_export_id(query, export_id), do: from(e in query, where: e.export_id == ^export_id)

  defp filter_by_remote_endpoint(query, nil), do: query
  defp filter_by_remote_endpoint(query, ""), do: query
  defp filter_by_remote_endpoint(query, remote_endpoint) do
    # pathless JSON_CONTAINS over the top-level array; BOUND param (never interpolated).
    # Intentionally case-sensitive (JSON binary comparison, independent of the utf8mb4_0900_ai_ci column
    # collation) — required for exact secure_key matching. A NULL endpoint_set (STORY 1 rows) is unmatched.
    from(e in query, where: fragment("JSON_CONTAINS(endpoint_set, JSON_QUOTE(?))", ^remote_endpoint))
  end
```

#### LiveView (`index.ex`, before/after)

```elixir
# handle_params — read filters from URL, assign entries + summary + active-filter flag; push focus to results
# BEFORE (lines 21-30)
  def handle_params(params, _url, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    result = AuditLog.list_entries_paginated(Pagination.normalize_page(params["page"]))

    socket = socket
      |> assign(:entries, result.items)
      |> assign(:page, result.page)
      |> assign(:total_pages, result.total_pages)

    {:noreply, socket}
  end
# AFTER
  def handle_params(params, _url, %{assigns: %{user: %{portal_is_admin: true}}} = socket) do
    filters = %{
      export_id: params["export_id"] || "",
      remote_endpoint: params["remote_endpoint"] || ""
    }

    result = AuditLog.list_entries_paginated(Pagination.normalize_page(params["page"]), filters)
    filtered? = filters.export_id != "" or filters.remote_endpoint != ""

    socket =
      socket
      |> assign(:entries, result.items)
      |> assign(:page, result.page)
      |> assign(:total_pages, result.total_pages)
      |> assign(:total_count, result.total_count)
      |> assign(:filters, filters)
      |> assign(:filtered?, filtered?)

    # NO unconditional focus push here: handle_params fires on BOTH filter submit AND paging (both are
    # push_patch), and focusing the results on every params change would steal focus from the activated
    # pager control on page navigation (requirements: pager keeps focus on the activated control). Focus is
    # instead driven by the template's `data-refocus` token, which is derived from the filter values only —
    # so it changes on a filter change but NOT on paging (which preserves the filters). (F-ext-4)
    {:noreply, socket}
  end

  # filter submit -> push_patch to the filtered URL (composes with ?page=N)
  @impl true
  def handle_event("filter", %{"export_id" => export_id, "remote_endpoint" => remote_endpoint}, socket) do
    {:noreply, push_patch(socket, to: filter_path(export_id, remote_endpoint))}
  end

  # results-container refocus token: changes iff the FILTER values change (paging preserves them), so the
  # FocusResults hook's updated() moves focus only after a filter submit, never on plain pagination. (F-ext-4)
  defp refocus_token(%{export_id: e, remote_endpoint: r}), do: "#{e}|#{r}"

  # Human-readable active-filter suffix appended to the aria-live summary and the table caption (F-ext4-2).
  # Empty string when no filter is active, so the base text renders unchanged.
  defp filter_suffix(%{export_id: e, remote_endpoint: r}) do
    parts =
      [{"export id", e}, {"student", r}]
      |> Enum.filter(fn {_label, v} -> v not in [nil, ""] end)
      |> Enum.map(fn {label, v} -> "#{label} \"#{v}\"" end)

    if parts == [], do: "", else: " (filtered by " <> Enum.join(parts, " and ") <> ")"
  end

  defp filter_path(export_id, remote_endpoint) do
    query = %{"export_id" => export_id, "remote_endpoint" => remote_endpoint}
            |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    if query == [], do: ~p"/reports/audit-log", else: ~p"/reports/audit-log?#{query}"
  end
```

Also update `audit_log_path/1` to preserve active filters when paging (thread `@filters` into the pager `path_fun`).

**Focus mechanism (F-ext-4, pinned).** The focus move is a `FocusResults` `phx-hook` registered in the app's existing `Hooks` object (`server/assets/js/app.ts:32`, alongside `CopyToClipboard`) — it is **not** a `push_event`/`handle_event("focus-results", …)` and **not** an unconditional focus on every `handle_params`. Reason: `handle_params` re-renders via `push_patch` for BOTH filter submit and paging, and a blanket focus-on-params would steal focus from the activated pager control on page navigation (requirements 605-607: the pager keeps focus on the activated control). The hook's `updated()` compares the container's `data-refocus` dataset value — derived from the filter values via `refocus_token/1` — against the previous one and focuses only when it changed, which happens on a filter change but not on paging (paging preserves the filters, so the token is unchanged). The `aria-live="polite"` region still announces the result count on every params change, so an SR user hears paging updates even without a focus move.

```ts
// server/assets/js/app.ts — add to the existing `const Hooks = { CopyToClipboard: {...}, ... }` object:
FocusResults: {
  mounted() { this._refocus = this.el.dataset.refocus },
  updated() {
    if (this.el.dataset.refocus !== this._refocus) {
      this._refocus = this.el.dataset.refocus
      this.el.focus()   // container is tabindex="-1", so it is programmatically focusable
    }
  }
},
```

#### Template (`index.html.heex`) — form, aria-live, empty-state branch, caption, scope

Key additions (full markup written in the commit):
- A real labeled `<form phx-submit="filter">`. **Use the `<.input>` component's built-in label, not a separate `<.label>`** — the core_components `<.input>` catch-all (`core_components.ex:383-391`) already renders its own `<.label for={@id}>` and has **no defaults for `:name`/`:value`** (271/274), so a bare `<.input id="export_id" type="text">` would raise on the missing assigns, and pairing it with a separate `<.label>` would emit a second, empty `<label>` per control. Correct idiom: `<.input id="export_id" name="export_id" type="text" label="Export id" value={@filters.export_id} />` and the same for `remote_endpoint`, plus a **visible** `<button type="submit">Filter</button>`. Placeholders are not labels; don't truncate the long accessible names. (If a bare HTML `<label for>`+`<input>` pair is preferred over `<.input>`, that also works — the invariant is *exactly one* associated label per control.)
- Wrap the result summary in `<div id="audit-results" role="status" aria-live="polite" tabindex="-1" phx-hook="FocusResults" data-refocus={refocus_token(@filters)}>Showing <%= @total_count %> event(s)<%= filter_suffix(@filters) %></div>` — the `aria-live` region is announced on every `handle_params` (filter + pager); the `data-refocus` token (filter-derived) changes only on a filter change, so the hook moves focus here on filter submit but NOT on paging.
- Branch the empty state on `@filtered?`:
  ```heex
  <div :if={length(@entries) == 0 and not @filtered?} class="my-4 text-sm">No data access events have been recorded yet.</div>
  <div :if={length(@entries) == 0 and @filtered?} class="my-4 text-sm">No events match the current filter.</div>
  ```
  (both inside/under the aria-live region so they're announced).
- `<table>` gains `<caption class="sr-only">Data access events<%= filter_suffix(@filters) %></caption>`; each `<th>` gains `scope="col"`.
- The pager already provides `aria-current` + `<nav aria-label>` (STORY 1) — no new work there; keep the two distinct pager labels.

Tests: query returns only matching rows for `export_id` (exact) and `remote_endpoint` (case-sensitive `JSON_CONTAINS`, matches intent + access rows, skips NULL STORY-1 rows); an injection-y `remote_endpoint` (`") OR 1=1 --`) matches nothing (bound param); LiveView renders labeled inputs (assert **exactly one** `<label>` associated per control — guards against the `<.input>` double-label) + submit button + caption + `scope="col"` + the aria-live summary; empty-state message differs by `@filtered?`. **Focus-token behavior (F-ext-4)**: the rendered `data-refocus` value on `#audit-results` **changes** across a filter submit but is **unchanged** across pager navigation (the client hook keys focus off this, so this HTML-level assertion proves paging won't steal focus without needing a JS runtime).

---

### Firestore composite index prerequisite + deploy checklist

**Summary**: The emulator serves the history query with **no** composite index (verified), so passing emulator tests do not prove real-project coverage. Create the `interactive_state_histories (platform_id, platform_user_id, resource_link_id, created_at)` index in dev and add a non-emulator deploy-checklist guard. Project convention is manual (console) index management (`firestore.indexes.json` intentionally empty); optionally capture it there.

> **Live-verified index state (2026-07-15, real projects, not the emulator).** The index situation was more subtle than "exists in pro, missing in dev." Before this step, `report-service-dev` already had **two** `interactive_state_histories` composite indexes, but **both lead with `context_id`** — `(context_id, platform_id, resource_link_id, created_at, __name__)` and `(context_id, platform_id, platform_user_id, resource_link_id, created_at, __name__)` — so neither can serve this walker's query, which has **no `context_id` equality** (a composite index whose leading field is `context_id` only serves queries that also filter `context_id ==`). That is exactly why the live history query returned `FAILED_PRECONDITION` on dev. `report-service-pro` was the only project that already had the exact `context_id`-less `(platform_id, platform_user_id, resource_link_id, created_at, __name__)` index. **This `context_id`-less index has since been created on `report-service-dev` (state `READY`) via `gcloud firestore indexes composite create`, and the full history read chain was then validated end-to-end on real staging data** (answers → LTI tuple → history metadata → state-doc-keyed-by-metadata-id, all `remote_endpoint`-matched; `created_at` observed at millisecond precision, `nanoseconds=133000000`, which is why the cursor must carry full `{seconds, nanoseconds}` and not a millis-rounded value). Note the platform's own history reads are evidently `context_id`-scoped (hence the pre-existing indexes); an alternative that would reuse the existing dev index #2 is to add a `context_id ==` filter (derivable from the same answer doc as the tuple) — **not** taken here, as the tuple-only key is the intended contract and the matching index now exists in both dev and pro.

**Files affected**:
- `specs/REPORT-76-cc-data-bulk-read-answers-history/deploy-checklist.md` — new (or a section in the PR description)
- `firestore.indexes.json` — optional edit (capture the index despite the manual convention)

**Estimated diff size**: ~30 lines (mostly docs).

Deploy checklist (must run against the **live** project, not the emulator):
```
# Verify the history composite index exists before exercising /history in a target project:
firebase firestore:indexes --project report-service-dev
# expect a composite on interactive_state_histories:
#   (platform_id ASC, platform_user_id ASC, resource_link_id ASC, created_at ASC)   [__name__ ASC appended automatically]
# NOTE: dev/pro also carry context_id-PREFIXED indexes on this collection — those do NOT satisfy this query
# (no context_id filter). Confirm the context_id-LESS one above is present; a FAILED_PRECONDITION means it isn't.
# If missing, create it (already done on report-service-dev, 2026-07-15):
gcloud firestore indexes composite create \
  --project=report-service-dev \
  --collection-group=interactive_state_histories \
  --query-scope=COLLECTION \
  --field-config field-path=platform_id,order=ascending \
  --field-config field-path=platform_user_id,order=ascending \
  --field-config field-path=resource_link_id,order=ascending \
  --field-config field-path=created_at,order=ascending
# (or use the console, or follow the click-to-create link the first FAILED_PRECONDITION query emits.)
```
Also on the checklist: (1) the shared `api` function `timeoutSeconds` bump (60 → 300) raises the ceiling for all co-located routes — call out in deploy review; (2) sanity-check the ALB/proxy idle timeout against ~300 s; (3) the two new migrations (`export_scratch`, `data_access_log.export_id`) run on deploy.

**Source-fidelity live validation (F-ext6-2 — the real-data half of the validation milestone).** This CANNOT be a
hermetic controller test (it needs live portal + Firestore); it is a manual / env-gated live step, run once
against a target project before `/answers` + `/history` are exercised for real:
```
# For a KNOWN run + learner with known real answers (fill in the identifiers for the target env):
#   REPORT_RUN_ID=<id>  KNOWN_REMOTE_ENDPOINT=<endpoint>  EXPECT_NONEMPTY=true
# 1. Hit GET /api/v1/reports/:id/answers (page 1) as the run owner.
# 2. Assert the page returns that learner's items (NOT an empty set) — i.e. the SourceKey-derived `source`
#    matches the Firestore `sources/{source}` where their answers actually live.
# PASS -> URL-derived source fidelity confirmed for this env's real runs.
# FAIL/empty -> the URL-derived `source` diverges from the answer's authoritative `source_key`
#    (rehosted/migrated activity or per-question source_key) — see the SourceKey step's "Source-derivation
#    fidelity (URL-only by design)" note; do NOT ship /history for that class until reconciled.
```
Specify identifiers + skip/fail behavior explicitly so this milestone is not silently skipped.

Optional `firestore.indexes.json` capture (only if the team chooses to deviate from manual management):
```json
{
  "indexes": [
    {
      "collectionGroup": "interactive_state_histories",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "platform_id", "order": "ASCENDING" },
        { "fieldPath": "platform_user_id", "order": "ASCENDING" },
        { "fieldPath": "resource_link_id", "order": "ASCENDING" },
        { "fieldPath": "created_at", "order": "ASCENDING" }
      ]
    }
  ],
  "fieldOverrides": []
}
```

---

## Open Questions

<!-- Implementation-focused only. Requirements questions live in requirements.md (all resolved there). -->

### RESOLVED: Composite `page_token` wire format
**Decision**: `base64url(JSON)` of `{"s": scratch_id, "i": endpoint_index, "c": inner_cursor}`, unsigned plaintext (as STORY 1). Integrity is capability (`strong_rand_bytes` scratch_id) + per-page ownership/`data_type` re-check + `endpoint_index ∈ [0, len)` + inner-cursor field validation — not signing (rejected in requirements Round-4). `Jason` round-trips cleanly; no throwaway check needed.

### RESOLVED: One Node route vs two
**Decision**: One `POST /bulk_read` with `collection` in the body. The two Elixir routes (`/answers`, `/history`) both call it; avoids duplicating the endpoint-walk loop. The Elixir `data_type` (`answers_bulk`/`history_bulk`) still binds each scratch to its route independently.

### RESOLVED: Default page caps (`endpoint_limit`, `read_limit`) and history batch sizes
**Decision**: `endpoint_limit` 250, `read_limit` 5000, `HISTORY_BATCH` 300, `GETALL_CHUNK` 300. All are tunable constants; `limit` (default 500 / **max 500** — server cap == default) only lowers the returned-item cap. `@max_limit` was lowered from an earlier 2000 to 500 (F-ext-3): requirements pin `@max_limit ≥ 500`.

**Update (2026-07-15, live byte-envelope probe) — `limit=500` alone is NOT byte-safe; the byte budget is the real guard.** The original reasoning ("500 keeps a page under the 10 MB gen1 cap") holds only for *average* item size. A live probe on staging (`functions/byte-envelope.js`) measured real items at answers median ~1.5 KB / **max ~313 KB** and history states median ~1.7 KB / **p95 ~52 KB** — highly variable, and large interactive states cluster by activity (a CODAP class export returns many 50–300 KB items in a row). At the tail **~10 near-max items reach 10 MB**, so a 500-item page can exceed the cap. No fixed item count is byte-safe when a single item can approach the Firestore 1 MiB doc limit. The actual protection is the **`RESPONSE_BYTE_BUDGET` (~8 MB soft) fourth cap** added to the walker (see "Fourth cap — response-byte budget" above): it bounds the page by accumulated serialized bytes, always admits ≥1 item (max item < 1 MiB ≪ 8 MB → progress guaranteed), and makes `limit` purely an item-count convenience rather than the byte-safety mechanism. With the byte budget in place, raising `@max_limit` above 500 later no longer risks the response cap (though it still must respect the requirements' contract). `read_limit`/`endpoint_limit`/batch sizes remain first-pass values to confirm at the validation milestone against real read cost/latency. None change the observable contract.

### RESOLVED: `LearnerData.fetch` group struct accessor in `to_endpoints/1`
**Context**: `to_endpoints/1` reads `group.learners`; `group_learners_by_runnable_url/1`'s exact output shape needed confirming.
**Decision**: Confirmed by reading the source (`learner_data.ex:296-338`) — groups are `%{runnable_url:, query_id:, learners: [row,...]}` and each row carries `:run_remote_endpoint` + `:runnable_url`. `to_endpoints/1` as written is correct; no change needed.

### RESOLVED: Test-seam mechanism for `ReportServiceStub` / `LearnerDataStub`
**Context**: How the controller-test stubs expose their canned responses.
**Decision**: Mirror the project's established `AthenaDBStub` pattern exactly — a **named `Agent`** started with `start(responses)` and selected via `Application.put_env(:report_server, :report_service_client, ...)` (and `:learner_data` / `:allowed_project_ids_source`), with `async: false` tests. Robust across processes; not the process dictionary. (Confirmed against `test/support/athena_db_stub.ex` + `report_controller_test.exs:68`.)

### RESOLVED: LiveView focus-move mechanism after filter submit
**Context**: `handle_params` re-renders via `push_patch` with no built-in focus move; a `JS` command bound to submit-click fires before the results re-render (focusing stale content), so it needs to trigger on the *update*.
**Decision**: A small `FocusResults` `phx-hook` on the `tabindex="-1"` results container whose `updated()` moves focus (`this.el.focus()`) when a `data-refocus` token (bumped on filter change, not on plain paging) changes. Confirmed the app already registers hooks (`phx-hook="CopyToClipboard"`, `"DownloadButton"`, etc.) so the infra exists, and LV is **0.20.14** (not 0.20.2) — `JS.focus/focus_first/push_focus` are available and `core_components.ex:646` uses `JS.focus_first`, but those are client-event-triggered and don't cover "focus after the async patch settles," so the hook is the correct mechanism. The `aria-live="polite"` region announces the result count independently, so even absent focus movement the SR user hears the change. Register `FocusResults` in the app's hooks object alongside the existing hooks.

### RESOLVED (DEFERRED): Server-side `question_id` filter for history (and answers)
**Context**: The history read is keyed by the LTI tuple and returns the learner's **entire** interactive-state timeline for the resource — all questions interleaved by `created_at` (live-verified: 22 snapshots across 3 `question_id`s for one staging learner). Question: should the bulk API accept a `question_id` filter, or is that a client concern?
**Decision — client-side; do NOT add a server-side question filter now.** Ship the tuple-only key.
- The client already receives `question_id` (and `answer_id`) on every item, so narrowing to one question is a one-line filter on the returned stream — no new param, cursor dimension, index, or test matrix.
- This is a **bulk-export** API (comprehensive extraction for research); consumers generally want the whole per-learner timeline and slice it themselves. A narrowing param cuts against that model.
- A server-side **post-filter** (the same mechanism as the existing `remote_endpoint` post-filter) would **not** help the metered dimension: the cost is Firestore *reads* (`read_limit`), not response bytes. It would still read every metadata + state doc in the tuple's stream and drop non-matching ones — compounding the documented "read many, return few" case, making pages sparse and resumption chatty, while saving nothing on reads.
- The only *efficient* server-side option is **index-based**: add `.where("question_id","==",…)` (the field is on the metadata doc) **plus a new composite index** `(platform_id, platform_user_id, resource_link_id, question_id, created_at, __name__)` in **both** dev and pro. The cursor stays `(created_at, __name__)`, so it's a clean, **non-breaking, additive** change — deferrable until a concrete consumer needs it.
- **The one condition that would flip this**: a real consumer that repeatedly wants a *single* question's history in isolation (e.g. a per-question report view) rather than pulling a learner's full stream once. At scale, pulling 22 snapshots to show 1 is wasteful, and the index-based filter earns its keep. Absent that consumer, tuple-only wins. Revisit if/when such a use case is identified; adding it later requires only the optional param + the composite index (no contract or cursor change). The same reasoning applies to a `question_id` filter on the answers path.

### RESOLVED (IN SCOPE — folded in): Server-side attachment download endpoint
**Now implemented as the build step "Attachment download endpoint — batch presign (`POST /api/v1/reports/:id/attachments`)" above.** Originally deferred as a separate story; folded into REPORT-76 because REPORT-76 *is* the API for pulling answer + history data and attachment content is part of that data, and the investigation showed the implementation is small (existing bucket var + IAM grant + presign helper + audit pattern). The decisions below record the design and the (now-superseded) reasoning that led here.
**Design as built**: batch `POST /api/v1/reports/:id/attachments` (run id in path); durable auth via `:id` (re-derives `endpoint_set`, survives the scratch TTL, reflects current permissions); server re-reads each doc via a Node metadata helper for the authoritative `publicPath`+owner (IDOR guard — never signs a client path); presigns with report-service's own server creds (no token-service brokering; `report-server-*` IAM already grants `s3:GetObject` on `<private-bucket>/interactive-attachments/*`); cap 500; TTL 600 s; partial-success per item; one audit row per call (`attachment_urls_issued`). End-to-end validated on staging (2.9 MB CODAP fetch). The walker itself stays reference-only (never inlines attachment bytes — that would defeat the `RESPONSE_BYTE_BUDGET`).
**Historical decision record (why it landed here):**
- **Feasibility is high (live-verified 2026-07-15).** Every answer/state doc the walker already reads carries a top-level `attachments` map: `name -> {folder:{id, ownerId}, publicPath, contentType}` (e.g. `audio1762605993968.mp3 -> {folder:{id:"NmxJhV3FpCOioRuKnNBg", ownerId:"<remote_endpoint>"}, publicPath:"interactive-attachments/<folderId>/<uuid>/audio….mp3", contentType:"audio/mpeg"}`; and `file.json -> {…, contentType:"application/json"}` for the CODAP offload). Both reference forms resolve through this same map, and **`folder.ownerId` IS the answer's `remote_endpoint`** — a ready-made authorization binding. So report-service has the full locator in-hand with **zero extra reads**.
- **Do NOT resolve/inline attachments inside the walker or bulk-read response.** Rehydrating an `__attachment__` re-inflates exactly the ≥400 KiB state that was offloaded to keep the doc small (and audio is larger), which would defeat the `RESPONSE_BYTE_BUDGET` guard and re-introduce the 10 MB-cap risk; it also adds per-item S3/token-service round-trips to an otherwise Firestore-only, bounded walker. The walker must keep passing references through verbatim.
- **If/when consumers need content, add a dedicated resolve endpoint** (its own story), e.g. `GET /api/v1/exports/{export}/attachments?answer_id=&name=`, that: (1) authorizes with the SAME ownership/endpoint_set derivation as bulk-read — the attachment's `folder.ownerId` (== `remote_endpoint`) must be in the export's authorized `endpoint_set`; (2) reads `attachments[name]` for `publicPath`/`contentType` (exactly as `transcribe_audio.ex` `get_audio_path/2` already does); (3) **presigns a short-lived S3 GET directly with report-service's own server creds** (`AWS.get_presigned_url/3`, bucket = `TokenService.get_private_bucket/0`, key = `publicPath`) and returns/redirects to the URL — **no token-service brokering** (report-service already holds `s3:GetObject` on `<private-bucket>/interactive-attachments/*` in both accounts — see the access-model bullet) and **not** a byte-proxy (avoids making report-service a bandwidth pipe); (4) audits each resolve like a `bulk_read` access row (`export_id`-correlated), reusing the `AuditLog.issue_download_url` pattern. One endpoint covers both `__attachment__` and `audioFile`.
- **Bucket access model — CONFIRMED PRIVATE at the AWS source of truth (live-verified 2026-07-15), BUT report-service already has the access it needs — no token-service brokering, no new IAM grant.** Despite the field name `publicPath`, the objects are not public-read (`publicPath` is just the S3 **key**): an unauthenticated `GET` returns **HTTP 403 `AccessDenied`**, and the staging bucket `token-service-files-private` (account **816253370536**) has a fully-locked-down public-access-block (all four flags true), so no public-URL shortcut exists — a GET must be presigned. **However**, presigning does not require token-service: report-service runs **in the same AWS account as the bucket in each environment** and its server user (`SERVER_ACCESS_KEY_ID`, already required by `runtime.exs`) **already holds `s3:GetObject` on `<private-bucket>/interactive-attachments/*`** — verified in both accounts (staging `report-server-staging`→`token-service-files-private/interactive-attachments/*`; production `report-server-prod`→`cc-student-work/interactive-attachments/*`), a grant added for the existing audio-transcription step (`transcribe_audio.ex`, which already builds `s3://<private-bucket>/<publicPath>`). A presigned URL authorizes **as the signer**, so with that grant the report-service-signed URL works for the client (who needs no creds). This *simplifies* the endpoint to a thin presign — no `getCredentials`/`readWriteToken` dance. (For context, the interactive runtime itself presigns via token-service temp creds in `attachments-manager.ts`, but report-service doesn't need to: it has standing, prefix-scoped access.) The ownership binding (`folder.ownerId` == `remote_endpoint` ∈ `endpoint_set`) is what authorizes at the report-service layer.
- **Buckets are environment-specific, but already handled by one env var + existing IAM.** The private bucket differs per environment — **staging `token-service-files-private`** (account 816253370536), **production `cc-student-work`** (account 612297603577) — and is already selected by the single **`TOKEN_SERVICE_PRIVATE_BUCKET`** env var → `TokenService.get_private_bucket/0` (set per-env via the `TokenServicePrivateBucket` CloudFormation param in `fargate/report-server.yml`). The matching `s3:GetObject` grant on `<that-bucket>/interactive-attachments/*` already exists in **both** `report-server-*` IAM policies. So the endpoint needs **no new infra and no new IAM** — just `presigned_url(:get, TokenService.get_private_bucket(), publicPath)` with the existing server creds, exactly how `run_csv`/`job_result` downloads are already presigned. (The `runtime.exs` default for `TOKEN_SERVICE_PRIVATE_BUCKET` is a fallback string only; real deploys set the per-env value.)
- **Scope note (placement TBD)**: originally deferred as "its own story," but since REPORT-76 is *the* API for pulling answer + history data and attachment content is part of that data, this may be promoted into scope now (see the companion attachment-download spec / decision pending). The implementation is small given everything above already exists (bucket var, server creds + IAM grant, `AWS.get_presigned_url`, the `attachments[name].publicPath` read, and the `AuditLog.issue_download_url` audit pattern). Whatever the placement, the **walker stays reference-only** (Firestore-only, byte-bounded); attachment content is a *separate endpoint*, not inlined into bulk-read. Prior art: `transcribe_audio.ex` (already reads `attachments[name].publicPath` from the private bucket) and, client-side, `portal-report/js/components/report/iframe-answer-report-item-attachment.tsx`.

## Self-Review

<!-- Phase 3, Step 2 — multi-perspective review of the IMPLEMENTATION spec.
     Every finding below was verified against the CURRENT source (line numbers re-read, not trusted
     from the spec) and, where a runtime assumption was involved, against a throwaway execution.
     Verification method is stated inline on each item so the assessment is auditable. -->

### Verification harness (what was actually checked)

Ground truth was re-established by reading the live source for every before/after edit in this plan:
`data_access_log_entry.ex`, `audit_log.ex`, `error_helpers.ex`, `learner_data.ex`, `report_utils.ex`,
`portal_dbs.ex`, `shared_queries.ex`, `report_service.ex`, `reports.ex`, `router.ex`, `application.ex`,
`stats_server.ex`, `accounts.ex`, `pagination.ex`, `params.ex`, the STORY-1 migration, and the Node
`index.ts` / `paths.ts` / `response-methods.ts` / `bearer-token-auth.ts` / `package.json` / `firebase.json`.
Two throwaway executions were run (Elixir 26): (1) `SourceKey.from_runnable_url/1` over 7 URL shapes;
(2) the `page_token` `Base.url_encode64`/`url_decode64 padding:false` round-trip plus the `parse_page_token`
key/type guard.

**Confirmed SOUND (re-verified, no change needed)** — recorded so the review is not just a defect list:
- **Authorization is not bypassed by discarding `_allowed` in `derive_endpoint_set/2`.** `LearnerData.fetch`
  independently calls `apply_allowed_project_ids_filter(user, …)` (`report_utils.ex:106-128`), which itself
  re-derives `get_allowed_project_ids(user)` (`portal_dbs.ex:140-147`: `:all` for admin, a project-id list for
  project-admin/researcher, `:none` otherwise) and injects the `ac_*_a.project_id IN (…)` scoping. The
  controller's `get_allowed_project_ids` call is only a pre-SQL short-circuit for the `[]`/`:none` cases
  (avoids `list_to_in([]) -> "IN ()" -> 500`). Not a gap.
- **The `endpoint_set` retype needs no migration.** STORY-1's `20260713080100_create_data_access_log.exs:18`
  created it as `:map` (→ MySQL `json`); the new `EctoJsonArray` custom type also dumps to `json`, so only the
  schema field declaration changes. STORY-1 rows wrote `null`, still valid. **(Correction, F-ext3-1: the schema
  field is the `EctoJsonArray` custom type, NOT a bare `{:array, :string}` — MyXQL does not json-decode a bare
  `{:array, _}` on load. See the "Why a custom Ecto type" note.)**
- **Cursor/lookahead state machine round-trips.** Traced the Node walker's `stop_endpoint_offset` /
  `endpoint_exhausted` / inner-cursor against the Elixir reassembly (`{index+off+1, nil}` when exhausted,
  `{index+off, next_inner}` when a cap was hit): the "exactly `cap` docs, more may remain" vs "exactly `cap`
  and done" distinction is resolved by the one-doc lookahead, so terminal detection and mid-endpoint resume
  are both correct.
- **`page_token` guard chain rejects malformed tokens.** Throwaway run confirms `Base.url_decode64(_, padding:
  false)` is lenient (accepts any url-safe-charset string), so the real gate is `Jason.decode` failing on
  non-JSON bytes — which the `with` chain handles → `:bad_request`. `strong_rand_bytes(32)` → 43-char id
  confirmed.
- **`getPath` leading-slash output** feeds `getCollection`/`getDoc` in shipping code
  (`get-answer.ts`, `get-plugin-states.ts`, `get-resource.ts`), so the walker's usage is precedented.
- Also spot-verified sound: route shadowing (`/reports/:id/answers` vs `/reports/:id`), the
  `@codes_by_status` reverse-map (adding `EXPIRED_CURSOR => 410` inverts cleanly, no collision),
  `StatsServer`'s `init → {:continue, …}` no-DB-in-init pattern the SweepServer mirrors, `Pagination`
  exposing `total_count`, `Accounts.revoke_api_token/2` at `accounts.ex:107`, and the `JSON_CONTAINS(…,
  JSON_QUOTE(?))` filter being a bound param (injection-safe).

---

### Firestore / Data-Integrity Engineer

#### RESOLVED: `SourceKey` reproduces only the report's URL fallback, not its primary `answers.source_key[question_id]`
**Decision (A)**: keep the URL-only derivation (Elixir can't cheaply read the authoritative key at derive time), but make the trade-off explicit and testable. Added a "Source-derivation fidelity (URL-only by design)" Technical-Note to the `SourceKey` step naming the uncovered divergence class and the future Node-side cross-check hook. **Source-fidelity is checked in two parts (split per F-ext6-2):** a *stubbed* controller test asserts the derived `source` is what the controller sends to Node (hermetic mechanics), and the *real-data* assertion — that the URL-derived `source` matches where a known learner's answers actually live — is an **env-gated live step in the deploy checklist** (it can't run under the stubbed suite). Original finding retained below.


**Verified against** `shared_queries.ex:406-436`. The report's own SQL builds the answer's source key as:
```
answers_source_key = "#{learners_and_answers_table}.source_key['#{question_id}']"   # line 428, "only exists if there is an answer"
source_key_from_runnable_url = "COALESCE(url_extract_parameter(resource_url,'answersSourceKey'), url_extract_host(resource_url))"   # 432-433
answers_source_key_with_no_answer_fallback =
  "COALESCE(#{answers_source_key}, IF(#{source_key_from_runnable_url} = 'activity-player-offline.concord.org', 'activity-player.concord.org', #{source_key_from_runnable_url}))"   # 435-436
```
So the report **prefers the source_key recorded on the actual answer** and uses the runnable-URL derivation only *when there is no answer*. STORY-3's `SourceKey.from_runnable_url/1` implements **only the fallback** (the inner `source_key_from_runnable_url` + offline remap). My throwaway run confirms it reproduces that inner expression faithfully (all 7 cases pass, incl. `answersSourceKey` override and offline→online remap).

**Why it matters**: the Node walker queries `sources/{source}/answers|interactive_state_histories`. If a run's answers were written under a `source_key` that diverges from the *current* `runnable_url` derivation (rehosted/migrated activity, or a per-question source_key), the walker queries the wrong Firestore `source` and **silently returns zero items** for that learner — no error, just missing data, which is exactly the failure mode an IRB/completeness audit can't see. In the common case they coincide (activity-player writes answers under the same key it derives from the URL), which is why this is a correctness *risk* concentrated on non-standard/migrated runs, not an everyday bug. Note Elixir cannot cheaply read the answer's `source_key` at derive time (it lives in Firestore/Athena, not the portal DB the derivation uses), so "just use the SQL's primary" is not free.

**Suggested resolution**: (a) make the validation-milestone acceptance explicitly assert, on real data, that the URL-derived `source` matches where a known learner's answers actually live; and (b) add a Technical-Note in the plan documenting that STORY-3 source derivation is URL-only-by-design and the divergence class it does not cover (with a follow-up hook: the Node history reader already reads one real answer doc to derive the LTI tuple — it *could* cross-check `answer.source_key` there and surface a mismatch signal instead of silently returning empty).

---

### QA / Test Engineer

#### RESOLVED: emulator harness depends on a globally-installed `firebase-tools`, not a pinned devDependency
**Decision (A)**: pin `firebase-tools` in `functions/devDependencies` and invoke via `npx firebase emulators:exec` so the harness is hermetic on CI (updated the "Node emulator test harness" step's `package.json` edit and summary). Also corrected the plan's "no `FIRESTORE_EMULATOR_HOST` reference" wording — it already appears at `firebase-client.ts:54`. Original finding retained below.


**Verified against** `functions/package.json` (jest `^24.8.0`, `test: "jest"`; scripts include `firebase:tools:install` = `npm install -g firebase-tools` and `emulator` = `firebase emulators:start …`, but **no** `firebase-tools` in `devDependencies`) and `firebase.json` (`emulators.firestore.port = 9090`, confirmed). The plan's `test:emulator` = `firebase emulators:exec …` therefore relies on a **global** `firebase` binary that CI would have to install out-of-band; there is also **no existing `emulators:exec` usage** in the repo and **no emulator-backed test** today (all 7 existing suites are pure in-memory).

**Why it matters**: the plan calls the emulator harness "verified-working" and makes it a prerequisite for the bulk-read, cursor-tie, and post-filter suites. If CI lacks a pinned `firebase-tools`, `npm run test:emulator` fails to launch and every emulator-backed assertion silently doesn't run — a green `npm test` (unit only) would look complete while the story's core coverage never executed.

**Suggested resolution**: add `firebase-tools` to `functions/devDependencies` (pinned), invoke it via `npx firebase emulators:exec` (or a local `node_modules/.bin` path) so the harness is hermetic, and have the fail-closed `emulator-setup.ts` guard remain as the second line of defense. Also correct the plan's claim of "no `FIRESTORE_EMULATOR_HOST` reference" — it already appears at `firebase-client.ts:54` (`process.env.FIRESTORE_EMULATOR_HOST || "localhost:9090"`).

---

### WCAG Accessibility Expert

#### RESOLVED: the filter form's `<.input type="text">` needs `name`/`value` and emits its own `<label>` — as written it double-labels
**Decision**: pinned the correct idiom in the template step — use `<.input>`'s built-in `label=` (supplying `name`/`value`) and drop the separate `<.label>`; the invariant is exactly one associated label per control, and the a11y test now asserts it. Original finding retained below.


**Verified against** `core_components.ex`: `attr :name, :any` (271) and `attr :value, :any` (274) have **no defaults**, and the plain-text catch-all `def input(assigns)` (383) renders both `name={@name}` / `value={…@value}` **and** its own `<.label for={@id}>{@label}</.label>` (386, `:label` defaults to `nil`). The plan's markup ("a real labeled `<form>` with `<.label for="export_id">`/`<.input id="export_id" type="text">`") would therefore (1) raise on the missing `@name`/`@value` assigns, and (2) if given a `name`/`value`, still render a **second, empty** `<label>` from the component itself — an a11y smell (empty/duplicate label for one control).

**Why it matters**: this is squarely in the mandated-accessibility surface of the story, and "labeled input" is one of its acceptance criteria; the intended fix (visible, associated label) is exactly what the double-label would undermine.

**Suggested resolution**: pick one idiom and pin it in the plan — either use the component's built-in label (`<.input id="export_id" name="export_id" type="text" label="Export ID" value={@filters.export_id}>` and drop the separate `<.label>`), or use a bare HTML `<label for>`+`<input>` pair (no `<.input>`). Either way, supply `name` and `value` explicitly. Update the Phase-3 test assertion ("renders labeled inputs") to check for exactly one `<label>` per control.

---

### Senior / API-Contract Engineer (minor accuracy + contract notes)

#### RESOLVED: the `data_access_log_entry.ex` changeset before/after drops two real `foreign_key_constraint` lines
**Decision**: extended the before/after in the "Persistence foundation" step to include and preserve `|> foreign_key_constraint(:user_id)` / `|> foreign_key_constraint(:report_run_id)` (lines 34-35), with a NOTE that only the cast/validate_inclusion lines change. Original finding retained below.


**Verified against** `data_access_log_entry.ex:28-35`: the live changeset ends with `|> foreign_key_constraint(:user_id)` / `|> foreign_key_constraint(:report_run_id)` (34-35), and the `cast` list wraps across two lines (28-29). The plan's BEFORE/AFTER shows neither. Applied literally, the AFTER would silently delete the FK constraints (losing the friendly changeset error on a bad `user_id`/`report_run_id`). Trivial to fix — extend the AFTER to retain 34-35 — but it must be called out so the edit isn't pasted verbatim.

#### RESOLVED: Node `4xx` responses collapse to a client `500`
**Decision**: kept the behavior (Elixir pre-validates the cursor so Node should never 4xx) but added an inline NOTE at the `serve_page/…` error branch documenting the collapse and the future truthful-mapping hook. Original finding retained below.


**Verified against** the plan's `serve_page/…` (`{:error, _reason} -> ErrorHelpers.server_error(conn)`) and `bulk_read/1` (`{:ok, %{body: %{"error" => error}}} -> {:error, error}`). A Node `res.error(400, …)` (e.g. a hand-crafted internal cursor that trips the defense-in-depth guard) therefore surfaces to the CLI as `500`, not `400`. Acceptable because Elixir pre-validates the cursor (`BulkParams.validate_inner_cursor` + numeric-field checks) so Node should never 400 in practice — but worth an inline note, and optionally mapping a Node-reported `badRequest` back to `bad_request` for truthfulness.

#### RESOLVED: "the 4 existing callers of `fetch` stay byte-identical"
**Verified**: literal `fetch/2` has exactly **one** caller (`fetch_and_upload/2`, `learner_data.ex:16`); the "4" figure belongs to `fetch_and_upload`. The default-arg mechanism (`opts \\ []`) is sound and `map_learner_data/2` has a single caller (line 127; `resource_data.ex` uses the differently-named `map_learner_data_to_runnable_data`), so the arity bump to `/3` breaks nothing. Only the prose count is wrong — corrected here, no code impact.

#### RESOLVED: SourceKey doc cites `hostname(runnable_url)`
**Verified**: the real SQL uses `url_extract_host(resource_url)` (`shared_queries.ex:433`), not `hostname(…)`. Cosmetic — the Elixir port uses `URI.parse/1`'s `.host`, which matches `url_extract_host` semantics; only the comment is imprecise.

---

## Self-Review — Round 2 (2026-07-14, verification-first pass)

<!-- Second multi-role pass. Every finding below was independently re-established against LIVE source
     (three parallel ground-truth passes over the Elixir, Node, and LiveView surfaces — line numbers
     re-read, not trusted from Round 1) and, where a runtime assumption was in question, against a
     throwaway probe. Verification method is stated inline. Headline items: F1, Q1, P1. -->

### Verification harness (Round 2)

Re-read live source for every before/after edit and factual claim: Elixir — `learner_data.ex`,
`report_utils.ex`, `portal_dbs.ex`, `shared_queries.ex`, `reports.ex`, `report_service.ex`,
`audit_log.ex`, `data_access_log_entry.ex`, `error_helpers.ex`, `router.ex`, `params.ex`,
`pagination.ex`, `accounts.ex`, `application.ex`, `stats_server.ex`, `athena_db_stub.ex`; Node —
`index.ts`, `middleware/bearer-token-auth.ts`, `api/helpers/paths.ts`, `middleware/response-methods.ts`,
`firebase-client.ts`, `package.json`, root `firebase.json`; LiveView — `core_components.ex`,
`audit_log_live/index.ex` + `.html.heex`, `custom_components.ex`, `assets/js/app.ts`, `mix.lock`.
Two throwaway probes: (1) a JS simulation of the history walker's item/read-cap loop
(impl.md:823-857); (2) read of the exact jest config in `functions/package.json`.

---

### Firestore / Data-Integrity Engineer

#### RESOLVED: History pages can exceed the requested `limit` by up to `HISTORY_BATCH − 1` (~299) items
**Decision (b)**: rewrote `readHistoryEndpoint`'s push loop to stop EXACTLY at `remItems` (mid-batch if
needed) and advance the inner cursor to the last CONSUMED metadata doc, so history now respects `limit`
precisely — matching the answers path. Large `HISTORY_BATCH`/`getAll` reads are retained (no extra
round-trips in the no-filter case); the only cost is re-reading the discarded batch tail on the next
page (already counted toward `read_limit`). Added a `hitItemCap` flag so the end-of-endpoint lookahead
is skipped when we broke mid-batch (a next metadata doc was provably already read → not exhausted → no
extra read). Added an emulator-test scenario asserting a page returns exactly `limit` items and resumes
at item `limit`+1 with no gap/dup. Original finding retained below.

**Severity: MEDIUM.** Requirements state "`limit` only lowers the returned-item cap," but
`readHistoryEndpoint` checks the item cap only at the TOP of the `while` loop (impl.md:824) and then
pushes an entire metadata batch's worth of matches (impl.md:836-849). Answers respects `limit` exactly
(`cap = min(remItems, remReads)`, impl.md:774), so this is a history-only asymmetry.

**Verified by throwaway simulation** of that exact control flow:
```
limit=500   → 600 items returned
limit=2000  → 2100 items returned
limit=10    → 300 items returned   (30× the requested page size)
```
The inner cursor still points at the last doc of the batch, so there is NO data loss or duplication —
the resume is correct. It is a page-size CONTRACT break, not corruption: a client that sets `limit` to
bound its own memory/response size can receive up to `limit + 299` items.

**Suggested resolution** (pick one, pin in the walker step): (a) also bound the batch by the item
budget — `batch = max(1, min(HISTORY_BATCH, remReads - reads, remItems - items.length))` (simplest;
costs more, smaller queries only when heavy post-filtering occurs); (b) stop pushing at `remItems` and
set the inner cursor to the last PUSHED doc (keeps large efficient reads; re-reads the discarded batch
tail on the next page); or (c) explicitly document `limit` as a batch-granularity SOFT cap for history
and require the client to tolerate `limit + HISTORY_BATCH − 1`, and note it in the requirements contract.

---

### Performance / Scale Engineer

#### RESOLVED: `read_limit` is a soft cap for history — actual Firestore reads can exceed it by up to `HISTORY_BATCH`
**Decision**: document, don't re-engineer. The overage is bounded (≤ one `HISTORY_BATCH`, ~6% over the
5000 default), non-runaway (the loop re-checks `reads >= remReads` at the top), and `read_limit` is an
internal cost-guard, not a client contract. Tighter batch-sizing (`min(HISTORY_BATCH, floor((remReads −
reads)/2))`) doesn't improve the worst case under heavy post-filtering (state docs are read regardless of
whether they pass the filter) and adds round-trips. Added a NOTE to the `HISTORY_BATCH` constant stating
the effective ceiling is `read_limit + HISTORY_BATCH`. No code change. Original finding retained below.

**Severity: LOW-MED.** Each history batch performs up to `2 × batch` reads (the metadata query PLUS the
state-doc `getAll`), but only the metadata query is bounded by the remaining read budget
(`batch = min(HISTORY_BATCH, remReads - reads)`, impl.md:825); the `getAll` at impl.md:833-834 adds
`stateDocs.length` more reads with no budget check. **Verified by probe**: with `remReads = 300`, one
iteration produced `reads = 600` (2× overshoot). So "bounded work per call = `read_limit`" is really
`read_limit + HISTORY_BATCH` worst-case for history; the "Bounded work per call" requirement should
reflect this. **Suggested resolution**: size the metadata batch against projected total reads
(`min(HISTORY_BATCH, floor((remReads - reads) / 2))`), or document the 2× factor and set `read_limit`
accordingly.

---

### QA / Test Engineer

#### RESOLVED: plain `npm test` will discover and run the `*.emulator.test.ts` suites and fail (fail-closed throw)
**Decision**: config-only fix (no code). Added `"\\.emulator\\.test\\."` to `jest.testPathIgnorePatterns`
so the default `jest` run skips the emulator suites, and changed the `test:emulator` script to re-include
them via a CLI override `--testPathIgnorePatterns "/node_modules/"`. **Verified with a throwaway jest@24
probe** that (1) the config ignore alone makes `--testPathPattern emulator` find ZERO tests (the ignore is
ANDed and not lifted by `--testPathPattern`), and (2) the CLI override restores them while the default run
still skips them. Updated the harness step's `package.json` edit + "Files affected". Original finding
retained below.

**Severity: MEDIUM.** **Verified against the live jest config** (`functions/package.json`):
`testRegex: "(/__tests__/.*|(\\.|/)(test|spec))\\.(jsx?|tsx?)$"` matches `bulk-read.emulator.test.ts`,
and `testPathIgnorePatterns` is only `["/node_modules/"]`. So the default `jest` run
(`"test": "jest"`) discovers the emulator test, whose top-level `import "./emulator-setup"` THROWS
(fail-closed) when `FIRESTORE_EMULATOR_HOST` is unset — turning every `npm test` on a dev box, and any
CI job that runs the default script without the emulator, red. The plan's claim that "plain `npm test`
keeps running the pure unit tests" is false as written. **Suggested resolution**: add
`"\\.emulator\\.test\\."` (or `"emulator"`) to `testPathIgnorePatterns` in the jest config so the
default run skips them; `test:emulator` opts them back in via `--testPathPattern emulator`. (Verified
jest 24 supports `--testPathPattern` and it coexists with `testRegex`.)

#### RESOLVED: the walker's core functions are not exported, so the emulator suite cannot assert on them directly
**Decision**: export `readAnswersEndpoint`/`readHistoryEndpoint` and assert on them directly at the walker
boundary (cursor/ordering/caps/post-filter/lookahead) — more targeted than round-tripping through
`bulkRead` and its `res.success`/`res.error` wrapping (which the pure cursor/header-guard tests already
cover). No runtime cost; the readers are pure (`endpoint + cursor + caps -> EndpointRead`). Added `export`
to both declarations with a Q2 note. Original finding retained below.

**Severity: LOW-MED.** `readAnswersEndpoint`/`readHistoryEndpoint` are module-private; only `bulkRead`
is default-exported (impl.md:769/796/869). The emulator suite's fine-grained assertions
(tie-at-page-boundary, cursor resume, duplicate-endpoint post-filter, lookahead-proves-exhausted) need
either exported helpers or a mock Express `res` supplying `.success`/`.error` — which come from the
`responseMethods` middleware (`middleware/response-methods.ts`) and are absent when the handler is
called directly. **Suggested resolution**: pin one approach in the test step — export the helpers for
tests, or add a small `res`-mock harness (`{ success: (o) => …, error: (s, m) => … }`).

---

### Senior Elixir / Backend Engineer

#### RESOLVED: `report_utils.ex` is listed in "Files affected" for the seams step but needs no edit
**Decision**: removed `report_utils.ex` from the seams step's "Files affected" and reworded the
`learner_data.ex` entry to state the allow-empty gating is a new private `maybe_ensure_not_empty/2` calling
the unchanged public `ReportUtils.ensure_not_empty/2`. Doc-only. Original finding retained below.

**Severity: LOW.** The `allow_empty` path lives entirely in `learner_data.ex` — `maybe_ensure_not_empty`
calls the already-public `ReportUtils.ensure_not_empty/2` (`report_utils.ex:90`, verified public `def`
with two clauses; the sole caller is `learner_data.ex:154`). The seam step's file list
("`report_server/reports/report_utils.ex` — edit (`ensure_not_empty` gains an allow-empty path via the
caller)") implies a diff that does not exist. **Suggested resolution**: drop `report_utils.ex` from
that step's "Files affected" and reword — the allow-empty gating is a new private helper in
`learner_data.ex`, not a change to `ensure_not_empty`.

#### RESOLVED: inline-comment inaccuracy — `list_to_in([])` returns `"()"`, not `"IN ()"`, and lives in `report_utils.ex`
**Decision**: corrected the `derive_endpoint_set/2` comment to
`ReportUtils.list_to_in([]) -> "()", so a caller's "... IN #{...}" -> "IN ()" syntax error -> 500`. The
short-circuit logic is unchanged. Comment-only. Original finding retained below.

**Severity: LOW (cosmetic).** The `derive_endpoint_set/2` comment (impl.md:1197) says
`list_to_in([]) -> "IN ()" -> 500`. **Verified**: `list_to_in/1` is in `report_utils.ex:4-5` and returns
`"()"` for `[]` (the `IN` keyword is prepended by callers, e.g. `"... IN #{list_to_in(...)}"`). The
resulting SQL is indeed `IN ()` (a syntax error), so the short-circuit is still required — only the
comment's attribution/quoting is off. **Suggested resolution**: fix the comment to
`list_to_in([]) -> "()" -> "... IN ()" syntax error`.

---

### Security Engineer / IRB

#### RESOLVED (dismissed): derive-once freezes authorization at page 1 — mid-export authz *reductions* are not enforced until TTL expiry
**Decision**: dismissed per project owner — the ≤1h freeze window on authorization *reductions* is
accepted as by-design and does not warrant a spec note or code change. Token revocation / role-flag clear
still halts an in-flight export immediately (AuthPlug), and the page-1 snapshot is correctly project-scoped
at creation. No change. Original finding retained below for the record.

**Severity: LOW-MED (by design; confirm IRB acceptance).** The endpoint set is derived and snapshotted
at page 1 and re-served from the scratch on every subsequent page; only per-request token validity is
re-checked (AuthPlug) — the authorized-project derivation is NOT re-run. So if a caller's authorization
is REDUCED mid-export (removed from a project) while their API token stays valid, the frozen snapshot
keeps serving the previously-authorized endpoints until the scratch's 1-hour sliding TTL lapses and a
fresh export re-derives. The plan's regression test covers TOKEN revocation / local-flag clear (which
DOES halt via 401), and the plan already notes "a pure Portal-side role change is not reflected" — this
finding asks to state the **TTL as the explicit enforcement bound for authz reductions** and confirm
that bound is acceptable to IRB. **Confirmed sound**: the page-1 snapshot is itself correctly
project-scoped — `LearnerData.fetch` independently re-derives allowed project ids via
`apply_allowed_project_ids_filter` (`report_utils.ex:106-128` → `PortalDbs.get_allowed_project_ids`).

#### RESOLVED: the `requireHeaderBearer` guard is log-hygiene, not an authorization boundary — state it as such
**Severity: informational.** **Verified**: the shared `bearerTokenAuth` accepts the token from query,
then body, then header (`middleware/bearer-token-auth.ts:23-34`), and runs app-level (`api.use`,
`index.ts:35`) BEFORE any per-route guard — so `requireHeaderBearer` runs AFTER it, not instead of it.
It does NOT add an authorization boundary: `bulk_read` inherits the shared-Node-bearer trust model
(possession of the Node bearer ⇒ authorization-blind Firestore read of any endpoint, identical to existing
routes like `get-answer`). No code change; recording so reviewers don't mistake the guard for authz.

**⚠ Correction (F-ext7-3): the earlier "genuinely closes the query/body-bearer log-leak vector" wording
overclaimed.** Because the guard runs *after* `bearerTokenAuth` has already extracted the query/body bearer,
and — more decisively — because the upstream ALB/proxy access log records the request URL *before any Express
middleware runs*, the guard **cannot** un-log a `?bearer=…` that a client already sent. What it *does* achieve:
(a) it rejects query/body bearer for this route (401), forcing header-only usage so a compliant client stops
leaking via URL/body on subsequent calls, and (b) it keeps the token out of app-level *body* logging. True
prevention of URL-logged tokens is a **proxy-layer** concern (don't log query strings). The reviewer's
"register a header-only check *before* the shared middleware" alternative was considered and **not adopted**:
it would move the rejection earlier in Express but would NOT change the access-log outcome (the proxy already
logged the URL), so it adds ordering complexity for no log-hygiene gain. Decision: keep the guard as-is with
the corrected, narrower rationale (above and in the middleware comment).

---

### Data-Integrity / Accuracy (minor Node seam drift)

#### RESOLVED: `firebase.json` location reference in the Node emulator-harness step
**Severity: LOW (cosmetic).** **Verified**: `firebase.json` is at the REPO ROOT, not `functions/firebase.json`
as the harness step's Summary implied (the `emulators.firestore.port = 9090` claim is correct, just at the
root file). Fixed the Summary to say "repo-root `firebase.json`". **On re-check, the getPath half of this
finding was a non-issue and is withdrawn**: `getPath` is `(source_key, type, id?) => Promise<string>`
(`paths.ts:8-9`), and the walker's `await getPath(ep.source, "answers")` maps `ep.source -> source_key`,
`"answers" -> type` correctly — the spec never misdescribes the signature, it only *uses* it, correctly.
No code impact.

---

## Self-Review — Round 3 (multi-role, verification-first, 2026-07-14)

<!-- Third multi-role pass, run after Rounds 1-2 closed. Fresh/under-attacked lenses: Concurrency/OTP
     correctness, Elixir↔Node wire-contract, requirements-coverage traceability, DB/migration, and an
     adversarial re-attack that also confirms every Round-1/2 RESOLVED decision was actually applied to
     the spec body (not merely recorded). Ground truth was re-established against LIVE source via five
     parallel recon passes (Elixir derive path, Elixir audit/concurrency, migrations/DB, Node seam,
     requirements↔implementation coverage), plus a throwaway Elixir run of the proposed SourceKey module
     and a direct read of bearer-token-auth.ts's control flow. Verification method is stated inline. -->

### Verification harness (Round 3)

Re-read live source: Elixir — `reports.ex` (`get_api_report_run/2`), `reports/report_run.ex`,
`types/ecto_report_filter.ex`, `reports/tree.ex`, `reports/athena/learner_data.ex`
(`map_learner_data/2`, `group_learners_by_runnable_url/1`), `shared_queries.ex`, `audit_log.ex`
(`create_entry/1`, `dump_filter/1`, `list_entries_paginated`), `data_access_log_entry.ex` (full schema +
changeset), `repo.ex`; migrations — full `server/priv/repo/migrations/` listing +
`20260713080100_create_data_access_log.exs`; Node — `middleware/bearer-token-auth.ts`,
`middleware/response-methods.ts`, `api/helpers/paths.ts`, `index.ts` (middleware order + `runWith`),
`firebase-client.ts`, root `firebase.json`, `functions/package.json`. Throwaway executions (Elixir 1.16.2 /
OTP 26): a standalone copy of the proposed `SourceKey` module over `{nil, host-only, answersSourceKey
override, offline→online}` inputs.

**Confirmed SOUND (re-attacked, recorded so the review is not just a defect list):**
- **DB/migration surface.** New migration timestamps (`20260714120000/120100`) sort strictly after the
  current latest (`20260713090000`); `on_delete: :nothing` is the house convention (100% of existing FKs,
  including `data_access_log`'s own refs to `users`/`report_runs`); adapter is `Ecto.Adapters.MyXQL`
  (`repo.ex:4`) so `:map`→MySQL `json` and `JSON_CONTAINS`/`JSON_QUOTE` are valid.
  **[SUPERSEDED by External Review Round 3 / F-ext3-1]** This bullet previously claimed the
  `{:array, _}`-schema-over-`:map`-column pattern was "novel but well-supported" — that was WRONG (it was
  reasoned generally, not verified against the adapter source). MyXQL only json-decodes `:map`/`{:map, _}`
  loaders, so a bare `{:array, _}` field fails to load; the JSON array now goes through the `EctoJsonArray`
  custom type instead. Lesson: verify adapter round-trip against the driver source, not by analogy.
- **Elixir↔Node wire contract.** `getPath` is `(source_key, type, id?) => Promise<string>` with a
  **leading-slash** result, and the walker `await`s it (`paths.ts:8-10`); `res.success(obj)` mutates to
  `{...obj, success: true}` and `res.error(s,m)` → `{success: false, error: m}`
  (`response-methods.ts:5-19`), both matched correctly by `bulk_read/1`; the single
  `runWith({secrets:[bearerToken]})` wraps every `api.*` route so `timeoutSeconds: 300` applies to all of
  them (already called out in the deploy note, `index.ts:64-71`). All wire field names agree.
- **Round-1/2 RESOLVED decisions were actually applied**, not just logged: FK-constraint lines preserved in
  the changeset before/after; `report_utils.ex` dropped from the seams step's Files-affected; the
  `list_to_in([]) -> "()"` comment; repo-root `firebase.json`; the `npm test` ignore pattern; the `<.input>`
  built-in-label idiom; the `hitItemCap` mid-batch guard; the exported `readAnswersEndpoint`/
  `readHistoryEndpoint`.
- **Requirements coverage is complete.** Every requirement and all 21 acceptance scenarios trace to a step;
  no orphan steps. (Two named requirements lack a *named* test — see P2 below.)

---

### Firestore / Data-Integrity Engineer

#### RESOLVED: a nil / non-binary `runnable_url` crashes the whole page-1 derive (500), where the report's own SQL tolerates it
**Decision (a — skip the learner)**: `to_endpoints/1` drops any learner whose usable `source` can't be
derived, so they contribute no endpoints instead of 500-ing the whole export, and no malformed `source` ever
lands in the persisted scratch/audit set. **⚠ Corrected by External Review Round 6 (F-ext6-1):** the first cut
filtered the *input* `is_binary(runnable_url)`, which still let a binary-but-hostless url (`"foo"` → `nil`,
`"https://"` → `""`) persist a `nil`/`""` `source`. Now `to_endpoints/1` maps through a total `derive_source/1`
(non-binary → nil, no `FunctionClauseError`) and filters on the DERIVED source (`is_binary(source) and source
!= ""`). Slice-step test covers a `nil` url AND a binary-malformed `"foo"`. Original finding retained below.

**Severity: LOW-MED.** **Verified** (throwaway Elixir run of the proposed module): `SourceKey.from_runnable_url/1`
has only a `when is_binary(runnable_url)` head, so `from_runnable_url(nil)` raises `FunctionClauseError`.
`to_endpoints/1` maps `l.runnable_url` with no guard, and `runnable_url` originates from
`external_activities.url` via an inner join with **no COALESCE** (`learner_data.ex:41`). The report's own
Athena SQL wraps the same derivation in `COALESCE(...)` (`shared_queries.ex:431-436`) and silently yields
NULL; the Elixir port instead **500s the entire export for every learner** on a single stray NULL — the
exact "silent/blast-radius" failure mode an IRB/completeness audit can't see (here it's loud-but-total
rather than silent-but-partial).

**Why it matters / likelihood**: effectively unreachable in normal operation — the rest of the pipeline
already assumes a binary `runnable_url` (e.g. `resource_data.ex` calls `URI.parse(runnable_url)` with no
nil handling), so a real NULL would already be breaking other paths. But the derive path has no
per-learner isolation: one bad row fails the whole page rather than that learner.

**Suggested resolution**: add a total fallback clause `def from_runnable_url(_), do: nil` (matching the
SQL's NULL-tolerance), OR filter nil-`runnable_url` learners in `to_endpoints/1`, and pin the intended
semantics (skip the learner vs. emit a nil `source` — note a nil `source` makes Node's `getPath(nil, …)`
build `"/sources//answers"`, which returns empty, i.e. a silently-skipped learner). Add a unit scenario
covering a learner with a nil `runnable_url`.

---

### Concurrency / OTP Correctness Engineer

#### RESOLVED: `merge_touched_endpoints/2` makes a non-essential tuple-cache write fatal to a successful page
**Decision**: made the merge fail-OPEN — the hard `{:ok, scratch} = Repo.update(...)` match is now a `case`
that logs and returns the un-updated scratch on `{:error, _}`, so a cache-write hiccup can never fail an
already-successful page. Added `require Logger` to the `Exports` context. This is the ONLY fail-open write in
the story; every audit write stays fail-closed. Original finding retained below.

**Severity: LOW-MED.** **Verified** against the proposed `Exports.merge_touched_endpoints/2` (Persistence
step) and `serve_page/…` (slice step). The merge ends with a hard match:
```elixir
{:ok, scratch} = scratch |> Ecto.Changeset.change(endpoint_set: updated) |> Repo.update()
```
`Repo.update/1` can return `{:error, changeset}` (transient DB failure, stale row), which makes this a
`MatchError` → uncaught → 500. But the tuple cache is a **pure optimization**: Node re-derives the LTI
tuple whenever `lti_tuple` is nil (the `answers … limit 1` read in `readHistoryEndpoint`). So a cache-write
failure should cost at most a redundant re-derive on the next page — yet as written it discards an
already-successful Firestore read and returns 500 (and the per-page audit access row, written *after* the
merge, never runs). `serve_page/…` has no rescue around the merge call.

**Suggested resolution**: make the merge tolerant so a cache-write failure never fails a good page:
```elixir
case scratch |> Ecto.Changeset.change(endpoint_set: updated) |> Repo.update() do
  {:ok, s} -> s
  {:error, _cs} -> Logger.warning("tuple-cache merge failed; will re-derive next page"); scratch
end
```
(Fail-*open* is correct **only** here — this is a cache, not the audit trail; the audit writes stay
fail-closed.)

#### RESOLVED: no dedup of concurrent same-export requests (lost-update on cache; duplicate page-1 rows)
**Decision**: document, don't re-engineer. Added a "Concurrency note (F3)" blockquote to the Persistence step
stating the tuple cache is last-writer-wins by design (safe because re-derivable) and that concurrent
page-1s yield independent `export_id`s (per-`export_id` retry-distinguishability). No code change; strict
page-1 dedup (natural-key unique index + upsert) is explicitly out of scope. Original finding retained below.

**Severity: LOW (informational; partly by-design).** **Verified**: no optimistic-lock / version column
exists anywhere (`grep optimistic_lock|lock_version` → 0 hits), and the only proposed unique index is on
`scratch_id` alone — there is no natural-key constraint on `(user_id, report_run_id, data_type)`. Two
consequences:
1. **Concurrent same-token pages** each read the scratch, compute `endpoint_set` from their own snapshot,
   and overwrite the whole array — a classic lost update. **Benign**: the only mutated field is the
   nil-fill tuple cache, re-derived on demand; no wrong data, at worst a redundant derive. (The absolute
   TTL `bump_ttl` `SET` is already idempotent under the same race — confirmed.)
2. **Concurrent page-1s** for one `(user, report_run)` each mint a distinct `scratch_id` and write a
   distinct `export_scoped` **intent audit row**, so one logical export can appear as two intent rows with
   two `export_id`s. Consistent with the story's documented at-least-once philosophy, but worth an explicit
   note for IRB/audit reconstruction (the retry-distinguishability guarantee is per-`export_id`, and a
   concurrent — not sequential — page-1 produces a *second* export_id rather than a retry of the first).

**Suggested resolution**: no code change required; add a one-line note to the "Server-side scratch" /
audit reasoning stating (a) the tuple cache is last-writer-wins by design (safe because re-derivable) and
(b) concurrent page-1s yield independent exports/`export_id`s. Only if strict page-1 dedup is ever wanted
would a natural-key unique index + upsert be needed — explicitly out of scope now.

---

### QA / Security-Hygiene Engineer

#### RESOLVED: the header-only-bearer unit test over-claims vs. the real two-layer pipeline (400 vs 401)
**Decision**: annotated the pure `require-header-bearer.test.ts` as testing the guard IN ISOLATION, and added
a two-middleware integration test (chaining `bearerTokenAuth` then `requireHeaderBearer` over a mock
`req`/`res`, no supertest) proving array-alone → 400, array+valid-header → 401, header-only → handler — the
400-vs-401 layering the requirement enumerates. Original finding retained below.

**Severity: LOW.** **Verified** against `bearer-token-auth.ts:23-39` (runs app-wide via `api.use`, *before*
`requireHeaderBearer`) and the guard. The shared middleware only accepts a **string** query bearer
(`typeof req.query.bearer === "string"`, line 23); a body bearer is accepted untyped (line 26). Tracing the
full pipeline per input form:
- scalar `?bearer=TOKEN` (valid) → shared middleware authenticates via query → guard sees `query.bearer` → **401** ✓
- array `?bearer[0]=TOKEN` / object `?bearer[x]=TOKEN` **alone** → not a string, no body, no header → shared
  middleware **400** ("No bearer found"), *guard never runs*
- array/object query bearer **+ valid `Authorization` header** → middleware auths via header → guard sees
  `query.bearer` → **401**
- scalar `body.bearer` (valid) → middleware auths via body → guard → **401**; array `body.bearer` →
  middleware sets it, `!== serverToken` → **401** (from the middleware, not the guard)
- header-only → allowed ✓

So the planned `require-header-bearer.test.ts` assertion ("401 for the first four query/body forms,
`next()` for header-only") is correct **for the guard in isolation** but does not reflect — and the plan
does not note — that array/object bearers *alone* are **400 from the shared middleware**, and the guard's
**401** for those forms only manifests when a valid header co-exists. The requirement enumerates this
400-vs-401 layering explicitly. No security hole (the token is rejected either way; the query-string
log-leak, if any, happens at the proxy access-log before any middleware regardless of status).

**Suggested resolution**: keep the fast in-isolation unit test but annotate it as such, and add one
integration-level assertion through both middlewares proving: array-bearer-alone → **400**;
array-bearer + valid header → **401**; header-only → handler.

---

### Product / Coverage Reviewer

#### RESOLVED: two named requirements lack a named test scenario
**Decision**: added a `teacher-actions`-run slice-step test (derives a non-empty endpoint set via stubbed
`LearnerData.fetch`), and the header-bearer 400-vs-401 layering is now covered by the integration test added
in the QA finding above. Original finding retained below.

**Severity: LOW.** **Verified** by the requirements↔implementation coverage cross-check (every requirement
and all 21 acceptance scenarios otherwise trace to a step). Two named requirements are architecturally
covered but have no dedicated scenario:
- **`teacher-actions`-type run** (requirements "Elixir bulk endpoints", lines ~178-187): the design is
  filter-derived with no run-type allowlist, so it "falls out," but no test exercises a `teacher-actions`
  run specifically.
- **Header-only bearer 400-vs-401 layering** (overlaps the QA finding above).

**Suggested resolution**: add a one-line test each — a `teacher-actions` run derives a non-empty endpoint
set (stubbed `LearnerData`), and the integration bearer assertion from the QA finding.

---

## External Review (Round 1) — 2026-07-14

<!-- First EXTERNAL review of the implementation spec (requirements.md had 4 external rounds; this doc had 0).
     Four findings; each was re-verified against LIVE source before applying. All applied. -->

### RESOLVED [HIGH]: production default bulk client resolved to the wrong module
**Finding**: `report_service/0` defaulted to the unqualified `ReportService`, which the controller never
aliases — so with `:report_service_client` unset (production), it resolves to the nonexistent
`Elixir.ReportService` and `report_service().bulk_read/1` fails; tests set the stub and miss this path.
**Verified**: real module is `ReportServer.ReportService` (`report_service.ex:1`); the controller aliases
`ReportServer.{AuditLog, Exports, PortalDbs, Reports}` (+ `Reports.{ReportFilter, SourceKey}`) but **not**
`ReportService`; STORY 1's `report_controller.ex` doesn't reference it either. Confirmed real.
**Decision**: fully-qualified the default to `ReportServer.ReportService` in both the `report_service/0`
accessor and the seam-accessor doc line. Adjusted the reviewer's test suggestion (an env-unset test would
call the real Node) to a feasible guard: assert `Code.ensure_loaded?(ReportServer.ReportService)` and
`function_exported?(…, :bulk_read, 1)`, so a mistyped default can't ship green.

### RESOLVED [HIGH]: bulk `parse_id/1` dropped STORY 1's max-bigint guard
**Finding**: the local `parse_id/1` accepted any positive integer; STORY 1's rejects `id > @max_bigint`.
A huge id passes parsing, is bound into `get_api_report_run/2` (only `is_integer`-guarded), and can trigger
a MySQL out-of-range error → 500 instead of the required indistinguishable 404.
**Verified**: `ReportServerWeb.Api.V1.Params.parse_id/1` guards `id > 0 and id <= @max_bigint`
(`params.ex:4,42-49`); the local copy guarded only `id > 0`; `Reports.get_api_report_run/2` guards only
`is_integer(id)` (`reports.ex:91-99`). Requirement: malformed `:id` must 404 (`requirements.md:102-107`).
Confirmed real.
**Decision**: dropped the redundant local `parse_id/1` and reuse `Params.parse_id/1` directly (same
`{:ok, id} | {:error, :not_found}` shape) — restores the `@max_bigint` guard AND removes the duplication
that caused the drift. Added an out-of-bigint-range `:id` → 404 test.

### RESOLVED [MEDIUM]: `@max_limit 2000` vs the ~500 response-size rationale
**Finding**: requirements say `limit` "only lowers" the ~500 cap, but the parser allowed 2000 (4×),
undermining the per-call sizing.
**Verified/adjudicated**: the strict "contract violation" framing is imprecise — requirements 209 / ~712
pin `@max_limit ≥ 500` (a floor) and "only lowers" means a caller can't exceed the *server max*, so 2000 is
contract-*permitted*. **But** the underlying concern is real: the ~500 figure was chosen to keep a page's
JSON "a few MB under the 10 MB gen1 response cap," and there is **no response-byte guard** anywhere
(`read_limit` bounds doc reads, not response bytes). A `limit=2000` answers page of large `report_state`
docs could exceed the 10 MB cap and fail the whole page.
**Decision (a — lower to 500)**: set `@max_limit 500` (server cap == default; still satisfies
`@max_limit ≥ 500`; simplest, honors the response-size rationale exactly). Documented that raising it later
must be paired with a response-size check. Updated all `max 2000` references (parser, pinned-decisions
bullet, RESOLVED Open Question).

### RESOLVED [MEDIUM]: audit-log focus management inconsistent + missing JS-hook file
**Finding**: the `handle_params` snippet pushed a focus event on *every* params change (incl. paging),
contradicting the RESOLVED decision (focus only when a `data-refocus` token bumped on filter change) and
requirements 605-607 (pager keeps focus on the activated control); and `server/assets/js/app.ts` (where the
`FocusResults` hook must be registered) was absent from "Files affected".
**Verified**: `app.ts:32` `const Hooks = {…}` has `CopyToClipboard` but no `FocusResults` (`app.ts:139`
`hooks: Hooks`); the audit-log step's Files-affected omitted `app.ts`; the `handle_params` AFTER called
`push_focus_to_results()` unconditionally. Confirmed real (both parts).
**Decision**: (1) added `server/assets/js/app.ts` to Files-affected and provided the `FocusResults` hook
(`updated()` focuses only when `data-refocus` changes); (2) removed the unconditional focus push from
`handle_params`, added a filter-derived `refocus_token/1` and a `data-refocus={refocus_token(@filters)}`
attribute on `#audit-results` so the token changes on filter submit but not on paging; (3) pinned the
mechanism in prose (hook, not `push_event`; `aria-live` still announces paging); (4) added an HTML-level
test that `data-refocus` changes across a filter submit and is unchanged across paging.

---

## External Review (Round 2) — 2026-07-14

<!-- Second external pass, on the Round-1-updated doc. Three findings, all about step-sequencing /
     forward-dependency consistency (does each independently-reviewable commit actually stand alone?).
     Each verified against live source before applying. All applied. -->

### RESOLVED [HIGH]: vertical slice used `EXPIRED_CURSOR` before the code was registered (forward dependency)
**Finding**: the validation-milestone controller calls `ErrorHelpers.render_error(conn, "EXPIRED_CURSOR", …)`
and its slice tests expect 410, but the plan added `"EXPIRED_CURSOR" => 410` only in the *following*
build-out step — so the slice commit would raise instead of returning 410, breaking the "each `###` step is
independently reviewable, no forward dependencies" invariant.
**Verified**: `error_helpers.ex` has no `EXPIRED_CURSOR` entry, and `render_error/4` does
`put_status(Map.fetch!(@statuses, code))` (`error_helpers.ex:23`) — `Map.fetch!` **raises `KeyError`** on an
unregistered code (→ 500, not 410). Confirmed real, HIGH.
**Decision (reviewer option a)**: moved the `EXPIRED_CURSOR → 410` `@statuses` edit *into* the vertical-slice
step (added `error_helpers.ex` to that step's Files-affected + the before/after block + a note on the
`Map.fetch!` hazard), and removed it from build-out (summary, Files-affected, before/after block, and the
now-redundant build-out test — folded the body-assertion into the slice's `EXPIRED_CURSOR` test). The slice
is now self-contained: its `:expired` path and its 410 test both work within the one commit.

### RESOLVED [LOW]: Persistence file list misattributed `create_scratch_with_intent/2` to `audit_log.ex`
**Finding**: the "Files affected" list said `audit_log.ex` should add `create_scratch_with_intent/2`, but the
proposed code correctly defines it in `ReportServer.Exports`, and the AuditLog section says to "add nothing
else here" (only make `dump_filter/1` public). An implementer following the file list could put the Multi in
the wrong context or duplicate it.
**Verified**: proposed `create_scratch_with_intent/2` is in the `exports.ex` block; `audit_log.ex` currently
has `create_entry/1` + private `dump_filter/1`. Confirmed real, LOW.
**Decision**: reworded the `audit_log.ex` file-list entry to "make `dump_filter/1` public — one-liner;
`create_scratch_with_intent/2` lives in `Exports`, NOT here." (`exports.ex` already lists it as the new
context.)

### RESOLVED [LOW]: cache-control step ownership was contradictory
**Finding**: the vertical-slice summary said `Cache-Control` lands "in the next step," but the slice code
already defines/calls `put_no_store/1` and the slice tests already assert `Cache-Control: no-store`; the
build-out step's file list includes no cache-control work.
**Verified**: the slice controller calls `put_no_store(conn)` and defines `put_no_store/1`; a slice test
asserts the header. Confirmed real, LOW.
**Decision**: rewrote the vertical-slice summary to state that `Cache-Control: no-store` **and** the
`EXPIRED_CURSOR` code are added in THIS (slice) step (both part of the resumability contract the milestone
validates), and that only `/history` + the per-page **access** audit row land in the next step (the page-1
**intent** row is already written in the slice, atomically with the scratch).

---

## External Review (Round 3) — 2026-07-14

<!-- Third external pass. One HIGH — a persistence-layer round-trip bug that BOTH a prior self-review round
     AND the first ground-truth DB agent had wrongly blessed as "sound" by analogy rather than adapter-source
     verification. Verified against the actual ecto_sql MyXQL adapter before applying. -->

### RESOLVED [HIGH]: MyXQL does not round-trip bare `{:array, _}` schema fields over a `json` column
**Finding**: the plan declared `ExportScratch.endpoint_set` as `{:array, :map}` and retyped
`data_access_log.endpoint_set` to `{:array, :string}`, but `Ecto.Adapters.MyXQL` wires JSON decode only for
`:map`/`{:map, _}`; MySQL has no array type. So the scratch-create and audit read/write paths would fail at
runtime.
**Verified (adapter source, not by analogy)**:
- `myxql.ex:153-158` — `loaders/2` prepends `json_decode` only for `{:map, _}` and `:map`; `{:array, _}` hits
  `loaders(_, type) -> [type]` with NO decode. MySQL returns a `json` column as a raw string, so a
  `{:array, _}` field hands a binary to Ecto's array loader → **hard load error on READ**.
- `myxql.ex` does not override `dumpers`; base `sql.ex:153` `dumpers(_, type) -> [type]` yields a plain list,
  which MyXQL JSON-encodes on the wire → **writes actually succeed**.
- `connection.ex:1530` `ecto_to_db({:array,_}) -> error! "Array type is not supported by MySQL"` fires only for
  a MIGRATION column typed `{:array,_}`; the plan's migrations use `:map`, so the **DDL half of the finding is a
  misfire** — migrations are fine.
- Net: writes succeed, **reads crash** — breaking `fetch_for_page` (page-N resume) and the audit-log admin
  display. Confirmed real, HIGH.
**Decision**: introduced a custom `ReportServer.Types.EctoJsonArray` (`type/0 == :map` so MyXQL's `:map` loader
prepends `json_decode`; list-shaped `cast/load/dump`), mirroring the repo's existing `EctoReportFilter`
precedent. Both `endpoint_set` fields now use it; migration columns stay `:map`; the stored value remains a
top-level JSON array, so the audit `JSON_CONTAINS(…, JSON_QUOTE(?))` pathless filter is unchanged. Added the
type module to Files-affected and an `endpoint_set` **DB round-trip** regression test (write → read-back →
compare) to both `exports_test.exs` and `audit_log_test.exs`.
**Process note**: this bug had been marked "confirmed sound" in Self-Review Round 3's DB bullet and by the
first ground-truth DB pass — both reasoned "Ecto dual-layer typing is well-supported" by analogy instead of
reading the adapter loaders. Both claims are now corrected in place (marked SUPERSEDED). Lesson carried
forward: verify adapter round-trip against the driver source, never by analogy. (Note: `requirements.md`'s
"Server-side scratch" section carries the same `{:array, :map}` phrasing and should get the same correction in
its next external round.)

---

## External Review (Round 4) — 2026-07-14

<!-- Fourth external pass. Two MEDIUM "apply-as-written breaks" — one test-infra (sandbox), one a missing
     template helper. Both verified against live code before applying. -->

### RESOLVED [MEDIUM]: `SweepServer` would hit the local Repo outside the `:manual` SQL sandbox in tests
**Finding**: the plan adds `SweepServer` to the app children unconditionally, and its
`handle_continue(:boot_sweep, …)` immediately calls `Exports.sweep_expired()` (`Repo.delete_all`). Under the
`:manual` sandbox, a boot/interval sweep from an unowned supervised process raises `DBConnection.OwnershipError`
and can restart-loop `mix test`.
**Verified**: sandbox is `:manual` (`test_helper.exs:2`), `config/test.exs` uses `pool:
Ecto.Adapters.SQL.Sandbox`. The precedent `StatsServer` is added unconditionally too, **but it queries
`PortalDbs` (`stats_server.ex:101,104`), NOT the sandboxed `ReportServer.Repo`** — so it is not a safe
precedent for touching the Repo at boot. `StatsServer` also already carries a `disabled?/0` gate driven by
`config :report_server, :stats_server, disable: …` (`runtime.exs:58`). Confirmed real, MEDIUM.
**Decision**: mirror `StatsServer` exactly — added `SweepServer.disabled?/0`
(`Application.get_env(:report_server, :exports_sweep)[:disable]`), gated `init/1` to start thin/inert (no
`{:continue, :boot_sweep}`, no interval) when disabled, and added a `runtime.exs` `:exports_sweep` config
defaulting **disabled in `:test`** (env-overridable, like `DISABLE_STATS_SERVER`). Sweep tests seed after the
`DataCase` checkout and call `Exports.sweep_expired/0` directly (or start an instance and `Sandbox.allow` it).
Added `config/runtime.exs` to the step's Files-affected.

### RESOLVED [MEDIUM]: audit-log template called an undefined `filter_suffix/1`
**Finding**: the result-summary `<div>` and the table `<caption>` both call `filter_suffix(@filters)`, but the
LiveView snippet defined only `refocus_token/1` and `filter_path/2` (and current `AuditLogLive.Index` has no
such helper) — applying as written leaves an undefined helper and fails compile/render.
**Verified**: grep of the plan found two `filter_suffix(@filters)` call sites and zero definitions. Confirmed
real, MEDIUM.
**Decision**: added a concrete `defp filter_suffix/1` to the LiveView step — returns `""` when no filter is
active (base text unchanged) and `" (filtered by export id \"…\" and student \"…\")"` otherwise; it renders in
both the `aria-live` summary and the `sr-only` caption. (Co-located HEEx compiles into the LiveView module, so
a `defp` helper is callable from the template.)

---

## External Review (Round 5) — 2026-07-14

<!-- Fifth external pass. One MEDIUM (error-handling gap in the permission short-circuit) + one LOW (Node
     boundary validation). Both verified through the live multi-hop call chain before applying. -->

### RESOLVED [MEDIUM]: portal permission-query error swallowed, then crashes deep in the query builder
**Finding**: `derive_endpoint_set/2` handles `:none` / `[]` / `_allowed`, but `get_allowed_project_ids/1` can
return `{:error, reason}` on a portal query failure; the `_allowed` catch-all swallows it, `LearnerData.fetch`
re-derives the same failing lookup, and `list_to_in({:error,_})` raises instead of the planned controlled
`SERVER_ERROR`.
**Verified (full chain, live source)**: `get_project_ids/2` returns `error -> error` from `query/3`
(`portal_dbs.ex:149-159`), so `get_allowed_project_ids/1` can yield `{:error, reason}` for a
project-admin/researcher; `apply_allowed_project_ids_filter/5` (`report_utils.ex`) re-calls
`get_allowed_project_ids`, special-cases only `:all`, else `list_to_in(allowed_project_ids)`; and
`list_to_in({:error,_})` hits the `Enum.map` clause → **`Protocol.UndefinedError` (Enumerable not implemented
for a tuple)** — an uncaught crash. Confirmed real, MEDIUM.
**Decision**: added an explicit `{:error, _reason} = err -> err` branch to `derive_endpoint_set/2` (before the
`_allowed` catch-all) so `first_page` maps it to a controlled `SERVER_ERROR`; `LearnerData.fetch` is never
reached on a first-lookup failure. Added a controller test (stub returns `{:error, reason}` → 500, no
`LearnerData.fetch`, no scratch/intent). Noted as out-of-scope: the residual raise-window if the SECOND
(internal) lookup inside `LearnerData.fetch` fails is pre-existing shared-code behavior the normal report path
also has — not introduced or fixed by STORY 3.

### RESOLVED [LOW]: Node route could return a no-progress page for malformed direct input (`limit: 0`)
**Finding**: `bulkRead` validated only `read_limit >= 1`, not `limit`/`endpoint_limit`; `limit: 0` →
`readAnswersEndpoint` `cap === 0` → returns `{items:[], innerCursor: start, exhausted:false}`, a same-position
page that violates the forward-progress invariant. Elixir clamps `limit >= 1`, but the Node route is
authorization-blind and internet-reachable behind the shared static bearer, so a malformed direct call (or a
future Elixir regression) could hit it.
**Verified**: `bulkRead` checks only `collection`, `source_endpoints`, `read_limit`; `readAnswersEndpoint` uses
`cap = Math.max(0, Math.min(remItems, remReads))` and returns no-progress at `cap === 0`. Confirmed real, LOW.
**Decision**: validate all three caps at the Node boundary — `Number.isInteger(v) && v >= 1` for `limit`,
`endpoint_limit`, `read_limit` — returning `res.error(400, "… must be an integer >= 1")` before either walker.
Added a pure `bulk-read.test.ts` boundary test (mock `req`/`res`, no Firestore).

---

## External Review (Round 6) — 2026-07-14

<!-- Sixth external pass. Two MEDIUM — one a genuine gap in an EARLIER fix (F1), one a test-coverage-integrity
     issue. Both verified (F-ext6-1 via a throwaway SourceKey run) before applying. -->

### RESOLVED [MEDIUM]: F1's fix guarded the input url, not the derived source — a binary malformed url still persists a nil/"" source
**Finding**: the F1 (Round 3) fix filtered `is_binary(runnable_url)`, but a binary url with no host and no
`answersSourceKey` still derives `source = nil` (and `"https://"` → `""`), which persists as `"source" => nil`
in the scratch — contradicting F1's own "no malformed `source` ever lands" goal and silently querying the wrong
Firestore path.
**Verified (throwaway `SourceKey` run)**: `"foo"` → `nil`, `"/relative/path"` → `nil`, `""` → `nil`,
`"https://"` → `""`. Confirmed real, MEDIUM — a genuine gap in my earlier F1 fix (guarded the wrong end).
**Decision**: restructured `to_endpoints/1` to derive the source via a total `derive_source/1` (non-binary →
`nil`, no `FunctionClauseError`) and then **filter on the DERIVED source** (`is_binary(source) and source !=
""`), which subsumes the input guard and keeps any `nil`/`""` source out of the persisted scratch/audit set.
Extended the slice-step test to cover a binary-malformed `"foo"` in addition to a `nil` url. Corrected the F1
decision note and the malformed-url test scenario in place.

### RESOLVED [MEDIUM]: real-data source-fidelity check was listed inside the stubbed controller suite
**Finding**: the "Source-fidelity on real data (validation-milestone gate)" scenario sat under "Tests (slice
scenarios, **using the stubs**)", but a real-data assertion can't run in a hermetic stubbed setup — risking a
false coverage claim where green stubbed CI reads as "real-data fidelity verified."
**Verified**: the bullet asserted the derived `source` equals the Firestore `sources/{source}` where a known
learner's answers actually live — inherently live-data. Confirmed real, MEDIUM.
**Decision**: split it. (1) A *stubbed* controller test asserts the derived `source` reaches Node (captured via
`ReportServiceStub.req.source_endpoints`) — hermetic mechanics. (2) The *real-data* assertion moved to the
deploy checklist as an **env-gated live step** with explicit run-id/endpoint identifiers and PASS/FAIL/skip
behavior, so it can't be silently skipped. Updated the SourceKey RESOLVED decision note to reflect the split.

---

## External Review (Round 7) — 2026-07-14

<!-- Seventh external pass. A HIGH reappeared (out-of-range Timestamp seconds -> 500), plus two MEDIUM and a
     LOW. All verified against live code / a throwaway `new Timestamp` run before applying. -->

### RESOLVED [HIGH]: out-of-range history cursor `seconds` throws an uncaught 500
**Finding**: cursor validation bounds `nanoseconds` but not `seconds`; a tampered `/history` page_token with an
integer-but-out-of-range `seconds` passes both Elixir and Node validation, then `new Timestamp(seconds, _)`
throws a RangeError → uncaught 500, violating the "a bad cursor must never throw a 500" contract.
**Verified (throwaway `new Timestamp` run)**: valid seconds ∈ `[-62135596800, 253402300799]`;
`new Timestamp(253402300800, 0)` and `new Timestamp(-62135596801, 0)` throw. `BulkParams.validate_inner_cursor/2`
and `validateHistoryCursor`/`reconstructTimestamp` all checked only `is_integer`/`isInt` on `seconds`. Confirmed
real, HIGH.
**Decision**: added the Firestore `seconds` bounds to **all three** guards — `@ts_min_seconds`/`@ts_max_seconds`
in `BulkParams` (in the `validate_inner_cursor/2` history guard), and a shared `isValidTsSeconds` used by both
`reconstructTimestamp` and `validateHistoryCursor` — so an out-of-range `seconds` returns
`BAD_REQUEST`/`badRequest` (400) at the Elixir edge and, defense-in-depth, in Node, before any `Timestamp` is
constructed. Added too-low/too-high `seconds` tests through the Elixir `/history` path and the Node cursor
helper (in-range boundary values pass).

### RESOLVED [MEDIUM]: `source_endpoints` validated only as an array, not the endpoint objects
**Finding**: `bulkRead` checked only `Array.isArray(source_endpoints)`; a direct bearer call with
`source_endpoints: [{}]` reaches `where("remote_endpoint","==",undefined)`, which the Firestore SDK throws on →
generic 500. Malformed endpoint entries should be controlled 400s, matching the caps/cursor boundary posture.
**Verified**: handler checks only the array; `readAnswersEndpoint`/`readHistoryEndpoint` pass `ep.source` /
`ep.remote_endpoint` straight into Firestore. Confirmed real, MEDIUM.
**Decision**: validate every endpoint object at the Node boundary — `source` and `remote_endpoint` non-empty
strings; `lti_tuple` null/absent or all-string `{platform_id, platform_user_id, resource_link_id}` — returning
400 before any walk. Extended the pure `bulk-read.test.ts` boundary suite (`[{}]`, missing/empty fields,
incomplete tuple).

### RESOLVED [MEDIUM]: `requireHeaderBearer` overclaimed its log-hygiene guarantee
**Finding**: the guard runs after `bearerTokenAuth` has already extracted query/body bearer, and the upstream
proxy access log records the URL before any Express middleware — so the guard cannot deliver the stated
"cannot slip the token into access logs" for a `?bearer=…`.
**Verified**: `api.use(bearerTokenAuth)` precedes the route (`index.ts:35`), and it extracts `req.query.bearer`
/ `req.body.bearer` before the header (`bearer-token-auth.ts:23-27`). Confirmed real (doc-accuracy), MEDIUM.
**Decision**: corrected the overclaim in both the middleware comment and the prior Security-Engineer RESOLVED
note. Accurate scope: the guard ENFORCES header-only usage for this route (401 on query/body bearer), stopping
future URL/body leaks by compliant clients and keeping the token out of app-level *body* logs — but it cannot
scrub a query param the proxy already logged; that's a proxy-layer concern (don't log query strings). The
"register before the shared middleware" alternative was considered and **not adopted** (moves the rejection
earlier but doesn't change the access-log outcome — no log-hygiene gain for added complexity).

### RESOLVED [LOW]: SweepServer test guidance conflicted with the named supervised singleton
**Finding**: the F-ext4-1 test note said a test could "start its own instance and `Sandbox.allow` it," but
`start_link/1` uses `name: __MODULE__` and the disabled supervised instance keeps that name — a second
`start_link([])` returns `{:error, {:already_started, pid}}`.
**Verified**: `start_link(_opts)` hardcoded `name: __MODULE__`; disabled mode still leaves the named process
running. Confirmed real, LOW.
**Decision**: made `:name` injectable (`start_link(opts)` → `Keyword.get(opts, :name, __MODULE__)`) and rewrote
the test note — primary coverage is `Exports.sweep_expired/0` directly; a test that wants the running GenServer
starts it under a DIFFERENT name (`name: :sweep_test`), `Sandbox.allow`s that pid, and drives it with a manual
`send(pid, :sweep)` (avoiding the boot-sweep/allow race).

---

## Internal Review — Adversarial Input Sweep (2026-07-14)

<!-- INTERNAL (not external) round, run to backfill the untrusted-input boundary theme that External Rounds
     5 & 7 kept surfacing HIGH/MED findings on, after external review was exhausted. Method: enumerate every
     client/direct-bearer-controlled input and hunt for a synchronous throw or unbounded work that slips past
     the current validators. Each candidate was verified with a throwaway `firebase-admin` run (query-building
     validation is synchronous, no emulator needed) before applying. -->

### RESOLVED [MEDIUM]: cursor `docId` — empty or containing "/" throws synchronously → 500 (AI-1)
**Verified (throwaway `firebase-admin` run)**: `orderBy(documentId()).startAfter("a/b")` throws ("the
corresponding value ... must be a document ID"), and `startAfter("")` throws ("Only a direct child can be used
as a query boundary"); history `startAfter(ts, "a/b")` throws the same. Both validators accepted these: Elixir
`validate_inner_cursor` guarded only `is_binary(d)`, Node `validate*Cursor` only `typeof docId === "string"`.
A tampered `page_token` therefore reached the walker → uncaught 500 — the same F-ext7-1 class.
**Decision**: require a PLAIN document id (non-empty, no "/") in BOTH layers — Elixir via a `check_doc_id/1`
helper used by both the answers and history `validate_inner_cursor` clauses (the client-facing 400 gate), and
Node via a shared `isPlainDocId` in `validateAnswersCursor`/`validateHistoryCursor` (defense-in-depth). Added
too-slash/empty `docId` tests through the Elixir `/answers` + `/history` path and the Node cursor helper.

### RESOLVED [MEDIUM]: `source` containing "/" breaks the collection-path arity → 500 (AI-2)
**Verified (throwaway run)**: `db.collection("/sources/a/b/answers")` throws ("collectionPath must point to a
collection") — a `source` with a "/" makes `getPath`/`getCollection` build an even-segment (document) path.
Reachable two ways: a direct bearer call with `source:"a/b"`, and a *legitimate* run whose `runnable_url`
carries `?answersSourceKey=a/b` (the derived source then contains "/"). Both → uncaught 500. `remote_endpoint`
is only a query VALUE, so a slash there is harmless — only `source` (a path segment) matters.
**Decision**: reject `source` containing "/" at the Node boundary (extended the F-ext7-2 endpoint-object
guard), and drop such endpoints in Elixir `to_endpoints/1` (extended the F-ext6-1 derived-source filter to
`... and not String.contains?(source, "/")`), so a slash source never lands in the scratch/audit set. Added a
Node boundary test (`source:"a/b"` → 400) and extended the malformed-url controller test.

### RESOLVED [LOW]: Node caps had no upper bound → unbounded work for a direct/leaked-bearer call (AI-3)
**Verified**: after F-ext5-2, `limit`/`endpoint_limit`/`read_limit` were validated `>= 1` but not capped; a
direct bearer call with `read_limit: 1e9` would drive unbounded Firestore reads until the ~300 s timeout.
Elixir always sends fixed 500/250/5000, and the bearer holder is trusted (possession already grants
authorization-blind reads), so this is defense-in-depth, LOW.
**Decision**: added generous per-cap maxima at the Node boundary (`limit ≤ 2000`, `endpoint_limit ≤ 10000`,
`read_limit ≤ 100000` — well above Elixir's fixed values, so tuning is never rejected) returning 400 on
exceed. Extended the boundary test.

**Swept and confirmed SOUND (no change):** `endpoint_index` upper bound (a huge `i` is caught by the
`idx >= length(endpoint_set)` bounds check → 400); `page_token` base64/JSON/`"c"`-type confusion (a non-map
`inner_cursor` falls to `validate_inner_cursor(_, _)` → 400); `:id` out-of-bigint (F-ext2 `@max_bigint`);
`report_run_id`/`limit` parsing; `render_error`'s `Map.fetch!` (code is always a hardcoded constant, never
client-derived); `chunkedGetAll` (only called with a non-empty ref list). No other client-reachable
synchronous-throw or unbounded-work path was found.

---

## Self-Review — Attachment endpoint (added after all prior internal + external review rounds, 2026-07-15)

<!-- Scoped to the "Attachment download endpoint" build step + its requirements/Overview, which were added
     after Rounds 1–5. Every finding below was verified against the CURRENT source (file:line re-read, not
     trusted from the spec) and, where a runtime assumption was involved, against a throwaway execution or the
     existing validation scripts (functions/validate-*.js — retained). Verification method stated inline. -->

### Verification harness (what was actually checked)
- Read real code: `aws.ex` (`get_presigned_url/3`, `get_server_credentials/0`, `get_exaws_client/1`),
  `athena_db.ex` (`get_download_url/2`, `get_exaws_client/0`→`get_aws_keys/0`→`:aws_credentials`,
  `@download_url_ttl_seconds`), `token_service.ex` (`get_private_bucket/0`), `reports.ex`
  (`get_api_report_run/2`), `params.ex` (`parse_id/1`), `post_processing/steps/transcribe_audio.ex`,
  Node `middleware/response-methods.ts` (`res.success`/`res.error`), `helpers/paths.ts` (`getDoc`), the
  vertical-slice `derive_endpoint_set/2` + `first_page/next_page` (implementation.md:1315–1470), and
  bulk-read's `GETALL_CHUNK`/`chunkedGetAll`.
- Throwaway runtime check (staging): `functions/check-history-attachments.js` — confirmed history STATE docs
  carry the top-level `attachments` map (13/22 snapshots; referenced attachment resolves to a `publicPath`),
  so the `collection:"history"` path is not a dead end. Reused `validate-attachment.js` (owner==remote_endpoint;
  presign→200 2.9 MB) and the earlier IAM checks (`report-server-*` GetObject on `<bucket>/interactive-attachments/*`).

### Senior Elixir / Backend Engineer

#### RESOLVED [HIGH]: `derive_endpoint_set/2` called with swapped argument order
**Finding**: The vertical-slice step defines and calls `derive_endpoint_set(user, report_run)`
(implementation.md:1342 call, :1452 def). The attachment controller calls `derive_endpoint_set(report_run,
user)` (implementation.md:1744) — **arguments transposed**. It would pass a `%ReportRun{}` where a `%User{}`
is expected, breaking the derivation (or matching the wrong clause). **Verified** by reading both sites.
**Fix**: call `derive_endpoint_set(user, report_run)` in the attachment controller, matching the definition.

#### RESOLVED [MEDIUM]: `parse_id` called on the wrong module (`BulkParams`, not `Params`)
**Finding**: The attachment controller calls `BulkParams.parse_id(params["id"])` (implementation.md:1741). The
established, review-hardened pattern is `ReportServerWeb.Api.V1.Params.parse_id/1` (STORY 1): the bulk
controller uses it directly (implementation.md:1315), and **RESOLVED [HIGH] at implementation.md:2704 already
deleted a bulk-local `parse_id/1` specifically to reuse `Params.parse_id/1`** (its `@max_bigint` guard prevents
an out-of-range `:id` from reaching the Ecto query → 500). `BulkParams.parse_id` reintroduces exactly the
dropped path (and likely doesn't exist). **Verified** against :1315, :1741, :2704. **Fix**: use
`Params.parse_id(params["id"])`.

### Security Engineer

#### RESOLVED [HIGH]: presign must use SERVER creds via the transcription pattern — NOT a variant of `get_presigned_url/3` (workgroup creds)
**Finding**: The step describes `AWS.get_presigned_url_for_key/4` as "a thin variant of the existing
`AWS.get_presigned_url/3`." But **`Aws.get_presigned_url/3` signs with WORKGROUP credentials** — its first arg
is `workgroup_credentials`, passed to `get_exaws_client(workgroup_credentials)` (aws.ex:32-38), and its only
caller is `old_report_live/query.ex:229` handing it per-user Athena workgroup creds. Those creds are the wrong
trust boundary for attachments (they're the user's Athena-report creds) and **cannot read the attachments
bucket**. The correct, existing pattern is the audio-transcription job (`transcribe_audio.ex`): read
`answer["attachments"][name]["publicPath"]` (`get_audio_path/2`), build
`s3://#{TokenService.get_private_bucket()}/#{publicPath}` (`get_audio_s3_url/1`), and access it with **SERVER
creds** (`Aws.get_file_contents` → `get_server_credentials/0`). **Verified**: server creds have GetObject on
the prefix (IAM, both accounts); `athena_db.get_download_url/2` — STORY 1's CSV presign — also uses server
creds (`get_exaws_client/0`→`:aws_credentials`), so "same creds as run_csv/job_result" is true but the *helper*
cited is the wrong one. **Fix**: drop the invented `get_presigned_url_for_key/4`; presign by building the
`s3://<private_bucket>/<publicPath>` URL (as `transcribe_audio` does) and calling the existing
`Aws.get_presigned_url(Aws.get_server_credentials(), s3_url, name)` — reuse the helper, pass **server** creds.

#### RESOLVED [LOW → NO-CHANGE]: authorize on `d.remote_endpoint`; do NOT gate on `folder.ownerId` (run-with-others makes them legitimately differ)
**Finding evolved across three verification passes — the conclusion is the spec was already right.**
- *v1 (wrong)*: "switch the authz key to `att.folder.ownerId` (the owner of the S3 folder the signed `publicPath`
  lives in), since that's the object actually being signed."
- *v2 (after a data scan)*: `functions/check-owner-field.js` over 81 real attachments (30 sources) showed
  `publicPath` 81/81, `remote_endpoint` 70/81, `folder.ownerId` 76/81, and when both set they matched 70/70.
  So `folder.ownerId` is a **less-reliable secondary field** and `remote_endpoint` is the canonical identity
  `endpoint_set` is keyed on → authorizing on `folder.ownerId` would risk filtering out valid data. Proposed a
  null-safe "reject when both present and differ" tripwire instead.
- *v3 (after reading the LARA source — the authoritative answer)*: `ownerId` is set by **LARA**, not
  token-service — `attachments-manager.ts:68` `ownerId: this.learnerId`, where
  `learnerId = writeOptions.runKey || writeOptions.runRemoteEndpoint`. And `handle-get-attachment-url.ts`
  documents that **`folder.ownerId` and the current learner legitimately differ "when answerMetadata is copied
  between users (run with others use case)"** — a student's answer doc can carry an attachment whose folder is
  owned by the *original* creator. **So the v2 tripwire is wrong too**: it would deny a legitimate collaborative
  attachment that is genuinely part of the authorized student's answer.
**Resolution — no code change.** Authorize on **`d.remote_endpoint`** (the doc's learner, matched against
`endpoint_set`), exactly as the spec's controller already does. Do **not** add any `folder.ownerId` equality
gate. Rationale: if student A's answer (A ∈ the researcher's `endpoint_set`) references a file physically in
student B's folder (A ran-with-others), that file is part of **A's answer content** and the researcher — entitled
to A's answers — should get it; gating on B's `ownerId` would wrongly deny it. LARA's own read path likewise does
**not** gate reads on `ownerId` (the `ownerId` match in `findFolder` only routes new *writes* to the user's own
folder); researcher-level authz via `report_run → endpoint_set` is the correct and sufficient layer. **Minor
cleanup only**: drop the Node helper's `?? att.folder?.ownerId` fallback so the authz key is unambiguously the
doc's `remote_endpoint` — a doc with no `remote_endpoint` (anonymous/`run_key`, out of scope) then resolves to
`not_authorized`, which is correct.

### Firestore / Node Engineer

#### RESOLVED [MEDIUM]: `getAll(...refs)` unchunked for up to 500 refs — bulk-read chunks at 300
**Finding**: `fetch_attachment_meta` does `admin.firestore().getAll(...refs)` with up to 500 refs in one call.
The bulk-read walker deliberately chunks `getAll` at `GETALL_CHUNK = 300` (`chunkedGetAll`, bulk-read.ts) to
stay within Firestore's batchGet limits. The attachment helper's single 500-ref `getAll` is inconsistent with
that discipline and risks the same limit the walker guards against. **Verified**: bulk-read defines
`GETALL_CHUNK = 300`; the attachment helper has no chunking. **Fix**: reuse `chunkedGetAll` (or the same
300-chunk loop) in the attachment helper.

### API-Contract / Senior Engineer

#### RESOLVED [LOW]: `AWS.presign_ttl_seconds()` does not exist
**Finding**: The controller returns `AttachmentJSON.results(results, AWS.presign_ttl_seconds())`, but there is
no such function. The presign TTL lives as `@download_url_ttl_seconds = 60*10` with a public
`AthenaDB.download_url_ttl_seconds/0`, and `get_presigned_url/3` hardcodes `expires_in: 60*10`. STORY 1's
`report_json.ex:18` surfaces `expires_in_seconds: AthenaDB.download_url_ttl_seconds()`. **Fix**: reference the
real TTL (reuse `download_url_ttl_seconds/0`, or define an `Aws`-level constant and use it in both the presign
and the JSON) so the wire `expires_in_seconds` can't drift from the actual signature lifetime.

### Product / Requirements

#### RESOLVED [LOW]: Overview undercounted the endpoints ("two authenticated endpoints")
**Finding**: requirements.md Overview said STORY 3 "adds two authenticated endpoints" — the attachment
download makes it three (answers, history, attachments). **Fix applied**: Overview rewritten to describe
answers + history + attachments and the presigned-URL batch endpoint.

### Confirmations (verified NOT issues)
- **`collection:"history"` resolves** — history state docs carry the `attachments` map with resolvable
  `publicPath` (throwaway `check-history-attachments.js`, 13/22).
- **`get_api_report_run/2`** returns `{:ok, run} | {:error, :not_found}`, matching the controller's
  `{:error, :not_found} -> NOT_FOUND 404` branch (reports.ex:91).
- **Node `res.success`/`res.error`** exist (response-methods.ts:5,10); the helper's usage is valid.
- **`endpoint_set` key** — the vertical slice emits `%{"remote_endpoint" => …}` (string key), matching the
  controller's `MapSet.new(endpoint_set, & &1["remote_endpoint"])`.
- **`name` containing "/" is safe** — it's only an object-key lookup (`d.attachments[name]`), never part of a
  Firestore path (the doc path uses source/doc_id, which the helper rejects "/" in), and the signed key comes
  from the authoritative `publicPath`, not from `name`.

### Attachment endpoint — Re-review (Round 2, after applying Round-1 fixes, 2026-07-15)

Re-ran the same roles against the *updated* attachment code (the `presign_server_get` helper, `disposition`
param, `parse_disposition`, chunking, arg/parse_id/authz fixes). Verified against real code.

#### RESOLVED [MEDIUM]: module-name casing bug introduced by the Round-1 TTL fix (`AthenaDb` vs `AthenaDB`)
**Finding**: The Round-1 presign helper wrote `AthenaDb.download_url_ttl_seconds()` (lowercase `b`) while the
controller wrote `AthenaDB.…`. The real module is **`ReportServer.AthenaDB`** (verified, athena_db.ex:1) —
Elixir aliases are case-sensitive, so `AthenaDb` resolves to a different, nonexistent module → compile error.
Introduced by my own fix. **Resolution (also fixes coupling)**: moved the presign TTL into `Aws` itself
(`@presign_ttl_seconds = 60*10`, `Aws.presign_ttl_seconds/0`), used by **both** `presign_server_get` (the
`expires_in`) and the controller (the wire `expires_in_seconds`) — one source of truth, and it drops the
cross-module reference to `AthenaDB` from the generic presign helper entirely (attachments aren't Athena).
Removed the now-unused `AthenaDb` alias from the controller.

#### RESOLVED [LOW]: `Aws.presign_server_get` coupling attachment presigns to the Athena module
**Finding**: Borrowing `ReportServer.AthenaDB.download_url_ttl_seconds/0` from `ReportServerWeb.Aws` for
*attachment* presigning is an odd dependency (attachment lifetime tied to the Athena download constant), and it
was the casing bug's root cause. **Resolution**: folded into the fix above — the TTL now lives in `Aws` with
`presign_server_get`.

#### RESOLVED [LOW]: `parse_disposition(nil)` default was implicit
**Finding**: The controller calls `BulkParams.parse_disposition(params["disposition"])`; an absent key makes
that `nil`. Unless `parse_disposition(nil)` explicitly returns `{:ok, "attachment"}`, the documented default
silently fails (or 400s a valid no-disposition request). **Resolution**: pinned the contract in the
files-affected note — `parse_disposition(nil) → {:ok, "attachment"}`, `"attachment"`/`"inline"` →
`{:ok, value}`, else `{:error, _}` → 400; added the "bad disposition → 400" and default-vs-inline assertions to
`attachment_controller_test.exs` (Round 1).

#### Confirmations (verified NOT issues)
- `get_bucket_and_path/1` and `get_exaws_client/1` are `defp` in `aws.ex` (verified :157,:166); `presign_server_get`
  lives in the same module, so the same-module calls need no visibility change.
- `re != nil and MapSet.member?(allowed, re)` correctly denies a `nil` `remote_endpoint` before the set check;
  `endpoint_set` keys are strings (`& &1["remote_endpoint"]`), so the `MapSet` comparison is well-typed.
- No remaining `AthenaDb`/`get_presigned_url_for_key`/`BulkParams.parse_id`/`presign_ttl_seconds`-as-`AWS.` refs
  in the build step (grep-verified).

### Attachment endpoint — Re-review (Round 3, remaining surface: audit attrs, params, JSON, 2026-07-15)

Verified the surface Round 2 hadn't: `log_attachment_urls` vs the real `DataAccessLogEntry.changeset`, the
`parse_*` helpers, and the `AttachmentJSON`/audit data flow. Read real code: `audit_log.ex:45` (`create_entry/1`),
`data_access_log_entry.ex:30-33` (validate_required + the STORY-1-narrow inclusion lists).

#### RESOLVED [MEDIUM]: audit couldn't record endpoints, and the write wasn't actually fail-closed
**Finding**: `sign_one` returned `%{doc_id, name, url|error}` with **no `remote_endpoint`**, but the audit row is
required to record the distinct signed learners in `endpoint_set` — the data wasn't in `results` to record.
Separately, the controller called `AuditLog.log_attachment_urls(...)` and then `json(...)` **unconditionally**,
ignoring the audit result — so a failed audit write would still return URLs, i.e. **not fail-closed** despite the
comment. **Verified** against the `sign_one` return shape and the controller body. **Fix**: `sign_one` now returns
`{result_map, signed_endpoint | nil}`; the controller collects the distinct non-nil endpoints for the audit and
**gates the JSON response on `log_attachment_urls/4` returning `{:ok, _}`** (failure → 500, no URLs leaked).
`log_attachment_urls/4` returns `create_entry/1`'s result.

#### RESOLVED [LOW]: changeset allow-list widening was described, not shown
**Finding**: The real `data_access_log_entry.ex` only allows `event: "download_url_issued"` and
`data_type: "run_csv"|"job_result"` (verified :31-33). The persistence step widens these for bulk; this step must
*additively* add `"attachment_urls_issued"` / `"attachment"`. The step said so in prose but didn't show the final
lists, risking an implementer dropping the bulk values. **Fix**: the audit subsection now shows the exact
`validate_inclusion` lines (all values), and notes `endpoint_set` is already `EctoJsonArray` post-persistence so a
list-of-strings round-trips.

#### RESOLVED [LOW]: `parse_attachment_items` didn't validate `collection` at the param layer
**Finding**: The Node helper rejects a bad `collection`, but Elixir sent items through unchecked — a bad
`collection` would surface as a Node round-trip error mapped to a generic 400, not a clean param error, and burns
a Firestore call. **Fix**: `parse_attachment_items/1` validates `collection ∈ {"answers","history"}` (plus the
non-empty `source`/`doc_id`/`name`) up front → 400 before any Node call.

#### Confirmations (verified NOT issues)
- `AuditLog.create_entry/1` exists (audit_log.ex:45) and drives `DataAccessLogEntry.changeset`; the attrs
  `log_attachment_urls/4` builds satisfy `validate_required([:event,:source,:data_type,:user_id,:report_run_id])`
  and `validate_inclusion(:source, ["web","api"])` (`"api"`).
- The Elixir↔Node seam shape matches: Node `res.success({results})` → body `%{"results"=>…, "success"=>true}`;
  `fetch_attachment_meta/1` mirrors `bulk_read/1` (`{:ok, Map.delete(body,"success")}`), so the controller's
  `{:ok, %{"results" => metas}}` binds; a Node `res.error` → `{:error, binary}` → the `is_binary` else-branch → 400.

### Attachment endpoint — Re-review (Round 4, verifying the Round-3 fixes, 2026-07-15)

#### RESOLVED [LOW]: `count` param had no persisted home (introduced/surfaced by Round 3)
**Finding**: Round 3 passed `length(results)` to `log_attachment_urls/4`, but `data_access_log` has no count
column — so `count` was an unused param *and* the requirements over-claimed the audit records "the attachment
count." **Fix**: dropped it — `log_attachment_urls/3(user, report_run, endpoints)`; requirements reworded to
"distinct `remote_endpoints` actually signed" only.

#### Confirmations (Round-3 fixes verified consistent)
- `results = Enum.map(signed, &elem(&1, 0))` and `endpoints = signed |> Enum.flat_map(fn {_r, re} ->
  List.wrap(re) end) |> Enum.uniq()` — `List.wrap(nil) == []`, `List.wrap(re) == [re]`, so only actually-signed
  learners are collected; well-formed.
- The Round-1 test bullet ("audit writes exactly one row with the distinct authorized endpoints; audit-write
  failure → 500 with no URLs leaked") now matches the fail-closed `case` — no test drift.
- No `/4`, `AthenaDb`, `get_presigned_url_for_key`, `BulkParams.parse_id`, or `AWS.presign_ttl_seconds` refs
  remain in the build-step code (grep-verified).

**Loop status**: stable — Round 4 found only the one `count` tidy (a Round-3 artifact) and no new substantive
issues. Recommend stopping here.

### Attachment endpoint — External review triage (Round 5: 4 fresh independent reviewers, 2026-07-15)

Four fresh subagents (Security/IRB, Senior Elixir/Backend, Firestore/Node, API-Contract+QA) reviewed the
attachment sections cold, with repo + staging access. All four independently agreed the **auth model is sound —
no cross-learner IDOR** (the forged-coordinates attack fails: the server re-reads the doc, uses the authoritative
`publicPath`, and gates on `remote_endpoint ∈ endpoint_set`). Three of four independently hit the `render_error`
bug; two hit the error-mapping/param-arity issue — strong signal these were real, not in-context rationalizations.
Triaged (each verified against real code before applying):

#### RESOLVED [HIGH]: `derive_endpoint_set/2` was `defp` in a different module → the controller couldn't call it (won't compile)
The vertical slice defined `derive_endpoint_set/2` (+ `to_endpoints/1`, `derive_source/1`, seam accessors) as
`defp` inside `BulkExportController`; `AttachmentController` is a separate module. **Fix**: extracted into a shared
public module `ReportServerWeb.Api.V1.EndpointSet`; both controllers delegate. (New file added to files-affected.)

#### RESOLVED [MED]: error mapping — Node/derivation 500s became client 400s, and param errors could 500
The `else` matched `{:error, code} when is_binary(code) -> 400`, so a Node/Firestore internal failure (binary
error, via the mirrored seam) surfaced as **400**; and the new `BulkParams` parsers, if they followed the existing
**3-tuple** `{:error, :bad_request, msg}` convention, would match no `else` clause → **500 for a bad body**.
**Fix**: pinned the parsers to the 3-tuple convention and rewrote `else` — `{:error, :bad_request, msg} -> 400`,
`{:error, :not_found} -> 404`, `{:error, _} -> 500`. Now param errors → 400, ownership → 404, and every
seam/derivation/Node failure → 500.

#### RESOLVED [MED]: `ErrorHelpers.render_error/4` called with a status integer as the `message`
`render_error(conn, "NOT_FOUND", 404)` put `404` in the `message` field (status comes from the code lookup).
**Fix**: use the named helpers `ErrorHelpers.not_found/1` / `bad_request/2` / `server_error/1` (STORY-1 pattern).

#### RESOLVED [MED]: attachment response lacked `cache-control: no-store`
The bulk endpoints call `put_no_store`; this response (a batch of 10-min credential-free URLs to student files)
returned `json/1` with no cache header. **Fix**: `put_resp_header(conn, "cache-control", "no-store")` before `json`.

#### RESOLVED [LOW-MED]: client `name` flowed unquoted into `Content-Disposition`
`filename=#{name}` unquoted. Downgraded from the reviewer's HIGH: a resolvable `name` must be a real key in the
doc's `attachments` map (LARA-generated `file.json`/`audio<ts>.mp3` — writer-constrained, not arbitrary client
input). **Fix (defense-in-depth)**: `safe_filename/1` strips CR/LF/quotes/control chars and RFC-6266-quotes it.

#### RESOLVED [LOW]: `getAll` unchunked exposure / route-guard shown in prose only / `Enum.zip` silent truncation
- Node route registration is now shown as **literal code** with the `requireHeaderBearer` guard + a "query/body
  bearer → 401" test (an omitted guard would re-open query-string-bearer leakage via the global auth).
- Added `validate_meta_count/2` in the controller: a Node result-count ≠ item-count is a contract violation → 500,
  never a silently `Enum.zip`-truncated `results`.
- Test list expanded with the reviewers' scenarios (boundary 500/501, non-string disposition, history path,
  meta-count mismatch, null-contentType inline, duplicate items, three-way mixed batch, filename sanitization,
  no-store header, no-publicPath → not_found, server-creds spy).

#### NOTED (IRB, not an open question): run-with-others consent is implicit
Documented in requirements (authz section) that a co-authored artifact from a run-with-others collaborator B is
returned to a researcher authorized for A — accepted because collaboration is within a shared class/activity
context, so B's participation permission is implicit in the same consent regime; no separate `ownerId`/permission
re-check (which would break legitimate collaboration). Recorded as a resolved decision, not an OPEN item.

#### DECLINED (with rationale)
- **Authorize on `(source, remote_endpoint)` rather than `remote_endpoint` alone** (Security, defense-in-depth):
  declined. `run_remote_endpoint` is globally unique per portal-learner-run (it embeds the `secure_key`), so a doc
  bearing an authorized `remote_endpoint` is that authorized learner's own data regardless of the `source`
  container; adding `source` to the check gates nothing extra and could only *reject* a learner's cross-source
  answers. Both the reviewer and prior analysis agree it is "safe in practice."
- **Dedupe `getAll` refs** (Node, efficiency): declined for v1. A doc with N attachments is re-read N times, but
  positional `snaps[i]↔items[i]` correctness depends on the non-deduped 1:1 mapping; deduping adds fan-out/fan-in
  complexity for a bounded (≤500-item) call. Noted as an available optimization, not needed for correctness.

#### Confirmations from the reviewers (independently verified, no change)
- Server-cred presign (not workgroup) is correct; `s3://<private_bucket>/<publicPath>` matches `transcribe_audio.ex`.
- IDOR guard holds (client `publicPath` never used; forged coordinates only resolve for already-authorized learners).
- History state docs carry the `attachments` map; missing-doc/missing-name → `meta: null` → `not_found`; `nil`
  `remote_endpoint` (anonymous) → `not_authorized` (fail-closed) — all confirmed against staging.
- The Elixir↔Node seam shape matches (`res.success({results})` → `{:ok, %{"results" => …}}`).

**Cross-step caveat surfaced by 3 reviewers**: the persistence step (changeset widening: `attachment_urls_issued`
event, `attachment` data_type, `EctoJsonArray` `endpoint_set`, `export_id`) MUST land before/with this step, or
`create_entry/1` rejects the audit row and the fail-closed path returns 500 for every call. Ordering is correct in
the plan; called out here as a hard sequencing dependency.
