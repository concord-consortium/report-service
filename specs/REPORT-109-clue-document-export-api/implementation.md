# Implementation Plan: CLUE Document Export API (Metadata, History, Content) Scoped by Report Run

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-109 (the CLUE function: https://concord-consortium.atlassian.net/browse/CLUE-742)
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Overview of the change

Three repositories change, in one PR each, and report-service's PR carries the whole report-server half (Doug: one implementation PR, Scott reviews design and code together).

- **report-service** (`server/`): the NULL id-list fix, the `clue_prepull` removal, the audit and scratch schema additions, the scope derivation, the CLUE client and its configuration, the controller and routes, the README.
- **collaborative-learning** (`functions-v2/`): the `clueExport` HTTPS function, its tests, its deploy-time param. Tracked as [CLUE-742](https://concord-consortium.atlassian.net/browse/CLUE-742), which blocks REPORT-109, so CLUE's release triage, notes and deploy timing see it.
- **cloud-formation** (`fargate/report-server.yml`): two parameters and their environment variables.

report-server and the function meet at one wire contract, defined once below under "The wire contract" and cited by both sides' steps.

## The wire contract

One POST per page to the function URL for the caller's portal, `Authorization: Bearer <CLUE_EXPORT_TOKEN>`, JSON body:

```json
{
  "operation": "documents" | "history" | "content" | "owners",
  "portal": "learn.concord.org",

  "owners": [
    {"class_hash": "<48 hex>", "uid": "1234" | "group_<off>_<gid>" | "class_<hash>",
     "kind": "student" | "group" | "class", "portal_class_id": 601, "offerings": [701, 703]}
  ],
  "inner_cursor": null | {"docId": "..."} | {"docId": "...", "index": 12, "entryId": "..."},
  "limit": 500, "owner_limit": 250, "read_limit": 5000,

  "classes": [{"class_hash": "<48 hex>", "offerings": [701, 703]}]
}
```

`owners`, `inner_cursor` and the three limits go with the three walk operations; `classes` goes only with `owners`.

Answers, status 200:

- walk operations: `{"success": true, "items": [...], "stop_owner_offset": 0, "inner_cursor": {...} | null, "owner_exhausted": true, "served_owner_offsets": [0, 2]}`. `stop_owner_offset` is an index into the request's `owners`. `inner_cursor` is `null` exactly when `owner_exhausted` is true.
- `owners`: `{"success": true, "groups": [{"class_hash": "...", "uid": "group_701_3", "offering": 701}]}`.

Errors: 400 for a malformed request, 401 for a missing or wrong bearer, 405 for a method other than POST, 500 for a read failure, each `{"success": false, "error": "<message>"}`. report-server maps every non-200 to its own 500 (R12), as `bulk_read`'s client does.

## Implementation Plan

### Treat a NULL id list as empty in `LearnerData`

**Summary**: R2's fix, alone and first, because it changes the bulk endpoints' behavior today and every later step's scope derivation goes through it.

**Files affected**:
- `server/lib/report_server/reports/athena/learner_data.ex`: `split_id_list/1` gains a `nil` clause.
- `server/test/report_server/reports/athena/learner_data_portal_test.exs` (new): the class 602 test.

**Estimated diff size**: ~40 lines

```elixir
  defp split_id_list(nil), do: []

  defp split_id_list(id_list) do
    id_list
      |> String.split(",")
      |> Enum.map(&String.trim/1)
  end
```

`get_unique_ids/2` keeps its `Map.get(&1, key, "")`: the default covers an absent key and the new clause covers a present `nil`, so both end as no ids. `get_info_by_ids/2` already has its own `nil` clause and is unchanged.

Test (`@moduletag :portal_db`, `async: false`, as `portal_fixture_test.exs`): `LearnerData.fetch(%ReportFilter{filters: [:class], class: [602]}, admin)` returns `{:ok, groups}` whose learners include learner 904 with `user_id` 102. Mutation it catches: deleting the `nil` clause raises `FunctionClauseError` in `String.split/3` (stage 4 reproduced exactly that on this branch).

---

### Remove the CLUE pre-pull flag

**Summary**: R21. Independent of the export; it removes a field from the catalog's list and resolve answers, so it is its own commit.

**Files affected**:
- `server/lib/report_server/packages/manifest.ex`: drop `clue_prepull` from `@type projection`, the `with` chain, the projection map, and the three `clue_prepull/1` clauses.
- `server/lib/report_server/packages/package_version.ex`: drop the field and its entry in `@fields`.
- `server/lib/report_server_web/api/v1/package_json.ex`: drop `clue_prepull:` from `current_version` (`:31`) and from `resolve/1` (`:45`).
- `server/priv/repo/migrations/20261022120000_remove_clue_prepull_from_package_versions.exs` (new).
- `server/test/report_server/packages/manifest_test.exs`: the valid fixture keeps `"clue_prepull" => true` (`:16`) as the evidence that the key is ignored; the default test (`:44-46`) drops `clue_prepull` from its drop list and its match; the `{"clue_prepull", "yes", "clue_prepull"}` refusal case (`:89`) goes; a new test asserts that `"clue_prepull" => "yes"` validates and that the projection has no `:clue_prepull` key.
- `server/test/support/fixtures/packages_fixtures.ex`: drop `"clue_prepull" => false` (`:15`).
- `server/test/report_server_web/api/v1/package_controller_read_test.exs`: drop the key from the two expected maps (`:94`, `:228`); replace the "resolves with its own clue_prepull" test (`:262-268`) with one that publishes a version whose manifest carries `"clue_prepull" => true` and asserts the resolve answer and the list's `current_version` have no `"clue_prepull"` key.

**Estimated diff size**: ~70 lines

```elixir
defmodule ReportServer.Repo.Migrations.RemoveCluePrepullFromPackageVersions do
  use Ecto.Migration

  def change do
    alter table(:package_versions) do
      remove :clue_prepull, :boolean, null: false, default: false
    end
  end
end
```

`remove/3` with the type keeps the migration reversible. The two archive fixtures (`class-counts-1.0.6.zip`, `class-counts-go-1.0.6.zip`) carry `"clue_prepull": true` and stay as built, so their checksums are untouched and every publish test that uses them is a second witness that the key is ignored. `build.sh:19` keeps writing the key for the same reason.

---

### Add the CLUE data types and `item_count` to the scratch and audit schemas

**Summary**: R16's schema half: the three `data_type`s on both allow-lists and the nullable `item_count` column. No caller yet, so existing behavior is unchanged.

**Files affected**:
- `server/lib/report_server/exports/export_scratch.ex`: `validate_inclusion(:data_type, ...)` gains `clue_documents_bulk`, `clue_history_bulk`, `clue_content_bulk`; the `endpoint_set` comment names both element shapes.
- `server/lib/report_server/audit_log/data_access_log_entry.ex`: the same three in the `data_type` allow-list; `field :item_count, :integer`; `:item_count` in `cast/3`.
- `server/priv/repo/migrations/20261022120100_add_item_count_to_data_access_log.exs` (new).
- `server/lib/report_server_web/live/audit_log_live/index.html.heex`: the Access cell gains `<span :if={entry.item_count}>, <%= entry.item_count %> items</span>` beside the job id (`:51`), so the rollout's audit-page check can read the count; `0` renders, `nil` (intent rows and existing kinds) does not.
- `server/test/report_server/audit_log_test.exs` (beside the refusal test at `:126` and the `endpoint_set` round trip at `:167`) and `server/test/report_server/exports_test.exs`: each new `data_type` is accepted, an unknown one is still refused, `item_count` round-trips and defaults to `nil`.
- `server/test/report_server_web/live/audit_log_live_test.exs`: a row with `item_count: 0` shows "0 items" and a row with `nil` shows no count.

**Estimated diff size**: ~80 lines

```elixir
defmodule ReportServer.Repo.Migrations.AddItemCountToDataAccessLog do
  use Ecto.Migration

  def change do
    alter table(:data_access_log) do
      add :item_count, :integer, null: true
    end
  end
end
```

The three names are module attributes in one place, `ReportServer.Exports.ExportScratch.clue_data_types/0`, which `DataAccessLogEntry`'s list and the controller both read, so the names agree by construction:

```elixir
  @bulk_data_types ["answers_bulk", "history_bulk"]
  @clue_data_types ["clue_documents_bulk", "clue_history_bulk", "clue_content_bulk"]

  def clue_data_types, do: @clue_data_types
  ...
    |> validate_inclusion(:data_type, @bulk_data_types ++ @clue_data_types)
```

REPORT-150's PR #444 edits the same `DataAccessLogEntry` lists and adds a `data_access_log` migration (requirements, Technical Notes), and it also edits `audit_log_live/index.html.heex` (the Run cell, for run-less rows) and `audit_log_live_test.exs`, the two files this step's count touches. Whichever merges second rebases onto the other's list, template and tests and takes a later migration timestamp; the two migrations touch different columns, so neither order breaks the other.

---

### Share the bulk export's learner gates and page helpers

**Summary**: a behavior-preserving refactor so the CLUE controller reuses rather than copies the gates, the no-store headers and the audit attributes. The existing bulk controller tests are the guard; no test changes.

**Files affected**:
- `server/lib/report_server_web/api/v1/endpoint_set.ex`: split `derive_endpoint_set/2` into `fetch_learners/2` (the derivable check, the allowed-project short-circuits and `LearnerData.fetch`, answering `{:ok, learners}` flattened from the groups, `{:ok, []}`, `{:error, :not_learner_derivable}` or `{:error, reason}`) and the existing mapping. `derive_endpoint_set/2` becomes `with {:ok, learners} <- fetch_learners(user, run), do: {:ok, to_endpoints(learners)}` with `to_endpoints/1` taking the flat list.
- `server/lib/report_server_web/api/v1/bulk_export.ex` (new): `put_no_store/1`, `audit_attrs/8` (the current seven arguments plus `item_count`, defaulting to `nil`), `raw_page_token/1`.
- `server/lib/report_server_web/api/v1/bulk_export_controller.ex`: call those; delete its private copies.

**Estimated diff size**: ~90 lines

`AttachmentController` also calls `derive_endpoint_set/2` and is unaffected, since its signature and answer do not change.

---

### Derive the CLUE scope owners

**Summary**: R5 to R7's report-server half as pure functions plus one portal lookup: which learners count, their class hashes, the student and class owners, the merge with the function's group owners, and the frozen order.

**Files affected**:
- `server/lib/report_server/clue.ex`: `writes_clue_documents?/1`.
- `server/lib/report_server/clue/scope.ex` (new): `ReportServer.Clue.Scope`.
- `server/lib/report_server/clue/class_hashes.ex` (new): the portal lookup, swappable as `:clue_class_hashes`.
- `server/test/support/portal_fixture.sql`: `portal_clazzes` gains `class_hash VARCHAR(48) NULL`; its `INSERT` names its three columns; an `UPDATE` sets class 601's hash (`'aaaa…'`, 48 lowercase hex), leaving 602 `NULL`, and another sets 603's to `''`.
- `server/test/report_server/clue/scope_test.exs` (new, also holding the `writes_clue_documents?/1` tests, since `clue_test.exs` is the CLUE Student Answers report's suite), `server/test/report_server/clue/class_hashes_portal_test.exs` (new, `:portal_db`), `server/test/report_server/clue/class_hashes_test.exs` (new, the empty-list case, which makes no query).

**Estimated diff size**: ~330 lines with tests

```elixir
  @clue_document_hosts ["collaborative-learning.concord.org", "dataflow-app.concord.org"]

  def writes_clue_documents?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host) in @clue_document_hosts

      _ ->
        false
    end
  end

  def writes_clue_documents?(_), do: false
```

`URI.parse/1` lowercases the scheme but keeps the host as written (checked: `HTTPS://Collaborative-Learning.Concord.Org/x` parses to scheme `"https"`, host `"Collaborative-Learning.Concord.Org"`), so the host needs the `String.downcase/1`. `is_clue_url?/1` is untouched (R6).

```elixir
defmodule ReportServer.Clue.Scope do
  @moduledoc """
  The scope owners of a CLUE export (requirements R5 to R7): who holds the documents a run may read, each
  with the offerings that narrow them. Owners are plain string-keyed maps so they store in `export_scratch`
  unchanged and go to the CLUE function as they are.
  """

  @doc "Student owners from learner rows, given `%{class_id => class_hash}`. Learners off CLUE hosts or without a hash are left out."
  def student_owners(learners, hashes) do
    learners
    |> Enum.filter(&ReportServer.Clue.writes_clue_documents?(&1.runnable_url))
    |> Enum.filter(&Map.has_key?(hashes, &1.class_id))
    |> Enum.group_by(&{hashes[&1.class_id], &1.class_id, Integer.to_string(&1.user_id)}, & &1.offering_id)
    |> Enum.map(fn {{hash, class_id, uid}, offerings} ->
      owner(hash, uid, "student", class_id, offerings)
    end)
  end

  @doc "One class owner per class holding a student owner, narrowed by that class's run offerings."
  def class_owners(student_owners) do
    student_owners
    |> Enum.group_by(&{&1["class_hash"], &1["portal_class_id"]}, & &1["offerings"])
    |> Enum.map(fn {{hash, class_id}, offering_lists} ->
      owner(hash, "class_" <> hash, "class", class_id, List.flatten(offering_lists))
    end)
  end

  @doc "The `owners` request's classes: each class hash with its run offerings."
  def classes(class_owners), do: Enum.map(class_owners, &%{"class_hash" => &1["class_hash"], "offerings" => &1["offerings"]})

  @doc "Group owners from the function's `owners` answer; a group is narrowed to its own offering."
  def group_owners(groups, class_owners) do
    class_ids = Map.new(class_owners, &{&1["class_hash"], &1["portal_class_id"]})

    Enum.map(groups, fn %{"class_hash" => hash, "uid" => uid, "offering" => offering} ->
      owner(hash, uid, "group", Map.fetch!(class_ids, hash), [offering])
    end)
  end

  @doc "The frozen order: by class hash, then owner id."
  def order(owners), do: Enum.sort_by(owners, &{&1["class_hash"], &1["uid"]})

  @doc "The audit key of an owner (R16)."
  def key(%{"class_hash" => hash, "uid" => uid}), do: "clue:#{hash}:#{uid}"

  defp owner(hash, uid, kind, class_id, offerings) do
    %{"class_hash" => hash, "uid" => uid, "kind" => kind, "portal_class_id" => class_id,
      "offerings" => offerings |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()}
  end
end
```

`Map.fetch!/2` in `group_owners/2` cannot miss for a well-behaved function, since every `owners` request class comes from `class_owners`; the controller validates the answer's class hashes against the request before calling it (next steps), so a misbehaving function is a controlled 500, not a crash.

```elixir
defmodule ReportServer.Clue.ClassHashes do
  @moduledoc "Portal class id to class hash, for the classes a CLUE export's learners are in."
  alias ReportServer.PortalDbs
  import ReportServer.Reports.ReportUtils, only: [list_to_in: 1]

  @doc "{:ok, %{class_id => class_hash}} for the ids whose class has a non-empty hash, or {:error, reason}."
  def fetch(_portal_server, []), do: {:ok, %{}}

  def fetch(portal_server, class_ids) do
    sql = "SELECT id, class_hash FROM portal_clazzes WHERE id IN #{list_to_in(class_ids)}"

    case PortalDbs.query(portal_server, sql) do
      {:ok, result} ->
        {:ok,
         result
         |> PortalDbs.map_columns_on_rows()
         |> Enum.filter(&(is_binary(&1.class_hash) and &1.class_hash != ""))
         |> Map.new(&{&1.id, &1.class_hash})}

      {:error, _} = err ->
        err
    end
  end
end
```

`list_to_in/1` takes integers only (`Integer.to_string/1`), so the interpolated list cannot carry SQL; the ids come from `rl.class_id`, an integer column.

Tests:
- `writes_clue_documents?/1`: `https://collaborative-learning.concord.org/branch/master/?unit=x` and `HTTPS://Collaborative-Learning.Concord.Org/` and `https://dataflow-app.concord.org/` pass; `https://collaborative-learning.concord.org.example.com/`, `ftp://collaborative-learning.concord.org/`, `https://activity.concord.org/?x=collaborative-learning.concord.org`, `nil` and `""` fail. The query-string case is the one `is_clue_url?/1` would pass, so it pins the difference.
- `Scope`: two learners of one student in offerings 701 and 703 make one owner with `[701, 703]`; a learner whose class has no hash is dropped; a class whose only learner is on a LARA URL yields no student owner and so no class owner; `class_owners/1` unions the offerings of every student in the class; `group_owners/2` gives a group the one offering in its answer row; `order/1` sorts by hash then uid. Each fixture uses distinct values per learner, so "keeps the last" and "folds" give different answers.
- `ClassHashes` on the portal fixture: `fetch(server, [601, 602, 603])` is `{:ok, %{601 => "aaaa…"}}`.

---

### The CLUE export client and its configuration

**Summary**: R20's report-server half: `CLUE_EXPORT_URLS` and `CLUE_EXPORT_TOKEN` read and validated at boot, and the HTTP client the controller calls, swappable for tests.

**Files affected**:
- `server/config/runtime.exs`: parse and validate the two variables (below `PACKAGE_BUCKETS`).
- `server/lib/report_server/clue_export.ex` (new): `ReportServer.ClueExport`.
- `server/test/support/clue_export_stub.ex` (new): `ReportServer.ClueExportStub`, the `ReportServiceStub` pattern, implementing both `url_for/1` and `call/2` so a test can drive the 503 gate and the page answers from one stub.
- `server/test/report_server/clue_export_test.exs` (new): `url_for/1` and the response mapping, using `Req.Test` through `:clue_export_req_options` (the `report_service_req_options` seam's twin).

**Estimated diff size**: ~170 lines

```elixir
clue_export_urls =
  case System.get_env("CLUE_EXPORT_URLS") do
    blank when blank in [nil, ""] ->
      %{}

    json ->
      case Jason.decode(json) do
        {:ok, urls} when is_map(urls) ->
          unless Enum.all?(urls, fn {portal, url} -> portal != "" and is_binary(url) and String.starts_with?(url, "https://") end) do
            raise "CLUE_EXPORT_URLS must map each portal server to an https function URL"
          end

          urls

        _ ->
          raise "CLUE_EXPORT_URLS must be a JSON object of portal server to function URL"
      end
  end

clue_export_token = System.get_env("CLUE_EXPORT_TOKEN")

if clue_export_urls != %{} and clue_export_token in [nil, ""] do
  raise "CLUE_EXPORT_URLS is set, so CLUE_EXPORT_TOKEN is required"
end

config :report_server, :clue_export, urls: clue_export_urls, token: clue_export_token
```

```elixir
defmodule ReportServer.ClueExport do
  @moduledoc """
  Client for CLUE's `clueExport` function, one deployment per CLUE project, chosen by the caller's portal.
  The function is stateless and authorization-blind: report-server decides the scope and owns the cursor.
  """

  # past the function's 300-second timeout, as bulk_read's client is
  @receive_timeout 310_000

  @doc "The function URL for a portal, or nil when CLUE export is not configured for it."
  def url_for(portal_server), do: Map.get(config()[:urls] || %{}, portal_server)

  @doc "{:ok, body_without_success} | {:error, reason}. Any non-200 is an error."
  def call(portal_server, req) do
    case url_for(portal_server) do
      nil ->
        {:error, :not_configured}

      url ->
        Req.new(Application.get_env(:report_server, :clue_export_req_options, []))
        |> Req.post(url: url, auth: {:bearer, config()[:token]}, json: req,
             receive_timeout: @receive_timeout, retry: false)
        |> case do
          {:ok, %{status: 200, body: %{"success" => true} = body}} -> {:ok, Map.delete(body, "success")}
          {:ok, %{body: %{"error" => error}}} -> {:error, error}
          {:ok, %{status: status}} -> {:error, "unexpected clueExport status #{status}"}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp config, do: Application.get_env(:report_server, :clue_export, [])
end
```

`retry: false` because a retried page is the client's job (R11, at-least-once with a stable token). Req 0.4.14's default (`:safe_transient`) already never retries a POST (`deps/req/lib/req/steps.ex:2106`), so the option states the rule rather than changing behavior, and keeps it if a later edit switches to `:transient`.

`config/test.exs` gets no `:clue_export` entry: `runtime.exs` runs under `mix test` too and its unconditional `config` replaces one, so with the variables unset (as the server tests run) `urls: %{}` is what makes a test that forgets the stub see the 503 path rather than a network call.

---

### The CLUE export controller and routes

**Summary**: R1 to R4, R8 to R12 and R16's rows: three actions over one `serve/4`, the first page's derivation and freeze, the page walk, the cursor and the audit rows.

**Files affected**:
- `server/lib/report_server_web/router.ex`: three routes beside `/history`.
- `server/lib/report_server_web/api/v1/bulk_params.ex`: three `validate_inner_cursor/2` clauses.
- `server/lib/report_server_web/api/v1/clue_export_controller.ex` (new).
- `server/test/report_server_web/api/v1/clue_export_controller_test.exs` (new).
- `server/test/support/clue_class_hashes_stub.ex` (new): `ReportServer.ClueClassHashesStub`, the class-hash stub the controller tests swap in as `:clue_class_hashes`.
- `server/lib/report_server_web/api/v1/endpoint_set.ex`: the moduledoc names `ClueExportController` as the reader of `fetch_learners/2`.

**Estimated diff size**: ~850 lines with tests (the controller ~250, the tests ~590)

```elixir
    get "/reports/:id/clue/documents", ClueExportController, :documents
    get "/reports/:id/clue/history", ClueExportController, :history
    get "/reports/:id/clue/content", ClueExportController, :content
```

```elixir
  def validate_inner_cursor(%{"docId" => d}, c) when c in ["clue_documents", "clue_content"], do: check_clue_key(d)

  def validate_inner_cursor(%{"docId" => d, "index" => i, "entryId" => e}, "clue_history")
      when is_integer(i) and i >= 0 do
    with :ok <- check_clue_key(d), do: check_clue_key(e)
  end

  # the characters clueExport's id pattern refuses: no RTDB key holds them, and a CLUE document id is an RTDB key
  defp check_clue_key(k) when is_binary(k) and k != "" do
    if String.match?(k, ~r{[/.#$\[\]]}),
      do: {:error, "inner_cursor ids must be plain CLUE keys"},
      else: :ok
  end

  defp check_clue_key(_), do: {:error, "inner_cursor ids must be non-empty plain CLUE keys"}
```

These sit above the catch-all clause. The collection names are report-server's own (`clue_history`, not `history`), so a LARA history cursor can never validate on the CLUE route or the reverse. `check_clue_key/1` refuses exactly the characters the function's id pattern refuses (`/^[^/.#$\[\]]+$/`, below), so every cursor the function would reject is a 400 here rather than a collapsed 500 (R10).

Controller outline (the parts that differ from `BulkExportController`):

```elixir
  @owner_limit 250
  @read_limit 5000

  def documents(conn, params), do: serve(conn, params, "clue_documents_bulk", "documents")
  def history(conn, params), do: serve(conn, params, "clue_history_bulk", "history")
  def content(conn, params), do: serve(conn, params, "clue_content_bulk", "content")
```

`serve/4` runs `Params.parse_id/1`, `Reports.get_api_report_run/2`, `BulkParams.parse_limit/1`, `parse_page_token/1` in that order (R2), then `clue_export().url_for(user.portal_server)`: `nil` answers 503 `SERVICE_UNAVAILABLE` "CLUE export is not configured for this portal." on every page, before any scratch or audit row (R20). Then `BulkExport.put_no_store/1` and first or next page.

First page:
1. `EndpointSet.fetch_learners(user, run)`: `{:error, :not_learner_derivable}` is 422, any other error 500, `{:ok, []}` is the empty terminal page.
2. `class_hashes().fetch(user.portal_server, distinct class_ids of the learners on CLUE hosts)`: error is 500.
3. `Scope.student_owners/2`, `Scope.class_owners/1`. With no student owner, the empty terminal page (no `owners` call).
4. `clue_export().call(portal, %{operation: "owners", portal: portal, classes: chunk})` for each chunk of at most `@owner_limit` entries of `Scope.classes(class_owners)`, with the class owners in `Scope.order/1`'s order so each call's classes are deterministic, concatenating the `groups`; any failed call is 500. Chunking keeps a run over more classes than the function's 1,000-class cap exportable. Each answer must be `%{"groups" => list}` whose every row's `class_hash` is one of the request's, whose `offering` is in that class's offerings, and whose `uid` starts with `"group_#{offering}_"`; anything else is logged and 500.
5. `owners = Scope.order(students ++ classes ++ Scope.group_owners(groups, class_owners))`.
6. Scratch plus intent atomically through `Exports.create_scratch_with_intent/2`, `endpoint_set: owners` on the scratch, `Enum.map(owners, &Scope.key/1)` on the intent row, `item_count: nil`. Then `serve_page` from index 0.

The empty terminal page writes its intent row as the bulk endpoints do (R8): `{items: [], next_page_token: nil, total_endpoints: 0}`.

Next page: `Exports.fetch_for_page(sid, user.id, id, data_type)` (404, 410), the index bound check against `length(scratch.endpoint_set)`, `BulkParams.validate_inner_cursor(inner, "clue_" <> operation)`, then `serve_page`.

`serve_page`:

```elixir
    slice = scratch.endpoint_set |> Enum.drop(index) |> Enum.take(@owner_limit)
    req = %{operation: operation, portal: user.portal_server, owners: slice, inner_cursor: inner,
            limit: limit, owner_limit: @owner_limit, read_limit: @read_limit}

    case clue_export().call(user.portal_server, req) do
      {:ok, %{"items" => items, "stop_owner_offset" => off, "inner_cursor" => next_inner,
              "owner_exhausted" => exhausted, "served_owner_offsets" => served}}
      when is_list(items) and is_boolean(exhausted) and is_integer(off) and off >= 0 and
             off < length(slice) and is_list(served) ->
        if Enum.all?(served, &(is_integer(&1) and &1 >= 0 and &1 <= off)) do
          # cursor assembly exactly as BulkExportController.serve_page
          ...
          served_keys = served |> Enum.uniq() |> Enum.map(&Scope.key(Enum.at(slice, &1)))
          attrs = BulkExport.audit_attrs(user, run, "bulk_read", data_type, sid, raw_token, served_keys, length(items))
          ...
        else
          # an offset outside what was walked: contract violation, fail closed
        end
```

`served_owner_offsets` must lie within `0..stop_owner_offset`, since the function cannot have served an owner it did not reach; that guard is what makes R16's "the owners served" trustworthy without the items naming an owner. The next cursor is checked against the wire contract too: `null` exactly when `owner_exhausted`, and otherwise a cursor that `BulkParams.validate_inner_cursor/2` accepts for the route, so a page can never mint a token that resumes nowhere or that the next request would refuse. A function error or an unexpected shape is 500 with no audit row and no cursor advance (R12), and the log names only the answer's keys and stop offset, never its items, which are student work.

Config seams, as the bulk controller's: `:clue_export_client` (default `ReportServer.ClueExport`) and `:clue_class_hashes` (default `ReportServer.Clue.ClassHashes`), read at call time with `Application.get_env/3`.

Tests (stubbing `LearnerDataStub`, `ClueExportStub` and a class-hash stub; learners on `https://collaborative-learning.concord.org/...` unless a test says otherwise):
- Per route: a first page serves the stub's items with `total_endpoints` equal to the owner count and writes one `export_scoped` row (owner keys, `item_count` nil) and one `bulk_read` row; resuming with the returned token sends the stored slice and cursor; the terminal token re-serves the final page; a token past an hour is 410; a `clue_history_bulk` token on `/clue/documents` is 404; an unconfigured portal is 503 with zero scratch and audit rows.
- Run kinds (R3): a `student-id-mapping` run (a Portal run) and a `student-answers` run (an Athena run) each serve a first page.
- Authorization: another user's run is 404; a token whose user has no report role is 401; a researcher whose allowed projects are `[]` gets an empty terminal page and an intent row.
- Empty scope (R8): learners exist but none has a class hash, and separately none is on a CLUE host; each answers `{items: [], next_page_token: nil, total_endpoints: 0}`, writes one intent row and no scratch row, and never calls the function (the stub raises if called).
- Scope (through the controller, so the frozen owners are what is asserted): 251 classes make two `owners` calls of 250 and 1 classes, and a group from the second call is frozen; a learner whose class has no hash adds no owner; a LARA learner adds none and its class gets no class owner; a branch-build and a `dataflow-app.concord.org` learner each add one; the `owners` request carries each class's run offerings; group rows from the stub become owners with their own offering; a stub group row naming an unrequested class or offering is 500 and writes no scratch row; the owners on page 2's request equal page 1's even when the learner stub changes between calls (frozen).
- Paging: a stub that serves one document's 7 entries 3 at a time (`owner_exhausted: false` with `{docId, index, entryId}` twice, then exhausted) and then a second owner's entries, driven to `next_page_token == null`, yields every entry once in order; an empty mid-export page with a token continues.
- Cursors: a malformed `clue_history` cursor (missing `entryId`, negative `index`, `docId` with `/`, `entryId` with `.`) and a `clue_documents` cursor whose `docId` holds `#` are 400 before the stub is called (the stub raises if called).
- Audit: a page row's `endpoint_set` is exactly the keys of `served_owner_offsets` (a stub serving owner 1 of 3 names only owner 1's key) and its `item_count` equals the items' length; a served offset beyond `stop_owner_offset` is 500 with no row.
- Headers: every 200 carries `cache-control: no-store` and `pragma: no-cache`.

The empty-grants and denied tests are the ones R23 names; the "a run the caller does not own" setup is `bulk_export_controller_test.exs:82-86` and the "no report role" setup is `auth_plug_test.exs:45-61` (a user with all three role flags false); each is reused by copying its setup, not its assertions.

---

### Document the CLUE export routes

**Summary**: R22. The README has no section for the bulk endpoints today, so the new section describes the three CLUE routes on their own and says what `/history` is not.

**Files affected**:
- `server/README.md`: a "CLUE document export" section after "The package catalog", and the two variables in "Environment Settings".

**Estimated diff size**: ~70 lines

Content: the three routes and their item fields (R13 to R15, as a table each), the scope in two sentences (the run's learners on CLUE-writing hosts, narrowed by the run's offerings, with documents that have no offering kept, plus their classes' group and class documents), paging (`total_endpoints` counts scope owners; terminate on `next_page_token == null`; at-least-once, de-duplicate on `doc_id` or `(doc_id, entry_id)`), a sentence that `/clue/history` is CLUE **document** history and `/history` is LARA interactive-state history from report-service's own Firestore, and the 503 when `CLUE_EXPORT_URLS` has no entry for the portal. The environment block gains:

```shell
export CLUE_EXPORT_URLS='{}'         # portal server to CLUE's clueExport function URL (see "CLUE document export")
export CLUE_EXPORT_TOKEN=            # the bearer clueExport checks; required whenever CLUE_EXPORT_URLS names a portal
```

---

### CLUE: the `clueExport` function (collaborative-learning)

**Summary**: R17 to R19, CLUE-742, on a branch `CLUE-742-clue-export-function` of collaborative-learning from `master`, one PR titled with `[CLUE-742]`. The handler, the walk, the `owners` read, the param, and tests. The CLUE PR carries the CLUE key and report-service's PR names only REPORT-109, since a CLUE key in another repository's PR pulls that PR into CLUE's release triage (`releasing-clue/preparing.md:90-91`).

**Files affected**:
- `functions-v2/src/clue-export.ts` (new): the `onRequest` export, bearer and request validation.
- `functions-v2/src/clue-export-walk.ts` (new): the three walks and `owners`, taking the Admin SDK handles as arguments.
- `functions-v2/src/index.ts`: `export {clueExport} from "./clue-export";`.
- `functions-v2/.env.collaborative-learning-staging`: `CLUE_EXPORT_PORTALS=learn.portal.staging.concord.org`.
- `functions-v2/.env.collaborative-learning-ec215`: `CLUE_EXPORT_PORTALS=learn.concord.org`.
- `functions-v2/.env.example`: the param and a one-line meaning.
- `functions-v2/test/clue-export-request.test.ts` (new, no emulator).
- `functions-v2/test/clue-export-emulator.test.ts` (new).
- `functions-v2/README.md`: the function, its secret, its service account, its deploy.

**Estimated diff size**: ~520 lines with tests (source ~280, tests ~240); split the walk and its emulator test into a second commit if review wants commits under 500.

```ts
import {onRequest} from "firebase-functions/v2/https";
import {defineSecret, defineString} from "firebase-functions/params";
import * as crypto from "crypto";
import * as admin from "firebase-admin";
import {walk, readGroupOwners, kMaxLimits} from "./clue-export-walk";

const exportBearer = defineSecret("CLUE_EXPORT_BEARER");
const exportPortals = defineString("CLUE_EXPORT_PORTALS");

export const clueExport = onRequest({
  serviceAccount: "clue-export-reader@",
  secrets: [exportBearer],
  invoker: "public",
  timeoutSeconds: 300,
  memory: "1GiB",
}, async (req, res) => {
  ...
});
```

`serviceAccount` ending in `@` expands to `clue-export-reader@<project>.iam.gserviceaccount.com` at deploy (`firebase-functions` 5.1.1, `lib/common/encoding.js:67-71`), so one source line names each project's own account. `invoker: "public"` because report-server calls with the bearer, not a Google identity; the bearer is the gate (R18).

Handler order, each refusal `{success: false, error}`:
1. Not POST: 405.
2. `req.query.bearer` or `req.body?.bearer` present: 400 ("bearer must be sent in the Authorization header"). Checked before the header so a token sent both ways is still refused.
3. `Authorization` not exactly `Bearer <token>`, or the token does not match: 401. Compare `sha256(sent)` with `sha256(secret)` using `crypto.timingSafeEqual`, so unequal lengths never short-circuit.
4. `validateRequest(req.body, portals)` fails: 400 with the first failing field. `portals` is `exportPortals.value()` split on commas.
5. Dispatch: `owners` to `readGroupOwners`, the rest to `walk`. A thrown read error is logged with the operation and owner count (never the body) and answers 500.

`validateRequest`:
- `operation` one of the four; `portal` on the param's list.
- Walks: `owners` a non-empty array of at most 250 (report-server sends at most `owner_limit` owners); each `class_hash` `/^[0-9a-f]{48}$/`; `kind` one of three; `uid` `/^\d+$/` for a student, `group_<int>_<segment>` for a group, `class_<that class_hash>` for a class; `portal_class_id` a positive integer; `offerings` an array of non-negative integers, at most 1,000; `inner_cursor` `null` or the operation's shape, every id a plain segment (`/^[^/.#$\[\]]+$/`, the characters no RTDB key may hold; a CLUE document id is an RTDB key); `limit` 1 to 500, `owner_limit` 1 to 250, `read_limit` 1 to 5,000 (`kMaxLimits`).
- `owners`: `classes` a non-empty array of at most 1,000 `{class_hash, offerings}` with the same checks.

The walk (`clue-export-walk.ts`), for owner `o` at offset `k` of the slice, while no limit is hit:

1. **Candidates**: Firestore `authed/{escapeKey(portal)}/documents` `where("context_id", "==", o.class_hash).where("uid", "==", o.uid)` (all of them; one read per document) and RTDB `/authed/portals/{escapeKey(portal)}/classes/{o.class_hash}/users/{o.uid}/documentMetadata` (one read). Merge by document id: the Firestore id, or the RTDB key, which are equal (requirements, Background). `escapeKey` is `shared/shared.ts`'s.
2. **In scope** (R7): offering = the first *present* value of RTDB `offeringId`, Firestore `offeringId`, and for a group the `<off>` in its uid, where present means a non-empty string or a number. CLUE types `offeringId` as a string that is `""` outside a portal (`shared/shared.ts:182`), so `""`, `null` and a missing field all mean no offering and fall through to the next source; `Number("")` would otherwise make it offering 0 and drop exactly the offering-less documents R7 keeps. A document is in scope when no source has an offering, or when the offering, parsed as a base-10 integer, is in `o.offerings`; a present value that is not an integer is out of scope. R13's `offering_id` is that same value as a number, or `null`.
3. **Order and cursor**: sort the in-scope ids with plain string comparison. For the slice's first owner only (`k == 0`), drop ids `<=` the request's `inner_cursor.docId` (`<` for history, so the cursor's own document resumes); every later owner starts from its first id, as in `bulk_read` (`functions/src/api/bulk-read.ts:238`).
4. **Per operation**:
   - `documents`: one R13 row per id, built from both stores' objects; one read already counted.
   - `content`: read `classes/{hash}/users/{uid}/documents/{id}` (one read each) and build the R15 row; `found: false` with nulls when absent.
   - `history`: for each id, `history` subcollection `orderBy("index").orderBy(FieldPath.documentId())`, `startAfter(cursor.index, cursor.entryId)` for the cursor's document, `limit(max(1, min(remaining items, remaining reads, 500)))`, building R14 rows; a short batch ends the document. The floor of 1 matters: on the emulator with Admin SDK 12.3.1, `limit(0)` returns every entry and a negative limit throws `INVALID_ARGUMENT`.
5. **Budget**: each item's `Buffer.byteLength(JSON.stringify(item))` counts against 8 MB; the first item of a page is always admitted, whatever the byte or read count (R11), so until the page holds an item neither the read limit nor the budget stops the walk (an owner that yields nothing is walked to its end, which its whole-owner candidate read bounds anyway), and a later one that would cross the budget stops the page before it. Hitting `limit`, `read_limit` or the budget after owner `k` has served an item answers `stop_owner_offset: k`, `owner_exhausted: false` and a cursor naming `k`'s last admitted item. Hitting one inside owner `k` before it has served any item answers `stop_owner_offset: k - 1`, `owner_exhausted: true` and a null cursor, since `k - 1` was walked to its end; `k` is never 0 there, because the page's first item is always admitted. Finishing an owner moves to the next until `owner_limit` owners are walked or the slice ends; the last owner walked is `stop_owner_offset`.
6. `served_owner_offsets` is every `k` that contributed an item.

Both stores are read whole for one owner because an owner's metadata is small (ten documents for a staging student, requirements Technical Notes) and sorting in the function avoids relying on the two stores ordering keys alike: RTDB orders integer-like keys numerically, Firestore orders ids as strings.

R14 extraction is a pure function of the stored document (`toHistoryRow(docId, snap)`): `JSON.parse(entry)` in a `try`; `parse_ok` false nulls every extracted field; `created` and `server_created` as ISO 8601 UTC (`new Date(ms).toISOString()`, `Timestamp.toDate().toISOString()`), `null` when not a finite number; `n_records` the array length or `null`; `is_revert` `=== true`; `entry_uid` the string or `null`; `entry_json` the stored string unchanged.

`readGroupOwners`: for each class and offering, `ref("authed/portals/{portal}/classes/{hash}/users").orderByKey().startAt(\`group_${off}_\`).endAt(\`group_${off}_\`)`, answering the keys only (requirements R17).

Tests without the emulator (`clue-export-request.test.ts`): call the exported handler with a hand-built request and response (stage 4 confirmed the v2 handler runs that way), with `CLUE_EXPORT_BEARER` and `CLUE_EXPORT_PORTALS` set in `process.env`, which is where a param's `value()` reads at run time: GET is 405; no header, a wrong token, `Basic x` and a right token with a trailing space are 401; a right token also sent as `?bearer=` or in the body is 400; each malformed field above is 400 and names the field; a portal off the list is 400. `toHistoryRow` over a parseable entry, an unparseable one and one without `isRevert`/`uid`. `deploy-env-files.test.ts` then requires `CLUE_EXPORT_PORTALS` in both `.env` files with no change to that test.

Emulator tests (`clue-export-emulator.test.ts`, run by `npm run test` while `npm run test:emulator` holds the Firestore and RTDB emulators up, as the other `*-emulator.test.ts` files are, `functions-v2/README.md:62-63`): seed one class with a student (documents in offerings 701, 702 and none), a group of 701, a group of 702, the class owner, a document present only in RTDB metadata and one only in Firestore, and a history of 7 entries with duplicate and gapped `index`. Then:
- `documents` for the student with offerings `[701]` returns the 701 and no-offering documents, not the 702 one, and both single-store documents with the right `metadata_sources`.
- `history` walked with `limit: 3` to exhaustion returns all 7 entries once in `(index, entryId)` order and no item twice; an entry is never split (every item's `entry_json` equals the seed byte for byte).
- `documents` over two owners whose ids interleave (owner 0 holds `m`, `n`; owner 1 holds `a`, `b`), with the test budget set so owner 1's first document does not fit, answers `stop_owner_offset: 0` exhausted, and the next call from owner 1 with a null cursor returns `a` and `b`; with the default budget, a call from owner 0 with cursor `{docId: "m"}` returns `n`, `a` and `b`.
- `content` for a document with no RTDB node is `found: false`; one with a 2 MB content string with `limit: 500` comes back whole and alone when the budget is set low through a test-only parameter of `walk` (the handler always passes 8 MB).
- The other two stops (R11): `documents` over three owners with `owner_limit: 2` answers `stop_owner_offset: 1`, exhausted, with only the first two owners' documents; `history` with `read_limit: 4` stops inside the 7-entry document with a cursor, and walking on from it returns the rest with no gap.
- `owners` for class offerings `[701]` returns the 701 group only, and nothing for an offering with no groups.
- Never writes: a full export of every route leaves an RTDB `get()` of the root and a Firestore listing of the seeded collections identical before and after.

Read-only by IAM (R19) is a deploy property, not testable on the emulator, and is checked on staging in the rollout below.

---

### cloud-formation: pass the CLUE export settings to report-server

**Summary**: R20's stack half, in `~/projects/cloud-formation` on `master` `4aa6b8a`, one PR.

**Files affected**:
- `fargate/report-server.yml`: two parameters beside `PackageBuckets` and two environment entries beside `PACKAGE_BUCKETS` (`:266-267`).

**Estimated diff size**: ~20 lines

```yaml
  ClueExportUrls:
    Type: String
    Default: ""
    Description: JSON object mapping each portal server to CLUE's clueExport function URL in that portal's CLUE
                 project, e.g. {"learn.concord.org":"https://clueexport-<hash>-uc.a.run.app"}. Empty disables CLUE export.
  ClueExportToken:
    Type: String
    Default: ""
    NoEcho: true
    Description: The bearer clueExport checks, from the CLUE project's CLUE_EXPORT_BEARER secret. Required when ClueExportUrls is set.
```

```yaml
            - Name: CLUE_EXPORT_URLS
              Value: !Ref ClueExportUrls
            - Name: CLUE_EXPORT_TOKEN
              Value: !Ref ClueExportToken
```

Empty defaults let the template deploy before the function exists: report-server boots with `%{}` and answers 503 on the CLUE routes until the stack is updated with values.

---

### Rollout and acceptance (no code)

**Summary**: the order the three PRs deploy in, and R24's two checks. Doug runs each deploy on his own go; this section is the checklist.

1. **Staging CLUE** (`collaborative-learning-staging`), through `releasing-clue`: create the service account `clue-export-reader` with `roles/datastore.viewer` and `roles/firebasedatabase.viewer`; create the secret `CLUE_EXPORT_BEARER` (a fresh 32-byte random value) and grant the account `roles/secretmanager.secretAccessor` on it; deploy `functions-v2`. Check the deployed function's service account is `clue-export-reader@…` and that a write attempted with that account's token is refused (R19; the requirements' open check that the Admin SDK's RTDB reads work under `firebasedatabase.viewer` is settled here).
2. **report-server** to staging (the `release-report-server` skill), with the two migrations; then the `report-service-qa` stack with `ClueExportUrls` and `ClueExportToken` set. Before step 2's stack values, the routes answer 503. The `clue_prepull` drop is destructive: from the migration task until the stack update replaces the old tasks, the package catalog's list, resolve and publish fail on staging, and rolling staging back past this release needs that migration rolled back first (`ReportServer.Release.rollback(ReportServer.Repo, 20261022120000)` in a one-off task, since `migrate-task.sh` only reports and applies). Production has no package tables, so its release creates and drops in one run with no window.
3. **Staging acceptance** (R24): a Student ID Mapping run over class `7be899cf…` on `learn.portal.staging.concord.org`, exported through all three routes with `limit=7` so the 26,632-entry document resumes mid-document, compared with a direct read of the same class (document, entry and content counts; no duplicate `(doc_id, entry_id)`; no gap in the per-document entry list); the audit page shows one intent row and one row per page with `item_count`.
4. **Production**: the same three steps against `collaborative-learning-ec215` and `report-service-prod`, in sprint 29 with the rest of the production list (`plan.md`).
5. **Production acceptance, REPORT-109's last step**: a run filtered by class only, to every class his corpus's `context_id`s name (class hashes mapped to portal class ids with one portal query), with no assignment, date or other filter. Every one of his August capture's 4,674 documents must be present, including the 73, except the two expected exclusions R24 names: teacher-owned documents and documents of a student with no learner row in the class, each counted and listed with its owner and reason. The additional documents are listed by `owner_kind` and offering so each is accounted for.

## Open Questions

### RESOLVED: R24's superset criterion under offering scoping
**Context**: requirements R24 leaves to this spec whether to require a run that selects every offering Scott's corpus covers, or to restate the criterion.
**Options considered**:
- A) Keep the criterion and fix the run: filter by class only, to every class his corpus covers. Under D1 a class-only filter gives each student owner every offering they have a learner in, and the no-offering rule keeps the rest, so the superset follows unless a document sits in an offering where its owner has no learner row.
- B) Restate the criterion as "every document of his in an offering the run selects".

**Decision**: A, with two named exclusions (Doug, 2026-10-22): teacher-owned documents and documents of a student with no learner row in the class are counted and listed, not failures. It tests the claim as Jira states it for every population the design covers, and B is weaker by construction: a run that selects nothing satisfies it. Including teacher documents in scope was considered and left out of this story.

### RESOLVED: Judgment call: a separate controller over shared helpers, not a parametrized `BulkExportController`
**Context**: the CLUE routes repeat the bulk routes' page skeleton but differ in the scope, the wire shape (`stop_owner_offset`, `served_owner_offsets`, no `touched_endpoints`), the 503 gate and the audit keys.
**Options considered**:
- A) `ClueExportController`, with the gates and helpers extracted into `EndpointSet.fetch_learners/2` and `BulkExport`.
- B) One controller with a per-route strategy module.

**Decision**: A. B threads a strategy through every branch of a controller whose tests already pin it; A changes the bulk controller only by moving three helpers out, which its existing tests guard.

### RESOLVED: Judgment call: the function applies the offering rule, report-server supplies it
**Context**: R7's offering test needs the document metadata, which only the function reads.
**Options considered**:
- A) Send each owner's offerings in the request; the function filters.
- B) The function returns every candidate; report-server filters.

**Decision**: A. B would send out-of-scope student work across the wire and count it against the page budget, and the function would still need a second pass for history and content of in-scope documents only. The function stays authorization-blind in the sense R18 means: it trusts the request's scope and only validates its shape.

### RESOLVED: Judgment call: the portal allow-list is a deploy-time param, not code
**Context**: R18 asks the function to refuse portals outside its project's.
**Options considered**:
- A) `defineString("CLUE_EXPORT_PORTALS")` in each `.env.<project>` file.
- B) A map from project id to portals in the source.

**Decision**: A. The per-project env files are where `functions-v2` already keeps per-project config, and `deploy-env-files.test.ts` fails if either file lacks the param.

## Self-Review

Roles: Senior Engineer, Security Engineer, Commit Reviewer, Test Writer, Operator, cc-data client author. Each finding was checked against the code, CLUE's source or a throwaway run before it was recorded; findings with one defensible correction are fixed in place.

### Senior Engineer

#### RESOLVED: An empty `offeringId` would have been read as offering 0
CLUE types `offeringId` as a string that is `""` outside a portal (`shared/shared.ts:182`, `src/lib/db-types.ts:71`), and the first draft compared it with `Number()`, which makes `""` offering 0 and puts the document out of scope, the opposite of R7's no-offering rule. The walk now treats `""`, `null` and a missing field as no offering at each source and falls through to the next.

#### RESOLVED: `URI.parse/1` lowercases the scheme, not the host
Checked with `elixir -e`: `HTTPS://Collaborative-Learning.Concord.Org/x` parses to scheme `"https"` and host `"Collaborative-Learning.Concord.Org"`. The note under `writes_clue_documents?/1` said the opposite; corrected, and the uppercase-host test case pins it.

### Security Engineer

#### RESOLVED: Each page sent every remaining owner to the function
The draft copied `bulk_read`'s `Enum.drop(endpoints, index)`, so page 1 of a large run would POST every owner's class hash, uid and offerings although the function walks at most 250. The controller now sends `Enum.take(@owner_limit)` of the slice and the function refuses more than 250, which also bounds the request a leaked bearer can make. The cursor math is unchanged: offsets are relative to the slice either way.

### Test Writer

#### RESOLVED: R8's two empty-scope cases had no named test
"No learner with a class hash" and "no learner on a CLUE-writing host" both end in an empty terminal page with an intent row, and neither may call the function. Added to the controller tests with a stub that raises if called, so a regression that reaches the `owners` call fails loudly.

#### RESOLVED: The client stub needs both of the controller's calls
The controller asks the client for `url_for/1` before anything else and `call/2` for every page; a stub with only `call/2` would make the 503 test untestable through the same seam. The stub's description now names both.

### Commit Reviewer

Every step compiles and passes on its own: the schema step adds names nothing calls yet; the helper extraction is guarded by the unchanged bulk tests; the scope step has no controller dependency; the client step's config defaults to `urls: %{}`; the controller step comes after all of them. Nothing found.

### Operator

Nothing found beyond what the rollout already orders: the template's empty defaults let it deploy before the function exists, and a missing entry is a 503, not a boot failure.

### cc-data client author

Nothing found: the envelope, token and termination rule are the bulk endpoints', and the items are R13 to R15's shapes passed through unchanged. REPORT-110's coverage note in the requirements still applies.

### Second pass (2026-10-22): Senior Engineer, Security Engineer, Test Writer, Commit Reviewer, Operator

Each finding below was checked against the code, CLUE's `origin/master` or a throwaway run (deleted afterwards) before it was recorded.

#### RESOLVED: Senior Engineer: a budget stop at an owner boundary lost the next owners' documents
The walk said "the cursor names the last admitted item" and did not limit the incoming cursor to the slice's first owner. A page that stopped before owner `k`'s first item answered `k` with owner `k - 1`'s last id as the cursor, and the resumed walk dropped every id of `k` that sorts at or below it. A throwaway simulation through `serve_page`'s cursor math (3 owners, 5 documents, budget 10) delivered 2 documents as worded and all 5, once each, with the fix. `bulk_read` never hits this because it admits each endpoint's first item (`bulk-read.ts:72`) and starts only offset 0 from the cursor (`:238`). Walk steps 3 and 5 now say both rules, and an emulator test pins them.

#### RESOLVED: Senior Engineer: the reason given for `retry: false` was wrong
Req 0.4.14's default `:safe_transient` retries only GET and HEAD (`deps/req/lib/req/steps.ex:2106`). A throwaway `Req.Test` run answered 503 to one POST with a single attempt and retried a GET three times. The option stays as a statement of the rule; the note now says that.

#### RESOLVED: Security Engineer: Elixir accepted cursor ids the function refuses
The drafted clauses reused `check_doc_id/1`, which refuses only `/`. A throwaway run of the clauses accepted `a.b`, `a#b`, `a$b`, `a[b` and `a]b`, which the function's id pattern refuses, so a hand-made token got the function's 400 collapsed to 500, against R10. The CLUE clauses now use `check_clue_key/1` with the function's character set (checked with `elixir -e`), and the cursor test covers `.` and `#`.

#### RESOLVED: Operator: the audit page cannot show `item_count`
Rollout step 3 reads `item_count` off the audit page, but its Access cell renders only `data_type`, `event`, `source` and the job id (`audit_log_live/index.html.heex:50-51`), and no step changed it. The schema step now adds the count to that cell, with a LiveView test. Checking the column directly would instead need a staging database session, which the acceptance otherwise does without.

#### RESOLVED: Test Writer: the "no report role" fixture is not in the bulk controller's tests
`bulk_export_controller_test.exs` has the not-owned run (`:82-86`) but no role-denied user; that setup is `auth_plug_test.exs:45-61`. The controller step now cites both.

#### RESOLVED: Test Writer: `npm run test:emulator` does not run jest
In `functions-v2/package.json` it only starts the Firestore and RTDB emulators; `npm run test` runs every jest file beside them (`functions-v2/README.md:62-63`). Corrected in the CLUE step.

#### RESOLVED: Commit Reviewer: the schema step named test files that do not exist
`test/report_server/audit_log/data_access_log_entry_test.exs` and `test/report_server/exports/export_scratch_test.exs` do not exist; the `data_type` refusal test is `audit_log_test.exs:126` and the scratch tests are `exports_test.exs`. The step now extends those.

Checked with no finding: `Scope`, `writes_clue_documents?/1`, the `BulkParams` clauses, the `runtime.exs` block and `ClueExport` compile against the real deps and pass the spec's cases (frozen owners round-trip through JSON unchanged); a throwaway copy of the `fetch_learners/2` split answers what `derive_endpoint_set/2` answers for every gate outcome and run kind, so `AttachmentController` and the bulk tests are unaffected; the `clue_prepull` line citations, the cloud-formation lines (`:232`, `:266-267` on `4aa6b8a`) and the parameters' YAML hold; `firebase-functions` 5.1.1 params read `process.env` at run time (`lib/params/types.js:273` for a secret, `:303` for a string); and `CLUE_EXPORT_PORTALS`'s comma list passes `deploy-env-files.test.ts`'s line pattern.

### Third pass (2026-10-22): Senior Engineer, Test Writer, Operator, Commit Reviewer, cc-data client author

Each finding below was checked against the code, CLUE's `origin/master`, the emulator or a throwaway run (deleted afterwards) before it was recorded.

#### RESOLVED: Senior Engineer: a run over more than 1,000 classes could never start
First-page step 4 sent every class in one `owners` call, and the function refuses more than 1,000 `classes`, so such a run would answer 500 on every first page. Step 4 now sends chunks of at most `@owner_limit` classes and concatenates the groups, within the existing wire contract; a controller test pins the split at 251 classes.

#### RESOLVED: Senior Engineer: a history batch could be sized zero
Walk step 4 sized a batch `min(remaining items, remaining reads, 500)`, which reaches 0 or below only on the page's first item, which step 5 admits "whatever the read count". On the emulator (Admin SDK 12.3.1) `limit(0)` returned all 5 seeded entries and `limit(-1)` threw `INVALID_ARGUMENT`. The batch now has a floor of 1, and step 5 says neither limit stops the walk before the page's first item, which is what keeps "`k` is never 0 there" true.

#### RESOLVED: Test Writer: the owner and read limits had no test
R11 lists four stops, and only `limit` and the byte budget were exercised: the controller tests stub the function, and no emulator case set `owner_limit` or `read_limit` below what the seed needs, so deleting either check left the suite green. Two emulator cases added.

#### RESOLVED: Commit Reviewer: the `config/test.exs` line could not take effect
`runtime.exs` runs under `mix test` (a throwaway test read `:portal_report`, which only `runtime.exs` sets) and a later `config` for the same key wins, so the drafted block's unconditional `config :report_server, :clue_export` replaced the `test.exs` line. The line is dropped; the client step now says the unset default is what gives the 503.

#### RESOLVED: Commit Reviewer: REPORT-150 also touches the audit page
PR #444's branch edits `audit_log_live/index.html.heex` (Run cell) and `audit_log_live_test.exs`, which the schema step now edits too. The overlap note names both; the hunks are three lines apart, so a rebase is mechanical.

#### RESOLVED: cc-data client author: the README's scope sentence dropped the no-offering rule
"Narrowed by the run's offerings" alone would tell a researcher that the roughly 890 offering-less documents are excluded. The README content now says they are kept.

#### RESOLVED: Operator: dropping `clue_prepull` breaks the image the release replaces
The release skill migrates before the stack update (`.claude/skills/release-report-server/SKILL.md`, step 6), and Ecto names every schema field, so the old image's `SELECT` includes `clue_prepull` (a throwaway `to_sql` of `PackageVersion` showed it). From the drop until the new tasks replace the old ones, the catalog's list, resolve and publish fail; a rollback to the previous image breaks them until the migration is rolled back. The skill counts this as a destructive migration the user must be told about.
**Options considered**:
- A) Keep R21 as one release, and add to rollout step 2 that the catalog fails during the stack update and that a rollback past this release needs the migration rolled back first.
- B) Ship the field removal in REPORT-109's release and the drop migration in the next report-server release, so the image that meets the dropped column never reads it. R21 still holds; only the migration's release moves.

**Decision**: A (Doug, 2026-10-22). Production has no package tables, so its release creates `package_versions` and drops the column in the same migration run, and no running image there ever reads it; the window exists only on staging, for the minutes of the stack update. Rollout step 2 says so.

Checked with no finding: rigse writes `class_hash` only as `SecureRandom.hex(24)` and backfilled every class (`rails/app/models/portal/clazz.rb:301-302`, `rails/db/migrate/20170202190333_add_class_hash.rb`), so every hash passes the function's 48-hex check; learner `class_id`, `user_id` and `offering_id` are integers, so `portal_class_id`, `uid` and `offerings` always pass; CLUE stamps `context_id` on every kind's Firestore metadata and keeps synthetic owners' RTDB nodes under `users/{owner}` (`src/lib/db.ts:681-685`, `:800-805`), so R7's candidate reads find group and class documents; CLUE deletes documents only by an `isDeleted` property or a dev-mode admin action, so the production superset check is not undercut by deletions; the item-count span and its LiveView test work with `audit_log_live_test.exs`'s `create_entry/3`; both new migrations are reversible and sort after REPORT-150's `20261021180000`; two concurrent exports share no row, and the TTL bump is an absolute `SET`, so a retried page racing it converges; every R-number is cited by a step, R9 through "R8 to R12".
