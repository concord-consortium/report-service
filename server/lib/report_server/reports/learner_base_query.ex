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
    "LEFT JOIN portal_runs run on (run.learner_id = pl.id)",
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

  @doc """
  Builds the base query with the caller's select list, and optional group_by/order_by.

  Not a pure builder: with `exclude_internal` set it runs its own portal query to resolve the
  internal teacher ids, so it can fail before any SQL is produced.
  """
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
        [
          "JOIN portal_student_permission_forms pspf ON (pspf.portal_student_id = psc.student_id)"
          | join
        ],
        [
          "pspf.portal_permission_form_id IN #{list_to_in(permission_form)}"
          | where
        ]
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
        [
          "JOIN portal_teachers pt ON (pt.id = ptc.teacher_id)"
          | join
        ],
        [
          "pt.id NOT IN #{list_to_in(internal_teacher_ids)}"
          | where
        ]
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
