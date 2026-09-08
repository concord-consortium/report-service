# Implementation Plan: Filter-Option Discovery in the API

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-92
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

> The core module below was written and run against a local MySQL 8.0.39 before this plan: a real
> paged walk visits every option exactly once across a page boundary that falls inside a run of
> identical labels, the count skips and bounds as specified, and the privacy enforcement overrides a
> researcher's request. One thing the first draft got wrong was found by running it and is now its
> own step. See "Verification behind this plan".
>
> The story spans two repos. The steps below are report-service unless marked **[cc-data-cli]**.

## Implementation Plan

**Already on master, from REPORT-91 (PR #420, merged 2026-09-08).** Two things this plan would
otherwise have built exist and are used as they are:

- `ReportServer.Reports.HideNames`, with `allowed?/1` and `enforce/2`, extracted from the report
  form's private `maybe_enforce_hide_names/2`. Its tests already pin the property this endpoint
  depends on, that `enforce/2` **overrides** an explicit `hide_names: false` for a researcher rather
  than merely defaulting it, which matters because a caller round-tripping a run's `report_filter`
  sends exactly that.
- The portal-DB test fixture, `server/test/support/portal_fixture.{ex,sql}` seeded from
  `test_helper.exs`, which raises in CI when the database is unreachable rather than silently
  excluding the tests that use it.

### Fix the three pre-existing `ReportFilterQuery` defects

**Summary**: Three defects that have to go first. The paging wrapper cannot name a column the inner
query does not alias, and the `permission_form` statement is illegal under a sql_mode the portal
databases happen not to run. An empty `allowed_project_ids` list renders `project_id IN ()`, a
syntax error, where the requirement is an empty result. And a `state` value ending in a backslash
breaks out of its own SQL literal. Its own commit: small fixes to shared code with their own
regression tests, reviewable without the endpoint around them.

**Files affected**:
- `server/lib/report_server/reports/report_filter_query.ex` — alias the `permission_form` value,
  short-circuit an empty `allowed_project_ids`, and quote `state` values MySQL-safely
- `server/lib/report_server/reports/report_utils.ex` — `escape_mysql_literal/1` and
  `mysql_string_list_to_in/1`
- `server/lib/report_server/reports/learner_hide_names.ex` — call the promoted escape
- `server/lib/report_server/reports/portal/detailed_metrics_by_school_report.ex`,
  `server/lib/report_server/reports/portal/summary_metrics_by_subject_area_report.ex`,
  `server/lib/report_server/post_processing/job.ex` — the other three MySQL call sites
- `server/lib/report_server/reports/report_filter.ex` — expose `dimensions/0` and
  `dimension_from_string/1`, and route `get_filter_type!/2` through the latter
- `server/test/report_server/report_filter_query_test.exs` — pin the corrected SQL, iterating
  `ReportFilter.dimensions()`

**Estimated diff size**: ~70 lines

```elixir
# get_filter_query(:permission_form, ...)
  value: "CONCAT(ap.name, ': ', ppf.name) AS fullname",
  ...
  order_by: "fullname",
```

```elixir
# get_query_and_params/4, beside the existing :none clause
    if allowed_project_ids == :none or allowed_project_ids == [] do
      {nil, []}
```

```elixir
# ReportUtils: promoted from LearnerHideNames, which keeps calling it
def escape_mysql_literal(str), do: str |> String.replace("\\", "\\\\") |> escape_single_quote()

def mysql_string_list_to_in(nil), do: "()"
def mysql_string_list_to_in(list) do
  "(#{list |> Enum.map(&("'#{escape_mysql_literal(&1)}'")) |> Enum.join(",")})"
end

# apply_secondary_filters/4, the :state branch
          mysql_string_list_to_in(filter_value)
```

`escape_single_quote/1` **does not change**: eleven of its fifteen call sites build Presto SQL, and
Presto does not treat backslash as an escape character, which is why `LearnerHideNames` carried its
own copy rather than extending the shared one. The MySQL-safe escape moves to `ReportUtils` so there
is one definition, and **all four MySQL call sites switch to it**: `get_filter_query/5`'s `state`
branch, the two aggregate portal reports, which feed the same caller-supplied `state` list into a
report whose rows get downloaded, and `post_processing/job.ex`. The switch is verified
behavior-preserving, byte-identical for every value without a backslash, so the three outside this
endpoint cost four changed lines and no risk.

The test drives the real helper with a value ending in a backslash and asserts the generated
statement returns no rows, that `O'Fallon` and `C:\x` still match, and that a state list without a
backslash renders exactly what it renders today, which is what makes the report call sites safe to
switch in the same commit.

`get_allowed_project_ids/1` returns `:all`, an empty list, a non-empty list or `{:error, _}`; only
`:none` was handled, and an empty list is what a de-provisioned project admin or researcher gets,
permanently, because `Api.AuthPlug` reads role flags off the stored `User` row and API tokens do not
expire. `ReportUtils.scope_by_allowed_projects/5` already pairs `[]` with `:none` for this exact
reason. Putting the case here rather than in each scoped builder keeps one statement of the rule and
gives the same answer for all ten dimensions that `:none` gives today. A test asserts the empty-list
caller gets no options and a count of zero rather than an error.

`SELECT DISTINCT ppf.id, CONCAT(...) ... ORDER BY ppf.name` orders by a column outside its select
list, which is `ERROR 3065` under `ONLY_FULL_GROUP_BY`. It works today only because the portal
databases run without that mode. Verified that this is exactly one of the ten dimensions: the other
nine either select the bare column they order by or already alias the expression.

**This is invisible to the web form.** `get_options/4` destructures each row positionally as
`[id, value]`, so a column's name never reaches a caller. The test asserts the generated SQL for
every dimension, pinning the other nine unchanged at the same time. It **iterates
`ReportFilter.dimensions()` rather than a literal list**, so it doubles as the check that the
dimension list the endpoint validates against and the builder clauses that serve them stay in step:
a dimension added to one and not the other fails here rather than at runtime.

---

### Preserve why a portal query failed

**Summary**: `PortalDbs.query/4` flattens every failure to a message string, so a caller cannot tell
a timeout from a real error. The count needs that distinction to tell the truth about why it is
missing, and the driver's own timeout text is explicitly ambiguous, so matching on it is not an
option. **Neither is matching on the exception type**, which carries the same ambiguity: see the
measurements below.

**Files affected**:
- `server/lib/report_server/portal_dbs.ex` — `query_with_reason/4` holds the body, `query/4` delegates
- `server/test/report_server/portal_dbs_test.exs` — classify all three failures, and pin `query/4`'s
  unchanged output

**Estimated diff size**: ~60 lines

```elixir
  @doc """
  Like `query/4` but preserves *why* a failure happened, as
  `{:error, :timeout | :busy | :db, message}`.

  The kind is decided by what is observable, not by the exception type.
  `DBConnection.ConnectionError` covers a query that blew its budget, a pool that could not hand
  out a connection, and a database that is down, so the struct alone cannot tell a timeout from an
  outage any more than its message can.
  """
  def query_with_reason(server, statement, params \\ [], options \\ []) do
    with {:ok, pool_name} <- get_or_start_pool(server) do
      query_options = Keyword.merge([timeout: @query_timeout], options)
      budget = Keyword.fetch!(query_options, :timeout)
      started = System.monotonic_time(:millisecond)

      case MyXQL.query(pool_name, statement, params, query_options) do
        {:ok, result} ->
          {:ok, result}

        {:error, %DBConnection.ConnectionError{reason: :queue_timeout} = e} ->
          Logger.error("Portal pool exhausted on #{server}: #{e.message}")
          {:error, :busy, e.message}

        {:error, %DBConnection.ConnectionError{} = e} ->
          Logger.error("Error connecting to #{server}: #{e.message}")
          {:error, kind_by_elapsed(started, budget), e.message}

        {:error, %MyXQL.Error{} = e} ->
          Logger.error("Error executing query on #{server}: #{e.message}")
          {:error, :db, e.message}

        _ ->
          Logger.error("Unknown error query on #{server}")
          {:error, :db, "Unknown error query on #{server}"}
      end
    end
  end

  # only a call that actually consumed its budget is a timeout
  defp kind_by_elapsed(started, budget) do
    if System.monotonic_time(:millisecond) - started >= budget, do: :timeout, else: :db
  end

  def query(server, statement, params \\ [], options \\ []) do
    case query_with_reason(server, statement, params, options) do
      {:ok, result} -> {:ok, result}
      {:error, _kind, message} -> {:error, message}
      error -> error
    end
  end
```

**Why the classifier is elapsed time rather than the exception type.** Measured against a live
MySQL 8.0.39 through MyXQL, the three failures an option query can hit:

| case | elapsed vs budget | by exception type | by elapsed time | `ConnectionError.reason` |
|---|---|---|---|---|
| `SELECT SLEEP(3)`, 500 ms budget | 503 / 500 ms | `:timeout` | `:timeout` | `:error` |
| missing table | 3 / 500 ms | `:db` | `:db` | n/a, `MyXQL.Error` |
| **database unreachable** | 2499 / 5000 ms | **`:timeout`** | `:db` | `:queue_timeout` |

The third row is why this step exists at all. Classifying on the struct reports a portal outage as
"the count did not complete within the time budget", which is the same comforting lie the first
draft of the count told, moved one level up rather than fixed. Its own message says what really
happened: "connection not available and request was dropped from queue after 2499ms". That case is
recognized precisely, through `reason: :queue_timeout`, and reported as `:busy`, which is also the
shape REPORT-88's download limiter exists to bound.

**`query/4` keeps one body rather than gaining a near-copy.** Its 18 call sites see no change: all
five shapes `MyXQL.query/4` can return were driven through today's implementation and through the
delegating one, and the outputs are identical, including the two non-struct shapes that fall to the
catch-all. Sharing the body also keeps the logging, which an earlier draft of this step silently
dropped, and keeps the bare `_` catch-all, which that draft had narrowed to `{:error, e}` so that a
non-tuple return would have raised `CaseClauseError` instead of returning an error. A test pins
`query/4`'s output for each shape so the delegation cannot drift.

---

### Extend the portal-DB test fixture

**Summary**: REPORT-91's fixture was built for the portal *reports*, which read `report_learners`
plus the join tables. The option queries read the entity tables the names live in, and six of the
ten are not there. Its own commit: schema and seed only, no production code.

**Files affected**:
- `server/test/support/portal_fixture.sql` — six new tables, two new columns, new seed rows

**Estimated diff size**: ~50 lines

Measured, not assumed: the shipped fixture was loaded into a scratch database and every dimension's
real `get_options_sql/1` output executed against it as a project-scoped caller.

| dimension | result against the fixture as shipped |
| --- | --- |
| `school`, `teacher`, `assignment`, `state` | run and return rows |
| `cohort` | `ERROR 1054` unknown column `admin_cohorts.name` |
| `permission_form` | `ERROR 1146` no `portal_permission_forms` |
| `class` | `ERROR 1146` no `portal_clazzes` |
| `student` | `ERROR 1146` no `portal_students` |
| `country` | `ERROR 1146` no `portal_countries` |
| `subject_area` | `ERROR 1146` no `admin_tags` |

So the paged walk over tied `class` labels and the researcher-sees-id-shaped-labels test on
`student`, the two tests the requirements single out as the ones that can actually fail, have
nothing to run against until this lands.

Added: `portal_clazzes (id, name, class_word)`, `portal_students (id, user_id)`,
`portal_permission_forms (id, name, project_id)`, `admin_projects (id, name)`,
`portal_countries (id, name)`, `admin_tags (id, tag, scope)` and `taggings (tag_id, context,
taggable_type, taggable_id)`; a `name` column on `admin_cohorts`, a `country_id` on
`portal_schools` and a `clazz_id` on `portal_offerings`; and the tied-label class rows the walk
needs, one of which has no class word so its label is NULL and the coalesced ordering has something
to prove.

`portal_offerings.clazz_id` was not in the original list and was found by sweeping every dimension
against every secondary filter: a dozen join patterns route through `po.clazz_id`, so without it the
whole cascade half of the fixture is unusable while the unnarrowed queries all pass.

**Three of the ninety pairs could not generate legal SQL, and the cause was the builder, not the
fixture.** All three predate this story, and the sweep that found them is now a test asserting that
none of the ninety fails.

- `assignment` narrowed by `cohort` emitted the `aci_cohort` alias twice for a **scoped** caller.
  `allowed_projects_assignment` and `cohort_items_assignment_ref` were the same join written twice,
  differing only by `LEFT`, so `get_join_where_sql/2`'s `Enum.uniq/1` could not collapse them. It
  worked as `:all`, which is why nobody reported it, and it meant a project admin or researcher
  could not filter assignments by cohort in the web form. The duplication was the defect, so the
  fix is one definition: the scoping list references `:cohort_items_assignment_ref` by name and that
  pattern becomes the `LEFT JOIN`. `LEFT` is equivalent here because the secondary filter's
  `aci_cohort.admin_cohort_id IN (…)` predicate discards the unmatched rows anyway, verified by
  running the before and after statements against the fixture and getting the same row.
- `country` narrowed by `teacher` and by `subject_area` reused `:school_member_from_school`, whose
  `psm.school_id = portal_schools.id` is correct for the `school` and `state` primaries but not for
  `country`, which reaches schools as `ps_country`. `country`'s `subject_area` chain additionally
  hung `po` off an unjoined `pc` and `t` off an unjoined `ea`. The `state` primary already has the
  correct form of the same chain, so `country` now mirrors it with a `ps_country`-keyed membership
  join rather than inventing one.

**`resolve_join_patterns/1` had to learn to recurse** for the shared reference to work: its atom
clause returned `[value]`, so a pattern naming another pattern emitted the atom into the SQL. It now
resolves what it looks up. Existing entries are unaffected, since a string still yields one string
and a list of strings still flattens to the same list.

Measured, so the form is provably untouched elsewhere: of the 180 statements the ten dimensions
generate against every secondary filter under both `:all` and a scoped caller, **exactly these six
changed and the other 174 are byte-identical**.

**New rows stay out of the existing tests' way.** Those tests either filter by class 601 or assert
`length(...) == 4` over `report_learners`, so seeded ids are chosen outside the existing 601/602,
71-74, 901-904 and 31-33 ranges and **nothing is added to `report_learners`**.

---

### Add the paging and counting core

**Summary**: The substance of the story: the wrapped keyset page, the cursor, and the two-layer
count bound. Kept separate from the controller so it can be tested without HTTP.

**Files affected**:
- `server/lib/report_server/reports/filter_options.ex` — new
- `server/test/report_server/reports/filter_options_test.exs` — new

**Estimated diff size**: ~230 lines

```elixir
defmodule ReportServer.Reports.FilterOptions do
  @moduledoc """
  Paged, keyset-ordered access to the report form's cascading filter-option lookup.

  Wraps `ReportFilterQuery.get_options_sql/1` rather than changing it, so the form keeps
  calling the unwrapped builder and its SQL cannot drift. The wrap names its own columns
  because an unaliased value expression's derived column is named with the expression text.
  """
  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery, HideNames}

  # Both the page and the count are bounded well under PortalDbs' five-minute module default: a
  # request a human or an LLM is waiting on has no business holding one of five shared connections
  # for minutes, and the wrap materializes the dimension's whole distinct option set per page.
  @portal_timeout_ms 5_000

  # The paging bounds are not redeclared here: `Api.V1.Params` already owns @default_limit and
  # @max_limit, the controller parses through it, and a Reports module must not depend on a Web one
  # to read them. `:limit` is therefore required rather than defaulted, so there is one definition.

  @doc "One page of options for `dimension`, narrowed by the rest of `report_filter`."
  def page(dimension, report_filter = %ReportFilter{}, user = %User{}, opts \\ []) do
    # is_integer, not just validated upstream: `limit` is interpolated into the statement below,
    # so the guard is what makes that safe on its own terms rather than by trusting a caller.
    limit = Keyword.fetch!(opts, :limit)
    true = is_integer(limit)
    cursor = Keyword.get(opts, :cursor)
    like = Keyword.get(opts, :like_text, "")

    filter = prepare(dimension, report_filter, user)

    allowed = allowed_project_ids(user)

    case ReportFilterQuery.get_query_and_params(filter, allowed, like, user.portal_server) do
      # no query: :none allowed projects, or an empty dependent filter
      {nil, _params} ->
        {:ok, [], nil}

      {query, params} ->
        inner = ReportFilterQuery.get_options_sql(query)
        {where, cursor_params} = cursor_clause(cursor)

        sql = """
        SELECT o.opt_id, COALESCE(o.opt_label, '') AS opt_label FROM (#{inner}) AS o (opt_id, opt_label)
        #{where} ORDER BY COALESCE(o.opt_label, ''), o.opt_id LIMIT #{limit + 1}
        """

        case PortalDbs.query(user.portal_server, sql, params ++ cursor_params, timeout: @portal_timeout_ms) do
          {:ok, result} -> {:ok, rows_to_options(result.rows, limit), next_cursor(result.rows, limit)}
          error -> error
        end
    end
  end

  @doc """
  The total, `:skipped` with an accurate reason when one could not be produced, or `{:error, _}`
  when the query itself is broken. Three shapes get a count skipped rather than one: the unbounded
  student request, which never runs; a count that consumed its whole budget; and a portal too busy
  to hand out a connection. Only the last is a genuine failure.
  """
  def count(dimension, report_filter = %ReportFilter{}, user = %User{}, opts \\ []) do
    like = Keyword.get(opts, :like_text, "")
    filter = prepare(dimension, report_filter, user)

    if unbounded?(dimension, report_filter, like) do
      {:skipped, "counting every student without a narrowing selection is unbounded"}
    else
      allowed = allowed_project_ids(user)

      case ReportFilterQuery.get_query_and_params(filter, allowed, like, user.portal_server) do
        {nil, _params} ->
          {:ok, 0}

        {query, params} ->
          inner = ReportFilterQuery.get_options_sql(query)
          sql = "SELECT COUNT(*) FROM (#{inner}) AS o (opt_id, opt_label)"
          # query_with_reason, not query: query/4 flattens every failure to a message string and
          # the driver's timeout text is itself ambiguous, so a real error would otherwise be
          # reported to the caller as a comforting "we ran out of time".
          case PortalDbs.query_with_reason(user.portal_server, sql, params, timeout: @portal_timeout_ms) do
            {:ok, result} -> {:ok, result.rows |> List.first() |> List.first()}
            {:error, :timeout, _} -> {:skipped, "the count did not complete within the time budget"}
            {:error, :busy, _} -> {:skipped, "the portal database was too busy to answer the count"}
            {:error, :db, message} -> {:error, message}
            # get_or_start_pool/1 fails before MyXQL is reached and returns a two-element tuple,
            # so query_with_reason/4 passes it straight through; without this clause it is a
            # CaseClauseError rather than the contract's SERVER_ERROR.
            {:error, message} -> {:error, message}
          end
      end
    end
  end

  # The target dimension is the PRIMARY filter: get_query_and_params/4 takes hd(filters), an empty
  # filters list short-circuits to no options, and the tail is never read. Narrowing comes from the
  # struct's own values, so the caller's filters list is replaced rather than merged with.
  defp prepare(dimension, report_filter, user) do
    report_filter
    |> HideNames.enforce(user)
    |> Map.put(:filters, [dimension])
    |> Map.put(dimension, nil)
  end

  defp unbounded?(:student, %ReportFilter{} = f, ""), do: no_narrowing?(f)
  defp unbounded?(_dimension, _filter, _like), do: false

  @narrowing ~w(cohort school teacher assignment class permission_form)a
  # `nil` is "not selected"; `[]` is a selection of nothing, which short-circuits the query to no
  # options, so it is narrowing and the count is the free, exact 0 the query builder already gives.
  defp no_narrowing?(f), do: Enum.all?(@narrowing, &(Map.get(f, &1) == nil))

  # A failed permission lookup is not "no projects": passing the {:error, _} tuple on reaches
  # list_to_in/1, which raises Protocol.UndefinedError from inside the query builder. Raise the
  # named exception the report path already raises for this, so the failure is legible in the
  # logs and the response is the contract's SERVER_ERROR either way.
  defp allowed_project_ids(user) do
    case PortalDbs.get_allowed_project_ids(user) do
      {:error, reason} ->
        raise ReportServer.Reports.AllowedProjectsLookupError,
          message: "allowed-projects lookup failed: #{inspect(reason)}"

      allowed ->
        allowed
    end
  end

  defp cursor_clause(nil), do: {"", []}
  defp cursor_clause({label, id}), do: {"WHERE (COALESCE(o.opt_label, ''), o.opt_id) > (?, ?)", [label, id]}

  defp rows_to_options(rows, limit) do
    rows |> Enum.take(limit) |> Enum.map(fn [id, label] -> %{id: to_string(id), label: label} end)
  end

  defp next_cursor(rows, limit) do
    if length(rows) > limit do
      [id, label] = Enum.at(rows, limit - 1)
      {label, to_string(id)}
    end
  end
end
```

Four things in there are load-bearing and none are obvious:

- **`prepare/3` replaces `filters` with the target dimension alone and clears that dimension's own
  value.** `get_query_and_params/4` takes `hd(filters)` as the dimension being asked about and
  destructures the rest as `_secondary_filters`, so the tail is never read: narrowing comes from the
  struct's dimension values and each dimension's own hardcoded secondary list. Verified by
  generating SQL both ways: `filters: [:student, :class, :teacher]` and `filters: [:student]` over
  the same values produce byte-identical statements. Replacing rather than merging also disposes of
  a type hazard, since `EctoReportFilter.load/1` leaves a stored run's `filters` as **strings**
  (`["student", "class"]`), which a caller round-trips back verbatim. Clearing the dimension's own
  value is what makes "show me the other schools" work rather than narrowing the answer to what is
  already picked.
- **The wrap names its own columns.** `AS o (opt_id, opt_label)` is not stylistic: an unaliased
  value expression's derived column is named with the expression text itself, so the outer predicate
  would have nothing usable to reference.
- **The wrap coalesces the label in its own projection, and every use reads that.** A NULL label is
  reachable in seven of the ten dimensions, and a row comparison against NULL is NULL, so a cursor
  carrying one matches nothing: probed at page size 2 over six class options with two NULL labels,
  page 1 returned two rows and page 2 returned none, ending a walk that the wrapped `COUNT(*)` said
  had six. Coalescing once, rather than repeating it in the `ORDER BY`, the predicate and the
  cursor, is what makes the four agree by construction. A genuine empty-string label is not a
  collision: the id tiebreaker keeps the order total, verified with both present.
- **`LIMIT limit + 1`** is how the next cursor is known without a second query: a row beyond the page
  means there is more.
- **The cursor's label is a bound parameter**, appended after the inner query's own `LIKE` params.
  Labels contain apostrophes, and this one comes from the caller.

Tests run against the portal-DB fixture, as extended by the preceding step, tagged `:portal_db` as
REPORT-91's own tests are. The scoping test needs `admin_project_users`, which
`get_allowed_project_ids/1` queries for a project admin: REPORT-91's fixture already creates that
table and seeds a project admin (user 555) and a researcher (557), so the two directions this story
asserts have real rows on both sides without further work.

With that in place:

- The end-to-end walk asserts the visited set equals the full expected set with no duplicates, on a
  fixture where three options share a label so a page boundary falls inside the tie. **The tied ids
  are 5, 9 and 40**, whose numeric and lexicographic orders disagree, which is the requirement's
  "ordering and comparison must agree on type" made concrete: probed on MySQL 8.0.39, a walk that
  pages numerically and then switches to a consistent *lexicographic* scheme still skips id 40
  entirely and reports no error. A fixture with ids 1, 2, 3 passes either way and proves nothing.
- Cascading asserts a specific option is **absent** after a narrowing selection, not merely that the
  list shrank.
- Scoping asserts a specific option is absent for a scoped user and present for a super-admin, so
  neither direction can pass against an empty fixture. Step 1's SQL regression test is driven with a
  **scoped** user, not `:all`, which is what makes it pin the requirement that `country`, `state` and
  `subject_area` keep applying no project scoping: driven as a super-admin those three statements
  look the same whether the scoping exists or not.
- The count returns `{:skipped, _}` for an unnarrowed `student` request and a number otherwise.
- A researcher-role request for `student` options yields id-shaped labels.

---

### Add static dimensions

**Summary**: A second kind of dimension that answers from a fixed server-defined vocabulary instead
of a portal query. Ships the seam and its first member; nothing about the ten portal dimensions
changes.

> **Branch note.** This spec's branch is cut from `REPORT-105-app-filter-live-select`, not from
> `master`: `ba0a442`, which adds `AthenaConfig.app_options/1`, is not an ancestor of master. So
> `app_options/1` is present while working here and absent on master. A PR opened against master
> from this branch would carry REPORT-105's commits, so #421 merges first and this branch rebases.
>
> **Depends on REPORT-105 having landed**, which supplies the first implementor's value list
> (`AthenaConfig.get_log_apps/0`) and the `enable_app_filter` report flag, **and on its follow-on
> PR #421**, which adds `AthenaConfig.app_options/1`, the search this step reimplements in terms of
> the shared rule below. The preceding steps do not depend on either.

**Files affected**:
- `server/lib/report_server/reports/filter_options/static_dimension.ex` — new, the behaviour
- `server/lib/report_server/reports/filter_options/app_dimension.ex` — new, the first implementor
- `server/lib/report_server/reports/option_label.ex` — new, the one Elixir statement of the rules
- `server/lib/report_server/reports/athena/athena_config.ex` — `app_options/1` calls `matches?/2`
- `server/lib/report_server/reports/filter_options.ex` — dispatch in `page/4` and `count/4`
- `server/test/report_server/reports/option_label_test.exs` — new
- `server/test/report_server/reports/filter_options_static_test.exs` — new

**Estimated diff size**: ~200 lines

The behaviour is two callbacks, and the lookup one takes the search text. Anything more and a static
dimension starts to look like a portal one:

```elixir
defmodule ReportServer.Reports.FilterOptions.StaticDimension do
  @moduledoc """
  A dimension whose options are a fixed, server-defined vocabulary rather than portal data:
  no query, no project scoping, no cascading. The wire contract is identical to a portal
  dimension's, so no client branches on the kind.

  `options/1` takes the search text, `""` meaning everything, so a dimension owns how its own
  vocabulary narrows as well as what is in it. Implementors must test a label with
  `OptionLabel.matches?/2` rather than rolling their own comparison: the rule is substring,
  case-insensitive, over the label, matching what the portal dimensions get from `LIKE` under a
  `_ci` collation.
  """
  @callback options(search :: String.t()) :: [{id :: String.t(), label :: String.t()}]
  @callback enabled_for_report?(ReportServer.Reports.Report.t()) :: boolean()
end
```

**Why the search belongs to the dimension, and the rule does not.** Two forces pull opposite ways
here. Search has to live with the vocabulary, because a future static dimension may not be a plain
pair list, and because `app`'s search already exists next to `app`'s values. But the *rule* has to
live in one place, because the natural thing to write in a new implementor is
`String.contains?(label, text)` with no downcase, which is case-sensitive while every portal
dimension is case-insensitive, and no test would fail. Splitting them gives both: the callback owns
the narrowing, one module owns what narrowing means.

What is shared is the **predicate**, not the traversal. `app_options/1` holds `{label, value}` pairs
and this endpoint holds `{id, label}`, so a shared `filter/2` would have to guess which slot carries
the label. Each caller knows its own slot; only the comparison has to agree:

```elixir
defmodule ReportServer.Reports.OptionLabel do
  @moduledoc """
  The one Elixir statement of what the option contract means by a label: whether it matches a
  search, and how it sorts. Both are case-insensitive, because the portal dimensions get that from
  SQL under a `_ci` collation (probed: `LIKE '%clue%'` matches `CLUE`, and `ORDER BY` puts
  `Dataflow` before `DEVOPS`), which cannot share this code. Elixir's own term order does the
  opposite, putting every uppercase letter first, so a plain `Enum.sort_by` on the label is wrong
  in a way no client can see until it pages two dimensions and gets two orderings.
  """
  def matches?(_label, ""), do: true
  def matches?(label, text), do: String.contains?(String.downcase(label), String.downcase(text))

  @doc "The total sort key for an option, matching a portal dimension's `ORDER BY label, id`."
  def sort_key({id, label}), do: {String.downcase(label), id}
end
```

`AthenaConfig.app_options/1`, which PR #421 adds for the form's LiveSelect, is reimplemented to test
its own first slot with it, so the web form's application search and the API's narrow through one
comparison instead of agreeing by coincidence. Its one call site (`form.ex:82`) does not change, and
a test pins that its results do not either.

`OptionLabel` gets its own test on both halves. For `matches?/2`: a lowercase needle against an
uppercase label, an uppercase needle against a lowercase label, and blank text matching everything.
That is the test that fails when someone writes `String.contains?(label, text)` with no downcase,
which is the natural thing to write and is case-sensitive while every portal dimension is not. For
`sort_key/1`: sorting the real `app` vocabulary puts `Dataflow` before `DEVOPS` and `GeniStarDev`
before `GRASP`, which is what MySQL returns for the same labels and what a bare
`Enum.sort_by(&elem(&1, 1))` gets backwards. Both assertions fail against the naive implementation,
which is the only reason either is worth writing.

The first implementor delegates to REPORT-105's list rather than restating it, which is what makes
the web form's option labels and the API's `{id, label}` one source:

```elixir
defmodule ReportServer.Reports.FilterOptions.AppDimension do
  @behaviour ReportServer.Reports.FilterOptions.StaticDimension

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.AthenaFailure

  # AthenaConfig.app_options/0 is {label, value} for Phoenix's options_for_select/2, which is
  # the reverse of this endpoint's {id, label}. Swapping here rather than keeping two lists is
  # the whole point: the form and the API cannot disagree about what a value is called.
  @impl true
  def options(search) do
    Enum.map(AthenaConfig.app_options(search), fn {label, value} -> {value, label} end)
  end

  # `app` is not declared in include_filters; it is gated by the same form_options flag the
  # web form uses, so teacher-actions (which reads logs_by_time and has no app partition)
  # rejects it here exactly as it hides the control there. AthenaFailure owns that reading.
  @impl true
  def enabled_for_report?(report), do: AthenaFailure.offers_app_filter?(report)
end
```

Registry and dispatch. `@static_dimensions` must not overlap `ReportFilter.dimensions()`; a test
asserts the two are disjoint, because a name in both would resolve by whichever lookup ran first.

```elixir
@static_dimensions %{"app" => AppDimension}

def page(dimension, report_filter, user, opts \\ []) do
  case Map.fetch(@static_dimensions, to_string(dimension)) do
    {:ok, module} -> static_page(module, opts)
    :error -> portal_page(dimension, report_filter, user, opts)   # today's body, unchanged
  end
end
```

`static_page/2` reuses the same ordering and cursor mechanics rather than inventing a second paging
model, so the envelope is indistinguishable:

```elixir
defp static_page(module, opts) do
  limit = Keyword.fetch!(opts, :limit)

  # The portal helpers take MyXQL's [id, label] rows; a static dimension holds {id, label} tuples,
  # so it keeps its own two-liners rather than reusing rows_to_options/2 and next_cursor/2 on a
  # shape they cannot match.
  rows =
    opts
    |> Keyword.get(:like_text, "")
    |> module.options()   # options/1: the module narrows its own vocabulary
    |> Enum.sort_by(&OptionLabel.sort_key/1)
    |> drop_through_cursor(Keyword.get(opts, :cursor))

  items = rows |> Enum.take(limit) |> Enum.map(fn {id, label} -> %{id: to_string(id), label: label} end)
  next = if length(rows) > limit do
    {id, label} = Enum.at(rows, limit - 1)
    {label, to_string(id)}
  end

  {:ok, items, next}
end

defp drop_through_cursor(rows, nil), do: rows
defp drop_through_cursor(rows, {label, id}) do
  Enum.drop_while(rows, &(OptionLabel.sort_key(&1) <= {String.downcase(label), id}))
end
```

The narrowing is the module's and the ordering, cursor and page mechanics are the endpoint's, which
is the split the wire contract needs: a caller cannot tell a static dimension from a portal one.

`count/4` dispatches the same way and returns `{:ok, length(filtered)}`. It never returns
`:skipped`: `unbounded?/3` is a statement about the `student` dimension's portal query and has no
meaning for a fixed list.

The endpoint step's slug validation gains the matching branch: a portal dimension is checked against
the report's `include_filters`, a static one against `module.enabled_for_report?(report)`.

Tests:

- the `app` dimension returns every projected application, with `none` carrying its explanatory
  label, and the ids are the raw enum values. Assert the id explicitly, **on the `none` option**:
  `app_options/1` is `{label, value}` and this endpoint is `{id, label}`, so a dropped swap yields
  options whose ids are human labels, which no caller could then submit as a filter value. Measured
  2026-09-07: of the fifteen entries `app_options/0` returns, `none` is the only one whose two slots
  differ, so a test written against any other application passes with the swap dropped.
- searching `clue` returns `CLUE`, so the static dimension is case-insensitive exactly as the portal
  dimensions are under a `_ci` collation, and `""` returns the whole vocabulary
- its envelope is byte-comparable in shape to a portal dimension's: same keys, string ids, a
  `next_page_token` that is null when the page is the last
- a limit smaller than the vocabulary pages correctly, and walking the pages visits every option
  exactly once with no duplicates, the same property asserted for portal dimensions
- the count is exact and is never `:skipped`
- narrowing dimensions, `start_date`, `end_date` and `exclude_internal` in the body are accepted and
  change nothing
- `student-actions` and `student-actions-with-metadata` accept the dimension; `teacher-actions`
  rejects it as a client error, matching where the form shows the control
- `ReportFilter.dimensions()` and the `@static_dimensions` keys are disjoint

### Add the endpoint

**Summary**: The HTTP surface over the core: parameter validation, the cursor codec, the response
envelope, and the route.

**Files affected**:
- `server/lib/report_server_web/api/v1/filter_options_controller.ex` — new
- `server/lib/report_server_web/api/v1/filter_options_json.ex` — new
- `server/lib/report_server_web/api/v1/filter_params.ex` — new, the `report_filter` object parser,
  its own module because REPORT-93's create and duplicate take the same object
- `server/lib/report_server_web/api/v1/params.ex` — accept a JSON-numeric `limit`, and the cursor codec
- `server/lib/report_server_web/router.ex` — the route
- `server/test/report_server_web/api/v1/filter_options_controller_test.exs` — new

**Estimated diff size**: ~280 lines

```elixir
post "/reports/filter-options", FilterOptionsController, :create
```

`POST` because the request carries student ids and search text that is often a student's name, which
must not travel in a URL that access logs record. `Plug.Parsers` merges the query string into
`conn.params` anyway, so a caller may still send `?limit=…`; the body is simply the documented place.

The request body:

```json
{
  "dimension": "student",
  "report_slug": "student-actions",
  "search": "smi",
  "limit": 50,
  "page_token": "eyJ…",
  "include_count": true,
  "report_filter": { "class": [7, 9], "cohort": null, "exclude_internal": true, "…": "…" }
}
```

`dimension` is the only required field. `include_count` defaults to **true when there is no
`page_token` and false when there is**: measured on 50,000 options a count costs what a page costs
(51 ms against 54 ms), since the wrap materializes the whole distinct set either way, so counting
every page of a walk roughly doubles it to re-derive one unchanged number. The default serves the
interactive case, which wants the total on the page it is looking at, and the flag overrides it in
either direction, including on a page resumed from a saved token. **The filter is nested under `report_filter`, byte-identical
to what `GET /api/v1/reports/:id` emits under that key**, rather than splatted across the top level.
The deciding argument is the client: `internal/api/types.go:13` holds a run's filter as
`json.RawMessage` and never decodes it, so nesting lets cc-data pass the blob straight back
(`{"dimension": d, "report_filter": run.ReportFilter}`) and stay as opaque about filter internals as
it is today. A flat body would force it to unmarshal the blob, splat it, and know which top-level
keys are controls rather than dimensions, acquiring a drift surface it does not currently have.
REPORT-93's create and duplicate need the same object, so one shape serves three endpoints with one
parse module on the server, and a later `from_run_id` stays unambiguous beside a nested object.

**Unknown keys inside `report_filter` are ignored, not rejected**, which is the rule already agreed
for `start_date`, `end_date` and `hide_names`. It is what keeps a client holding a cached filter
working against a server that has since gained a dimension, `app` having been exactly that six
months ago.

`search` is the search text. Not `query`, which is already an MCP tool name in cc-data
(`internal/mcpserver/tools.go:215`, the SQL tool) and would put two unrelated meanings in front of
one LLM; not `like_text`, which leaks the SQL operator into a public contract. The caller's
`filters` list, which the API emits inside `report_filter`, is **accepted and ignored**: `prepare/3`
puts the target dimension at the head itself, and `get_query_and_params/4` never reads the tail.

The envelope is the API's established paged shape plus the count fields:

```elixir
%{
  items: Enum.map(options, &%{id: &1.id, label: &1.label}),
  next_page_token: token,
  count: count,                  # null unless a count was asked for and produced
  count_skipped: skipped?,       # true only when one was asked for and refused
  count_skipped_reason: reason   # null when not skipped
}
```

Three states, each distinguishable without reading the reason string: a number with
`count_skipped: false` is the total; `null` with `count_skipped: true` plus a reason was asked for
and refused, the unbounded student query or a count that tripped the timeout; `null` with
`count_skipped: false` was never asked for. `count_skipped` keeps exactly one meaning, so no client
ever substring-matches English to tell "too expensive" from "you did not ask".

`count` is never omitted when skipped: an absent JSON number decodes to zero in Go, which is
cc-data's language, so the one consumer that exists would read "we did not count" as "there are
none".

**A count that errors degrades to skipped rather than failing the response.** `count/4` distinguishes
a broken query from a refusal, and the controller logs the former at error level, but it still
returns the page with `count_skipped: true`: the page and the count run the same inner statement, so
a count that breaks after a page succeeded is a transient the caller cannot act on, and failing a
page that worked would be worse for the client than handing it the rows without a total.

**`Params.parse_limit/1` needs extending, carefully.** It accepts only a binary today and returns
`{:error, "limit must be an integer"}` for a JSON-numeric `25`, which is the shape a JSON client
naturally sends and a confusing thing to tell it. The added clause must not change what the existing
GET endpoints accept:

```elixir
# before the existing {:ok, _} catch-all, which would otherwise shadow it
{:ok, value} when is_integer(value) -> {:ok, value |> max(1) |> min(@max_limit)}
```

Placed after the catch-all the compiler says so ("this clause cannot match because a previous clause
always matches"), so this cannot ship silently; the note is here to save the round trip.

The page token carries the `(label, id)` cursor, base64 of a JSON pair, opaque by convention. It is
not signed: the dimension, the narrowing filter and the project scoping are all rebuilt from the
request and the caller's role on every page, so a forged token can at worst start the caller at an
odd position inside their own already-scoped result.

**The dimension is resolved through an allowlist, never `String.to_atom/1`.** Atoms are not garbage
collected, so converting a caller-supplied string is an exhaustion vector on an endpoint a client is
expected to call repeatedly. It also protects `prepare/3`, which uses `Map.put(dimension, nil)`: a
struct is a map, so an unrecognized key would be silently *added* rather than rejected.

**The allowlist is `ReportFilter`'s, not a fourth copy of it.** "What is a valid dimension" is
already answered by `@valid_filter_types` (`report_filter.ex:12`), which `get_filter_type!/2`
allowlists a form value against before its own `String.to_atom/1`. This story makes that list public
rather than restating it, and Out of Scope is what licenses the coupling: the endpoint "serves the
dimensions `%ReportFilter{}` already has", so tracking the struct is the intended behavior and a
private copy would be the drift.

```elixir
# in ReportFilter, replacing the private @valid_filter_types usage
def dimensions, do: @filter_type_atoms

def dimension_from_string(raw) when is_binary(raw) do
  if raw in @valid_filter_types, do: {:ok, String.to_atom(raw)}, else: :error
end

# in the controller
defp parse_dimension(raw) when is_binary(raw) do
  case ReportFilter.dimension_from_string(raw) do
    {:ok, dimension} -> {:ok, dimension}
    :error -> {:error, "dimension must be one of: " <> Enum.map_join(ReportFilter.dimensions(), ", ", &to_string/1)}
  end
end
```

`get_filter_type!/2` in the LiveView delegates to `dimension_from_string/1`, so the unsafe
conversion exists in exactly one place, and the error message is generated from the list so the two
cannot disagree.

**One list is not enough on its own, so the agreement gets asserted.** `ReportFilter`'s list is not
in fact the last word on what this endpoint can answer for: the real constraint is which dimensions
`get_filter_query/5` has a clause for, in `ReportFilterQuery`. The two agree today, ten and ten,
verified by driving every one through the builder, and nothing enforces it. An eleventh entry added
without a matching builder clause would be accepted by the endpoint and then fail inside the query
builder. So **step 1's SQL regression test iterates `ReportFilter.dimensions()` instead of a literal
list of ten**, which turns a test that already exists into the assertion that every dimension the
API accepts is one the builder can serve. The static-dimension disjointness test checks
`@static_dimensions` against the same function.

**What the controller parses into the `%ReportFilter{}`**, which is worth stating because two of
these are requirements that are easy to miss by simply not writing the line:

- the ten id dimensions, each validated as integers except `state`, whose values are strings.
  **`null` and `[]` are preserved as themselves and never coalesced.** They mean different things to
  the query builder: `nil` is "not selected", while `[]` makes `has_empty_dependent_filters?/2`
  (`report_filter_query.ex:597`) short-circuit the whole query to no options, and
  `get_dependent_filters/1` makes nearly every dimension a dependent of nearly every other. This is
  the value a round-tripping caller actually sends: choosing a filter type in the web form and
  selecting nothing stores `[]`, it survives `EctoReportFilter`, and `report_filter_json/1` emits
  `"class": []` beside `"cohort": null`. `Jason` decodes the two correctly on its own, so the work
  here is the test rather than the parsing;
- `exclude_internal`, which is **not** inert: it narrows the `teacher` dimension by adding a
  `NOT IN` over Concord's own teacher ids, and costs an extra portal query to resolve them. It
  flows through `prepare/3` untouched, so the only work is parsing it and testing that it does
  narrow;
- `start_date` and `end_date`, accepted and ignored. Accepting them is the requirement: the API's
  own `report_filter_json/1` emits them on every run, so a caller adjusting a run's filter and
  asking what else is available would otherwise be rejected for sending fields the API just handed
  it. The same goes for `hide_names`, which is accepted and then overridden by role.

**The endpoint documents that an empty-set selection narrows to nothing**, since a caller sending
`"class": []` gets an empty `items` and `count: 0` with nothing else to explain it. No envelope field
records the reason. The skipped-count precedent does not apply: there the number was *missing* and
would have decoded to zero in Go, which is a lie, whereas zero here is the true answer and the caller
has the `[]` it sent in its own request.

Controller-level tests cover the validation surface: a non-integer id, an unknown dimension, an
unknown slug, a malformed token, and a dimension outside a named report's `include_filters`. Plus
the acceptance cases above: a request carrying `start_date`, `end_date` and `hide_names` succeeds
rather than erroring, an `exclude_internal: true` request for `teacher` options returns a narrower
set than the same request without it, and the `null` versus `[]` pair is asserted in both
directions, `"class": null` returning the same options as omitting the key while `"class": []`
returns none. The count's three states are asserted as three distinct wire shapes: a first page
carries a number, the same request with a `page_token` carries `count: null` with
`count_skipped: false`, and `include_count: true` on that same paged request brings the number back.

---

### **[cc-data-cli]** Client, CLI and MCP surface

**Summary**: The consuming half, in the other repo. Independent of the server steps once the wire
shape is fixed.

**Files affected**:
- `internal/api/endpoints.go` — `FilterOptions`, `DrainFilterOptions` (carrying the repeated-token
  guard) and `FilterOptionsFor`, which holds the page-or-drain choice so neither caller repeats it
- `internal/api/types.go` — `FilterOptionsPage` and `FilterOption`, alongside `BulkPage`
- `internal/reportview/reportview.go` — the payload the CLI and the MCP tool both render
- `cmd/reports.go`, `cmd/reports_test.go` — `cc-data reports filter-options`
- `internal/mcpserver/tools.go`, `types.go`, `server_test.go` — the MCP tool, named
  `reports_filter_options` to match `reports_list` and `reports_jobs`, its `include_count` field
  described as the one to set when the user asks how many there are
- `internal/guidance/src/tools.md` — the tool's catalog entry (REPORT-104's guard requires it)
- `README.md` — the command listing
- `internal/api/filter_options_test.go` — fake-server tests pinned to a wire capture

The helpers live in `endpoints.go` beside the method they serve rather than in `pagination.go`,
which holds the `GET` helpers generic over `Page[T]`; these are neither generic nor `GET`.

**Estimated diff size**: ~260 lines

The existing `FetchPage`/`DrainPages` are `GET`-only, so the `POST` shape costs a sibling helper.
It does **not** reuse `Page[T]`: that type is `{Items, NextPageToken}`, `encoding/json` drops
unknown fields, and this envelope carries three more, so reusing it would discard the count on the
way in while the MCP tool still tells an LLM to ask for it. `FetchBulkPage` already set the
precedent, returning a `BulkPage` whose envelope "may carry total_endpoints":

```go
type FilterOptionsPage struct {
	Items              []FilterOption `json:"items"`
	NextPageToken      *string        `json:"next_page_token"`
	Count              *int           `json:"count"`
	CountSkipped       bool           `json:"count_skipped"`
	CountSkippedReason *string        `json:"count_skipped_reason"`
}

func (c *Client) FilterOptions(ctx context.Context, req FilterOptionsReq) (FilterOptionsPage, error)
func (c *Client) DrainFilterOptions(ctx context.Context, req FilterOptionsReq) ([]FilterOption, *int, error)
```

`Count` is a pointer so the wire's explicit `null` stays distinguishable from a real zero, which is
the whole reason the server never omits the field. The drain loop keeps the `seen` set that aborts
on a repeated token; the keyset cursor strictly increases, so it never trips on a well-behaved
server.

The MCP tool is registered read-only, and its name and description go into the shared guidance
catalog **in the same commit**, because REPORT-104's drift guard fails CI otherwise. That is the
guard working as intended rather than an obstacle.

## Open Questions

None. The requirements resolved every design question, and the implementation risks (whether the
wrap composes for every dimension, whether a keyset walk is exact across a tie, and how a timeout is
told from an error) were run rather than assumed.

## Verification behind this plan

All of the following was written into the real repo, run against a local MySQL 8.0.39, and then
reverted:

- **A real paged walk is exact.** Over five classes of which three share the label "Lincoln High", at
  page size 2, `FilterOptions.page/4` returned ids `2, 5`, then `9, 40`, then `77`: five options
  visited once each, with the page boundary falling inside the tie. This is the property offset
  paging fails, and the reason the ordering carries the id.
- **The count behaves as specified.** `{:ok, 5}` for the class dimension, and
  `{:skipped, "counting every student without a narrowing selection is unbounded"}` for an
  unnarrowed student request, which never runs the query.
- **The privacy enforcement holds.** `HideNames.allowed?/1` is false for a project researcher, and
  `enforce/2` turns an explicit `hide_names: false` into `true` for them.
- **A bug in the first draft was found by running it, and became its own step.** The draft mapped
  every count failure to `{:skipped, "the count did not complete within the time budget"}`. A
  narrowed student count against a fixture missing the `portal_students` table was duly reported as
  a timeout, which is a comforting lie about a broken query. Probing `PortalDbs.query/4` showed it
  flattens a timeout, a missing table and a bad column to indistinguishable message strings, and that
  the driver's timeout text is itself ambiguous ("possibly due to a timeout **or because the pool
  has been terminated**"), so text matching is not a fix either. Hence the `query_with_reason/4`
  step, verified to classify a real timeout as `:timeout` and a missing table as `:db`.

## Self-Review

Multi-role review of this plan, run after it was written. Roles: Commit Reviewer, Test Engineer,
Senior Elixir Engineer, and Security Engineer. Every issue was checked against the current *and*
the proposed code before being written down. All three below survived and are fixed above.

### Senior Elixir Engineer / Security Engineer

#### RESOLVED: a failed permission lookup raises from inside the query builder
`FilterOptions` called `PortalDbs.get_allowed_project_ids(user)` and passed the result straight into
`ReportFilterQuery.get_query_and_params/4`. That function returns `:all`, `:none`, a list, **or**
`{:error, reason}` when the portal permission query itself fails.

Verified what the tuple does: `get_query_and_params/4` tests only for `:none`, so the tuple reaches
`get_filter_query/5`, which tests only for `:all`, and then `list_to_in/1`, which calls `Enum.map` on
it. The result is `Protocol.UndefinedError: protocol Enumerable not implemented for {:error,
"portal unreachable"} of type Tuple`, raised from deep inside the query builder, which says nothing
about what actually failed.

The codebase already has a convention for this exact failure, and an earlier draft of this plan
invented a second one. `ReportUtils.scope_by_allowed_projects/5` (`report_utils.ex:138`) **raises**
`AllowedProjectsLookupError` on the same `{:error, reason}`, with a comment recording why swallowing
it into a zero-row result is wrong (REPORT-76's controlled `SERVER_ERROR`). `ReportFilterQuery` has
its own scoping branches and never calls that function, so the mechanism is not inherited, but the
convention applies.

**Resolution**: `allowed_project_ids/1` raises the same exception. The wire result is identical to
the tagged tuple the draft proposed, because `ErrorJSON.render/2` has an `/api/`-prefix clause that
renders any raised exception in the contract shape: called directly, `render("500.json", conn)` for
an `/api/` path returns `%{error: "SERVER_ERROR", message: "Internal Server Error"}`, with no
exception detail reaching the client. Given identical behavior, one convention beats two, and
`page/4`, `count/4` and the controller each lose an error branch instead of gaining one.

A 503 would arguably suit a transient upstream failure better than a 500, and this API already uses
`SERVICE_UNAVAILABLE` that way for the download limiter (`report_controller.ex:99`). Not done here:
the exception is shared with REPORT-76's bulk path, so giving it a `Plug.Exception` status would
change a shipped contract for a different endpoint. That is its own ticket.

#### RESOLVED: the dimension reached `String.to_atom/1` territory with no allowlist
The plan validated the dimension only by saying an unknown one is a client error, without saying how
the caller's string becomes an atom. Atoms are never garbage collected, so converting caller-supplied
strings on an endpoint a client is expected to call repeatedly and interactively is an exhaustion
vector.

It compounds with `prepare/3`, which does `Map.put(dimension, nil)` on a `%ReportFilter{}`: a struct
is a map, so an unrecognized key is silently *added* rather than rejected, and the corrupted filter
then flows into the query builder. **Resolution**: the caller's string is resolved through
`ReportFilter.dimension_from_string/1`, made public for this, which also generates the error message
so the two cannot drift. An earlier draft hardcoded a fourth copy of the dimension list in the
controller instead; the list is now exposed once and the ten-dimension SQL regression test iterates
it, so the list the endpoint validates against and the builder clauses that serve it cannot
disagree.

### Commit Reviewer / Test Engineer

#### RESOLVED: the plan's tests depend on a fixture no step in it builds
Three of the test bullets assert on results, and the prose introduced them as running "over the
fixture the earlier steps make available". Verified against the plan's own step list: none of its six
steps creates a portal-DB fixture. The only harness is built by REPORT-91's "Add the portal-DB test
harness" step, in a different story, which this plan never mentions.

That is a real scheduling hazard rather than a wording slip: the two stories are independent in the
backlog, so REPORT-92 can land first, and if it does, its result-level tests, including the paged
walk that is the whole point of the story, cannot be written. Checking further, REPORT-91's
eight-table fixture is also not sufficient here: the scoping test needs `admin_project_users`,
because `get_allowed_project_ids/1` queries it for a project admin.

**Resolution**: half settled, half real. The scheduling hazard went away when REPORT-91 merged on
2026-09-08, and the `admin_project_users` half of the finding was wrong: the shipped fixture does
create that table and seeds both a project admin and a researcher. The rest stands. Loading
`portal_fixture.sql` into a scratch database and executing every dimension's real generated SQL
against it shows four dimensions run and six fail, `cohort` on a missing `admin_cohorts.name` column
and the other five on tables the fixture has no reason to carry for the report tests it was built
for. Extending it is now its own step ahead of the core, rather than an assumption inside it.

### Checked and cleared

- **The keyset cursor's type is consistent.** `next_cursor/2` stringifies the id and `cursor_clause/1`
  binds it as a parameter against an integer column, which MySQL coerces numerically, matching the
  numeric `ORDER BY`. The exact walk observed in stage 5 confirms ordering and comparison agree.
- **`unbounded?/3` reads the caller's filter, not the prepared one, and that is correct.** The
  question it answers is whether the *caller* supplied narrowing; `prepare/3` clears the target
  dimension's own value afterwards, so a request for `student` options that already selected students
  is still unnarrowed. `country`, `state` and `subject_area` are absent from `@narrowing` because they
  do not appear in the student dimension's secondary-filter configuration and genuinely do not narrow
  it.

---

### Second review round (2026-09-08)

Four plan-level defects, each checked against the current and the proposed code before being
written down. The steps above carry the fixes.

- **RESOLVED: the result-level tests had no fixture.** The earlier round called this settled. It was
  not: loading `portal_fixture.sql` into a scratch database and running every dimension's real
  generated SQL shows four run and six fail. Extending the fixture is now its own step.
- **RESOLVED: only the count was time-bounded.** `page/4` passed no options and inherited the
  five-minute module default, while the requirements claimed the walk was bounded by a timeout.
  Both now pass `@portal_timeout_ms`.
- **RESOLVED: `count/4` had no clause for a pool-start failure.** `query_with_reason/4` returns
  `get_or_start_pool/1`'s two-element tuple unchanged, which the `case` did not match.
- **RESOLVED: `unbounded?/3` skipped a count that was free and exact.** It read `[]` as the absence
  of narrowing, so a `student` request with `"class": []` reported the count skipped where the
  requirements say it returns zero.
- **RESOLVED: `static_page/2` reused portal helpers on the wrong shape.** They destructure MyXQL's
  `[id, label]` rows; the static rows are `{id, label}` tuples, and `after_cursor/2` was never
  defined.
