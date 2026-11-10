# Implementation Plan: Project researchers see only their project's permission-form students

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-195
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

All paths are under `server/`. No dependency or lockfile changes. Every step compiles and passes `mix test` on its own; the PR lands as a whole, so the intermediate state after the split lookup (a mixed admin and researcher user sees their researcher project's students by the admin rule until the learner step) never deploys.

Test command, per the repo's convention (dummy env vars, docker MySQL up for the `:portal_db` tests):

```shell
SERVER_ACCESS_KEY_ID=test SERVER_SECRET_ACCESS_KEY=test REPORT_SERVICE_TOKEN=test HIDE_USERNAME_HASH_SALT=test mix test
```

### Expired researcher rows grant nothing

**Summary**: R1. One module attribute holds the live-researcher condition, and both the `is_project_researcher` role flag and the researcher project lookup use it.

**Files affected**:
- `lib/report_server/portal_dbs.ex`: the attribute, `@role_flags`, `get_project_ids/3`
- `test/support/portal_fixture.sql`: `expiration_date` column and three expiry rows
- `test/report_server/portal_dbs_catalog_test.exs`: flag and lookup tests

**Estimated diff size**: ~60 lines

```elixir
# rigse's User#_project_user_researchers: a row expiring today is already expired
@live_researcher "apu.is_researcher = 1 AND (apu.expiration_date IS NULL OR apu.expiration_date > CURDATE())"

@role_flags """
...
EXISTS (
  SELECT 1
  FROM admin_project_users apu
  WHERE #{@live_researcher} AND apu.user_id = u.id
) AS is_project_researcher
"""
```

`get_project_ids/3` stops interpolating a column name and takes the whole condition: `get_project_ids(user, "apu.is_admin = 1", options)` and `get_project_ids(user, @live_researcher, options)`, over `FROM admin_project_users apu`. The next step replaces it, so it stays a minimal change here.

Fixture: `admin_project_users` gains `expiration_date DATE NULL`; the existing two rows get `NULL`; new rows `(6,900,564,0,1,DATE_SUB(CURDATE(), INTERVAL 1 DAY))`, `(7,900,565,0,1,CURDATE())`, `(8,900,566,0,1,DATE_ADD(CURDATE(), INTERVAL 1 DAY))`. Relative dates keep the rows meaning the same thing on every run. Users 564 to 566 need no `users` row for the lookup; the flag tests read `@role_flags` through `get_user_roles/3`, which selects `FROM users u WHERE u.id = ?`, so the three users get `users` rows (logins `res.expired`, `res.today`, `res.tomorrow`).

Tests (`portal_dbs_catalog_test.exs`):
- `get_user_roles/3`: 564 and 565 are `is_project_researcher: false`, 566 and 557 (null expiration) are `true`.
- `get_allowed_project_ids/2` for a `%User{portal_is_project_researcher: true}` with each id: 564 and 565 get `[]`, 566 and 557 get `[900]`. (The next step turns `[]` into `:none`; the test changes with it.)

---

### One lookup returns the admin and researcher lists

**Summary**: R2, R3. A struct carries both lists from one query; every consumer that is not student-scoped scopes by their union, and the empty-list shape disappears.

**Files affected**:
- `lib/report_server/reports/allowed_projects.ex` (new): the struct and `ids/1`
- `lib/report_server/portal_dbs.ex`: `get_allowed_project_ids/2`, the roles query, `get_project_ids/3` removed
- `lib/report_server/reports/report_utils.ex`: `scope_by_allowed_projects/5` takes the struct, the `[]` clause goes
- `lib/report_server/reports/dimension_scope.ex`: `restrict/2` takes the struct, the `[]` clause goes, the doc updated
- `lib/report_server_web/api/v1/endpoint_set.ex`: the `[]` branch goes; the `:none` comment stops calling it unreachable
- `lib/report_server/packages.ex`: `portal_allowed_project_ids/1` flattens the struct
- `test/support/portal_fixture.sql`, `test/report_server/portal_fixture_test.exs`: project 902 rows
- Tests that build allowed lists: `report_utils_test.exs`, `dimension_scope_test.exs`, `report_filter_query_test.exs`, `report_filter_query_db_test.exs`, `bulk_export_controller_test.exs`, `clue_export_controller_test.exs`, `attachment_controller_test.exs`, `package_controller_create_test.exs`, `package_controller_state_test.exs`, `package_controller_read_test.exs`, `package_controller_validate_test.exs`, `portal_dbs_catalog_test.exs`

**Estimated diff size**: ~250 lines, most of it test call sites

```elixir
defmodule ReportServer.Reports.AllowedProjects do
  @moduledoc """
  The projects a portal user holds a live project role on: `admin`, the projects they administer,
  and `researcher`, the ones they research and do not also administer. At least one list is
  non-empty; `PortalDbs.get_allowed_project_ids/2` answers `:none` for a user with neither.

  A project admin sees a project's students through its cohort classes; a project researcher sees
  only those of them holding one of that project's permission forms, as rigse's
  `Report::LearnerPolicy` does. Scopes that reach no students use `ids/1`.
  """
  @enforce_keys [:admin, :researcher]
  defstruct [:admin, :researcher]

  def ids(%__MODULE__{admin: admin, researcher: researcher}), do: admin ++ researcher
end
```

`PortalDbs`:

```elixir
@project_roles """
SELECT apu.project_id, MAX(COALESCE(apu.is_admin, 0) = 1) AS is_admin, MAX(#{@live_researcher}) AS is_researcher
FROM admin_project_users apu
WHERE apu.user_id = ?
GROUP BY apu.project_id
"""

def get_allowed_project_ids(user = %User{}, options \\ []) do
  cond do
    user.portal_is_admin -> :all
    user.portal_is_project_admin || user.portal_is_project_researcher -> get_allowed_projects(user, options)
    true -> :none
  end
end

defp get_allowed_projects(user = %User{}, options) do
  case query(user.portal_server, @project_roles, [user.portal_user_id], options) do
    {:ok, %{rows: rows}} -> to_allowed_projects(rows)
    error -> error
  end
end

defp to_allowed_projects(rows) do
  admin = for [id, 1, _] <- rows, do: id
  researcher = for [id, 0, 1] <- rows, do: id

  if admin == [] and researcher == [] do
    :none
  else
    %AllowedProjects{admin: admin, researcher: researcher}
  end
end
```

MyXQL returns each `MAX(<boolean>)` as the integer 0 or 1 (checked against the fixture: user 562 gives `[[900, 1, 0], [902, 0, 1]]`, an expired row `[[900, 0, 0]]`, an unknown user `[]`). `is_admin` is a nullable column in rigse (default false), and a bare `MAX(apu.is_admin = 1)` is NULL for a NULL row, which neither pattern matches, so the `COALESCE` keeps a researcher row whose `is_admin` is NULL, as rigse's `is_researcher` scope and the role flag do. A NULL `is_researcher` gives NULL there and grants nothing, as intended. The stored flags still gate the query, so a user whose stored flags are all false is `:none` without a portal call, as today.

Consumers:
- `ReportUtils.scope_by_allowed_projects/5`: the list clause becomes `%AllowedProjects{} = allowed`, rendering `list_to_in(AllowedProjects.ids(allowed))` where it rendered the list. The `[]` clause is deleted; the `:none` clause keeps `1 = 0`, and its comment drops the empty-list wording.
- `DimensionScope.restrict/2`: the same, with `project_predicate(config.where, AllowedProjects.ids(allowed))`. The `scope/2` doc drops "An empty list".
- `EndpointSet.fetch_learners/2`: the `[] -> {:ok, []}` branch is deleted. The `:none` branch's comment becomes true: a researcher whose stored flag is still set but whose rows have all expired reaches it.
- `Packages.portal_allowed_project_ids/1`: `%AllowedProjects{} = allowed -> {:ok, AllowedProjects.ids(allowed)}` replaces the `is_list(ids)` guard, which the lookup can no longer satisfy; `:all`/`:none` still pass through. `administers?/3` and `project_allowed?/2` keep taking a list.
- `FilterOptions`, `ReportFilter`, `ReportFilterQuery` and `report_live/form.ex` pass the value through untouched.

Fixture additions (verified not to disturb any existing test except the learner-count assertion in `portal_fixture_test.exs`, which grows to seven learners and three classes): project 902 `Proj C`; cohort 3 (902) holding teacher 36 (user 136) and activity 801; class 604 taught by 36; students 76, 77, 78 (users 106 to 108) in 604, with learners 905 to 907 on offering 704 (activity 801, class 604) and their `report_learners` rows; form 15 (`Form C`, 902) signed by 76, and form 12 (901) signed by 77; `admin_project_users` rows for 562 (admin of 900, researcher on 902) and 563 (researcher on 902).

Test call sites: a list `[p]` becomes `%AllowedProjects{admin: [p], researcher: []}`, through a local `admin(ids)` helper in each file that has more than two. `allowed: []` in the bulk and CLUE export tests becomes `allowed: :none`, which keeps the "no fetch, empty page" assertion on the branch that remains. `report_utils_test.exs` loses its empty-list test and `report_filter_query_test.exs` its "an empty allowed-projects list behaves as :none does", since that shape no longer exists; the latter file's other `[]` arguments become `:none`, and `dimension_scope_test.exs`'s "an empty list restricts to nothing" keeps only its `:none` assertion.

New tests (`portal_dbs_catalog_test.exs`, replacing the previous step's lookup assertions):
- 555 is `admin: [900], researcher: []`; 557 is `admin: [], researcher: [900]`; 562 is `admin: [900], researcher: [902]`, which the stored-flag `cond` gave as `[900]` alone; 564 and 565 are `:none`; 566 is `researcher: [900]`.
- A user with both roles on one project is in `admin` only: covered by a fixture row `(9,900,567,1,1,NULL)` and the assertion `admin: [900], researcher: []`.
- A site admin who also holds a researcher row is `:all`: fixture user 570 (a site admin through `roles_users` `(1,570)`) with row `(16,900,570,0,1,NULL)`, looked up as `%User{portal_is_admin: true, portal_is_project_researcher: true}`, gets `:all` (fails if the `cond` tests the researcher flag first); `learner_scoping_db_test.exs` gives 570 every fixture learner (901 to 907), including 903 and 904, which hold no project 900 form. A new user rather than 560, whose `get_user_roles/3` assertion expects no researcher flag.
- A researcher row with a NULL `is_admin` still counts: fixture row `(13,901,568,NULL,1,NULL)` and the assertion `admin: [], researcher: [901]` (fails without the `COALESCE`).

---

### Learner scoping applies the permission-form rule to researcher projects

**Summary**: R4. `LearnerBaseQuery`'s project scoping admits a researcher project's learner only when the student holds that project's form.

**Files affected**:
- `lib/report_server/reports/allowed_projects.ex`: `predicate/3`, `consent_exists/2`
- `lib/report_server/reports/report_utils.ex`: `scope_by_allowed_projects/6` takes an optional student ref
- `lib/report_server/reports/learner_base_query.ex`: calls `scope_by_allowed_projects/6` with `"rl.student_id"`
- `test/support/portal_fixture.sql`: a two-project researcher
- `test/report_server/reports/report_utils_test.exs`, new `test/report_server/reports/learner_scoping_db_test.exs`
- `test/report_server/reports/portal/student_id_mapping_report_db_test.exs`: its "a project researcher is scoped by their project, like a project admin" asserts `researcher == project_admin`, the contract this step reverses; it becomes "a project researcher sees a strict subset of the project admin's learners" (`[901]` against `[901, 903, 904]`)

**Estimated diff size**: ~170 lines

```elixir
@doc """
The predicate restricting `project_col` to these projects. `consent` is a condition that holds
when a student the row reaches has a permission form of `project_col`'s project; it applies to
the researcher projects only. Without it both lists take the admin rule.
"""
def predicate(allowed, project_col, consent \\ nil)

def predicate(allowed = %__MODULE__{}, project_col, nil), do: in_clause(project_col, ids(allowed))
def predicate(allowed = %__MODULE__{researcher: []}, project_col, _consent), do: in_clause(project_col, ids(allowed))

def predicate(%__MODULE__{admin: admin, researcher: researcher}, project_col, consent) do
  [{admin, nil}, {researcher, consent}]
  |> Enum.reject(fn {ids, _} -> ids == [] end)
  |> Enum.map_join(" OR ", fn
    {ids, nil} -> "(#{in_clause(project_col, ids)})"
    {ids, condition} -> "(#{in_clause(project_col, ids)} AND #{condition})"
  end)
end

@doc "Whether the student `student_ref` holds a permission form of the project `project_col`."
def consent_exists(student_ref, project_col) do
  "EXISTS (SELECT 1 FROM portal_student_permission_forms pspf_r " <>
    "JOIN portal_permission_forms ppf_r ON (ppf_r.id = pspf_r.portal_permission_form_id) " <>
    "WHERE pspf_r.portal_student_id = #{student_ref} AND ppf_r.project_id = #{project_col})"
end

# an empty list never reaches here: predicate/3 drops it, and the struct always has one non-empty list
defp in_clause(column, ids), do: "#{column} IN (#{Enum.map_join(ids, ",", &Integer.to_string/1)})"
```

An admin-only struct renders the bare `IN` whatever `consent` is, so an admin-only caller's learner and option SQL is byte-identical to the previous step's; `report_filter_query_test.exs`'s golden option SQL pins it. `AllowedProjects` renders its own `IN` list rather than importing `ReportUtils.list_to_in/1`, because `ReportUtils` calls into `AllowedProjects` and a two-way import is a compile-time cycle. The `_r` aliases are unused anywhere in `lib/report_server/reports/`, so the subquery cannot capture an outer alias.

`ReportUtils`:

```elixir
# a bodiless head: Elixir allows only variables and defaults in it, and it must precede the clauses
def scope_by_allowed_projects(allowed, join, where, assignment_id_ref, teacher_id_ref, student_id_ref \\ nil)
```

`apply_allowed_project_ids_filter/5` stays as it is, for Teacher Status and Resource Metrics. `LearnerBaseQuery.apply_filters/2` stops calling it and pipes `PortalDbs.get_allowed_project_ids(user)` into `scope_by_allowed_projects(join, where, "po.runnable_id", "ptc.teacher_id", "rl.student_id")` itself, which is the shape the form-names step then feeds from its `allowed:` option; so no caller ever passes `apply_allowed_project_ids_filter` a student ref.

The assignment predicate keeps the union (`AllowedProjects.ids/1`); the teacher predicate becomes `AllowedProjects.predicate(allowed, "ac_teacher_a.project_id", consent)`, with `consent = student_id_ref && AllowedProjects.consent_exists(student_id_ref, "ac_teacher_a.project_id")`. With no student ref (Teacher Status, Resource Metrics) the SQL is byte-identical to the previous step's. The `:all`, `:none`, `{:error, _}` and `%AllowedProjects{}` clauses each take the sixth argument (the default lives only in the head) and are otherwise unchanged.

The `EXISTS` is correlated on the row's own cohort join, so it adds no rows and `LearnerBaseQuery.group_by/0` stays correct.

Tests:
- `report_utils_test.exs`: an admin-only struct with a student ref renders the same SQL as with none; a researcher-only struct renders it and no `IN ()`; a mixed struct renders both branches joined by `OR`; no student ref renders no `EXISTS` for a researcher struct.
- `learner_scoping_db_test.exs` (`:portal_db`), running `StudentIdMappingReport.get_query/2` for classes 601, 602 and 604 as `%User{}` structs with the stored flags set, through the real lookup. Expected learner ids, all checked against the fixture with the final SQL:
  - 557 (researcher on 900): `[901]`. 903 and 904 are in 900's cohort classes without 900's form.
  - 555 (admin of 900): `[901, 903, 904]`.
  - 563 (researcher on 902): `[905]`. 906's student holds only project 901's form; 907's holds none.
  - 562 (admin of 900, researcher on 902): `[901, 903, 904, 905]`.
  - 564 (expired researcher on 900): `[]`; 566 (expires tomorrow): `[901]`.
  - 569 (researcher on 900 and 902): `[901, 905]`. Fixture rows `admin_project_users` `(14,900,569,0,1,NULL)`, `(15,902,569,0,1,NULL)` and `portal_student_permission_forms` `(13,78,11)`: student 78 is in 902's class 604 and holds only 900's form, so 907 is out under the same-project rule and in under a check against the whole researcher list (checked on the fixture: `[901, 905]` against `[901, 905, 907]`). The row changes no other expectation in this plan: 557, 563 and 562 keep the learners above, and the `student` and `permission_form` scopes keep the ids the next step lists.
  - one Athena-path assertion: `LearnerData.fetch(filter, user, allow_empty: true)` for 557 yields learner 901 alone, so the change is shown to reach both consumers of `LearnerBaseQuery.build/4`.

---

### Filter options and label resolution apply the same rule

**Summary**: R5. The `student` and `permission_form` scopes in `DimensionScope` take the researcher condition; `class` and the other scoped dimensions keep the union.

**Files affected**:
- `lib/report_server/reports/dimension_scope.ex`: a `consent` entry on two scopes, `restrict/2`
- `test/report_server/reports/dimension_scope_test.exs`, `test/report_server/reports/report_filter_values_test.exs`
- `test/report_server/reports/filter_options_test.exs` and `test/report_server_web/api/v1/filter_options_controller_test.exs`: the hide-names tests that list researcher 557's student labels as `["101", "102", "103", "104"]` expect `["101"]`, the one student holding project 900's form
- The recent-logs tests and the README's "Recent logs for a class" paragraph are unchanged: the class gate reads the `class` scope, which keeps its cohort rule, so researcher 557's class 2 (a cohort class with no students) still answers an empty list

**Estimated diff size**: ~120 lines

```elixir
student: %{join: [...], project: "ac.project_id",
  consent: AllowedProjects.consent_exists("ps.id", "ac.project_id")},
permission_form: %{join: [...], project: "ac.project_id",
  consent: "ppf.project_id = ac.project_id"},
```

`@scopes` is a module attribute, so `consent_exists/2` runs at compile time; `AllowedProjects` is compiled first because of the call, with no cycle since it does not depend on `DimensionScope`.

`restrict/2` for a struct matches `%{project: column, consent: consent}` first and renders `AllowedProjects.predicate(allowed, column, consent)`; every other config keeps `project_predicate(config.where, AllowedProjects.ids(allowed))`. The two consent configs carry `project:` in place of `where:`, so their column has one spelling and no `"ac.project_id IN"` string is parsed. `ReportFilterQuery.apply_scope/3`'s `{join, [where]}` match already takes one predicate string, so the option queries need no change, and neither does `ReportFilter.value_select/3`.

For `permission_form`, the scope's joins already tie the form to a signing student in a cohort class of `ac`'s project, so requiring the form to be that project's own is the whole consent condition: the signer is then a student the researcher sees.

Tests:
- `dimension_scope_test.exs`: for `researcher: [900]`, `student` gives `[71]` and `permission_form` `[11]`; for `admin: [900]` they give today's `[71, 72, 73, 74]` and `[11, 12, 13]` (checked against the fixture). For `admin: [900], researcher: [902]`, `student` adds 76 and not 77 or 78. For `researcher: [900, 902]`, `student` gives `[71, 76]` and not 78, whose only form is 900's while its class reaches the project list only through 902 (fails if the consent compares against the list rather than `ac.project_id`). `class` and the four other scoped dimensions return the same ids for `researcher: [900]` as for `admin: [900]` (for `class`, today's nine classes, which fails if `class` gains the consent condition).
- `report_filter_values_test.exs`: a researcher on 900 naming student 73 gets `{:error, :out_of_scope, _}`, and naming 71 resolves.

---

### A researcher sees only their projects' form names

**Summary**: R10. For a caller with a researcher project, a learner whose class is not reached through one of their admin projects gets the Student Metadata `permission_forms` column and the Athena `permission_forms` list cut to the caller's projects' forms; learners of admin-project classes, and every caller without a researcher project, are unchanged. The allowed-projects result is looked up once per run and passed to both the scoping and the column. The admin-class check defined here is the one the CLUE and name steps reuse.

**Files affected**:
- `lib/report_server/reports/allowed_projects.ex`: `researcher?/1`, `admin_class_sql/2`, `form_project_ids/1`, `form_names_sql/1`
- `lib/report_server/reports/learner_base_query.ex`: an `allowed:` option on `build/4`
- `lib/report_server/reports/portal/student_metadata_report.ex`: the `permission_forms` column
- `lib/report_server/reports/athena/learner_data.ex`: `fetch/3` looks up once, `build_query/3` takes it; `get_permission_form_map/3` filters by project
- `test/support/portal_fixture.sql`: student 76 also holds form 12, listed first
- `test/report_server/reports/allowed_projects_db_test.exs` (new), `test/report_server/reports/portal/student_metadata_report_db_test.exs`, `test/report_server/reports/athena/learner_data_portal_test.exs`

**Estimated diff size**: ~200 lines, about 70 of them code

```elixir
@doc "Whether the caller holds a researcher project, which narrows what consent-bound outputs show."
def researcher?(%__MODULE__{researcher: [_ | _]}), do: true
def researcher?(_allowed), do: false

@doc """
The condition that a row's class is reached through one of the caller's admin projects, the
portal's `User#is_project_admin_for_clazz?`: the class (`:class`, over `rl.class_id`) has a teacher
in a cohort of an admin project. `nil` for a caller with no researcher project, whose every row is
treated alike.
"""
def admin_class_sql(allowed, by) do
  if researcher?(allowed), do: admin_class_exists(allowed.admin, by), else: nil
end

defp admin_class_exists([], _by), do: "FALSE"

defp admin_class_exists(admin_ids, :class),
  do: "EXISTS (SELECT 1 FROM portal_teacher_clazzes ptc_n #{@admin_cohort_joins} " <>
        "WHERE ptc_n.clazz_id = rl.class_id AND #{in_clause("ac_n.project_id", admin_ids)})"

@doc "The projects whose forms a narrowed row may name: `:all` for a caller with no researcher project."
def form_project_ids(allowed), do: if(researcher?(allowed), do: ids(allowed), else: :all)

@doc """
The `permission_forms` column for this caller. Unnarrowed rows read `rl.permission_forms`; a
narrowed row (not in an admin-project class) keeps only the forms of `form_project_ids/1`, in the
portal's stored text and order. The portal writes `permission_forms` and `permission_forms_id` as
parallel comma lists with commas inside names replaced, so a position in one is the same form in
the other; lists of different lengths give NULL rather than a misaligned name.
"""
def form_names_sql(allowed) do
  case {form_project_ids(allowed), admin_class_sql(allowed, :class)} do
    {:all, _} -> "rl.permission_forms"
    {ids, "FALSE"} -> narrowed_form_names(ids)
    {ids, admin_class} -> "CASE WHEN #{admin_class} THEN rl.permission_forms ELSE #{narrowed_form_names(ids)} END"
  end
end

defp narrowed_form_names(project_ids) do
  """
  (SELECT GROUP_CONCAT(SUBSTRING_INDEX(SUBSTRING_INDEX(rl.permission_forms, ',', jt.pos), ',', -1)
                       ORDER BY jt.pos SEPARATOR ',')
     FROM JSON_TABLE(CONCAT('[', COALESCE(rl.permission_forms_id, ''), ']'),
                     '$[*]' COLUMNS (pos FOR ORDINALITY, fid INT PATH '$')) jt
     JOIN portal_permission_forms ppf_v ON (ppf_v.id = jt.fid)
    WHERE #{in_clause("ppf_v.project_id", project_ids)}
      AND #{comma_count("rl.permission_forms")} = #{comma_count("rl.permission_forms_id")})
  """
  |> String.replace(~r/\s+/, " ")
  |> String.trim()
end

defp comma_count(col), do: "CHAR_LENGTH(#{col}) - CHAR_LENGTH(REPLACE(#{col}, ',', ''))"
```

`@admin_cohort_joins` is `JOIN admin_cohort_items aci_n ON (aci_n.item_type = 'Portal::Teacher' AND aci_n.item_id = ptc_n.teacher_id) JOIN admin_cohorts ac_n ON (ac_n.id = aci_n.admin_cohort_id)`. A researcher-only caller has `admin: []`, so the check is `FALSE` and the column is the narrowed expression alone, with no `CASE`. The `_n` and `ppf_v` aliases are unused elsewhere in `lib/report_server/reports/`.

Checked on the fixture: learner 901 (`Proj A: Form 1,Proj B: Form 2`, ids `11,12`) gives `Proj A: Form 1` for project 900 and `Proj B: Form 2` for 901; learners with no forms give NULL; a three-id, two-name pair gives NULL. The subquery reads only the learner's own short lists and the small forms table, by primary key.

`LearnerBaseQuery.build/4` takes `allowed:` and falls back to the lookup, and `apply_filters` scopes with `scope_by_allowed_projects(allowed, ...)` instead of calling the lookup itself:

```elixir
allowed = Keyword.get_lazy(opts, :allowed, fn -> PortalDbs.get_allowed_project_ids(user) end)
```

`StudentMetadataReport.get_query/2` looks up `allowed` once, passes it to `build/4`, and selects `{AllowedProjects.form_names_sql(allowed), "permission_forms"}`. An `{:error, _}` lookup maps to `:all` in the column, and the scoping's error clause fails the query as today.

`LearnerData.fetch/3` takes `allowed:` from its options, or looks it up once, and passes it to `build_query(report_filter, user, opts \\ [])`, whose `allowed:` falls back to the lookup as `build/4`'s does and is passed on to `build/4`. The default keeps `build_query/2` callable, so `learner_base_query_test.exs` and `learner_data_test.exs`, which call it for a site admin and a no-role user (no `in_admin_class` either way), are unchanged. When `admin_class_sql(allowed, :class)` is not nil, the query also selects it as `in_admin_class` (the `DISTINCT` row count is unchanged, since the value is per class) and the returned learner map carries it, for the CLUE step; `upload/1` drops it before encoding, since the uploaded fields are the ones the AWS Glue configuration names. `get_permission_form_map/3` also selects `ppf.project_id`, and a row whose `in_admin_class` is not 1 keeps only the forms whose project is in `form_project_ids(allowed)`; every other row keeps every form, as today. `count/2` is unchanged: `count_query/1` replaces the column list, so it needs neither the column nor a lookup of its own beyond `build/4`'s.

Fixture: `portal_student_permission_forms` gains `(76, 12)`, and learner 905's `report_learners` row gets `permission_forms` `'Proj B: Form 2,Proj C: Form C'` and `permission_forms_id` `'12,15'`, so a researcher's kept form can sit second. Student 76 already holds 902's form, so the learner and scope expectations of the earlier steps are unchanged.

Tests:
- `allowed_projects_db_test.exs` (`:portal_db`): `researcher?/1`, `form_project_ids/1` and `admin_class_sql/2` give `false`, `:all` and `nil` for `:all`, `:none` and an admin-only struct; `admin_class_sql/2` is `FALSE` for a researcher-only struct. The narrowed expression run over a derived table aliased `rl` gives the second name alone for the second position's project, NULL when no position matches, and NULL for lists of different lengths (each case fails if its line of the SQL is removed).
- `student_metadata_report_db_test.exs`: researcher 563 (on 902) gets `Proj C: Form C` for learner 905; mixed user 562 gets the full `Proj A: Form 1,Proj B: Form 2` for 901 (class 601, a cohort class of its admin project 900; fails if the `CASE` is removed) and `Proj C: Form C` for 905 (class 604, reached only through 902); admin 555 still gets `Proj A: Form 1,Proj B: Form 2` for 901, and the existing site-admin test is unchanged.
- `learner_data_portal_test.exs`: `fetch/3` for 563 maps learner 905 to `["Proj C: Form C"]`; for 562 maps 901 to both names and 905 to `["Proj C: Form C"]`; for 555 maps 901 to both names; for 562 the fetched map carries `in_admin_class` 1 on 901 and 0 on 905, and `upload/1` (through `AthenaDBStub`) writes no `in_admin_class` key (fails if the drop is removed).

---

### A researcher's CLUE export holds only student documents

**Summary**: R11. For a caller with a researcher project, only classes reached through one of their admin projects keep their class owner and group owners; every other class gives its student owners only. A researcher-only caller therefore makes no `owners` call.

**Files affected**:
- `lib/report_server_web/api/v1/endpoint_set.ex`: `fetch_learners/3` with an optional `allowed` (looked up when absent), passed to `LearnerData.fetch/3` as `allowed:`
- `lib/report_server_web/api/v1/clue_export_controller.ex`: `first_page` looks up `allowed` once and passes it to `fetch_learners/3` and `derive_owners/3`
- `server/README.md`: the CLUE export's "Scope." paragraph
- `test/report_server_web/api/v1/clue_export_controller_test.exs`

**Estimated diff size**: ~70 lines

`EndpointSet.fetch_learners/3` takes an optional `allowed`, looked up when absent, and passes it to `LearnerData.fetch/3` as `allowed:`; with `first_page`'s own lookup that is one portal round trip per first page. `derive_owners/3`, when `AllowedProjects.researcher?(allowed)`, keeps a class owner only when the class's learners carry `in_admin_class` 1, the column the form-names step selects; a missing or 0 value drops it, so the check fails closed and needs no portal query of its own. `fetch_groups/2` then runs over the kept class owners only, and not at all when none is kept, so a researcher-only caller sends no `owners` request. For every other caller it is unchanged. Owners are frozen on the first page, so a token already issued keeps its owners, as for any change to the run's learners.

README, appended to "Scope.": for a caller who holds a researcher project, a class reached through one of their admin projects keeps its class and group documents, and any other class gives its student documents only, because a group or class document can hold the work of students outside their consent.

Tests (`clue_export_controller_test.exs`, through the existing `allowed_project_ids_source` and `clue_export_client` stubs):
- a researcher struct over learners carrying `in_admin_class: 0` sends a documents request whose `owners` are the student owners alone, and no `owners` request (fails if the guard is removed);
- an admin struct over the same learners, without the key, still sends the class and group owners;
- a mixed struct whose learners carry `in_admin_class` 1 in one class and 0 in another sends class and group owners for the first only, and its `owners` request names only the first class (fails if the class filter is removed).

---

### Names follow the portal's per-class rule

**Summary**: R12. For a caller allowed names who also holds a researcher project, each name and username is shown only when the learner's class teacher is in a cohort of one of the caller's admin projects; every other row gets today's hidden values. Admin-only callers and site admins get byte-identical SQL.

**Files affected**:
- `lib/report_server/reports/allowed_projects.ex`: the `{:student, ref}` clause of `admin_class_sql/2`
- `lib/report_server/reports/hide_names.ex`: the moduledoc
- `lib/report_server/reports/learner_hide_names.ex`: `student_name_sql/2`, `username_sql/2`
- `lib/report_server/reports/portal/student_metadata_report.ex`: passes the `allowed` it already looks up
- `lib/report_server/reports/athena/learner_data.ex`: the pre-hide in `fetch/3`'s row mapping, over the `in_admin_class` column
- `lib/report_server/reports/report_filter.ex`: a public `student_label_expr/2`, which `label_expr(:student, ...)` calls
- `lib/report_server/reports/report_filter_query.ex`: the student option's value and `LIKE` both call `ReportFilter.student_label_expr/2`
- Tests: `learner_hide_names_test.exs`, `student_metadata_report_db_test.exs`, `learner_data_portal_test.exs`, `report_filter_values_test.exs`, `filter_options_test.exs`

**Estimated diff size**: ~210 lines, about 80 of them code

The per-row condition is `AllowedProjects.admin_class_sql(allowed, :class)` from the form-names step. Student labels use a `{:student, ref}` clause added here, true when one of the classes of the student `ref` names has a teacher in a cohort of an admin project; labels pass `{:student, "ps.id"}`:

```elixir
defp admin_class_exists(admin_ids, {:student, student_ref}),
  do: "EXISTS (SELECT 1 FROM portal_student_clazzes psc_n " <>
        "JOIN portal_teacher_clazzes ptc_n ON (ptc_n.clazz_id = psc_n.clazz_id) #{@admin_cohort_joins} " <>
        "WHERE psc_n.student_id = #{student_ref} AND #{in_clause("ac_n.project_id", admin_ids)})"
```

The `FALSE` clause of `admin_class_exists` is reachable here: `allowed?/1` reads the flags stored at login while the lookup is live, so a user whose admin rows were removed after login is allowed names with `admin: []`, and `FALSE` hides every row for them.

`LearnerHideNames.student_name_sql(hide_names, predicate)` and `username_sql/2`: with `hide_names` true, or `predicate` nil, today's expressions; otherwise `CASE WHEN <predicate> THEN rl.student_name ELSE CAST(rl.student_id AS CHAR) END`, and the same over the username and its hash. The hidden `student_name` is then a string where it was an integer; the CSV bytes are the same, and the run page's JSON download (`format_results/2` in `report_run_live/show.ex`) carries `"76"` where `hide_names: true` carries `76`.

`StudentMetadataReport` passes `AllowedProjects.admin_class_sql(allowed, :class)`.

`LearnerData.fetch/3`, in its row mapping (it holds the filter; `upload/1` sees only the rows), when the filter's `hide_names` is false and the condition is not nil, reads the `in_admin_class` column the form-names step selects and, for a row where it is not 1, uploads `student_name` as the student id string and `username` as `Base.encode16(:crypto.hash(:sha, salt <> username))`, the digest the Presto and MySQL paths produce. A nil username stays nil, as `SHA1(CONCAT(salt, NULL))` does in MySQL: rigse's `update_field` leaves the column NULL when its lookup chain fails, and `salt <> nil` raises. With `hide_names` true it changes nothing, since Athena then hashes the username itself and pre-hiding would hash it twice.

`ReportFilter.student_label_expr(hide_names, allowed)` (public) returns the bare expression, with no alias: `CAST(u.id AS CHAR)` when `hide_names` is true; the name label `CONCAT(TRIM(u.first_name), ' ', TRIM(u.last_name), ' <', TRIM(u.id), '>')` when `admin_class_sql(allowed, {:student, "ps.id"})` is nil; otherwise `CASE WHEN <that predicate> THEN <name label> ELSE CAST(u.id AS CHAR) END`. `label_expr` takes `allowed` as a third argument (`value_select/3` already holds it), and its `:student` clause becomes a call to `student_label_expr/2`. `ReportFilterQuery.get_filter_query(:student, ...)` drops its own two label strings and calls it once, appending `AS fullname` at the select and using the same raw expression in the `LIKE`, so a hidden student cannot be found by typing their name. The option text thereby gains the stored label's `TRIM`, which differs only for a name with surrounding spaces. Run labels stored in `report_filter_values` come from `label_expr`, so they follow.

`HideNames.allowed?/1` and `enforce/2` and their callers are unchanged: the filter's flag stays the caller's choice, and the per-row rule is applied where the query is built.

Tests, with fixture user 562 (admin of 900, researcher on 902) and `hide_names: false`:
- Student Metadata: learner 901 (an admin class) carries `Stu One` and `stu.one`; learner 905 (reached through 902) carries `"76"` and the same hash `hide_names: true` gives it (fails if the CASE is removed).
- `LearnerData.fetch/3`, with `:hide_username_hash_salt` pinned as `student_metadata_report_db_test.exs` pins it (the test env's salt is random per call): 905's uploaded name and username equal the Student Metadata hidden values; with `hide_names: true` 905's username is the raw username, not pre-hashed; with 905's username set to NULL the fetch succeeds and uploads a nil username.
- Filter options for 562: student 76's label is its user id (106), and searching its name returns nothing while searching `106` finds it; student 71 keeps its name label. Resolved labels: 71 named, 76 by id.
- Admin 555 and site admin: the generated SQL contains no `ptc_n` (byte-identical to the previous step's).
- A stale admin flag: `%User{portal_is_project_admin: true, portal_user_id: 557}` with `hide_names: false` gets learner 901 as `"71"` and its hash (fails if the `[]` clause is removed or returns nil).

---

### A named permission form follows the same rule

**Summary**: R14. For a caller with a researcher project, a `permission_form` filter value matches a learner or a student only when the form is one of the caller's projects' or the class is reached through one of their admin projects, so another project's form id cannot be used to learn which consented students hold it.

**Files affected**:
- `lib/report_server/reports/allowed_projects.ex`: `named_form_sql/3`
- `lib/report_server/reports/learner_base_query.ex`: the `permission_form` filter
- `lib/report_server/reports/report_filter_query.ex`: `apply_secondary_filters/5` takes `allowed` from `get_filter_query/5` and adds the condition to the `permission_form` secondary filter of every primary dimension
- Tests: `learner_scoping_db_test.exs`, `filter_options_test.exs`

**Estimated diff size**: ~90 lines

```elixir
@doc """
The extra condition on a row matched through `form_col`, a named permission form: nil for a caller
with no researcher project; else the form belongs to one of the caller's projects, or the row's
class is reached through one of their admin projects (`by` as for `admin_class_sql/2`).
"""
def named_form_sql(allowed, form_col, by) do
  if researcher?(allowed) do
    "(EXISTS (SELECT 1 FROM portal_permission_forms ppf_f WHERE ppf_f.id = #{form_col} " <>
      "AND #{in_clause("ppf_f.project_id", ids(allowed))}) OR #{admin_class_sql(allowed, by)})"
  else
    nil
  end
end
```

`LearnerBaseQuery`'s `permission_form` filter adds `named_form_sql(allowed, "pspf.portal_permission_form_id", :class)` beside its `IN` when it is not nil, with the `allowed` the learner step already holds. `ReportFilterQuery.apply_secondary_filters/5` does the same for the `permission_form` entry of `@secondary_filter_config`, with `{:student, "pspf.portal_student_id"}`, since its joins always reach `pspf`. A researcher-only caller's admin check is `FALSE`, so for them only the project test remains. `ppf_f` is unused elsewhere in `lib/report_server/reports/`.

Stored runs re-run through `LearnerBaseQuery`, so a run that named a foreign form id returns the same narrowed rows as a new one.

Tests:
- `learner_scoping_db_test.exs`: researcher 563 (on 902) with `permission_form: [12]` (a 901 form) gets `[]` (gets `[905]` if the condition is removed), and with `[15]` gets `[905]`; mixed user 562 with `[12]` gets `[901]` (class 601 is an admin class) and not 905.
- `filter_options_test.exs`: for 563, student options narrowed by form 12 are empty (fails if the secondary condition is removed) and narrowed by form 15 are `[76]`, and class options narrowed by form 12 are empty where they give `[604]` without the condition (fails if only the `student` cascade gets it); for mixed user 562, student options narrowed by 12 are `[71]` and class options `[601]` (fails if the option path's admin-class check is dropped or given the learner query's `:class`, which the suite otherwise never runs for a caller with an admin project); for admin 555 narrowing by 12 is unchanged.

---

### A researcher's CLUE work links point only at work they may see

**Summary**: R15. The `clue_link_to_work` step learns the run owner's allowed projects and, for an owner with a researcher project, links a row only to the learner's own document or to a document in an admin-project class.

**Files affected**:
- `lib/report_server/post_processing/job_server.ex`: `add_job/5` takes `allowed` and stores it on the `%Job{}`
- `lib/report_server/post_processing/job.ex`: an `allowed` field (default `:none`), copied into the `%JobParams{}` `process_rows/5` builds; `get_learners/3` selects `in_admin_class` when `AllowedProjects.admin_class_sql(allowed, {:class, "po.clazz_id"})` is not nil
- `lib/report_server/post_processing/job_params.ex`: an `allowed` field (default `:none`)
- `lib/report_server/post_processing/steps/clue_link_to_work.ex`: the guard in `process_row/3`
- `lib/report_server/reports/allowed_projects.ex`: a `{:class, ref}` clause of `admin_class_sql/2`, with `:class` meaning `{:class, "rl.class_id"}`
- `lib/report_server_web/live/report_live/post_processing.ex`: passes `PortalDbs.get_allowed_project_ids(report_run.user)`, the owner whose scope the run's rows already follow
- `lib/report_server_web/live/old_report_live/query.ex`: passes `:none`; it holds no `%User{}` (only portal session credentials), and no route reaches it since `/old-reports` redirects; with `:none` its CLUE links stay empty
- `test/report_server/post_processing/job_test.exs`, new `test/report_server/post_processing/job_learners_db_test.exs`

**Estimated diff size**: ~90 lines

```elixir
defp link_allowed?(%JobParams{allowed: :all}, _learner, _document_uid), do: true
defp link_allowed?(%JobParams{allowed: %AllowedProjects{researcher: []}}, _learner, _document_uid), do: true

defp link_allowed?(%JobParams{allowed: allowed}, learner, document_uid) do
  AllowedProjects.researcher?(allowed) and
    (document_uid == Integer.to_string(learner.user_id) or learner[:in_admin_class] == 1)
end
```

`process_row/3` writes the link only when `link_allowed?/3`, else returns the row unchanged, as it already does for a row with no learner. The guard fails closed: only `:all` and an admin-only struct link freely, a researcher struct gets the per-row check, and anything else (`:none`, the default) links nothing. A job read back from the jobs file without `allowed` takes the default `:none`; such jobs are only listed, never run again (`JobServer.read_jobs_file/1`), so the default changes no stored result. Every new job carries the owner's value. A failed lookup (`{:error, _}`) would also link nothing, but `add_job` is called only after a successful lookup: on an error the LiveView starts no job and puts an error flash, as its download handler already does for an audit failure. `report_run.user` is loaded wherever this component renders, since the run page already queries with it.

Tests (`job_test.exs`, through `JobOverrides.learners` for the learner map):
- researcher allowed, a row whose `documentUid` is another user and whose learner has no `in_admin_class`: no link (fails if the guard is removed);
- the same row with `documentUid` equal to the learner's `user_id`: linked;
- a mixed owner with `in_admin_class: 1` and another user's document: linked;
- an admin-only owner: every row linked, as today;
- an owner whose lookup gave `:none`: another user's document is not linked (fails if the guard treats a non-researcher value as unrestricted).
- `job_learners_db_test.exs` (`:portal_db`), without the learners override so `get_learners/3` queries the fixture: for owner 562, another user's document is linked on a row for `SECUREKEY123` (learner 901, class 601) and not on one for `SECUREKEY905` (class 604). The four above set `in_admin_class` by hand, so without this a dropped or misreferenced column (whose SQL error `get_learners/3` turns into `%{}`) passes.

---

### README: who sees which students

**Summary**: R7.

**Files affected**:
- `server/README.md`: a short "Who sees which students" subsection at the end of "Available Reports"

**Estimated diff size**: ~10 lines

Content, per R7: a site admin sees every student; a project admin sees the students in their projects' cohort classes, on assignments in those projects' cohorts or materials; a project researcher sees only those of them who hold one of that same project's permission forms, which applies to the student reports, the exports and the filter options alike; a researcher whose access has expired on the portal sees nothing; for any caller other than a site admin who holds a researcher project, full permission-form names, CLUE group and class documents, and names show only in classes reached through one of their admin projects, as the portal decides names, and elsewhere the form names are narrowed to their projects' forms and the CLUE export holds student documents only; the teacher-level reports count students without the permission-form narrowing.

## PR body (R9)

Carries, as one paragraph for the 1.13.1 notes: researchers' reports, exports and filter options now include only students with one of their project's permission forms; for any caller other than a site admin who holds a researcher project, outside the classes their admin projects reach, permission-form names list only their projects' forms and CLUE exports no longer include group or class documents; a researcher's permission-form filter matches only their projects' forms outside their admin-project classes; a researcher's CLUE link-to-work column links only to work they may see; expired researcher access no longer grants new report-server data or package administration (results already stored stay downloadable to their owner); Athena results created before the release keep their original students and should be re-run; and a user who administers one project and researches another now gets the second project's students (and its packages) under the researcher rule, with names shown only in their admin projects' classes.

It also tells the reviewer that the story's "student, class, and any dimension that reaches students" was narrowed to `student` and `permission_form`, because consent gates a researcher's students and not the cohort classes their project reaches (R5), and, after the staging deploy, carries the R13 results.

## Open Questions

### RESOLVED: Judgment call: keep the name `get_allowed_project_ids`?
**Options considered**:
- A) Keep it, now returning the struct.
- B) Rename to `get_allowed_projects`.

**Decision**: A. The name is also the stub contract (`LearnerDataStub`, `PackagesPortalStub`) and the `:allowed_project_ids_source` config key; renaming adds churn across those files and changes no behavior.

### RESOLVED: Judgment call: split the struct step from the learner rule?
**Options considered**:
- A) Separate steps: the shape change, then the rule.
- B) One step.

**Decision**: A. The shape change is mostly mechanical test churn and reviews best alone; the rule step is then a small diff whose tests are all about the rule. The intermediate state never deploys (see the plan's opening).

### RESOLVED: Low confidence: does the new fixture data disturb existing tests?
**Decision**: Checked by applying the fixture additions and running the `:portal_db` suite (250 tests): only `portal_fixture_test.exs`'s learner-count test fails, and the plan updates it.

## Self-Review

Roles: Senior Engineer, Commit Reviewer, Test Writer, Security Engineer, Operator. The plan's library code, fixture and R8 cases, the compile-time `consent_exists/2` call inside `@scopes` included, were built as throwaway code and passed.

### Test Writer

#### RESOLVED: the test inventory missed eight files
The full suite with the plan applied failed beyond the files first listed, in `report_filter_query_db_test.exs`, `package_controller_read_test.exs` and `package_controller_validate_test.exs` (list call sites, now in the split step), `student_id_mapping_report_db_test.exs` (learner step), and `filter_options_test.exs` and `filter_options_controller_test.exs` (filter-options step). Each is now named in the step whose change breaks it.

#### RESOLVED: two existing tests assert the contract this story reverses
`student_id_mapping_report_db_test.exs` asserts a researcher's learners equal a project admin's, and the filter-options hide-names tests list all four of 557's cohort students. Left alone they would fail; rewritten without thought they would keep documenting the old rule. The plan now says what each asserts afterwards.

### Commit Reviewer

#### RESOLVED: each test change belongs to the step that breaks it
The researcher-label tests pass through the split step (the union still shows 557 all four students) and break only at the filter-options step; the student-ID-mapping test breaks at the learner step. Moving them there keeps every step green on its own.

### Operator

#### RESOLVED: the README's recent-logs paragraph describes the class gate
"Recent logs for a class" says the class must be one the caller's project grants reach. `class` keeps its cohort rule, so the sentence stays true as written.

### Self-review round 1

Roles: Senior Engineer, Security Engineer, QA Engineer, Commit Reviewer, Release Manager. The R4 and R5 ids and `form_names_sql/1` reproduce on the fixture with every planned addition, the last under `ONLY_FULL_GROUP_BY`, on Elixir 1.16.2.

#### RESOLVED: a NULL `is_admin` dropped a live researcher project
`admin_project_users.is_admin` is nullable in rigse; a row `(NULL, 1)` gave `[901, nil, 1]`, which neither `to_allowed_projects/1` pattern matches, while the role flag said researcher. `@project_roles` now reads `MAX(COALESCE(apu.is_admin, 0) = 1)`, with a fixture row and test.

#### RESOLVED: the `scope_by_allowed_projects/6` head would not compile
A bodiless head with a pattern (`allowed = %AllowedProjects{}`) is a compile error ("only variables and \\ are allowed as arguments in function head"). The head now takes plain variables and every clause takes the sixth argument.

#### RESOLVED: the consent scopes' code block and prose disagreed
The code kept `where: ["ac.project_id IN"]` while the prose added `project:`, two spellings of one column. The two configs now carry `project:` in place of `where:`, in both.

#### RESOLVED: the `EndpointSet` change sat in two steps
The form-names step described `fetch_learners` taking `allowed` without listing `endpoint_set.ex`; the CLUE step listed it. It is now described and listed in the CLUE step only.

#### RESOLVED: the `FALSE` clause was called unreachable
`allowed?/1` reads stored flags and the lookup is live, so a stale admin flag reaches `admin: []`. The prose says so, and a test with 557 flagged as project admin guards the clause.

#### RESOLVED: the packages `is_list` guard would be orphaned
The lookup no longer returns a list, so `portal_allowed_project_ids/1`'s struct clause replaces the guard rather than sitting beside it.

#### RESOLVED: the PR body missed R9's reviewer note and R13
The section now carries the `student`/`permission_form` narrowing note and the staging results, lists the package-catalog and mixed-role changes once each, and says the form-name and CLUE changes apply to any caller with a researcher role.

### Self-review round 2

Roles: Data Pipeline Engineer, Integration Engineer, Mutation Tester, Technical Writer. Built as throwaway code over the fixture: the `DISTINCT` learner query keeps its row count with `in_admin_class` (4, 1 and 3 rows for 562, 563 and 555), and the name `CASE`s, upload and CLUE owner filter give the plan's values.

#### RESOLVED: the CLUE mixed-role test could not reach a portal
`admin_classes_sql/2` ran through `PortalDbs.query` on the request user's server, which in `clue_export_controller_test.exs` is `learn.concord.org` (`{:error, "Unknown server learn.concord.org"}` under the test env). `derive_owners/3` now reads the `in_admin_class` column `LearnerData` already selects, so the three outputs share one check and `admin_classes_sql/2` is gone.

#### RESOLVED: pre-hiding raised on a NULL username
`salt <> nil` raises `ArgumentError` (run on the fixture), which would fail a mixed caller's whole Athena run. A nil username now stays nil, as MySQL's hash does, with a test.

#### RESOLVED: the names step edited a README subsection that did not exist yet
"Who sees which students" is created by the later README step, whose R7 content already covers names, so the names step no longer touches the README.

#### RESOLVED: the `:student` admin-class clause was defined a step before its first use
It now arrives in the names step with the student labels that use it.

#### RESOLVED: the researcher CLUE test asserted on the stub's own items
The documents in a first page are whatever the stub returns, so the test now asserts on the `owners` the documents request sends.

#### RESOLVED: the PR body said expired researchers lose all report-server data
Out of Scope keeps their stored results downloadable to their owner, so the release-note line now says "new" data and names the exception, as R9 does.

### Self-review round 3

Roles: Implementer (cold read), Database Reviewer, Operator / On-call, Privacy Reviewer. On a synthetic portal with rigse's indexes the consent `EXISTS` uses `portal_student_permission_forms.portal_student_id`, the admin-class `EXISTS` `portal_teacher_clazzes.clazz_id`, and an 8,000-row Student Metadata shape runs in the same 0.2 to 0.4 s with and without them. The membership-oracle finding became R14 in requirements.md.

#### RESOLVED: the learner step left `apply_allowed_project_ids_filter/6`'s student ref orphaned
The form-names step moves `LearnerBaseQuery` to `scope_by_allowed_projects` directly, after which no caller passed the sixth argument. The learner step now makes that move itself and leaves `apply_allowed_project_ids_filter/5` alone.

#### RESOLVED: `build_query/3` would have broken two unlisted test files
`learner_base_query_test.exs` and `learner_data_test.exs` call `LearnerData.build_query/2`. The new argument is now an optional keyword list, and `count/2`, which needs no column, stays unchanged.

#### RESOLVED: the pre-hide had no stated home
`upload/1` receives only the rows, not the filter's `hide_names`. The names step now places it in `fetch/3`'s row mapping.

#### RESOLVED: no test separated the same-project consent rule from a check over the researcher list
Fixture user 569 (researcher on 900 and 902) and the row `(78, 11)` give learner 907 and student 78 a form of the other researcher project; the learner and scope tests now assert them out. The test fails if the consent compares against the list.

#### RESOLVED: the JSON download was not named where the hidden name changes type
The names step now says the run page's JSON carries `"76"` where `hide_names: true` carries `76`, as R8 now does.

### Self-review round 4

Roles: Adversarial Researcher, Whole-Plan Builder, Spec Clarity Reviewer. Every planned fixture row applied to the real fixture with no code change fails only the planned learner-count test in the full suite (1487 tests); the R4, R5 and R14 learner and student ids reproduce on a scratch copy.

#### RESOLVED: R14's option test could not tell the `student` cascade from every cascade
The test narrowed student options only, so a condition added to one `@secondary_filter_config` entry passed. It now also asserts class options narrowed by form 12 are empty for 563 (`[604]` without the condition, checked on the fixture).

#### RESOLVED: round 3's preamble called R14's finding OPEN
It was resolved as R14; the line now says so.

#### RESOLVED: process narrative in the self-review preambles
The four preambles described how the checks were run; each is now one line keeping its conclusion, and a stray leading space before the names step's `FALSE` note is gone.

### Self-review round 5

Roles: Whole-Plan Builder, Implementer, Test Writer (mutation), Commit Reviewer. Every step was built in order as throwaway code over the fixture, the full suite run after each (green throughout once the fixes below were applied), and 35 mutations of guarded lines tried; the three that survived the planned tests are the two test gaps below.

#### RESOLVED: the consent predicate changed an admin-only caller's option SQL
`predicate/3` wrapped an admin-only struct's branch in parentheses, so the filter-options step failed `report_filter_query_test.exs`'s golden SQL (`WHERE ((ac.project_id IN (7,8)))`). An admin-only struct now renders the bare `IN`.

#### RESOLVED: the split step missed one empty-list test
`report_filter_query_test.exs`'s "an empty allowed-projects list behaves as :none does" raises once `[]` is gone; it is deleted with the others, and the file's `[]` arguments become `:none`.

#### RESOLVED: no test reached the option path's admin-class check
Passing the learner query's `:class` (an SQL error in option queries) or dropping the admin branch left the suite green, since only researcher-only 563 narrows options by a form. The R14 tests add mixed user 562 (`[71]`, `[601]`).

#### RESOLVED: no test reached `get_learners/3`'s new column
All four link tests set `in_admin_class` through `JobOverrides.learners`, so dropping the column or giving it `rl.class_id` passed. A `:portal_db` test now runs the real lookup.

#### RESOLVED: the link step's file list and the old query component
`JobParams` lives in `job_params.ex`, now listed, with `process_rows/5` copying `job.allowed`. `old_report_live/query.ex` has no `%User{}` to look up and no route, so it passes `:none`.

#### RESOLVED: the pre-hide equality test needs a pinned salt
`AthenaConfig.get_hide_username_hash_salt/0` returns a fresh random salt per call in the test env, so the MySQL and Elixir hashes differ unless the test pins it.

