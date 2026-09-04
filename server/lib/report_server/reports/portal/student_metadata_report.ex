defmodule ReportServer.Reports.Portal.StudentMetadataReport do
  use ReportServer.Reports.Report, type: :portal

  alias ReportServer.Reports.{LearnerBaseQuery, LearnerHideNames}

  # GROUP_CONCAT cuts mid-value at group_concat_max_len with only a warning nothing reads, which
  # would misalign the teacher columns. The hint raises the ceiling for this statement alone: a
  # SET SESSION would be a second statement and would leak across the pooled connection. It rides
  # on the first column because get_sql/2 renders "SELECT " <> cols, which is where MySQL wants it.
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

  # the portal joins the teacher lists with ", " and permission_forms with ","; normalize so the
  # file has one splitting rule
  defp csv_list(col), do: "REPLACE(#{col}, ', ', ',')"

  # One entry per teacher named in teachers_id, in that list's own order, so all five teacher
  # columns align by index. Two properties keep that true:
  #
  #   * The positions come from teachers_id, not from portal_teachers. GROUP_CONCAT skips NULLs, so
  #     reading through the teacher table drops a teacher with no school, and an id with no teacher
  #     row, out of the list entirely and misaligns every later index. COALESCE keeps the position.
  #   * The school is chosen once, and both the district and the state are read from that row.
  #     Choosing each field independently pairs one school's district with another school's state.
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
