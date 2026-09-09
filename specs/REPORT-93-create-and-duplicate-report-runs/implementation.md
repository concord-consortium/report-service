# Implementation Plan: Create and duplicate report runs

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-93
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

Two repositories. Steps one to ten are `report-service` and land as one PR; steps eleven to thirteen are `cc-data-cli` and land as a second PR that needs the server deployed to be useful. The scoped source lands before the label lookup that reads it, so the commits are one, three, two, then four onwards. Every requirements question is resolved. The two that shaped this plan: an id is usable exactly when `filter-options` offers it, which is steps two, three and four sharing one per-dimension definition, and the partition warning is not reproduced on the API, which is why no step below computes an estimate.

## Implementation Plan

### Pin the status-to-code direction and add the duplicate-guard code

**Summary**: `ErrorHelpers` inverts `@statuses` to answer `code_for_status/1`, which silently breaks the moment a second code shares a status. The Portal guard needs a 409 code, so the direction is made explicit first, on its own, before anything depends on it.

**Files affected**:
- `server/lib/report_server_web/api/error_helpers.ex` — add `PORTAL_DUPLICATE_UNNECESSARY` to `@statuses`; replace the `@codes_by_status` inversion with an explicit map naming one primary code per status.
- `server/test/report_server_web/api/error_helpers_test.exs` — new.

**Estimated diff size**: ~70 lines

`@statuses` gains one entry:

```elixir
"PORTAL_DUPLICATE_UNNECESSARY" => 409,
```

and the inversion is replaced by a declared table, with the reason it is not derived:

```elixir
  # The code a raised exception renders as, one per status. Not an inversion of @statuses: more
  # than one code can share a status (409 is both NOT_READY and PORTAL_DUPLICATE_UNNECESSARY),
  # and inverting picks whichever the map happens to yield last.
  @primary_code_by_status %{
    400 => "BAD_REQUEST",
    401 => "NOT_AUTHENTICATED",
    404 => "NOT_FOUND",
    409 => "NOT_READY",
    410 => "EXPIRED_CURSOR",
    422 => "UNPROCESSABLE",
    500 => "SERVER_ERROR",
    503 => "SERVICE_UNAVAILABLE"
  }

  def code_for_status(status), do: Map.get(@primary_code_by_status, status, "SERVER_ERROR")
```

Tests, in both directions, because one direction alone reintroduces the defect in a new shape. Forward: every status in `@primary_code_by_status` maps to a code that exists in `@statuses` and carries that status, which is the agreement a hand-written table can lose. Backward: every status appearing in `@statuses` is a key in `@primary_code_by_status`. Then `code_for_status(409) == "NOT_READY"` and an unmapped status is `SERVER_ERROR`.

The backward assertion is the one that is easy to leave out and the one that matters most. Verified by running the plan's original three assertions against a `@statuses` that had gained `"TOO_MANY_REQUESTS" => 429`: they all still pass, while `code_for_status(429)` silently returns `SERVER_ERROR` where today's inversion returns the right code. Without it, this step trades a defect that fires when two codes share a status for one that fires when a code introduces a new status.

### Escape the state dimension and make label derivation report its failures

**Summary**: `ReportFilter.get_filter_values/2` interpolates `state` values into SQL unescaped, returns `%{}` for both "no id dimensions" and "the portal query failed", and resolves any id it is handed regardless of who is asking. All three are fixed here, before any new caller exists.

**Files affected**:
- `server/lib/report_server/reports/report_filter.ex` — escape `state`; return a tagged tuple; recognize the empty-statement case without querying.
- `server/lib/report_server_web/live/report_live/form.ex` — unwrap the tuple at the one existing call site.
- `server/test/report_server/reports/report_filter_values_test.exs` — new, DB-backed.

**Estimated diff size**: ~170 lines

The `state` branch loses its hand-rolled quoting, and with the id expression coming from `DimensionScope` the same line stops naming a column at all:

```elixir
  # id_expr is DimensionScope.id_expr(:state), COALESCE(portal_schools.state, '(Unknown)')
  ["SELECT DISTINCT '#{dimension}' AS table_name, #{id_expr} as id, #{label_expr} as name " <>
   "FROM #{from} #{joins} WHERE #{id_expr} IN #{mysql_string_list_to_in(ids)} #{scope}" | acc]
```

`mysql_string_list_to_in/1` already brackets its own output, so the surrounding parentheses go with the interpolation, and it is the escape that closes the injection. `ReportServer.Reports.ReportUtils` is imported for it. The nine integer dimensions take `list_to_in/1` on the same shape, which is what makes them one generated select rather than ten hand-written ones.

The `DISTINCT` is not cosmetic and is the reason the hand-written `GROUP BY state` can go. Today's selects need neither because they touch one table; adding the scope joins makes each one fan out by teachers times cohorts per entity. Measured on a synthetic school with twenty teachers in five cohorts each, the scoped select returns 100 rows where the distinct form returns 1, and a filter naming fifty schools multiplies that again across a `UNION ALL` on a request path. `get_options_sql/1` already carries `SELECT DISTINCT` for exactly this reason (`report_filter_query.ex:922-925`), which is another way of saying the two queries should look alike.

The per-dimension selects stop being hand-written. Each one is generated from `DimensionScope`'s id expression, base and scope predicate, so an id resolves exactly when `filter-options` would have offered it. Only the label expression stays local to this module, because that is the one part option discovery projects differently:

```elixir
      {:ok, values} ->
        case unresolved(report_filter, values) do
          [] -> {:ok, values}
          missing -> {:error, :out_of_scope, missing}
        end
```

`unresolved/2` compares the ids asked for against the ids the shared expression resolved, per dimension, so the error names the dimension and the specific ids rather than saying the filter was rejected. Sharing the id expression is what keeps that honest: `state`'s option id is `COALESCE(portal_schools.state, '(Unknown)')`, so the select's `IN` target is that expression too and `(Unknown)` resolves like any other value. Verified both directions against the fixture: today's `state IN ('(Unknown)','ma','NH')` resolves `["NH", "MA"]` and silently drops the offered `(Unknown)`, while the shared expression resolves all three and returns `ma` as `MA`.

Because the resolved id is canonical and the asked-for one may not be (MySQL's collation is case-insensitive), the create stores what came back rather than what was sent. That is one line in the caller, and it is what stops two runs with the same filter from being stored differently.

The return becomes `{:ok, map} | {:error, reason}`, and the empty reduction is recognized before the query rather than by letting MySQL reject an empty statement:

```elixir
  def get_filter_values(report_filter = %ReportFilter{}, user = %User{}) do
    case build_value_selects(report_filter) do
      [] ->
        {:ok, %{}}

      selects ->
        case PortalDbs.query(user.portal_server, Enum.join(selects, "\nUNION ALL\n")) do
          {:ok, results} -> {:ok, group_values(results)}
          {:error, error} -> {:error, error}
        end
    end
  end
```

The `Logger.error` inside the error branch goes: the caller now sees the reason and decides, and a helper that both logs and returns the failure produces two lines per failure at different levels of the stack.

`ReportLive.Form.create_run/2` is the only existing caller. It unwraps and keeps its current lenient behavior explicitly rather than by accident:

```elixir
    # the form has always created the run even when the labels could not be derived; the run is
    # still valid and its filter still runs, so a failed lookup degrades the display, not the run
    report_filter_values =
      case ReportFilter.get_filter_values(report_filter, user) do
        {:ok, values} -> values
        {:error, error} -> Logger.error("Unable to derive filter values: #{inspect(error)}"); %{}
      end
```

Tests: the injection regression, asserting that `state: ["CA') OR 1=1 -- "]` returns no rows rather than every state (this is the mutation the escape catches; without it the fixture returns every state, which stage 2 confirmed); a filter with only `app` and dates returns `{:ok, %{}}` without touching the portal; a filter with ids returns the labels; each of the ten dimensions derives its documented label shape; a scoped caller asking for an id outside their projects gets `{:error, :out_of_scope, [{:cohort, [7]}]}` while a super-admin gets the label, which is the pair that fails if the scoping is added but `unresolved/2` is not; the three taxonomies resolve for a scoped caller; `state: ["(Unknown)"]` resolves against a fixture school with a null state, which is the assertion that fails the moment the label select stops using the option query's id expression; `state: ["ma"]` resolves and is stored as `MA`.

### One scoped source per filter dimension

**Summary**: "which entities of dimension D may this user see" exists in two shapes already and the label lookup needs a third. It becomes one module instead, with `get_filter_values/2` as its first caller.

**Files affected**:
- `server/lib/report_server/reports/dimension_scope.ex` — new.
- `server/lib/report_server/reports/portal/detailed_metrics_by_school_report.ex`: delete the dead `country: -1` branch.
- `server/lib/report_server/reports/portal/summary_metrics_by_subject_area_report.ex`: the same.
- `server/test/report_server/reports/dimension_scope_test.exs` — new, DB-backed.

**Estimated diff size**: ~230 lines

The module answers one question per dimension: the expression that *is* the id, the base table, the joins that reach a project, and the predicate that restricts it. The values are lifted verbatim from `ReportFilterQuery`'s `@join_patterns`, its ten `build_base_query/1` configs and its seven `get_filter_query/5` scoping clauses rather than rewritten, so adoption later is a move, not a reconciliation.

The id expression is nine primary keys and one synthesized value: `state` is `COALESCE(portal_schools.state, '(Unknown)')`, which is why `(Unknown)` is an offered option and why anything that resolves ids by hand gets it wrong. Holding it here is what makes "resolvable" and "discoverable" the same predicate rather than two that have to be kept in agreement:

```elixir
  @doc """
  The joins and predicate that restrict `dimension` to what `allowed` covers, or `:none` when the
  dimension is a global vocabulary that is deliberately unscoped.

  `:all` (a portal super-admin) scopes nothing. An empty list or `:none` is a caller who can see no
  project-scoped data, which is not the same as "no restriction": it restricts to nothing.
  """
  def scope(dimension, allowed)
```

Three cases carry the detail that a rewrite would lose. `:cohort` needs no join at all, just `admin_cohorts.project_id IN (...)`. `:assignment` is the only disjunction, `(ac.project_id IN (...)) OR (apm.project_id IN (...))`, because an activity reaches a project either through a cohort or through `admin_project_materials`, and it is also the only one whose joins are `LEFT` for that reason. `:teacher` anchors on `portal_teachers.id`, which is why the label select is built from this module's own base rather than keeping the label query's `pt` alias: sharing the base is what lets the scope joins be literals rather than a parameterized anchor.

`:country`, `:state` and `:subject_area` return `:none` (unscoped), which is REPORT-92's recorded decision that the three are global taxonomies carrying no per-person data, and is a decision worth being able to point at rather than infer from a missing clause. They still carry an id expression, so membership for those three is "this id exists" rather than "no check at all".

The module deliberately does **not** expose the cascade. Membership is against the unnarrowed option set: a caller may name a cohort and a school that do not intersect, and that is an empty report, not a bad request. An implementation that reached for `ReportFilterQuery.get_query_and_params/4` instead would inherit `apply_secondary_filters/4` and start refusing valid combinations, which is the specific mistake this note exists to prevent.

The `Enum.member?(country, -1)` branches in `DetailedMetricsBySchoolReport` (`detailed_metrics_by_school_report.ex:57-67`) and `SummaryMetricsBySubjectAreaReport` (`summary_metrics_by_subject_area_report.ex:112`) are deleted here, because this module states what a country id is and `-1` is not one. Verified it never was: the `:country` option query has projected `portal_countries.id` since `89aad07` added the reports and the filter in one commit, with the `COALESCE` on the label only, so no form submission or option response could ever have produced it.

An `{:error, reason}` from the allowed-projects lookup raises `AllowedProjectsLookupError`, matching `ReportUtils.scope_by_allowed_projects/5`'s existing convention that a failed permission lookup must never be swallowed into a zero-row answer.

The portal fixture gains what those tests need and did not have: an entity outside project 900 for each scoped dimension, an activity that reaches a project only through `admin_project_materials`, and a school with no state, so `(Unknown)` is a real option to resolve.

Tests: each of the seven scoped dimensions restricts to a fixture entity inside the caller's projects and excludes one outside it; the three taxonomies are unaffected by `allowed`; `:all` returns everything; an empty list returns nothing rather than everything, which is the mutation that catches the classic inverted-empty-check bug; the assignment disjunction admits an activity reachable only through `admin_project_materials`, which a conjunction would drop; every dimension's id expression is byte-identical to the one `ReportFilterQuery` builds its options with, which is the assertion that fails if the two ever drift apart again.

### Re-point ReportFilterQuery at the shared scope

**Summary**: with the scoped source in place, `ReportFilterQuery` stops carrying the second copy. Option discovery and label resolution then share one definition of who may see what.

**Files affected**:
- `server/lib/report_server/reports/report_filter_query.ex` — the seven `get_filter_query/5` scoping branches and the `allowed_projects_*` join patterns.
- `server/test/report_server/reports/report_filter_query_db_test.exs` — unchanged assertions, re-run as the proof.

**Estimated diff size**: ~140 lines, mostly deletions

Held back while REPORT-92's PR was open, because the churn would have landed mid-review on that story's own file. #422 merged as `562bd03`, so the constraint is gone and the consolidation belongs here rather than in a follow-up nobody is tracking.

Each of the ten `build_base_query/1` configs takes its `id:`, `from:` and base `join:`/`where:` from the module, leaving only the label expression, the `LIKE` and the ordering local, and each of the seven branches currently inlines its own scoping: `:cohort` a bare `admin_cohorts.project_id IN (...)`, `:school`, `:teacher`, `:permission_form`, `:class` and `:student` a named join pattern plus `ac.project_id IN (...)`, and `:assignment` the same shape with `LEFT` joins and the disjunction over `admin_project_materials`. Those values moved into `DimensionScope` verbatim precisely so this step is a move rather than a reconciliation: the branches call the module and the `@join_patterns` entries it now owns are deleted from the map.

The proof is that the existing DB-backed statement tests are untouched and still pass. REPORT-92 established that of the 180 statements the ten dimensions generate against every secondary filter, under both `:all` and a scoped caller, exactly six changed and 174 were byte-identical; that comparison is the harness this step re-runs. A statement that differs after the move is a reconciliation error, which is the whole reason the values were lifted verbatim rather than rewritten.

`:country`, `:state` and `:subject_area` call the same function and get `:none` back, which is what makes "these three are unscoped" a stated decision rather than an absent clause. That was REPORT-92's finding, and a reader who goes looking for the missing scoping and adds it would silently change the two aggregate reports.

### Extract the form's filter validation into a shared module

**Summary**: `check_app_supported/2` and `check_apps_known/1` are private to the LiveView, and the API needs the same rules. They move to a module both call, with the dimension-offered check that the API also needs and the form gets for free by only rendering offered dimensions.

**Files affected**:
- `server/lib/report_server/reports/filter_validation.ex` — new.
- `server/lib/report_server_web/live/report_live/form.ex` — delete the two private functions, call the module.
- `server/test/report_server/reports/filter_validation_test.exs` — new.

**Estimated diff size**: ~240 lines

```elixir
defmodule ReportServer.Reports.FilterValidation do
  @moduledoc """
  The rules a report filter must satisfy before a run is created from it. Not authorization:
  `HideNames` and the report queries' project scoping own that.

  `validate/2` is the set both the web form and the API apply. `check_no_empty_selections/1` is
  applied by the API only, and is public rather than folded in so that stays a decision someone
  made rather than an omission: a half-filled filter row is a live editing state in the form,
  where the submit gate already prevents the common case, and a finished request over the API.
  """

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.{FilterOptions, Report, ReportFilter}

  def validate(report_filter = %ReportFilter{}, report = %Report{}) do
    with :ok <- check_app_supported(report_filter, report),
         :ok <- check_dimensions_offered(report_filter, report) do
      :ok
    end
  end

  # `[]` narrows a filter-options request to nothing and constrains a run to nothing, because the
  # report queries gate every dimension on have_filter?/1. Accepting it would answer a request to
  # select nothing with a run over everything the caller can see.
  def check_no_empty_selections(report_filter = %ReportFilter{}) do
    case Enum.filter(ReportFilter.dimensions(), &(Map.get(report_filter, &1) == [])) do
      [] -> :ok
      empty -> {:error, :invalid, "no values selected for: #{Enum.join(empty, ", ")}"}
    end
  end

  # Whether the filter expresses any constraint at all, which is what an Athena create is judged
  # by because its report's query builder is not affordable in a request. hide_names and
  # exclude_internal are modifiers, not constraints: neither narrows anything on its own.
  # The dates are interpolated raw into the portal statement by apply_start_date/3, so nothing
  # downstream can make an unparseable one safe. Applied by the API parser and again by the
  # context function, because a duplicate is built from a stored filter and skips the parser.
  def check_dates(report_filter = %ReportFilter{}) do
    case Enum.reject([start_date: report_filter.start_date, end_date: report_filter.end_date], &valid_date?/1) do
      [] -> :ok
      bad -> {:error, :invalid, "#{Enum.map_join(bad, ", ", fn {key, _} -> key end)} must be an ISO 8601 date (YYYY-MM-DD)"}
    end
  end

  defp valid_date?({_key, value}) when value in [nil, ""], do: true
  defp valid_date?({_key, value}) when is_binary(value), do: match?({:ok, _}, Date.from_iso8601(value))
  defp valid_date?(_), do: false

  def check_constrains_anything(report_filter = %ReportFilter{}) do
    dimensions = Enum.any?(ReportFilter.dimensions(), &(Map.get(report_filter, &1) not in [nil, []]))
    others = [report_filter.start_date, report_filter.end_date] |> Enum.any?(&(to_string(&1) != ""))

    if dimensions or others or ReportFilter.app_list(report_filter.app) != [] do
      :ok
    else
      {:error, :invalid, "a filter must name at least one dimension, date or application"}
    end
  end

  def check_app_supported(%ReportFilter{app: app}, report = %Report{}) do
    case ReportFilter.app_list(app) do
      [] -> :ok
      apps -> if offers_app_filter?(report), do: check_apps_known(apps), else: {:error, :invalid, "This report does not support an application filter."}
    end
  end

  def check_dimensions_offered(report_filter, report) do
    case Enum.reject(selected_dimensions(report_filter), &offered?(&1, report)) do
      [] -> :ok
      unoffered -> {:error, :invalid, "This report does not filter on: #{Enum.join(unoffered, ", ")}"}
    end
  end
end
```

`offers_app_filter?/1` is **not** moved. It stays on `AthenaFailure` and this module calls it, exactly as `AppDimension.enabled_for_report?/1` already does (`filter_options/app_dimension.ex:20`, with a comment explaining that the API gates `app` by the same `form_options` flag the web form uses). The predicate already serves two modules from where it lives, so moving it would be a rename touching REPORT-106's module and its test to make a call site read marginally better. Following the existing precedent costs nothing and leaves that module alone.

`offered?/2` is the same rule `FilterOptionsController.check_dimension_offered/3` applies, static dimensions through `FilterOptions.static_dimension/1` and the rest through `report.include_filters`. The single-dimension predicate lives here and the controller calls it, so the rule has one definition rather than one per caller; `check_dimensions_offered/2` is the many-dimension wrapper this story needs.

Re-pointing that controller is safe in a way an earlier draft of this plan got wrong. `filter_options_controller.ex` was created by REPORT-92 (141 insertions, no deletions) rather than edited, and #422 merged as `562bd03`, so the file is on master and this story edits a settled one with no stack to inherit.

The form's `check_app_supported/2` took a `form_options` map rather than a `%Report{}`, so its call site changes shape; `get_form_options/2` keeps its `enable_hide_names` half, which is a rendering concern the API has no use for.

Every failure is `{:error, :invalid, message}` rather than `{:error, message}`, for the reason the Self-Review records: a bare binary is indistinguishable from a portal failure by the time it reaches the controller.

Tests: an unknown application is rejected; an application on a report without the filter is rejected; an empty application list is accepted on every report; a dimension the report does not list is rejected; the three static dimensions are judged by their own `enabled_for_report?/1`. Each assertion names a filter that differs from a passing one in exactly the field under test.

For `check_dates/1`: `"2026-01-01' OR '1'='1"` is rejected, and the mutation it catches is that same value reaching `apply_start_date/3`, which returns `run.start_time >= '2026-01-01' OR '1'='1'`; a valid ISO date and a nil are accepted; an empty string is accepted as absent, matching what the form submits for a blank control; both dates bad are named in one message.

For `check_constrains_anything/1`: an empty filter is rejected; a filter carrying only `hide_names` or only `exclude_internal` is rejected, which is the pair that fails if the modifiers are counted as constraints; a filter carrying only `app`, only `start_date`, or one dimension is accepted, the `app` case being the log run the requirements bless and the form cannot make.

For the empty-selection rule: `cohort: []` is rejected and names `cohort`; `cohort: nil` and `cohort: [1]` are both accepted, which is the pair that fails if the check is written as `Enum.empty?/1` and starts rejecting unset dimensions; two empty dimensions are both named in one message; and `validate/2` does **not** reject `cohort: []`, which is the assertion that fails if someone later folds the API-only rule into the shared set and changes the form.

### Widen FilterParams to parse a whole run filter

**Summary**: `FilterParams.parse/1` builds the subset of a filter that narrows options. Creating a run needs `app`, `hide_names` and `filters` too. One parser gains them rather than a second one being written, which is safe because neither new field reaches the options query.

**Files affected**:
- `server/lib/report_server_web/api/v1/filter_params.ex` — parse `app` and `hide_names`; derive `filters`; update the module doc.
- `server/test/report_server_web/api/v1/filter_params_test.exs` — extend.

**Estimated diff size**: ~100 lines

Verified before writing this step: with `app` and `hide_names` parsed into the struct, the whole filter-options surface stays green (62 tests across `filter_options_controller_test.exs` and `filter_options_test.exs`, 0 failures). It cannot be otherwise: `app` is not a dimension in `ReportFilterQuery` at all, and `FilterOptions.prepare/3` overrides `hide_names` with `HideNames.enforce/2` before the query is built (`filter_options.ex:165-170`).

`start_date` and `end_date` gain the validation they have never had. They are the second injection this story would open, and unlike `state` the fix belongs entirely in the parser, since the report queries interpolate them by design and are shared with the form:

```elixir
  # Interpolated raw into the portal statement by apply_start_date/3. The body lives on
  # FilterValidation as check_dates/1 so the context function can apply the same rule to a
  # duplicate, which never reaches this parser; this is the shape check a JSON body needs on top
  # of it, since a number or an object arrives here where only a binary can arrive there.
  defp date(filter, key) do
    case Map.get(filter, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, _} -> {:ok, value}
          _ -> {:error, "#{key} must be an ISO 8601 date (YYYY-MM-DD)"}
        end
      _ -> {:error, "#{key} must be a string"}
    end
  end
```

This tightens the filter-options endpoint too, which accepts anything there today and ignores it. That is a behavior change to a shipped endpoint and is deliberate: a caller sending a malformed date to `filter-options` and the same date to `create` should not be told it is fine by one and rejected by the other. The same now holds for a non-boolean `hide_names` and a non-list `app`, which that endpoint also ignored. Round-tripping a run's own filter is unaffected, since `ReportJSON.report_filter_json/1` always emits `app` as a list and `hide_names` as a boolean.

The parser is not the only caller. `FilterValidation.check_dates/1` holds the `Date.from_iso8601` rule and both this parser and `Reports.create_api_report_run/3` call it, because duplicate builds from a stored filter and never reaches a parser. A stored run can carry an unvalidated date: `ReportFilter.from_form/2` copies `form.params["start_date"]` as it arrives, and the template's `<.input type="date">` constrains a browser and not a crafted event.

`@string_dimensions` goes too: which dimension takes strings is `DimensionScope.id_type/1`'s answer, and this parser was its third copy.

`filters` is ignored here rather than derived here. The parser drops any client-supplied list, and the derivation lives in the context function so that create and duplicate produce it the same way; see that step for why the duplicate path cannot inherit it.

The module doc's "hide_names is dropped because the caller's role decides it" is now false and is rewritten: the parser carries it, and `HideNames.enforce/2` overrides it on both paths.

Tests: an injection payload in `start_date` is rejected rather than stored, and the same payload reaching `apply_start_date/3` is the mutation the rejection catches; a valid ISO date round-trips; a non-string date is rejected; an empty string is treated as absent, matching what the form submits for a blank control; `app` accepts a list of strings, rejects a non-list and rejects non-string members; `hide_names` accepts a boolean and rejects anything else; a client-supplied `filters` key is ignored and never reaches the struct.

### Create runs through the context, not the controller

**Summary**: the insert, the label derivation, the `HideNames` enforcement and the Athena kickoff are one operation that both endpoints and (for the kickoff) the web UI's duplicate share. It lives in `Reports`, so the controller is only parsing and rendering.

**Files affected**:
- `server/lib/report_server/reports.ex` — `create_api_report_run/3` and `duplicate_api_report_run/3`.
- `server/test/report_server/reports_api_runs_test.exs` — new.

**Estimated diff size**: ~250 lines

```elixir
  @doc """
  Creates a run from a caller-supplied filter, deriving the labels and starting an Athena query.

  Returns the run with `:user` loaded. `report_filter_values` is always derived here and never
  accepted from a caller: a stored label is a point-in-time snapshot, so trusting one lets a
  renamed cohort keep its old name forever.
  """
  def create_api_report_run(user = %User{}, report = %Report{}, report_filter = %ReportFilter{}) do
    report_filter = HideNames.enforce(report_filter, user)

    with :ok <- FilterValidation.validate(report_filter, report),
         :ok <- FilterValidation.check_dates(report_filter),
         :ok <- FilterValidation.check_no_empty_selections(report_filter),
         :ok <- check_yields_query(report_filter, report, user),
         {:ok, values} <- derive_values(report_filter, user),
         {:ok, run} <- create_report_run(%{user_id: user.id, report_slug: report.slug, report_filter: report_filter, report_filter_values: values}) do
      {:ok, run |> Repo.preload(:user) |> start_athena_query_async(report)}
    end
  end
```

Failures are tagged by kind, not left as bare messages: `FilterValidation.validate/2` returns `{:error, :invalid, message}` and `derive_values/2` wraps a portal failure as `{:error, :derivation_failed, reason}`, so the controller can render one as a 400 carrying the message and the other as a 500 that logs the reason rather than returning it. Both are binaries otherwise, and the Self-Review records what that costs.

`duplicate_api_report_run/3` takes the source run, coalesces a `nil` stored filter to `%ReportFilter{}` (a stored run can have one; `custom_components.ex:264-266` and `report_controller.ex:105` both defend against it), normalizes any `[]` dimension to `nil`, and calls the same function, which applies `check_dates/1` to the stored filter (a duplicate whose dates do not parse is refused rather than repaired: dropping a date bound would return more data than the source run did, where normalizing `[]` provably cannot move a row), so the clone is built from the source's slug and filter rather than from its struct.

The normalization is why duplicate does not simply reuse the create path whole. A stored run can carry `[]` on a second or later dimension, which the form's submit gate does not cover, and that run already behaves as unconstrained: `cohort: []` and `cohort: nil` generate byte-identical SQL. So normalizing cannot change what the copy returns, it only stops the copy from displaying a filter it does not apply, and it keeps a run the user can open and re-run from being one they cannot duplicate. That is what keeps `athena_query_id` out of the clone: the field is never in the attrs map, so no test can pass by accident of the changeset's cast list.

`filters` is derived here, for both endpoints:

```elixir
  # Display metadata, derived rather than accepted: a client-supplied list would be a second
  # source of truth for which dimensions a filter carries. Reversed because the runs table
  # reverses it again to display (custom_components.ex:269), matching what from_form/2 stores.
  # Derived on duplicate too, and not copied: the field survives a database round trip as a list
  # of strings rather than atoms, so a copied one is a different type from a created one.
  defp derive_filters(report_filter) do
    ReportFilter.dimensions()
    |> Enum.filter(&(Map.get(report_filter, &1) not in [nil, []]))
    |> Enum.reverse()
  end
```

Deriving on both paths is what keeps the requirement true rather than half true. `FilterParams.parse/1` is not on the duplicate path, so a derivation living there would leave a clone carrying whatever the source stored, in the source's form order rather than declaration order, and typed as `[binary]` rather than `[atom]`.

A filter that yields no query is refused rather than stored, because 201 for a run that can never return a row is a wrong answer and costs the client a second call to discover it. The check branches on the one thing that decides whether an exact answer is affordable:

```elixir
  # A Portal report's get_query is a pure builder, so building and throwing the query away is the
  # exact answer for the price of the allowed-projects lookup. An Athena report's runs the portal
  # learner query and uploads the learner file, so it gets the input rule and the async kickoff
  # reports what is left. Not a per-report callback: defaulted, it is a timeout waiting for the
  # next expensive report; required, it is boilerplate on eleven modules for one answer.
  defp check_yields_query(report_filter, %Report{type: :portal} = report, user) do
    case report.get_query.(report_filter, user) do
      {:ok, _query} -> :ok
      {:error, message} when is_binary(message) -> {:error, :invalid, message}
      {:error, reason} -> {:error, :derivation_failed, reason}
    end
  end

  defp check_yields_query(report_filter, _report, _user),
    do: FilterValidation.check_constrains_anything(report_filter)
```

`check_constrains_anything/1` joins the other API-only rule on `FilterValidation`: at least one dimension with values, a `start_date`, an `end_date` or an `app`. `hide_names` and `exclude_internal` do not count, because neither constrains anything on its own; `exclude_internal` in particular contributes no clause at all when the portal has no Concord schools, since `get_internal_teacher_ids/1` returns `[]` both for that and for a failed query (`report_utils.ex:168-172`). The app-and-dates-only log run the requirements bless stays creatable, which is why the dates and `app` count.

The kickoff is a supervised task, for the reason in the requirements spec's Technical Notes:

```elixir
  # Starting an Athena query runs the portal learner query and uploads the learner file before
  # Athena is contacted, so it is far too slow to hold a request open for. ensure_current/1's
  # atomic claim is what keeps a concurrent GET /reports/:id from starting the same query twice.
  defp start_athena_query_async(run, %Report{type: :athena}) do
    run_starter().(run)
    run
  end

  defp start_athena_query_async(run, _report), do: run

  # Injectable so the test env can supply a starter that does no Repo work: a task started from
  # Task.Supervisor has no ownership of the sandboxed connection, so a hard-wired one dies inside
  # the task and takes every assertion about the kickoff with it. Same seam SweepServer uses.
  defp run_starter,
    do: Application.get_env(:report_server, :athena_run_starter, &start_athena_query_task/1)

  defp start_athena_query_task(run) do
    Task.Supervisor.start_child(ReportServer.PostProcessingTaskSupervisor, fn ->
      AthenaRunOps.ensure_current(run)
    end)
  end
```

Tests: `filters` on a created run is `[:school, :cohort]` for a filter naming cohort and school, and a duplicate of a run whose stored `filters` is `["cohort", "school"]` comes back derived rather than copied, which is the assertion that fails if the derivation stays in the parser; a dimension left `nil` does not appear in `filters` while one with ids does, the mutation being `not in [nil, []]` written as `!= nil`; a Portal create with an empty filter is refused with the builder's own message and inserts nothing, while the same create with one dimension succeeds (delete the branch and the first of those stores a run that 422s on every download); an Athena create with an empty filter is refused by the input rule; an Athena create carrying only `app` is accepted, which pins the residual this decision knowingly leaves; a create naming a dimension with an empty list is refused and inserts nothing, while the same filter with that dimension unset succeeds; a duplicate of a stored run carrying `school: []` succeeds and stores `school: nil`, with the new run's SQL equal to the source's (the assertion that fails if normalization is replaced by refusal, and the one that fails if it is replaced by a copy); an Athena create inserts with `athena_query_id: nil`; a Portal create starts no task; a duplicate of an Athena run whose source has a query id and a result URL produces a run with neither (delete the field-copy and this fails); a duplicate re-derives labels rather than copying, asserted by renaming the fixture cohort between the two runs and checking the second run's label is the new name; a duplicate of a run with `report_filter: nil` succeeds; a non-admin's create comes back with `hide_names: true` whatever was sent; a failed label derivation fails the create and inserts nothing.

The rename assertion is the one that distinguishes re-derivation from copying: with a fixture that returns the same label for both runs, copying and deriving are indistinguishable.

### POST /api/v1/reports

**Summary**: the create endpoint. Parsing, the report lookup, and rendering; everything else is the context function from the previous step.

**Files affected**:
- `server/lib/report_server_web/router.ex` — one route.
- `server/lib/report_server_web/api/v1/report_controller.ex` — `create/2`.
- `server/test/report_server_web/api/v1/report_create_test.exs` — new.

**Estimated diff size**: ~150 lines

The route goes above `get "/reports/:id"`, since `POST` and `GET` do not collide but keeping the reports routes grouped in path order is how the scope currently reads.

```elixir
  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, report} <- find_api_report(params["report_slug"]),
         {:ok, report_filter} <- FilterParams.parse(params["report_filter"]),
         {:ok, run} <- Reports.create_api_report_run(user, report, report_filter) do
      conn |> put_status(:created) |> json(ReportJSON.show(run))
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, :invalid, message} -> ErrorHelpers.bad_request(conn, message)
      {:error, :out_of_scope, dimensions} -> ErrorHelpers.bad_request(conn, out_of_scope_message(dimensions))
      {:error, message} when is_binary(message) -> ErrorHelpers.bad_request(conn, message)
      {:error, :derivation_failed, reason} -> log_and_server_error(conn, reason)
      {:error, reason} -> log_and_server_error(conn, reason)
    end
  end
```

`find_api_report/1` resolves the slug through `Tree.find_report/1` and requires it to be in `Tree.api_report_slugs()`, so a slug that exists but is not API-exposed is `NOT_FOUND` rather than a report the API does not otherwise serve. A missing or non-string `report_slug` is a `BAD_REQUEST` instead, since nothing was named to be not found.

Tests: a create naming a cohort outside the caller's projects returns 400 naming the dimension and the id, and stores no run; an Athena create returns 201 and the run JSON with the id, slug, execution and filter, with `athena_query_state` null, which is the assertion that fails if the kickoff is moved back inside the request; a Portal create returns 201; an unknown slug and a non-API slug both return 404 with the same body; a malformed `report_filter` returns 400 with the parser's message; a missing `report_slug` returns 400; an unauthenticated request returns 401; `hide_names` is true in the response for a non-admin who sent false; the created run appears in `GET /api/v1/reports` for its owner and not for another user.

### POST /api/v1/reports/:id/duplicate

**Summary**: the duplicate endpoint and the Portal force guard.

**Files affected**:
- `server/lib/report_server_web/router.ex` — one route.
- `server/lib/report_server_web/api/v1/report_controller.ex` — `duplicate/2`.
- `server/test/report_server_web/api/v1/report_duplicate_test.exs` — new.

**Estimated diff size**: ~155 lines

```elixir
  def duplicate(conn, %{"id" => id_param} = params) do
    user = conn.assigns.current_user

    with {:ok, id} <- Params.parse_id(id_param),
         {:ok, source} <- Reports.get_api_report_run(user, id),
         {:ok, report} <- find_api_report(source.report_slug),
         :ok <- check_duplicate_allowed(report, source, params),
         {:ok, run} <- Reports.duplicate_api_report_run(user, report, source) do
      conn |> put_status(:created) |> json(ReportJSON.show(run))
    else
      ...
    end
  end

  # A Portal run is computed on request, so a duplicate of one is a new id over identical live
  # data. The habit comes from Athena, where duplicating is the only way to take a fresh snapshot.
  defp check_duplicate_allowed(%Report{type: :portal}, source, params) do
    if params["force"] == true do
      :ok
    else
      {:portal_duplicate, source.id}
    end
  end

  defp check_duplicate_allowed(_report, _source, _params), do: :ok
```

The refusal renders through `ErrorHelpers.render_error/4` with the code from step one, and its body is pinned rather than left to whatever reads well:

```elixir
    ErrorHelpers.render_error(
      conn,
      "PORTAL_DUPLICATE_UNNECESSARY",
      "Run #{source.id} is a Portal report, computed live on every request, so a duplicate returns " <>
        "the same data under a new id. Re-read run #{source.id} for current data, or pass " <>
        "force: true to duplicate anyway.",
      %{run_id: source.id}
    )
```

The body's keys are therefore exactly `error`, `message` and `run_id`, and a test asserts that set. This is not tidiness: cc-data's `AsCLIError` copies a coded error's `Extra` through unchanged (`errors.go:74-87`), `CLIError.Envelope/0` merges every key of it into the single-line JSON the CLI prints (`output.go:43-56`), and `codedError/1` returns the same envelope to an MCP caller (`mcpserver/server.go:49-60`). So whatever this map holds is public surface from the day it ships. Pinning the keys server-side puts the guard where someone adding a field can see the rule, which is the discipline REPORT-127 adopts for the `NOT_READY` body and for the same reason.

The message names re-reading rather than any particular client's flag, because the server has no business knowing about `--refresh`. REPORT-94 renders the client-side half of the same advice, `"%s already exists; Portal reports are live, so use --refresh to re-pull current data"`, and quotes this guard as its justification, so the two are meant to agree and this is the copy they agree with.

Tests: an Athena duplicate returns 201 and a new id; the new run's `report_filter` equals the source's and its `athena_query_id` is null; a Portal duplicate without `force` returns 409, the code, a message naming the source run id, and that id in the body; the 409 body's keys are exactly `error`, `message` and `run_id`, which is the test that fails when someone adds a field to it rather than the CLI disclosing it silently; `force: true` duplicates; `force: "true"` as a string does not (the guard is a boolean, and a JSON client that sends a string gets the refusal rather than an accidental duplicate); another user's run id returns 404; a non-integer id returns 404.

### Duplicate action in the runs UI

**Summary**: a duplicate control on the runs table and the run detail page, on both `/reports/runs` and `/reports/all-runs`.

**Files affected**:
- `server/lib/report_server_web/components/custom_components.ex` — an actions column on `report_runs/1`.
- `server/lib/report_server_web/live/report_run_live/duplicate.ex` — new, the action both LiveViews call.
- `server/lib/report_server/reports.ex`: `get_report_run_for_user/2`, the own-or-admin read the show page currently inlines.
- `server/lib/report_server_web/live/report_run_live/index.ex` — `handle_event("duplicate", ...)`.
- `server/lib/report_server_web/live/report_run_live/show.ex` — the same, plus the control in its template.
- `server/test/report_server_web/live/report_run_duplicate_test.exs` — new.

**Estimated diff size**: ~220 lines

The component gains a column rather than a caller-supplied slot: both call sites want the same action, and a slot would let them drift.

The handler is one shared module, `ReportRunLive.Duplicate`, rather than a copy per LiveView, and the message naming out-of-scope ids lives on `FilterValidation` so the controller and the LiveView render the same refusal.

The handler re-authorizes rather than trusting the event. `ReportRunLive.Index` has no `handle_event/3` at all today, so this is the first write action on that page and the run id arrives from the DOM; a handler that resolved it without an ownership check would let any authenticated user duplicate any run by id. The rule is the one the run page already applies, `report_run.user_id == user.id || user.portal_is_admin` (`report_run_live/show.ex:36`), lifted to `Reports.get_report_run_for_user/2` so both LiveViews and the component call one predicate instead of the show page having its own.

`Reports.get_api_report_run/2` is deliberately **not** that function. It is own-only, which cannot serve `/reports/all-runs`, and it additionally filters to `Tree.api_report_slugs()`, which couples a UI action to an API-exposure decision. Nothing is excluded by that filter today, since every non-`tbd` report is API-exposed, but `TBDReport` and a commented-out `tbd` report group both exist in the tree (`tbd_report.ex:2`, `tree.ex:239`), so the first `tbd` report to ship would make the duplicate button fail on its runs for no reason a reader could reconstruct.

Every failure the context function can return is handled, because the alternative is a crashed LiveView on a stale filter. `duplicate_api_report_run/3` returns `{:error, :invalid, message}`, `{:error, :out_of_scope, dimensions}` and `{:error, :derivation_failed, reason}`, and the first two are reachable from this button: a run whose ids fall outside the clicking user's projects after a membership change, and a legacy run whose dates do not parse. Each renders through the existing `put_flash(:error, ...)` the runs pages already use, with the derivation failure logged rather than shown. On success the handler redirects to the new run, which is where `create_run/2` already sends a user.

Tests: clicking duplicate on my own run creates a run owned by me and redirects to it; an admin duplicating another user's run on `/reports/all-runs` creates a run owned by the admin; a non-admin cannot reach `/reports/all-runs` at all (this already holds, and the assertion pins it now that a write action lives on that page); **a non-admin sending a duplicate event naming another user's run id is refused**, which is the mutation that catches a handler resolving the id without re-authorizing and is not covered by the page-level check, since the event bypasses `handle_params/3`; a run whose filter no longer validates renders a flash and leaves the page rather than crashing the view; duplicating a Portal run from the UI succeeds without a force flag, since the guard is an API concern.

### cc-data: typed create and duplicate client methods

**Summary**: two methods on the API client and the request types they take, over the existing `postJSON`.

**Files affected**:
- `cc-data-cli/internal/api/reports.go` — `CreateReport`, `DuplicateReport` and `CreateReportReq`, which sits beside its method exactly as `FilterOptionsReq` sits beside `FilterOptions`.
- `cc-data-cli/internal/api/errors.go` — the new error code constant, beside the rest of the vocabulary.
- `cc-data-cli/internal/api/reports_test.go` — extend.
- `cc-data-cli/test/` — wire captures for both endpoints and the guard.

**Estimated diff size**: ~200 lines

`CreateReportReq` carries `ReportSlug string` and `ReportFilter json.RawMessage`, matching `FilterOptionsReq`'s existing decision to pass a filter through as raw JSON so the client never decodes one (`endpoints.go:93-95`). `DuplicateReport` takes a bare `force bool` rather than a request struct, since the run id is in the path and one flag is not a body worth naming.

`reportview.RunPayload` is the single-run shape the two commands and the two tools render, so neither surface invents its own.

`CodePortalDuplicateUnnecessary` joins the existing code constants. No mapping work is needed: `AsCLIError` already forwards an unknown code's code, message and extra to the exit-code contract (`errors.go:74-87`), which is why the server was made to return a coded error rather than prose. That passthrough is also why the server pins the 409 body's keys: `run_id` reaches the printed envelope and the MCP result without either surface naming it.

Tests are pinned to wire captures of the real endpoints, including the 409 body, so the client's decoding is checked against what the server actually emits rather than against a hand-written fixture.

### cc-data: reports create and reports duplicate

**Summary**: the two commands, the `--report-filter` expression, and the same flag added to `filter-options`.

**Files affected**:
- `cc-data-cli/cmd/reports.go` — two subcommands, one shared filter-expression helper, `--report-filter` on `filter-options`.
- `cc-data-cli/cmd/reports_test.go` — extend.
- `cc-data-cli/docs/` — the command list.

**Estimated diff size**: ~250 lines

The filter expression is the JSON object the API emits, taken from `--report-filter` or from `--report-filter-file`, with the two mutually exclusive. It is validated as JSON locally so a typo is a usage error rather than a server round trip, and is otherwise passed through untouched: the server owns what a valid filter is, and a client-side schema would be a second definition of it that could disagree.

The same helper backs `filter-options`, which is what makes the two commands agree by construction rather than by review. That closes the gap REPORT-92 recorded (`specs/REPORT-92-filter-option-discovery-api.md:358`), and `follow-ups.md`'s entry for it is deleted in this step.

A failure that the server did not answer reports that the run may have been created and points at `reports list`, rather than suggesting a retry. `Client.do` already refuses to retry a non-idempotent request for exactly this reason (`internal/api/client.go:116-121`); the client's job is to say what that means. The rule is `api.AsWriteCLIError/2` rather than a CLI helper, because the MCP tools need it more: an agent whose `reports_create` died in transport has no reason not to call it again. Only a 4xx proves the write did not happen, since a 5xx can come from a proxy in front of the server.

Both commands carry the flags-to-request and call steps on a struct, as `filterOptionsFlags` already does, because a step reached only through `RunE` needs a stored credential and so cannot be tested at all. Verified by mutation: before the seam, dropping `--report-filter` from the create body, ignoring `--force`, ignoring `--json` and dropping the possibly-created advice each left the suite green.

Residual, accepted: a transport failure on a write exits 1 (`INTERNAL`) rather than 6 (`TRANSIENT`), because a non-idempotent request is never retried and so never becomes a `TransientError`. That is the shipped behavior of `reports filter-options`, which is also a POST, and changing the exit-code contract is its own decision.

Tests: `--report-filter` and `--report-filter-file` produce identical request bodies; passing both is a usage error; malformed JSON is a usage error and makes no request; the Portal guard's message reaches stdout with the run id in it; a transport error's text names `reports list`; `filter-options --report-filter` narrows the request body the fake server receives.

### cc-data: MCP tools and guidance entries

**Summary**: `reports_create` and `reports_duplicate` tools, and the catalog entries the drift guard requires.

**Files affected**:
- `cc-data-cli/internal/mcpserver/tools.go` — two tools.
- `cc-data-cli/internal/guidance/src/tools.md` — two entries.
- `cc-data-cli/internal/guidance/guard_test.go` — no change; it fails until the entries exist.

**Estimated diff size**: ~120 lines

`TestGuidanceDocumentsEveryTool` enumerates the registered tools from a live in-memory server and compares both directions (`guard_test.go:55-68`), so registering a tool without a catalog entry fails the build. That is the intended order: register, watch it fail, document.

The `reports_duplicate` description names the Portal re-pull path before it names `force`, so a well-behaved caller never trips the server guard; the guard catches the rest. The CLI command's `Short` and `Long` say the same thing in the same order, since a terminal user reads those and never sees a tool description. The full workflow prose, create a mapping run then pull it, belongs to REPORT-95 and is deliberately not written here.

## Open Questions

None. Every decision this story raised is a requirements question and is resolved in `requirements.md`.

## Self-Review

### Whoever has to run the tests

#### RESOLVED: the Athena kickoff task cannot do Repo work under the test sandbox

The plan starts `AthenaRunOps.ensure_current/1` in an unnamed supervised task, and that function's first act is a `Repo.update_all` claim. A task started from `Task.Supervisor` runs under a pid with no ownership of the test's sandboxed connection, so in the test env it raises inside the task, the task dies without failing the test, and every assertion about the kickoff either cannot be written or passes vacuously. Verified against the one existing precedent for supervised Repo work in this codebase: `SweepServer` does not rely on an allowance at all, it carries a config-driven `disabled?/0` kill switch that keeps it inert in the test env, and its test starts a second named instance and calls `Ecto.Adapters.SQL.Sandbox.allow/3` on it by hand (`exports/sweep_server.ex:19-25`, `test/report_server/exports/sweep_server_test.exs:44-51`).

So the kickoff gets the seam this codebase already uses for exactly this problem, rather than being hard-wired:

```elixir
  defp run_starter,
    do: Application.get_env(:report_server, :athena_run_starter, &start_athena_query_task/1)
```

with the test config supplying a starter that records the run and does no Repo work. The point is not test convenience: without the seam, "an Athena create starts the query" is a claim no test in the suite can make, and the requirement it comes from would ship unverified. The counterpart assertion, that the real starter is what production uses, is a one-line default-value test.

### Whoever has to review the resulting commits

#### RESOLVED: two different failures return the same error shape, so the controller cannot tell them apart

In `create_api_report_run/3` the `with` chains `FilterValidation.validate/2`, which returns `{:error, binary}` for a client mistake, and `ReportFilter.get_filter_values/2`, which after step two returns `{:error, reason}` where `reason` is whatever `PortalDbs.query/4` handed back. Verified that this is a binary: `query/4` unwraps `query_with_reason/4`'s three-tuple to `{:error, message}` (`portal_dbs.ex:56-62`). The controller's `else` clause matches on `{:error, message} when is_binary(message)` and renders 400, so a portal outage during label derivation would be reported to the caller as a bad request, with the raw MySQL error text as its message.

That is both a wrong status and an internals leak, and it is invisible in review because both branches read as `{:error, message}`. The context function tags its failures by kind instead:

```elixir
      {:error, :invalid, message}          # the caller's filter is wrong: 400 with the message
      {:error, :out_of_scope, dimensions}  # ids the caller cannot see: 400 naming them
      {:error, :derivation_failed, reason} # the portal failed: 500, reason logged, not returned
```

and the controller matches on the tag rather than on the shape of the payload. The changeset failure keeps its own clause. This also removes the temptation to make `get_filter_values/2` return a friendly string, which would have pushed presentation into the query layer.

#### RESOLVED: step one adds a code that nothing uses until step seven

Intentional and worth stating rather than leaving a reviewer to wonder: `PORTAL_DUPLICATE_UNNECESSARY` is added with the table it forces to be rewritten, six steps before its caller, because the table rewrite is the risky part and it is much easier to review on its own than folded into the endpoint that motivated it. The unused entry compiles and its test asserts the property that matters, that adding it did not move `code_for_status(409)`.

### Senior Engineer

#### RESOLVED: `Reports` calling `AthenaRunOps` is a mutual module reference, and it compiles

`AthenaRunOps` already calls `Reports.update_report_run/2` (`athena_run_ops.ex:24`), so putting a kickoff in `Reports` makes the two modules reference each other. Verified rather than assumed: adding the call and running `mix compile --force` produced no error, warning, cycle or deadlock. They are runtime references, not compile-time ones; nothing here is a struct or a macro.

#### RESOLVED: `put_status(:created) |> json(...)` really does send 201

Checked against the vendored Phoenix rather than from memory: `Phoenix.Controller.json/2` sends `conn.status || 200` (`deps/phoenix/lib/phoenix/controller.ex:363-366`), so the status survives. The plan uses `put_status/2` in two places and both depend on it.

## Requirements Coverage

Every requirement in `requirements.md`, and the step that implements it. Checked in both directions.

| Requirement | Step |
|---|---|
| `POST /reports` creates from slug and filter, response is the run JSON shape | POST /api/v1/reports |
| `POST /reports/:id/duplicate` clones from the stored run | POST /api/v1/reports/:id/duplicate |
| Both 404 a non-API slug and a non-owned id, indistinguishably | both endpoint steps |
| No rerun or refresh sibling | negative requirement, no step |
| `report_filter_values` always server-derived, never accepted | context step |
| Duplicate re-derives rather than copying labels | context step, rename assertion |
| "No labels to derive" distinguished from "derivation failed" | escape and tuple step |
| `filters` derived server-side in reverse declaration order | context step, since duplicate never reaches the parser |
| `hide_names` forced by role | context step |
| `app` only on reports that offer it, and only known values | FilterValidation step |
| A dimension the report does not offer is a client error | FilterValidation step |
| An empty value list is a client error on create, API only | FilterValidation step, context step |
| A filter that yields no query is refused, exactly for Portal and by input rule for Athena | context step |
| Duplicate normalizes an empty value list rather than refusing | context step |
| The `state` injection is fixed | escape and tuple step |
| Ids outside the caller's allowed projects are refused, naming them | one scoped source, escape and tuple step |
| The scoping is expressed once rather than per dimension | one scoped source, then re-point ReportFilterQuery |
| `start_date` and `end_date` are validated as ISO dates, on both endpoints | FilterParams step, FilterValidation step, context step |
| Athena duplicate free, Portal duplicate needs `force` | duplicate endpoint step |
| 409 with its own code, `code_for_status/1` unchanged | ErrorHelpers step |
| The 409 body's keys are pinned and asserted | duplicate endpoint step |
| The refusal's message points at re-reading, not at a client flag | duplicate endpoint step |
| MCP and CLI descriptions steer Portal callers to re-pull | command step and MCP step |
| Both endpoints start the Athena query, as a supervised task | context step |
| The response may carry a null `athena_query_state` | POST /api/v1/reports |
| A clone carries no `athena_query_id`, asserted by test | context step |
| Duplicating a run with a `nil` stored filter is read as the empty filter rather than raising | context step |
| Both endpoints respond 201 | both endpoint steps |
| Duplicate action on the runs table and the run page | web UI step |
| Present on all-runs, owned by the clicker, `HideNames` applied | web UI step |
| The UI duplicates Portal runs freely | web UI step |
| Typed client methods over `postJSON` and `AsCLIError` | client step |
| A transport failure is reported as possibly-created | client and command steps |
| `reports create`, `reports duplicate`, MCP tools, catalog entries | command and MCP steps |
| JSON `--report-filter` and `--report-filter-file` | command step |
| The same expression reused on `filter-options` | command step |
| Fake-server tests pinned to live wire captures, including the guard | client step |

### Gaps found, requirement with no step

**Gap 1 (closed): the CLI command descriptions are now covered.** `reports duplicate`'s `Short` and `Long` name the Portal re-pull path before they name `force`, so the steering exists on both surfaces rather than only over MCP.

**Gap 2 (closed): the null-state claim now has an assertion.** The create endpoint's tests assert that an Athena create returns 201 with `athena_query_state` null, which is what fails if the kickoff is ever moved back inside the request.

### Gaps found, step no requirement asked for

**Orphan 1 (resolved): the plan no longer moves `offers_app_filter?/1`.** It stays on `AthenaFailure` and `FilterValidation` calls it, matching `AppDimension.enabled_for_report?/1`, which already reaches across module boundaries for the same predicate. REPORT-106's module and its test are untouched.

**Orphan 2 (resolved): re-pointing `FilterOptionsController` stays, on one-source-of-truth grounds.** The objection in the first draft was that it edits a file under review; verified that the file is *created* by REPORT-92 rather than existing on master, so this story stacks on top of it with nothing to conflict with. The duplication it removes is real: without it, "is this dimension offered by this report" is written twice, once per caller.

**Orphan 3: the plan adds an `:athena_run_starter` config seam.** This came out of the stage-7 review rather than from a requirement. Without it the kickoff requirement cannot be tested at all, so it is arguably implied, but it is a new configuration key that a reviewer will ask about.
