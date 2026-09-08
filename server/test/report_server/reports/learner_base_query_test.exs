defmodule ReportServer.Reports.LearnerBaseQueryTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{LearnerBaseQuery, ReportFilter, ReportQuery}
  alias ReportServer.Reports.Athena.LearnerData

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

  # pinned so an edit to the base cannot silently change what the Athena reports send to the portal
  @expected %{
    {"class only", "super-admin"} =>
      "SELECT DISTINCT rl.learner_id AS learner_id, rl.student_id AS student_id, rl.class_id AS class_id, rl.class_name AS class, rl.school_name AS school, rl.user_id AS user_id, COALESCE(u.primary_account_id, u.id) AS primary_user_id, rl.offering_id AS offering_id, rl.username AS username, rl.student_name AS student_name, rl.last_run AS last_run, rl.teachers_id AS teachers_id, rl.permission_forms_id AS permission_forms_id, ea.url AS runnable_url, pl.secure_key AS secure_key, pl.created_at AS created_at FROM report_learners rl JOIN portal_learners pl ON (rl.learner_id = pl.id) JOIN users u ON (u.id = rl.user_id) JOIN portal_offerings po ON (po.id = rl.offering_id) JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id) JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id) JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id) LEFT JOIN portal_runs run on (run.learner_id = pl.id) WHERE (rl.class_id IN (600))   ",
    {"class only", "no-roles"} =>
      "SELECT DISTINCT rl.learner_id AS learner_id, rl.student_id AS student_id, rl.class_id AS class_id, rl.class_name AS class, rl.school_name AS school, rl.user_id AS user_id, COALESCE(u.primary_account_id, u.id) AS primary_user_id, rl.offering_id AS offering_id, rl.username AS username, rl.student_name AS student_name, rl.last_run AS last_run, rl.teachers_id AS teachers_id, rl.permission_forms_id AS permission_forms_id, ea.url AS runnable_url, pl.secure_key AS secure_key, pl.created_at AS created_at FROM report_learners rl JOIN portal_learners pl ON (rl.learner_id = pl.id) JOIN users u ON (u.id = rl.user_id) JOIN portal_offerings po ON (po.id = rl.offering_id) JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id) JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id) JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id) LEFT JOIN portal_runs run on (run.learner_id = pl.id) WHERE (rl.class_id IN (600)) AND (1 = 0)   ",
    {"cohort+school+dates", "super-admin"} =>
      "SELECT DISTINCT rl.learner_id AS learner_id, rl.student_id AS student_id, rl.class_id AS class_id, rl.class_name AS class, rl.school_name AS school, rl.user_id AS user_id, COALESCE(u.primary_account_id, u.id) AS primary_user_id, rl.offering_id AS offering_id, rl.username AS username, rl.student_name AS student_name, rl.last_run AS last_run, rl.teachers_id AS teachers_id, rl.permission_forms_id AS permission_forms_id, ea.url AS runnable_url, pl.secure_key AS secure_key, pl.created_at AS created_at FROM report_learners rl JOIN portal_learners pl ON (rl.learner_id = pl.id) JOIN users u ON (u.id = rl.user_id) JOIN portal_offerings po ON (po.id = rl.offering_id) JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id) JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id) JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id) LEFT JOIN portal_runs run on (run.learner_id = pl.id) join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id) join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id) WHERE (run.start_time <= '2026-06-30') AND (run.start_time >= '2026-01-01') AND (rl.school_id IN (7)) AND (aci_teacher.admin_cohort_id in (1,2)) AND (aci_assignment.admin_cohort_id in (1,2))   ",
    {"cohort+school+dates", "no-roles"} =>
      "SELECT DISTINCT rl.learner_id AS learner_id, rl.student_id AS student_id, rl.class_id AS class_id, rl.class_name AS class, rl.school_name AS school, rl.user_id AS user_id, COALESCE(u.primary_account_id, u.id) AS primary_user_id, rl.offering_id AS offering_id, rl.username AS username, rl.student_name AS student_name, rl.last_run AS last_run, rl.teachers_id AS teachers_id, rl.permission_forms_id AS permission_forms_id, ea.url AS runnable_url, pl.secure_key AS secure_key, pl.created_at AS created_at FROM report_learners rl JOIN portal_learners pl ON (rl.learner_id = pl.id) JOIN users u ON (u.id = rl.user_id) JOIN portal_offerings po ON (po.id = rl.offering_id) JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id) JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id) JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id) LEFT JOIN portal_runs run on (run.learner_id = pl.id) join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id) join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id) WHERE (run.start_time <= '2026-06-30') AND (run.start_time >= '2026-01-01') AND (rl.school_id IN (7)) AND (aci_teacher.admin_cohort_id in (1,2)) AND (aci_assignment.admin_cohort_id in (1,2)) AND (1 = 0)   ",
    {"permission_form+student", "super-admin"} =>
      "SELECT DISTINCT rl.learner_id AS learner_id, rl.student_id AS student_id, rl.class_id AS class_id, rl.class_name AS class, rl.school_name AS school, rl.user_id AS user_id, COALESCE(u.primary_account_id, u.id) AS primary_user_id, rl.offering_id AS offering_id, rl.username AS username, rl.student_name AS student_name, rl.last_run AS last_run, rl.teachers_id AS teachers_id, rl.permission_forms_id AS permission_forms_id, ea.url AS runnable_url, pl.secure_key AS secure_key, pl.created_at AS created_at FROM report_learners rl JOIN portal_learners pl ON (rl.learner_id = pl.id) JOIN users u ON (u.id = rl.user_id) JOIN portal_offerings po ON (po.id = rl.offering_id) JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id) JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id) JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id) LEFT JOIN portal_runs run on (run.learner_id = pl.id) JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id) WHERE (rl.student_id IN (70)) AND (pspf.portal_permission_form_id IN (11))   ",
    {"permission_form+student", "no-roles"} =>
      "SELECT DISTINCT rl.learner_id AS learner_id, rl.student_id AS student_id, rl.class_id AS class_id, rl.class_name AS class, rl.school_name AS school, rl.user_id AS user_id, COALESCE(u.primary_account_id, u.id) AS primary_user_id, rl.offering_id AS offering_id, rl.username AS username, rl.student_name AS student_name, rl.last_run AS last_run, rl.teachers_id AS teachers_id, rl.permission_forms_id AS permission_forms_id, ea.url AS runnable_url, pl.secure_key AS secure_key, pl.created_at AS created_at FROM report_learners rl JOIN portal_learners pl ON (rl.learner_id = pl.id) JOIN users u ON (u.id = rl.user_id) JOIN portal_offerings po ON (po.id = rl.offering_id) JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id) JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id) JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id) LEFT JOIN portal_runs run on (run.learner_id = pl.id) JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id) WHERE (rl.student_id IN (70)) AND (pspf.portal_permission_form_id IN (11)) AND (1 = 0)   ",
  }

  test "the base query generates the expected SQL for every filter and role shape" do
    assert length(@cases) == 3 and length(@users) == 2

    for {case_label, filter} <- @cases, {user_label, user} <- @users do
      {:ok, query} = LearnerBaseQuery.build(filter, user, LearnerData.learner_cols())
      {:ok, sql} = ReportQuery.get_sql(query)

      assert sql == Map.fetch!(@expected, {case_label, user_label}),
             "generated SQL changed for #{case_label} / #{user_label}"
    end
  end

  test "LearnerData.build_query/2 produces exactly what the base query produces for its own columns" do
    assert length(@cases) == 3 and length(@users) == 2

    for {_case_label, filter} <- @cases, {_user_label, user} <- @users do
      {:ok, shipped} = LearnerData.build_query(filter, user)
      {:ok, base} = LearnerBaseQuery.build(filter, user, LearnerData.learner_cols())

      assert ReportQuery.get_sql(shipped) == ReportQuery.get_sql(base)
    end
  end

  test "the caller's select list is what gets projected" do
    {:ok, query} =
      LearnerBaseQuery.build(%ReportFilter{filters: [:class], class: [600]},
        %User{portal_server: "portal.example.com", portal_is_admin: true},
        [{"rl.learner_id", "learner_id"}])

    {:ok, sql} = ReportQuery.get_sql(query)

    assert String.starts_with?(sql, "SELECT rl.learner_id AS learner_id FROM report_learners rl")
    refute sql =~ "secure_key"
  end

  test "group_by and order_by are absent unless asked for, and rendered when they are" do
    filter = %ReportFilter{filters: [:class], class: [600]}
    user = %User{portal_server: "portal.example.com", portal_is_admin: true}
    cols = [{"rl.learner_id", "learner_id"}]

    {:ok, plain} = LearnerBaseQuery.build(filter, user, cols)
    {:ok, plain_sql} = ReportQuery.get_sql(plain)
    refute plain_sql =~ "GROUP BY"
    refute plain_sql =~ "ORDER BY"

    {:ok, grouped} =
      LearnerBaseQuery.build(filter, user, cols, group_by: "rl.id", order_by: [{"learner_id", :asc}])

    {:ok, grouped_sql} = ReportQuery.get_sql(grouped)
    assert grouped_sql =~ "GROUP BY rl.id"
    assert grouped_sql =~ "ORDER BY learner_id asc"
  end

  test "the grouping carries the primary key of every table the portal reports project from" do
    assert LearnerBaseQuery.group_by() == "rl.id, u.id, ea.id, pl.id"
  end

  test "every alias in the grouping is one the base query actually joins" do
    {:ok, query} =
      LearnerBaseQuery.build(%ReportFilter{filters: [:class], class: [600]},
        %User{portal_server: "portal.example.com", portal_is_admin: true},
        [{"rl.learner_id", "learner_id"}])

    {:ok, sql} = ReportQuery.get_sql(query)
    aliases = LearnerBaseQuery.group_by() |> String.split(", ") |> Enum.map(&hd(String.split(&1, ".")))

    assert length(aliases) == 4

    for table_alias <- aliases do
      assert sql =~ ~r/\b#{table_alias}\b/, "#{table_alias} is grouped but never joined"
    end
  end

  test "run_remote_endpoint_sql/1 matches the string LearnerData builds in Elixir" do
    portal_server = "portal.example.com"
    sql = LearnerBaseQuery.run_remote_endpoint_sql(portal_server)

    assert sql ==
             "CONCAT('https://#{portal_server}/dataservice/external_activity_data/', COALESCE(pl.secure_key, ''))"
  end

  test "a filter with nothing to constrain it is rejected rather than run unscoped" do
    assert {:error, "Cannot run query with no filters"} =
             LearnerBaseQuery.build(%ReportFilter{},
               %User{portal_server: "portal.example.com", portal_is_admin: true},
               [{"rl.learner_id", "learner_id"}])
  end

  test "a caller with no allowed projects is constrained to zero rows" do
    {:ok, query} =
      LearnerBaseQuery.build(%ReportFilter{filters: [:class], class: [600]},
        %User{portal_server: "portal.example.com"}, [{"rl.learner_id", "learner_id"}])

    {:ok, sql} = ReportQuery.get_sql(query)

    assert sql =~ "(1 = 0)"
  end
end
