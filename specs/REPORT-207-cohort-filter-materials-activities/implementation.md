# Implementation Plan: The cohort filter admits activities attached through the cohort's project materials

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-207
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

Four commits, each green on its own. The whole plan was built in this worktree as throwaway code on REPORT-195's branch: `mix compile --warnings-as-errors` is clean, and `mix test` runs 1569 tests with 0 failures (1558 before, 11 added). With step 1 alone it ran 1564 tests and with steps 1 and 2 it ran 1565, both with 0 failures. Every code change below has a test that fails when that change alone is reverted (see Self-Review, Test Writer).

All paths are under `server/`.

## Implementation Plan

### One rule for the cohort filter's activity side, used by the learner query

**Summary**: Adds `ReportServer.Reports.CohortFilter`, the single definition of which activities a selected cohort admits (R1, R4), adds cohort 6 to the portal fixture, and switches `LearnerBaseQuery` to the rule. That one switch covers Student ID Mapping, Student Metadata, the four Athena student reports and the three exports (R2's first bullet).

**Files affected**:
- `lib/report_server/reports/cohort_filter.ex`: new.
- `lib/report_server/reports/learner_base_query.ex`: the cohort clause drops the `aci_assignment` join and uses the rule.
- `test/support/portal_fixture.sql`: cohort 6, and two rows of other types that collide with activity ids.
- `test/report_server/reports/cohort_filter_db_test.exs`: new; the rule against the fixture, and the learner paths.
- `test/report_server/reports/learner_base_query_test.exs`: the cohort SQL snapshot.
- `test/report_server/reports/report_filter_query_db_test.exs`, `test/report_server/portal_fixture_test.exs`: two enumerations cohort 6 moves.

**Estimated diff size**: ~150 lines

`lib/report_server/reports/cohort_filter.ex`:

```elixir
defmodule ReportServer.Reports.CohortFilter do
  @moduledoc """
  The activity side of the cohort filter: a selected cohort admits an activity that is one of its
  `ExternalActivity` items or one of its project's `ExternalActivity` materials, the two ways
  project scoping accepts an activity. The teacher side, a teacher who is an item of a selected
  cohort, is each report's own join.

  Both subqueries are uncorrelated, so MySQL materializes each once. A correlated `EXISTS` would
  run once for every row the teacher side admits.
  """

  import ReportServer.Reports.ReportUtils, only: [list_to_in: 1]

  @doc "SQL that is true when the activity `activity_ref` names is admitted by one of `cohort_ids`."
  def activity_in_cohorts(activity_ref, cohort_ids) do
    ids = list_to_in(cohort_ids)

    "(#{activity_ref} IN (SELECT aci_cf.item_id FROM admin_cohort_items aci_cf " <>
      "WHERE aci_cf.item_type = 'ExternalActivity' AND aci_cf.admin_cohort_id IN #{ids}) " <>
      "OR #{activity_ref} IN (SELECT apm_cf.material_id FROM admin_project_materials apm_cf " <>
      "JOIN admin_cohorts ac_cf ON (ac_cf.project_id = apm_cf.project_id) " <>
      "WHERE apm_cf.material_type = 'ExternalActivity' AND ac_cf.id IN #{ids}))"
  end

  @doc """
  SQL that is true when the `admin_cohorts` row aliased `cohorts` admits one of `activity_ids`,
  the same rule as `activity_in_cohorts/2` read from the cohort's side.
  """
  def cohort_admits_activities(cohorts, activity_ids) do
    ids = list_to_in(activity_ids)

    "(#{cohorts}.id IN (SELECT aci_cf.admin_cohort_id FROM admin_cohort_items aci_cf " <>
      "WHERE aci_cf.item_type = 'ExternalActivity' AND aci_cf.item_id IN #{ids}) " <>
      "OR #{cohorts}.project_id IN (SELECT apm_cf.project_id FROM admin_project_materials apm_cf " <>
      "WHERE apm_cf.material_type = 'ExternalActivity' AND apm_cf.material_id IN #{ids}))"
  end
end
```

The `_cf` alias suffix keeps the subqueries' tables apart from every alias the callers already bind (`aci_teacher`, `aci_cohort`, `aci_teacher_a`, `apm_a`, `apm`, `ac`). The ids are the filter's integer lists, rendered by the same `list_to_in/1` every other filter clause uses.

`lib/report_server/reports/learner_base_query.ex`: add `CohortFilter` to the `ReportServer.Reports` alias list, and in `apply_filters/3`:

```elixir
    {join, where} = if have_filter?(cohort) do
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id)"
          | join
        ],
        [
          "aci_teacher.admin_cohort_id in #{list_to_in(cohort)}",
          CohortFilter.activity_in_cohorts("po.runnable_id", cohort)
          | where
        ]
      }
```

`test/support/portal_fixture.sql`, appended:

```sql
-- Cohort 6 holds teacher 31 and no activity, so project 900's materials are its only route to an
-- activity: 801 and 803 are admitted, and 802, which no project holds, is not.
INSERT INTO admin_cohorts VALUES (6,'Cohort Six',900);
INSERT INTO admin_cohort_items VALUES (9,6,'Portal::Teacher',31);
-- Rows of other types whose ids are activities' ids: cohort 2 does not hold activity 803, and
-- project 901 does not hold activity 802.
INSERT INTO admin_cohort_items VALUES (10,2,'Investigation',803);
INSERT INTO admin_project_materials VALUES (3,901,'Investigation',802);
```

With the decoy rows alone on today's code the suite stays at 1558 tests, 0 failures.

`test/report_server/reports/cohort_filter_db_test.exs` (`:portal_db`, `async: false`), in full apart from the Teacher Actions block step 3 adds:

```elixir
defmodule ReportServer.Reports.CohortFilterDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{CohortFilter, ReportFilter, ReportQuery}
  alias ReportServer.Reports.Athena.LearnerData
  alias ReportServer.Reports.Portal.StudentIdMappingReport

  @server PortalFixture.server()

  defp activities(cohort_ids) do
    sql = "SELECT ea.id FROM external_activities ea WHERE #{CohortFilter.activity_in_cohorts("ea.id", cohort_ids)} ORDER BY ea.id"
    {:ok, result} = PortalDbs.query(@server, sql)
    List.flatten(result.rows)
  end

  defp cohorts(activity_ids) do
    sql = "SELECT ac.id FROM admin_cohorts ac WHERE #{CohortFilter.cohort_admits_activities("ac", activity_ids)} ORDER BY ac.id"
    {:ok, result} = PortalDbs.query(@server, sql)
    List.flatten(result.rows)
  end

  test "a cohort admits its own activity items" do
    assert activities([3]) == [801]
  end

  test "a cohort admits its project's materials" do
    assert activities([6]) == [801, 803]
  end

  # Cohort 2's 803 and project 901's 802 are of other types, so neither counts.
  test "a cohort admits no activity that is neither its item nor its project's material" do
    assert activities([2]) == []
    assert activities([5]) == []
  end

  test "read from the cohort's side, the rule admits the same pairs" do
    assert cohorts([803]) == [1, 6]
    assert cohorts([801]) == [1, 3, 4, 6]
    assert cohorts([802]) == []
  end

  describe "the learner reports" do
    defp user(id, flags), do: struct(%User{portal_server: @server, portal_user_id: id}, flags)

    defp learner_ids(user, cohort_ids) do
      filter = %ReportFilter{filters: [:cohort], cohort: cohort_ids}
      {:ok, query} = StudentIdMappingReport.get_query(filter, user)
      {:ok, sql} = ReportQuery.get_sql(query)
      {:ok, result} = PortalDbs.query(@server, sql)
      result |> PortalDbs.map_columns_on_rows() |> Enum.map(& &1.learner_id) |> Enum.sort()
    end

    defp athena_learner_ids(user, cohort_ids) do
      filter = %ReportFilter{filters: [:cohort], cohort: cohort_ids}
      {:ok, groups} = LearnerData.fetch(filter, user, allow_empty: true)
      groups |> Enum.flat_map(& &1.learners) |> Enum.map(& &1.learner_id) |> Enum.sort()
    end

    # Teacher 31 also teaches learner 902, whose activity 802 no project holds, so 902 is absent.
    test "a cohort keeps learners on its project's materials, for every kind of caller" do
      admin = user(555, portal_is_project_admin: true)
      researcher = user(557, portal_is_project_researcher: true)
      site_admin = user(560, portal_is_admin: true)

      assert learner_ids(admin, [6]) == [901, 903, 904]
      assert learner_ids(researcher, [6]) == [901]
      assert learner_ids(site_admin, [6]) == [901, 903, 904]

      assert athena_learner_ids(admin, [6]) == [901, 903, 904]
      assert athena_learner_ids(researcher, [6]) == [901]
    end

    # Teacher 36 is in cohort 5 and teaches learners on 801, which project 904 does not hold.
    test "a cohort's teacher is not enough when the activity is neither its item nor its material" do
      assert learner_ids(user(560, portal_is_admin: true), [5]) == []
    end
  end
end
```

The researcher row (557, project 900) gets only 901 because REPORT-195's consent rule still applies: of teacher 31's learners on 801, only student 71 holds project 900's form 11.

`test/report_server/reports/learner_base_query_test.exs`: in both `{"cohort+school+dates", _}` expected strings, delete ` join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id)` and replace `(aci_assignment.admin_cohort_id in (1,2))` with:

```
((po.runnable_id IN (SELECT aci_cf.item_id FROM admin_cohort_items aci_cf WHERE aci_cf.item_type = 'ExternalActivity' AND aci_cf.admin_cohort_id IN (1,2)) OR po.runnable_id IN (SELECT apm_cf.material_id FROM admin_project_materials apm_cf JOIN admin_cohorts ac_cf ON (ac_cf.project_id = apm_cf.project_id) WHERE apm_cf.material_type = 'ExternalActivity' AND ac_cf.id IN (1,2))))
```

The two enumerations cohort 6 moves:
- `report_filter_query_db_test.exs` "scoping keeps another project's cohort out": `assert options(:cohort) == [{"1", "Cohort One"}, {"6", "Cohort Six"}]`. Project 901's cohort 2 is still out, which is what the test is for.
- `portal_fixture_test.exs` "the project scoping rows give one project admin a subset and another nothing": the last query becomes `SELECT DISTINCT aci.item_id ...`, since teacher 31 is now an item of two project-900 cohorts. The expected `[%{item_id: 31}, %{item_id: 35}]` stays.

---

### The filter options follow the same rule

**Summary**: The two option cascades that relate cohorts and assignments use `CohortFilter` (R3): assignments under a selected cohort, and cohorts under a selected assignment. Their join patterns become unused and are deleted.

**Files affected**:
- `lib/report_server/reports/report_filter_query.ex`: the two cascade configs, a `where` that may be a function, two wrappers, two join patterns removed.
- `test/report_server/reports/report_filter_query_db_test.exs`: the pinned assertion replaced, one test added.

**Estimated diff size**: ~35 lines

`lib/report_server/reports/report_filter_query.ex`:

- Add `CohortFilter` to the `ReportServer.Reports` alias list.
- Delete the `cohort_items_assignment` and `cohort_items_assignment_ref` entries of `@join_patterns`; nothing else reads them. The `from_assignment` entry of `DimensionScope`'s `@cohort_joins` stays, because the assignment scope uses it; `cohort_join(:from_assignment)` has no caller left.
- Under the comment above `@secondary_filter_config`, add: `# A where is a prefix that the selected ids' IN list completes, or a function of the selected ids`.
- `cohort.assignment` becomes `%{join: [], where: &ReportFilterQuery.cohort_admits_assignments/1}`, and `assignment.cohort` becomes `%{join: [], where: &ReportFilterQuery.assignment_in_cohorts/1}`. A remote capture of the module's own public function compiles in the attribute (built and run).
- In `apply_secondary_filters/5`, the `where` comes from a two-clause private helper, so the IN list (and its `DimensionScope.id_type/1` choice) is built only for a prefix:

  ```elixir
  defp secondary_where(where, _filter_name, filter_value) when is_function(where, 1), do: where.(filter_value)

  defp secondary_where(prefix, filter_name, filter_value) do
    in_clause = case DimensionScope.id_type(filter_name) do
      :string -> mysql_string_list_to_in(filter_value)
      :integer -> list_to_in(filter_value)
    end

    "#{prefix} #{in_clause}"
  end
  ```

- Beside `with_named_form_check/4`:

  ```elixir
  @doc false
  def assignment_in_cohorts(cohort_ids), do: CohortFilter.activity_in_cohorts(DimensionScope.id_expr(:assignment), cohort_ids)

  @doc false
  def cohort_admits_assignments(assignment_ids), do: CohortFilter.cohort_admits_activities(DimensionScope.from(:cohort), assignment_ids)
  ```

  `id_expr(:assignment)` is `external_activities.id` and `from(:cohort)` is `admin_cohorts`, the tables the two option queries select from, so the wrappers read the names from where they are defined rather than repeating them.

`test/report_server/reports/report_filter_query_db_test.exs`: replace "a scoped caller can narrow assignments by cohort" with:

```elixir
  test "a scoped caller can narrow assignments by cohort, to its items and its project's materials" do
    assert options(:assignment, %ReportFilter{cohort: [1]}) == [{"801", "Activity One"}, {"803", "Activity Three"}]
    assert options(:assignment, %ReportFilter{cohort: [6]}) == [{"801", "Activity One"}, {"803", "Activity Three"}]
    assert options(:assignment, %ReportFilter{cohort: [3]}) == [{"801", "Activity One"}]
  end

  test "a materials-only assignment leaves the cohorts of its project selectable" do
    assert options(:cohort, %ReportFilter{assignment: [803]}) == [{"1", "Cohort One"}, {"6", "Cohort Six"}]
    assert options(:cohort, %ReportFilter{assignment: [802]}) == []
  end
```

801 and 803 are every assignment this caller (`@allowed`, project 900) sees, and cohorts 1 and 6 every cohort, so only the cohort 3 and 802 assertions fail when a cascade ignores the selected ids.

The existing "narrowing one dimension by another generates legal SQL" test already runs every cascade, these two included, against the fixture. The filter-option API and the report form both go through `ReportFilterQuery`, so neither needs its own change.

---

### Teacher Status, the resource metrics reports and Teacher Actions use the rule

**Summary**: The last four cohort clauses switch to `CohortFilter` (R2's second and third bullets, R4). Teacher Actions is tested on the fixture, which gains `report_learners.runnable_id`; the three portal reports select columns the fixture lacks, so they are tested by their SQL.

**Files affected**:
- `lib/report_server/reports/portal/teacher_status_report.ex`, `resource_metrics_summary_report.ex`, `resource_metrics_details_report.ex`: the cohort clause.
- `lib/report_server/reports/athena/teacher_actions_report.ex`: `get_activities/2`'s cohort clause.
- `test/support/portal_fixture.sql`: `report_learners.runnable_id`.
- `test/report_server/reports/portal/cohort_filter_reports_test.exs`: new.
- `test/report_server/reports/cohort_filter_db_test.exs`: the Teacher Actions block.

**Estimated diff size**: ~70 lines

In each of the three portal reports, add `alias ReportServer.Reports.CohortFilter` under the `use` line, and in `apply_filters/3`:

```elixir
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' and aci_teacher.item_id = pt.id)"
          | join
        ],
        [
          "aci_teacher.admin_cohort_id in #{list_to_in(cohort)}",
          CohortFilter.activity_in_cohorts("ea.id", cohort)
          | where
        ]
```

Teacher Status's old WHERE also repeated `aci_assignment.item_id = ea.id`; it goes with the join it restated.

`teacher_actions_report.ex`: add `alias ReportServer.Reports.CohortFilter`, and in `get_activities/2` drop the `left join admin_cohort_items aci_assignment ...` entry and replace `"aci_assignment.admin_cohort_id in #{list_to_in(cohort)} and aci_assignment.item_id = po.runnable_id"` with `CohortFilter.activity_in_cohorts("po.runnable_id", cohort)`. Its `aci_teacher` LEFT join and `get_usernames/2` are unchanged.

`test/support/portal_fixture.sql`: the `report_learners` column line becomes `learner_id INT, student_id INT, user_id INT, offering_id INT, class_id INT, runnable_id INT NULL,`. `get_activities/2` joins `rl.runnable_id`; every insert names its columns, so no other line changes, and the full suite stays green with it.

`test/report_server/reports/portal/cohort_filter_reports_test.exs`:

```elixir
defmodule ReportServer.Reports.Portal.CohortFilterReportsTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{CohortFilter, ReportFilter, ReportQuery}
  alias ReportServer.Reports.Portal.{ResourceMetricsDetailsReport, ResourceMetricsSummaryReport, TeacherStatusReport}

  # These reports select columns the portal fixture does not carry, so they are checked by their SQL;
  # the rule itself runs against the fixture in CohortFilterDbTest. A site admin needs no portal read.
  @site_admin %User{portal_server: "portal.example.com", portal_is_admin: true}

  for report <- [TeacherStatusReport, ResourceMetricsSummaryReport, ResourceMetricsDetailsReport] do
    test "#{inspect(report)} admits a cohort's activities through the shared rule" do
      filter = %ReportFilter{filters: [:cohort], cohort: [6], exclude_internal: false}
      {:ok, query} = unquote(report).get_query(filter, @site_admin)
      {:ok, sql} = ReportQuery.get_sql(query)

      assert sql =~ CohortFilter.activity_in_cohorts("ea.id", [6])
      refute sql =~ "aci_assignment"
    end
  end
end
```

`cohort_filter_db_test.exs`: add `TeacherActionsReport` to the Athena alias (`alias ReportServer.Reports.Athena.{LearnerData, TeacherActionsReport}`) and this block. `ReportQuery.get_log_db_name/0` reads `:athena` config that `config/test.exs` does not set, so the block sets it the way `recent_logs_controller_test.exs` does and restores it.

```elixir
  describe "Teacher Actions" do
    setup do
      original = Application.get_env(:report_server, :athena)
      Application.put_env(:report_server, :athena, log_db_name: "log_ingester_qa")

      on_exit(fn ->
        if original, do: Application.put_env(:report_server, :athena, original), else: Application.delete_env(:report_server, :athena)
      end)
    end

    # Teacher 31's classes have offerings of 801 and 802; cohort 6 admits 801, through project
    # 900's materials, and not 802.
    test "the activity list admits a cohort's project's materials" do
      site_admin = %User{portal_server: @server, portal_user_id: 560, portal_is_admin: true}
      filter = %ReportFilter{filters: [:cohort], cohort: [6]}

      assert {:ok, %ReportQuery{where: where}} = TeacherActionsReport.get_query(filter, site_admin)
      assert "log.activity IN ('https://activity.example.org/a?answersSourceKey=src.example.org')" in where
    end
  end
```

Under today's rule cohort 6 admits no activity, so the query carries only the `log.username` clause and the assertion fails.

---

### Document what a cohort filter keeps

**Summary**: R8. One paragraph in the README's "Who sees which students", after the teacher-level reports paragraph.

**Files affected**:
- `README.md` (the server's): one paragraph.

**Estimated diff size**: ~5 lines

```markdown
A cohort filter keeps the learners whose teacher is in one of the selected cohorts and whose
assignment is either an item of one of those cohorts or on the materials list of one of their
projects. It applies within what the rules above let the caller see, so it never adds a student
they could not see without it.
```

## Release notes

For the 1.13.1 notes, which REPORT-195 shares: "Filtering a report by cohort now includes learners on activities that are on the cohort's project's materials list, not only those that are items of the cohort. Portal reports pick this up the next time they are opened. An Athena report filtered by cohort before 1.13.1 may be missing learners; duplicate it to get the full set. Its bulk, attachments and CLUE exports already include them, so until it is duplicated they may hold learners its CSV does not. A Teacher Actions run filtered by a cohort that holds no activities of its own may have held the cohort's teachers' events on every activity; a duplicate holds only the activities on the cohort's project's materials, unless the teachers assigned none of them."

## Open Questions

### RESOLVED: Judgment call: a function-valued `where` in the cascade config, or a special case in `apply_secondary_filters/5`?
**Context**: Every cascade `where` today is a prefix the IN list completes; the two cohort/assignment cascades need a whole predicate built from the ids.
**Options considered**:
- A) Let a config `where` be a 1-arity function of the selected ids, as a remote capture.
- B) Match the two `{primary, secondary}` pairs by name in `apply_secondary_filters/5`.

**Decision**: A. The config stays the one place that says how each pair narrows, and the function branch is one line. B would put two pairs' rules outside the table that holds every other pair's.

### RESOLVED: Judgment call: one commit or four?
**Context**: The rule, the learner query, the options and the teacher-level reports could ship as one ~260-line commit.
**Options considered**:
- A) Four: the rule with its first user, the options, the remaining reports, the README.
- B) One commit.

**Decision**: A. Each step is green on its own, and the reviewer sees the rule's tests before the call sites that depend on them.

## Self-Review

Roles: Commit Reviewer, Test Writer, Senior Engineer, Security Engineer, Operator. Each finding was checked by building the plan as throwaway code and is fixed in place.

### Commit Reviewer

#### RESOLVED: only the first and last states had been run
The plan claimed every step green, but the suite had been run only after step 1 and after all four. Steps 1 and 2 were rebuilt without step 3's files and run green. The opening line gives the counts per state.

### Test Writer

#### RESOLVED: a test title claimed something it cannot catch
"two cohorts admit the union of their activities, each once": the rule is a WHERE condition, which cannot add a row, so the "each once" half could not fail. What the test does pin is that two selected cohorts' admitted sets combine (801 through cohort 1's item and cohort 6's materials, 803 through materials). Retitled to say that; R5 is met by construction, and requirements.md says so.

#### RESOLVED: each change's test, by mutation
Reverting each call site alone fails exactly its own tests: `LearnerBaseQuery` (the snapshot and the learner test), Teacher Actions (its fixture test), each of the three portal reports (its SQL test), and each option cascade replaced with an item-only rule (its option test). In `CohortFilter` (both functions at once), dropping the materials branch fails 7 tests, dropping the items branch fails 4, and admitting every activity fails 10, including both learner negatives. Dropping the `item_type` or `material_type` check from either function fails a predicate test.


### Self-review round 1

#### QA Engineer

##### RESOLVED: the option tests could not catch a cascade that ignores the selection
The caller's scope is project 900, whose assignments are exactly 801 and 803 and whose cohorts are exactly 1 and 6, so every option assertion held with both wrappers returning `1 = 1` (run: 0 failures). Added assignments under cohort 3 (only 801) and cohorts under 802 (none); with the same mutation both tests fail.

##### RESOLVED: no DB test checked `item_type` or `material_type`
Dropping either check from `activity_in_cohorts/2` failed only the SQL snapshot, and from `cohort_admits_activities/2` failed nothing. Step 1's fixture gains an `Investigation` item 803 in cohort 2 and an `Investigation` material 802 of project 901; each of the four mutations now fails a predicate test, and the full plan stays green.

##### RESOLVED: the mutation counts were measured before these tests
Re-measured on the full suite with the changes above; Test Writer's entry carries the new counts.

#### Senior Engineer

##### RESOLVED: step 2 said `cohort_join(:from_assignment)` stays because the scope uses it
The scope reads `@cohort_joins.from_assignment` directly; after this step `cohort_join/1` is called only for `:from_teacher` and `:from_school_member`. Reworded.

### Self-review round 2

Built step by step from this text on REPORT-195's branch: 1564, 1565 and 1569 tests, 0 failures each, `--warnings-as-errors` clean.

#### Test Writer

##### RESOLVED: "two selected cohorts admit the union of their activities" could not catch what it names
Cohorts 1 and 6 each admit exactly 801 and 803 alone, so the test passed with `activity_in_cohorts/2` reading only the first or only the last selected cohort (run: only the SQL snapshot failed), and every other mutation it failed was already caught by `activities([6])`. Deleted with the `No DISTINCT` comment, which no WHERE predicate can make true; counts and Test Writer's mutation counts re-measured.

#### Operator

##### RESOLVED: the release notes told users to re-run Portal reports and said only that rows were missing
Portal runs are computed on every read, so only Athena runs need a duplicate; and on today's code a Teacher Actions run under a materials-only cohort carries no `log.activity` clause (run on the fixture), so the fix narrows it. The release note now says both.


### Self-review round 3

Built from this text on REPORT-195's branch: 1569 tests, 0 failures; the `CohortFilter` mutation counts in Test Writer's entry (7, 4 and 10) re-measured and unchanged.

#### Operator

##### RESOLVED: the release note overstated what a Teacher Actions duplicate holds, and missed the exports
A duplicate still holds every activity when the cohort's teachers assigned none it admits (`cohort: [5]` with the fix, run on the fixture), and an old Athena run's exports re-read learners live (`EndpointSet.fetch_learners`). The release note now says both; see requirements.md.

#### Spec Editor

##### RESOLVED: two earlier entries carried superseded test counts
The first Commit Reviewer entry said 1566 and round 1's QA entry 1570, against the opening line's 1565 and 1569. Both now defer to the opening line.
