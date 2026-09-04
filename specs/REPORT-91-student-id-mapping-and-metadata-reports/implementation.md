# Implementation Plan: Student ID Mapping and Student Metadata Portal Reports

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-91
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

> Every module below was written and run against a local MySQL 8.0.39 before this plan was written,
> and then deleted: the base-query extraction was diffed against the current `LearnerData` output,
> both report modules were built on the extracted base and executed, and the result-level test
> harness was proved by pointing `PortalDbs` at the local database. What follows is code that has
> run, not code that should work. See "Verification behind this plan" at the end.
>
> **That run was against the pre-REPORT-105 base.** REPORT-105 has since split the learner query out
> of `fetch/3` into a public `build_query/2` and added two callers of it, which changes the shape of
> the first step below and nothing else: it moved the query without touching the join set, the
> filters or the columns. The first step's diff and its test have been rewritten against the
> post-105 code and need re-running there; every later step is unaffected.

## Implementation Plan

### Extract the shared learner base query

**Summary**: Move the `%ReportQuery{}` construction and filter application out of
`Athena.LearnerData.build_query/2` into a neutral `ReportServer.Reports.LearnerBaseQuery`, taking
the caller's select list. Behavior-preserving and independently reviewable: nothing else changes,
and the step is complete when the Athena reports generate byte-identical SQL.

REPORT-105 already performed the execution/construction split this step used to have to make, so
what is left is a move plus a `cols` parameter. It also gave the base two more callers, both of
which have to keep working: `LearnerData.count/2` (which reshapes the base's `cols` into
`COUNT(DISTINCT rl.learner_id)` through `count_query/1`) and the report form's submit-time
partition estimate, which reaches `count/2` through the `:learner_data` application seam.

**Files affected**:
- `lib/report_server/reports/learner_base_query.ex`: new
- `lib/report_server/reports/athena/learner_data.ex`: `build_query/2` delegates to it
- `test/report_server/reports/learner_base_query_test.exs`: new

**Estimated diff size**: ~170 lines (~110 new module, ~55 removed from `LearnerData`, ~50 test)

The new module, in full:

```elixir
defmodule ReportServer.Reports.LearnerBaseQuery do
  @moduledoc """
  The filtered, user-scoped learner query over the portal DB's `report_learners` table.

  One definition of the join set, the owner project scoping and the seven filter dimensions,
  shared by `Athena.LearnerData` (which runs it and post-processes in Elixir) and the
  `type: :portal` student reports (which project their own select lists onto it).
  """
  import ReportServer.Reports.ReportUtils

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{ReportFilter, ReportQuery}

  @from "report_learners rl"
  @join [
    "JOIN portal_learners pl ON (rl.learner_id = pl.id)",
    "JOIN users u ON (u.id = rl.user_id)",
    "JOIN portal_offerings po ON (po.id = rl.offering_id)",
    "JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id)",
    "JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id)",
    "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id)",
    "LEFT JOIN portal_runs run on (run.learner_id = pl.id)"
  ]

  @doc """
  The grouping that collapses this query's fan-out to one row per learner.

  Every table the select list can read contributes its primary key. `rl.id` alone is accepted only
  while MySQL can see the joins: the project scoping's `1 = 0` clause lets the optimizer discard
  them, and `ONLY_FULL_GROUP_BY` then rejects their columns.
  """
  def group_by, do: "rl.id, u.id, ea.id, pl.id"

  @doc """
  The `run_remote_endpoint` string, byte-identical to the one `LearnerData` builds in Elixir,
  including the trailing-slash form for a learner with no `secure_key`.
  """
  def run_remote_endpoint_sql(portal_server) do
    "CONCAT('https://#{portal_server}/dataservice/external_activity_data/', COALESCE(pl.secure_key, ''))"
  end

  @doc "Builds the base query with the caller's select list, and optional group_by/order_by."
  def build(report_filter = %ReportFilter{}, user = %User{}, cols, opts \\ []) do
    query = %ReportQuery{
      cols: cols,
      from: @from,
      join: [@join],
      group_by: Keyword.get(opts, :group_by, ""),
      order_by: Keyword.get(opts, :order_by, [])
    }

    {join, where} = apply_filters(report_filter, user)
    ReportQuery.update_query(query, join: join, where: where)
  end

  defp apply_filters(%ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment,
        permission_form: permission_form, class: class, student: student,
        exclude_internal: exclude_internal, start_date: start_date, end_date: end_date}, user = %User{}) do
    join = []
    where = []

    {join, where} = apply_allowed_project_ids_filter(user, join, where, "po.runnable_id", "ptc.teacher_id")

    {join, where} = if have_filter?(cohort) do
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id)",
          "join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id)"
          | join
        ],
        [
          "aci_teacher.admin_cohort_id in #{list_to_in(cohort)}",
          "aci_assignment.admin_cohort_id in #{list_to_in(cohort)}"
          | where
        ]
      }
    else
      {join, where}
    end

    {join, where} = if have_filter?(permission_form) do
      {
        ["JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id)" | join],
        ["pspf.portal_permission_form_id IN #{list_to_in(permission_form)}" | where]
      }
    else
      {join, where}
    end

    internal_teacher_ids = if exclude_internal do
      get_internal_teacher_ids(user.portal_server)
    else
      []
    end

    {join, where} = if exclude_internal && length(internal_teacher_ids) > 0 do
      {
        ["JOIN portal_teachers pt ON (pt.id = ptc.teacher_id)" | join],
        ["pt.id NOT IN #{list_to_in(internal_teacher_ids)}" | where]
      }
    else
      {join, where}
    end

    where = where
      |> apply_where_filter(school, "rl.school_id IN #{list_to_in(school)}")
      |> apply_where_filter(teacher, "ptc.teacher_id IN #{list_to_in(teacher)}")
      |> apply_where_filter(assignment, "po.runnable_id IN #{list_to_in(assignment)}")
      |> apply_where_filter(class, "rl.class_id IN #{list_to_in(class)}")
      |> apply_where_filter(student, "rl.student_id IN #{list_to_in(student)}")
      |> apply_start_date(start_date)
      |> apply_end_date(end_date)

    {join, where}
  end
end
```

`LearnerData.build_query/2` keeps its column list and loses everything else, so `fetch/3` and
`count/2` keep calling it and never learn that the body moved:

```elixir
@learner_cols [
  {"DISTINCT rl.learner_id", "learner_id"},
  # ... the other fifteen, unchanged
]

def learner_cols, do: @learner_cols

def build_query(report_filter = %ReportFilter{}, user = %User{}) do
  LearnerBaseQuery.build(report_filter, user, @learner_cols)
end
```

where `@learner_cols` is the existing 16-column list moved to a module attribute unchanged,
`DISTINCT rl.learner_id` and all, plus a `def learner_cols, do: @learner_cols` accessor so the
test below can pass the real list rather than a copy of it. A module attribute alone is
compile-time and not callable from another module. `build_query/2` passes no `group_by`, so the
Athena path keeps the `DISTINCT` collapse it has today; only the new reports group.

Keeping `build_query/2` rather than repointing its callers is deliberate. It is REPORT-105's public
surface, `count_query/1` reshapes what it returns, and the report form reaches it through the
`:learner_data` seam that `test/support/learner_data_stub.ex` stands in for, so leaving the name in
place keeps this step a move and keeps that stub honest.

**The test is the point of this step**, and it now starts from a base that is partly pinned:
REPORT-105's `learner_data_test.exs` already asserts that `build_query/2` selects distinct learners
and carries a cohort filter into the `WHERE`, and that `count_query/1` is that query from the `FROM`
onward. Those pass unchanged through a correct move and fail on a botched one, so they are the first
guard and this step does not restate them.

What they do not cover is the filter matrix: they exercise one filter shape and one role. So the new
test pins the extraction by generating SQL across shapes and roles and asserting each against a
stored expectation, so a later edit to the base cannot silently change what the four shipped Athena
reports, or the partition estimate, send to the portal:

```elixir
@cases [
  {"class only", %ReportFilter{filters: [:class], class: [600]}},
  {"cohort+school+dates", %ReportFilter{filters: [:cohort], cohort: [1, 2], school: [7],
                                        start_date: "2026-01-01", end_date: "2026-06-30"}},
  {"permission_form+student", %ReportFilter{filters: [:student], permission_form: [11], student: [70]}}
]
@users [
  {"super-admin", %User{portal_server: "portal.example.com", portal_is_admin: true}},
  {"no-roles", %User{portal_server: "portal.example.com"}}
]

test "the base query generates the expected SQL for every filter and role shape" do
  assert length(@cases) == 3 and length(@users) == 2
  for {case_label, filter} <- @cases, {user_label, user} <- @users do
    {:ok, query} = LearnerBaseQuery.build(filter, user, LearnerData.learner_cols())
    {:ok, sql} = ReportQuery.get_sql(query)
    assert sql == expected_sql(case_label, user_label)
  end
end
```

The `assert length(...)` lines are deliberate: without them a `for` over an accidentally-empty list
asserts nothing.

---

### Add the portal-DB test harness

**Summary**: Give the suite a way to execute portal SQL, which it has never had. Every existing
portal-report test asserts on a generated string, and the two new reports have properties (row grain,
count correctness, hash values) that only execution can check. REPORT-105's `:learner_data` seam and
its `LearnerDataStub` do not close this gap and are not an alternative to it: the stub replaces the
whole of `LearnerData` with canned answers, which is the opposite of executing the SQL a report
generates. It is worth reading before writing tests here for one thing only, which is that it is
installed with a bare `Application.put_env`; that is global, and it is why the tests using it are not
`async: true`. This is its own step because it is
test infrastructure the later steps consume, and because it is the one step that touches how tests
run rather than what they assert.

**Files affected**:
- `test/support/portal_fixture.ex`: new, creates and seeds the fixture schema
- `test/support/portal_fixture.sql`: new, the eight tables the base query touches
- `config/test.exs`: set the fixture portal server's `<SERVER>_DB` variable
- `test/test_helper.exs`: build the fixture once per run

**Estimated diff size**: ~190 lines, nearly all fixture SQL

`PortalDbs` resolves a portal server's credentials from a `<SERVER>_DB` environment variable and
hardcodes `database: "portal"`, so the fixture works by naming a test-only portal server and
pointing it at the MySQL the Ecto repo already uses:

```elixir
# config/test.exs
System.put_env("PORTAL_TEST_EXAMPLE_COM_DB", "mysql://root:xyzzy@localhost:3406")
```

```elixir
defmodule ReportServer.PortalFixture do
  @server "portal-test.example.com"

  def server, do: @server

  # PortalDbs derives this name from the server, so config/test.exs and the fixture cannot drift
  # apart silently; a test asserts the variable it names is set
  def env_var do
    "#{@server}_DB" |> String.replace(".", "_") |> String.replace("-", "_") |> String.upcase()
  end

  def setup! do
    {:ok, _} = ensure_database()

    Path.join(__DIR__, "portal_fixture.sql")
    |> File.read!()
    |> String.split(";\n", trim: true)
    |> Enum.each(fn statement ->
      case ReportServer.PortalDbs.query(@server, statement) do
        {:ok, result} -> result
        {:error, reason} -> raise "portal fixture statement failed: #{reason}\n#{statement}"
      end
    end)
  end
end
```

`setup!` raises rather than ignoring a failed statement: a fixture that half-loads leaves the later
tests failing on absent rows, which sends the reader looking in the wrong place. The connection
details come from the same `<SERVER>_DB` variable `PortalDbs` reads, so the credentials are written
once, in `config/test.exs`, which builds the URL from the values the `Repo` is already configured
with.

The fixture seeds the cases the requirements care about, and the list is longer than it first
looked: the second-pass review found three defects, and a fixture without these shapes catches none
of them.

- One class, one learner whose joins fan out (two teachers on the class, two `portal_runs`).
- A second learner carrying the null edges: no `secure_key`, no `external_activities.url`, no
  `teachers_district`.
- A teacher belonging to **two** schools whose districts and states are **crossed** (`Dist W` in NH,
  `Dist Y` in MA), so a district paired with the wrong state is provably wrong rather than
  plausible.
- A third learner whose `teachers_id` names a teacher with no school membership and a teacher id
  with no `portal_teachers` row.
- A fourth learner with a `NULL` `teachers_id`.
- The rows the project scoping reads: `admin_project_users`, `admin_cohorts`, `admin_cohort_items`
  and `admin_project_materials`, seeded so one project admin sees a strict subset of the
  super-admin's rows and a second project admin sees none. Equal scoped and unscoped results would
  make the scoping test unable to fail.
- `portal_school_memberships` carrying the portal's own `member_type_id_index`, so an `EXPLAIN`
  against the fixture says something about production.

**Two things about this step are easy to get wrong, and both were found by running them.**

*Skipping has to use a tag, not a context value.* Returning `{:ok, skip: true}` from `setup_all`
does nothing: ExUnit does not skip on a context key, so the tests run anyway and fail on the
connection. Verified. The mechanism that works is a tag plus an exclusion decided at boot:

```elixir
# every DB-backed test module
@moduletag :portal_db

# test_helper.exs
unless ReportServer.PortalFixture.reachable?() do
  IO.puts("portal fixture database unreachable; excluding :portal_db tests")
  ExUnit.configure(exclude: [:portal_db])
end
ExUnit.start()
```

Verified: with `:portal_db` excluded the tagged module is reported as excluded and untagged tests
still run. CI runs the container, so nothing is excluded there.

*The reachability check cannot be `has_db_connection?/1`, and the fixture cannot create its own
schema.* Two related traps, both verified:

- `PortalDbs.has_db_connection?/1` only checks that the `<SERVER>_DB` variable is **set**. It
  returns `true` on a machine with no database running, so using it as the gate excludes nothing
  and every tagged test then fails.
- `PortalDbs` hardcodes `database: "portal"`, so its pool cannot connect until that schema exists.
  Running `CREATE DATABASE portal` *through* `PortalDbs` fails, and fails confusingly: the pool
  cannot start, so the error is a two-second queue timeout about pool sizing rather than an unknown
  database.

So the schema is created outside `PortalDbs`, by a plain MyXQL connection with no `:database`, and
`reachable?/0` is an actual query:

```elixir
def reachable? do
  case ReportServer.PortalDbs.query(server(), "SELECT 1", [], timeout: 2_000) do
    {:ok, _} -> true
    _ -> false
  end
end

defp ensure_schema! do
  # no :database, because "portal" is what we are about to create
  {:ok, conn} = MyXQL.start_link(hostname: "localhost", port: 3406, username: "root", password: "xyzzy")
  MyXQL.query!(conn, "CREATE DATABASE IF NOT EXISTS portal")
  GenServer.stop(conn)
end
```

---

### Make the hide-names rule reachable outside the report form

**Summary**: `maybe_enforce_hide_names/2` and `allow_hide_names?/1` are private to
`report_live/form.ex`, so the one rule keeping student names away from researchers cannot be called
by anything else, including REPORT-93's create-run endpoint. Move them to a module both can use.
This lands before the metadata report because that report is the first Portal report to emit a
student name.

**Files affected**:
- `lib/report_server/reports/hide_names.ex`: new
- `lib/report_server_web/live/report_live/form.ex`: delegate to it
- `test/report_server/reports/hide_names_test.exs`: new

**Estimated diff size**: ~70 lines

```elixir
defmodule ReportServer.Reports.HideNames do
  @moduledoc """
  Who may see learner names, and the enforcement that overrides a request that asks to.
  Lives outside the LiveView so every path that builds a report filter can apply it.
  """
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportFilter

  @doc "Only portal admins and project admins may see names."
  def allowed?(%User{portal_is_admin: true}), do: true
  def allowed?(%User{portal_is_project_admin: true}), do: true
  def allowed?(%User{}), do: false

  @doc "Forces hide_names on for anyone not allowed to see them, whatever the filter asked for."
  def enforce(report_filter = %ReportFilter{}, user = %User{}) do
    if allowed?(user), do: report_filter, else: %{report_filter | hide_names: true}
  end
end
```

`form.ex`'s two private functions go away entirely and the four places that built a filter from form
params call `HideNames` directly: `submit_form`, `debug_form`, `live_select_change` and
`update_options`. Delegations would have left a local name that no longer carries logic and could
drift from the shared rule. Behavior is unchanged and the existing form tests pass untouched.

Tests assert the full role matrix, including that `enforce/2` overrides an explicit
`hide_names: false` for a researcher rather than merely defaulting it.

---

### Add the Student ID Mapping report

**Summary**: The first of the two reports. Small, because the previous steps did the work.

**Files affected**:
- `lib/report_server/reports/portal/student_id_mapping_report.ex`: new
- `lib/report_server/reports/tree.ex`: register in the `student-reports` group
- `test/report_server/reports/portal/student_id_mapping_report_test.exs`: new

**Estimated diff size**: ~130 lines

```elixir
defmodule ReportServer.Reports.Portal.StudentIdMappingReport do
  use ReportServer.Reports.Report, type: :portal

  alias ReportServer.Reports.LearnerBaseQuery

  def get_query(report_filter = %ReportFilter{}, user = %User{portal_server: portal_server}) do
    LearnerBaseQuery.build(report_filter, user, cols(portal_server),
      group_by: LearnerBaseQuery.group_by(), order_by: [{"learner_id", :asc}])
  end

  defp cols(portal_server) do
    [
      {"rl.learner_id", "learner_id"},
      {"rl.user_id", "user_id"},
      {"COALESCE(u.primary_account_id, u.id)", "primary_user_id"},
      {"rl.student_id", "student_id"},
      {"rl.class_id", "class_id"},
      {"rl.offering_id", "offering_id"},
      {"ea.url", "runnable_url"},
      {LearnerBaseQuery.run_remote_endpoint_sql(portal_server), "run_remote_endpoint"}
    ]
  end
end
```

`run_remote_endpoint_sql/1` lives on `LearnerBaseQuery` rather than in the report, because the
metadata report emits the same column and the string has to be byte-identical to the one
`LearnerData` builds in Elixir; one definition is what makes that checkable.

The tree entry:

```elixir
StudentIdMappingReport.new(%Report{
  slug: "student-id-mapping",
  title: "Student ID Mapping",
  subtitle: "One row per selected learner with the portal ids and the run_remote_endpoint that joins them to the answers, history and attachments stored for those learners. No names.",
  include_filters: [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form]
}),
```

No `form_options`: `hide_names` provably changes nothing here, so the checkbox is not offered, and
`enable_app_filter` is meaningless for a Portal query. Two consequences of REPORT-105 follow from
the empty list, both wanted and neither needing code here: a filter carrying `app` is rejected by
`check_app_supported/2` at submit rather than stored and ignored, and `warning_applicable?/1` reads
`false`, so the submit-time learner count that log reports pay for never runs for either new report.

Tests, split by what they can check:

- SQL-shape (no database): the eight column names in order; the grouping carrying `u.id` and
  `ea.id` alongside `rl.id`, and no `DISTINCT`; project scoping absent for a super-admin and `1 = 0`
  for a role-less user; the no-filter super-admin case returning
  `{:error, "Cannot run query with no filters"}`.
- Result-level (fixture): one row for the fanning-out learner, `get_count_sql/1` returning `1` not
  `4`, `run_remote_endpoint` equal to the Elixir construction for both a present and an absent
  `secure_key`, and the null-`runnable_url` learner present in the report.
- Result-level, the zero-allowed-projects case, **executed** on both surfaces: `PortalDbs.query/4`
  and `PortalDbs.stream_query/4` each return zero rows rather than an error. A SQL-shape assertion
  cannot stand in for this one; it is what let the `ERROR 1055` defect through the first review.
  Both roles that reach the clause are covered, the role-less user (`:none`, no portal query) and a
  project admin whose lookup returns `[]`, because they are different code paths into it and the
  second is what showed the grouping was enumerated one table short.
- Result-level, project-admin scoping: a project admin sees a strict subset of what a super-admin
  sees for the same filter, and a project admin with no projects sees nothing. Written here rather
  than in the metadata step because both reports project onto one base query, so one scoping test
  covers the shared behavior; the metadata step asserts only what its own select list adds.
- `hide_names` is a no-op: `get_query/2` with the flag set and unset produces identical SQL and, on
  the fixture, identical rows. This is the claim that justifies withholding `enable_hide_names` from
  this report, so it is the one assertion standing between that decision and a silent regression.
- API surface, which needs no production code but is otherwise pinned by nothing. The requirement
  is that both reports are reachable through `/api/v1` *because* of the type-based mechanism
  REPORT-88 shipped, and that mechanism lives in `Tree` and `ReportJSON`, which this story does not
  own. Nothing here would fail if a later change dropped them out of it. Assert on the two values
  the mechanism derives rather than on the run body's key set: REPORT-106 added `athena_query_id`
  and `athena_query_error` to it, both always `nil` for a Portal run, and the set itself is already
  guarded by `@run_keys` in `report_controller_test.exs`.

```elixir
test "both reports are exposed through the v1 API by the type-based mechanism" do
  for slug <- ["student-id-mapping", "student-metadata"] do
    report = Tree.find_report(slug)
    assert report.type == :portal
    assert report.api_report_type == nil
    assert report.derives_learner_data, "#{slug} must be accepted by the bulk endpoints"
    assert slug in Tree.api_report_slugs()
    refute slug in Tree.athena_report_slugs()
  end
end

test "a run of either report reports execution sync and a null report_type" do
  user = user_fixture()
  for slug <- ["student-id-mapping", "student-metadata"] do
    {:ok, run} = Reports.create_report_run(%{user_id: user.id, report_slug: slug,
                                             report_filter: %ReportFilter{filters: [:class], class: [1]}})
    json = ReportJSON.show(run)
    assert json.execution == "sync"
    assert json.report_type == nil
  end
end
```

- The empty result: a filter matching no learners yields zero rows rather than an error, so the
  Portal download path REPORT-88 established renders a header-only CSV with `200`. Asserted at the
  query level (zero rows, valid SQL) and through the download endpoint for one of the two reports,
  since the CSV encoding is REPORT-88's and needs confirming here only once.

---

### Add the Student Metadata report

**Summary**: The second report, plus the MySQL spellings of the anonymization the Athena reports
express in Presto.

**Files affected**:
- `lib/report_server/reports/learner_hide_names.ex`: new
- `lib/report_server/reports/portal/student_metadata_report.ex`: new
- `lib/report_server/reports/tree.ex`: register in the `student-reports` group
- `test/report_server/reports/learner_hide_names_test.exs`: new
- `test/report_server/reports/portal/student_metadata_report_test.exs`: new

**Estimated diff size**: ~260 lines

```elixir
defmodule ReportServer.Reports.LearnerHideNames do
  @moduledoc """
  The MySQL spellings of the learner anonymization the Athena reports express in Presto, so a
  hidden value from a `type: :portal` student report equals the Athena one for the same learner.
  """
  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.ReportUtils

  def student_name_sql(true), do: "rl.student_id"
  def student_name_sql(_), do: "rl.student_name"

  # Presto: TO_HEX(SHA1(CAST((salt || username) AS VARBINARY))) -> uppercase hex of the digest.
  # MySQL SHA1() already returns lowercase hex, so UPPER(SHA1(...)) matches and HEX(SHA1(...))
  # would double-encode.
  def username_sql(true) do
    salt = escape_mysql_literal(AthenaConfig.get_hide_username_hash_salt())
    "UPPER(SHA1(CONCAT('#{salt}', rl.username)))"
  end

  # MySQL treats backslash as an escape character inside a string literal and Presto does not,
  # so escaping only the quotes (as the Athena path does) silently changes what gets hashed.
  defp escape_mysql_literal(str) do
    str |> String.replace("\\", "\\\\") |> ReportUtils.escape_single_quote()
  end
  def username_sql(_), do: "rl.username"
end
```

```elixir
defmodule ReportServer.Reports.Portal.StudentMetadataReport do
  use ReportServer.Reports.Report, type: :portal

  alias ReportServer.Reports.{LearnerBaseQuery, LearnerHideNames}

  # GROUP_CONCAT cuts its result at group_concat_max_len (1024 bytes by default), mid-value, with
  # only a warning nothing reads, which would misalign the teacher columns this report guarantees
  # are aligned. A per-statement optimizer hint raises the ceiling for this query without touching
  # the pooled connection's session, which a SET SESSION would, and without a second statement,
  # which the one-statement contract forbids. It rides on the first column because that is where
  # ReportQuery puts it: get_sql/2 renders "SELECT " <> cols, so the hint lands immediately after
  # SELECT, which is where MySQL expects it.
  @group_concat_hint "/*+ SET_VAR(group_concat_max_len=1048576) */"

  def get_query(report_filter = %ReportFilter{hide_names: hide_names}, user = %User{portal_server: portal_server}) do
    LearnerBaseQuery.build(report_filter, user, cols(portal_server, hide_names),
      group_by: LearnerBaseQuery.group_by(), order_by: [{"learner_id", :asc}])
  end

  defp cols(portal_server, hide_names) do
    [
      {"#{@group_concat_hint} rl.learner_id", "learner_id"},
      {"rl.user_id", "user_id"},
      {"COALESCE(u.primary_account_id, u.id)", "primary_user_id"},
      {"rl.student_id", "student_id"},
      {"rl.class_id", "class_id"},
      {"rl.school_id", "school_id"},
      {LearnerBaseQuery.run_remote_endpoint_sql(portal_server), "run_remote_endpoint"},
      {LearnerHideNames.student_name_sql(hide_names), "student_name"},
      {LearnerHideNames.username_sql(hide_names), "username"},
      {"rl.class_name", "class"},
      {"rl.school_name", "school"},
      {csv_list("rl.teachers_id"), "teacher_user_ids"},
      {csv_list("rl.teachers_name"), "teacher_names"},
      {csv_list("rl.teachers_email"), "teacher_emails"},
      {teacher_school_field("name"), "teacher_districts"},
      {teacher_school_field("state"), "teacher_states"},
      {"rl.permission_forms", "permission_forms"},
      {"DATE_FORMAT(rl.last_run, '%Y-%m-%dT%H:%i:%s')", "last_run"}
    ]
  end

  # the portal joins these lists with ", " while permission_forms uses ","; normalize so the
  # file has one splitting rule
  defp csv_list(col), do: "REPLACE(#{col}, ', ', ',')"

  # One entry per teacher NAMED IN teachers_id, in that list's own order, so all five teacher
  # columns align by index. report_learners' own teachers_district/teachers_state cannot be used:
  # they carry one entry per (teacher, school) pair, so they do not line up with teachers_id or
  # teachers_name.
  #
  # Two properties keep that alignment true:
  #
  #   * The positions come from teachers_id, not from portal_teachers. GROUP_CONCAT skips NULLs, so
  #     driving this from the teacher table drops a teacher who has no school, and a teacher id with
  #     no teacher row, out of the list entirely, shortening it and misaligning every later index.
  #     COALESCE keeps the position and leaves the cell empty.
  #   * The school is chosen once, with ORDER BY ps.id LIMIT 1, and both the district and the state
  #     are read from that row. Choosing each field independently pairs one school's district with
  #     another school's state for any teacher who belongs to more than one.
  #
  # The list is bounded by the teachers on one class, and the membership lookup uses the portal's
  # member_type_id_index, so the per-row cost does not grow with the size of either table.
  defp teacher_school_field(field) do
    """
    (SELECT GROUP_CONCAT(COALESCE(
              (SELECT pd.#{field}
                 FROM portal_school_memberships psm
                 JOIN portal_schools ps ON (ps.id = psm.school_id)
                 LEFT JOIN portal_districts pd ON (pd.id = ps.district_id)
                WHERE psm.member_type = 'Portal::Teacher' AND psm.member_id = jt.tid
                ORDER BY ps.id LIMIT 1), '')
            ORDER BY jt.pos SEPARATOR ',')
       FROM JSON_TABLE(CONCAT('[', REPLACE(COALESCE(rl.teachers_id, ''), ' ', ''), ']'),
                       '$[*]' COLUMNS (pos FOR ORDINALITY, tid INT PATH '$')) jt)
    """
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
```

`get_count_sql/1` discards the select list, so the count query loses the hint. That is correct
rather than a gap: it selects `1 AS qrow` and concatenates nothing. Verified through the real
builder that the hinted statement runs on all three paths a Portal report reaches (the web run, the
web column sort, and the API's `stream_query/4`), and that the count still returns one row per
learner.

An alternative was considered and not taken: adding a `hints` field to `%ReportQuery{}`. It reads
better, but it puts a MySQL-only concept into the struct the Athena reports share, for one report's
need, and step one is deliberately a pure move of that struct's construction.

`teacher_school_field/1` now takes the district column's field name (`name` or `state`) rather than
a qualified column, because both fields are read from the same subquery row.

`COALESCE(rl.teachers_id, '')` is not decoration: `CONCAT` with a `NULL` argument yields `NULL`, and
`JSON_TABLE(NULL, ...)` is not the empty list. The empty string yields `[]`, which is zero rows, a
`NULL` from `GROUP_CONCAT`, and an empty cell.

The one new failure mode this shape introduces, which the requirements record: `JSON_TABLE` raises
`ERROR 3141` on malformed JSON, so a `teachers_id` that is not a bare comma-separated id list fails
the whole report rather than one row. The portal writes it as `ts.map{|t| t.id}.join(", ")`, so the
shape holds in practice.

The tree entry, written out because its `form_options` is the one place the two reports differ:

```elixir
StudentMetadataReport.new(%Report{
  slug: "student-metadata",
  title: "Student Metadata",
  subtitle: "One row per selected learner with the human-readable context: name, username, class, school, teachers, permission forms. Joins 1:1 to Student ID Mapping on learner_id. Names are hidden unless you are an admin and clear the hide-names option.",
  include_filters: [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form],
  form_options: [enable_hide_names: true]
}),
```

`form_options` carries `enable_hide_names: true` and nothing else. The two log reports carry
`enable_app_filter: true` beside it since REPORT-105; that option gates a partition constraint on
the Athena log table and must not be copied here.

Tests:

- `LearnerHideNames`: `username_sql(true)` produces `UPPER(SHA1(CONCAT('<salt>', rl.username)))` and
  specifically not `HEX(SHA1(...))`; the salt is escaped. A result-level test asserts the value
  equals `:crypto.hash(:sha, salt <> username) |> Base.encode16()`, which is the same digest the
  Presto expression yields, so the two report families cannot drift apart. The salt is pinned in the
  test rather than read from config, since an unconfigured salt is randomized per boot.
- `StudentMetadataReport`: the eighteen column names; `student_name` selecting `rl.student_id` under
  hide-names and `rl.student_name` without; the five teacher columns and `permission_forms` all
  emerging comma-separated with no spaces; `last_run` as `2026-05-01T10:00:00`; and the null-edge
  learner emitting an empty cell for `last_run` while `teacher_names` populates.
- **Teacher-column alignment, on a fixture built to break it.** This is the report's stated
  contract and the reason those two columns are derived rather than read, so it gets tests that fail
  if any part of it changes. Three cases, each of which caught a real defect during the second-pass
  review:
  - Two teachers, one belonging to two schools: all five columns split to the same number of entries
    and index *i* names the same teacher in each. Verified: `31,32` / `Ann Teach,Bob Teach` /
    `ann@e.org,bob@e.org` / `Dist W,Dist Y` / `NH,MA`.
  - The two schools' districts and states **crossed**, so the district and the state at index *i*
    must come from the same school. On a fixture where `Dist W` is in NH and `Dist Y` is in MA, the
    earlier `MIN()` implementation emitted `Dist W,Dist Y` against `MA,MA`, reporting a NH teacher in
    MA. The test asserts the pair, not each column separately.
  - A teacher with no school membership and a teacher id with no `portal_teachers` row: the lists
    keep their positions. Verified: three names against `Dist W,,` and `NH,,`, where the earlier
    implementation emitted one entry against three names.
- A learner with a `NULL` `teachers_id` emits empty cells rather than failing the statement.
- **No silent truncation.** `GROUP_CONCAT` cuts mid-value at `group_concat_max_len` and raises
  warning 1260, which nothing inspects; a truncated list misaligns the columns the test above
  pins. The step either raises the limit for this query or asserts `result.num_warnings == 0`,
  and a test drives a deliberately tiny limit to prove the guard fires.
- Grain: the two reports emit equal `learner_id` sets for the same filter, and one row each for a
  single-learner filter.

---

### Document the two reports for consumers

**Summary**: Satisfies the Documentation requirement. The column contracts these reports establish
are consumed by cc-data (REPORT-94) and described to Claude (REPORT-95), and the non-obvious parts
are the ones a reader will get wrong. Kept as its own step so the code steps stay reviewable.

**Files affected**:
- `server/README.md` or the reports documentation: the two reports' column contracts

**Estimated diff size**: ~50 lines

What has to be written down, because none of it is inferable from the column names:

- The per-learner grain, and that grouping back to a student is by `user_id` / `primary_user_id`.
- That all five teacher columns are aligned by index, and that a teacher in more than one school
  contributes one deterministically chosen district and state rather than all of them.
- That every list column separates on `","`.
- That `run_remote_endpoint` is the join key to cc-data's stored `remote_endpoint`, and that a
  learner with no `secure_key` yields the trailing-slash form that joins to nothing.

## Open Questions

None. Every decision this plan depends on was resolved in `requirements.md`, and the three that
carried implementation risk (the extraction being behavior-preserving, the reports composing on the
extracted base, and the result-level harness being reachable) were run rather than assumed.

## Verification behind this plan

All of the following ran against a local MySQL 8.0.39, **on the pre-REPORT-105 base**, and was then
deleted. The first item below is the one that needs re-running before the first step is reviewed as
a move, because its diff target has changed; the rest are unaffected, since REPORT-105 relocated the
learner query without changing the join set, the filters or the columns:

- **The extraction is byte-identical.** `LearnerBaseQuery.build/4` was written, and the SQL it
  produces for `LearnerData`'s column list was diffed against the SQL the then-inline construction
  produces, across three filter shapes and two role shapes. All six statements matched exactly,
  which is what makes the first step safe to review as a pure move. Re-run against
  `build_query/2`'s output, which is now the thing being moved and is directly callable, so the
  diff no longer needs the inline construction reconstructed to compare against.
- **Both report modules compile and run on the extracted base**, producing the column sets, the
  hide-names substitutions, the comma-normalized teacher lists and the ISO `last_run` that
  `requirements.md` specifies, and a `get_count_sql/1` of `1` for a learner whose joins fan out to
  four rows.
- **The result-level harness works end to end.** With `P_EXAMPLE_ORG_DB` pointing at the local
  MySQL and the fixture in a schema named `portal`, `PortalDbs.has_db_connection?/1` returns true and
  `PortalDbs.query/2` runs the real report SQL, returning the expected single row and count. That
  retires the largest implementation risk in the plan, since the requirements ask for result-level
  tests the suite has never been able to write.

## Deviations found while implementing

Three things the plan did not anticipate, each settled in the code and recorded here so the plan and
the branch agree:

- **`AthenaConfig.get_hide_username_hash_salt/0` crashed in test.** `:athena` is configured under
  `config_env() == :prod` and in `dev.exs` only, so the getter ran `Keyword.get(nil, ...)` the first
  time a test reached it, which the metadata report does through `LearnerHideNames`. It now defaults
  the missing config the way the log-projection getters beside it already do, with its own test. No
  Athena report reached it before, which is why nothing caught it earlier.
- **Each report needs two test files, not one.** The result-level tests are `async: false` (they
  share one portal database and one global salt) and tagged `:portal_db` so they are excluded when
  that database is unreachable, while the SQL-shape tests stay `async: true` and DB-free. Splitting
  them by module is what lets both properties hold, so each report has a `_test.exs` and a
  `_db_test.exs`.
- **The API-surface test moved.** The plan wrote it against both reports in the mapping report's
  step, which is a forward dependency on a report that does not exist yet at that point. The mapping
  step asserts its own report; the both-reports version lives in the metadata step, where both exist.

## Requirements coverage

Every requirement bullet was walked against the six steps above. Four had no step, and were settled
as follows rather than left implicit:

- **Project-admin scoping, result-level**, and **`hide_names` is a no-op for the mapping report**:
  implemented. Both are named in the mapping report step's test list, and the harness fixture gains
  the project-scoping rows. Both guard claims the design leans on, and the scoping case is what
  caught the grouping being enumerated one table short.
- **Bulk-endpoint acceptance** and **the two REPORT-105 interaction rules**: the requirements now
  say these hold by construction and name where they are enforced (`EndpointSet`'s
  `derives_learner_data` gate, and REPORT-105's `check_app_supported/2` and
  `warning_applicable?/1`). Restating them as tests here would add assertions that fail on another
  story's change while testing nothing this story owns. What this story pins is the report
  attributes those mechanisms read.

No step lacks a requirement. Step sizes are unchanged except the two reports' test lists.

## Self-Review, second pass (post-REPORT-105, verified by execution)

Run after the rebase onto REPORT-105. Everything below was executed against a fixture portal schema
on MySQL 8 through the real `PortalDbs` code path, not read. The findings that change what the SQL
must be are written up in `requirements.md`'s second-pass Self-Review, because they change stated
contracts rather than only the code; this section carries what changes in this plan.

### Commit Reviewer

#### RESOLVED: the extraction is byte-identical on the post-REPORT-105 base

The header note asked for this to be re-run against `build_query/2` rather than the pre-105 inline
construction. Done: `LearnerBaseQuery.build/4` was written as this plan specifies, and its SQL was
compared to `LearnerData.build_query/2`'s for three filter shapes (class only; cohort with school
and a date range; permission form with student) against two roles (super-admin, role-less). All six
statements are identical. The first step is safe to review as a pure move, and the plan's own test
matrix is what pinned it.

### Database Engineer

#### RESOLVED: `group_by: "rl.id"` is not enough, in both report modules

Both `get_query/2` code blocks pass `group_by: "rl.id"`. That statement is rejected outright by
MySQL 8 whenever the project scoping contributes its `1 = 0` clause, because the impossible `WHERE`
lets the optimizer drop the joins and the select list then fails `ONLY_FULL_GROUP_BY`. See the
finding in `requirements.md`. The change here is one string in each module,
`group_by: "rl.id, u.id, ea.id, pl.id"`, which was verified to be accepted with the clause present
and to
still emit one row per learner.

The mapping report's test list says "`GROUP BY rl.id` present and no `DISTINCT`". That assertion has
to change with the string, and it is worth asserting the joined primary keys are in the grouping
rather than matching the literal, so the test says why they are there.

**Resolution**: applied, with the value on `LearnerBaseQuery` rather than copied into both reports:
the grouping is determined by the base query's join set, so it belongs beside the joins, and two
copies that must agree is the shape this repo's reviewers flag. `LearnerBaseQuery.group_by/0` carries
the reason, its own test asserts the value and that every alias in it is one the base actually joins,
and each report's test asserts it uses the shared value. Verified after the change: the role-less
caller and a project admin with no projects both return zero rows through `query/4` and through
`stream_query/4`, for both reports.

#### RESOLVED: `teacher_school_field/1` needs to be rebuilt, not adjusted

`MIN(#{col})` and the `portal_teachers`-driven `FROM` are each responsible for one of the two
alignment defects in `requirements.md`. The replacement shape, verified end to end, is one derived
table computing district and state together per teacher from its lowest-id school, joined to a
`JSON_TABLE` expansion of `rl.teachers_id` so that every listed teacher keeps a position. That is
also the fix for the `DEPENDENT SUBQUERY` per row that `EXPLAIN` shows, so all three findings close
with one rewrite rather than three patches.

Two consequences for this step: the helper stops being a one-column function (district and state
come from the same derived table, so it emits both), and the step gains a guard or a documented
failure mode for a `teachers_id` that is not a bare id list, since `JSON_TABLE` raises `ERROR 3141`
rather than returning NULL.

**Resolution**: rewritten above. The helper now takes a field name, expands `teachers_id` with
`JSON_TABLE` so every listed teacher keeps a position, and reads the district and the state from one
school chosen by `ORDER BY ps.id LIMIT 1`. Verified on the four-learner fixture: all five teacher
columns split to the same count on every row, `Dist W` carries `NH`, the schoolless and unknown
teachers appear as empty positions, and a `NULL` `teachers_id` yields empty cells. `EXPLAIN` now
reports a `ref` lookup on `member_type_id_index` rather than a full scan with a hash join. The
`ERROR 3141` failure mode is recorded rather than guarded, with the portal-side reason it does not
arise in practice.

### QA Engineer

#### RESOLVED: the harness step is now load-bearing for correctness, not only for coverage

The plan orders the portal-DB harness second, before the reports, and treats it as infrastructure
for properties that "only execution can check". The second pass shows it is stronger than that: the
three defects found are all invisible to the SQL-shape tests this plan writes, and two of them are
invisible to any fixture where each teacher has one school and every teacher id resolves. The
harness step should state the fixture shape the later tests need, since the fixture is what does the
catching:

- a learner whose joins fan out (already specified),
- a teacher in two schools whose districts and states are crossed, so a district cannot be paired
  with the wrong state by accident,
- a teacher with no school membership and a teacher id with no `portal_teachers` row, so the
  position count is exercised,
- a caller with no allowed projects, executed rather than string-matched.

**Resolution**: the harness step now lists the fixture shape, including the crossed districts and
the `member_type_id_index`, and the two report steps' test lists name the cases that need it.

#### RESOLVED: the truncation guard has one viable mechanism, and the plan should name it

The metadata step offers "either raises the limit for this query or asserts `result.num_warnings ==
0`". Verified: `SET SESSION` is not available (a second statement, and it leaks across the pooled
connection), while the per-statement hint
`SELECT /*+ SET_VAR(group_concat_max_len=1048576) */ ...` works and leaves the session value at
1024. `num_warnings` is present on `%MyXQL.Result{}`, and on the streamed download path it arrives
per batch, so an assertion there has to be per batch. Whichever is chosen, the plan should name it
rather than leaving the choice to the implementer, because only one of the two options exists.

**Resolution**: the requirement now names the optimizer hint, so the metadata step raises the limit
for its own statement and the `num_warnings` assertion becomes a test rather than the mechanism. The
rewritten helper also lowers the exposure: the concatenated list is one entry per teacher on one
class, not one per (teacher, school) pair.

## Self-Review

Multi-role review of this plan, run after it was written. Roles: Commit Reviewer (are the steps
really independent, does step N compile without step N+1), Test Engineer (can each named test
actually be written against the harness the plan provides), Senior Elixir Engineer, and Security
Engineer. Every issue was checked against the current *and* the proposed code before being written
down, which for a plan mostly means building the proposed thing far enough to see whether the claim
survives. All four below survived, and all four are now fixed above.

### Commit Reviewer

#### RESOLVED: the extraction step's test calls something the step does not define
Step one described moving `LearnerData`'s column list to a module attribute, `@learner_cols`, and
then its test called `LearnerData.learner_cols()`. A module attribute is compile-time and is not
callable from another module, so the test as written would not compile against the step as
described.

The alternative, copying the sixteen columns into the test, is worse than it looks: the test exists
to prove the extraction changed nothing, and a copied list makes it prove that a copy equals a copy.
**Resolution**: the step adds a one-line `def learner_cols, do: @learner_cols` accessor and the test
passes the real list.

### Test Engineer

#### RESOLVED: `{:ok, skip: true}` from `setup_all` does not skip anything
The harness step said a developer without the container should not see red, and implemented that by
returning `{:ok, skip: true}` from `setup_all`. ExUnit does not skip on a context key; skipping is a
tag-and-exclude mechanism.

Verified by writing exactly the proposed `setup_all` around a test whose body is `flunk/1`: the test
**ran** and failed. So the plan's stated goal and its mechanism were opposites, and the failure mode
is the one it was trying to prevent, on every machine without the database. Verified the working
alternative too: `@moduletag :portal_db` with `--exclude portal_db` reports the module as excluded
while untagged tests still run. **Resolution**: the step now uses the tag, with `test_helper.exs`
deciding the exclusion at boot.

#### RESOLVED: the fixture cannot bootstrap itself, and its reachability gate is not a gate
Two traps in the same step, both verified against the real code:

- `PortalDbs.has_db_connection?/1` reads as a liveness check and is not one: it returns `true` when
  the `<SERVER>_DB` environment variable is merely *set*. On a machine with no database running it
  says yes, so the exclusion never triggers and every tagged test fails on connection.
- `PortalDbs` hardcodes `database: "portal"`, so its pool cannot connect until that schema exists,
  and the fixture's own `CREATE DATABASE` therefore cannot go through `PortalDbs`. Probed with the
  schema dropped: the call fails after two seconds with a queue-timeout message about pool sizing,
  which is a genuinely misleading thing to hand a developer whose real problem is that they never
  created the database.

**Resolution**: `reachable?/0` runs an actual `SELECT 1` with a short timeout, and the schema is
created by a plain MyXQL connection opened with no `:database` before any pool starts.

### Security Engineer

#### RESOLVED: the salt escaping breaks hide-names parity for a salt containing a backslash
`LearnerHideNames.username_sql/1` interpolated the salt after `ReportUtils.escape_single_quote/1`,
which doubles quotes and leaves backslashes alone. That is correct for the Athena path it was copied
from and wrong here, and `requirements.md` says so in as many words: MySQL treats a backslash inside
a string literal as an escape character and Presto does not.

Verified end to end with a salt of `sa\lt`. MySQL, given the literal the proposed code produces,
drops the backslash and hashes `saltstu.one` to `9E90B470…`; Elixir and Presto hash the real
five-character salt to `4B5BDEC5…`. Different digests, no error, and the symptom is that hidden
usernames from the two report families stop joining, which is precisely the property the story
promises and the hardest kind of breakage to trace back.

**Resolution**: a local `escape_mysql_literal/1` escapes backslashes before quotes. The requirements
already called for this; the implementation had quietly reverted to the Athena spelling.

Two candidates were checked and dropped: `run_remote_endpoint_sql/1` is defined in step one and used
in steps four and five, so no step references a symbol a later step introduces; and
`ReportQuery.get_count_sql/1` discards `order_by` while preserving `group_by`, so the reports' own
ordering cannot affect their row counts.
