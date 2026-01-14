defmodule ReportServer.Reports.Portal.SummaryMetricsBySubjectAreaReport do
  use ReportServer.Reports.Report, type: :portal

  def get_query(report_filter = %ReportFilter{country: country, state: state, subject_area: _subject_area}, user = %User{}) do
    # Choose query strategy based on which filter provides best selectivity
    # Country/State filters are more selective than subject area, so start from schools when they're present
    if have_filter?(country) || have_filter?(state) do
      get_query_from_schools(report_filter, user)
    else
      get_query_from_subject_areas(report_filter, user)
    end
  end

  # Query strategy: Start from schools (best for country/state filters)
  defp get_query_from_schools(report_filter, user) do
    %ReportQuery{
      cols: [
        {"trim(at.tag)", "subject_area"},
        {"count(distinct ps.country_id)", "number_of_countries"},
        {"count(distinct ps.state)", "number_of_states"},
        {"count(distinct ps.id)", "number_of_schools"},
        {"count(distinct pt.id)", "number_of_teachers"},
        {"count(distinct po_class.id)", "number_of_classes"},
        {"count(distinct coalesce(stu.primary_account_id, stu.id))", "number_of_students"},
        {"group_concat(distinct pg.name order by cast(pg.name as unsigned) separator ', ')", "class_grade_levels"}
      ],
      from: "portal_schools ps",
      join: [[
        "left join portal_countries pc on (pc.id = ps.country_id)",
        "join portal_school_memberships psm on (psm.school_id = ps.id and psm.member_type = 'Portal::Teacher')",
        "join portal_teachers pt on (pt.id = psm.member_id)",
        "join users u on (u.id = pt.user_id)",
        "join portal_teacher_clazzes ptc on (ptc.teacher_id = pt.id)",
        "join portal_clazzes po_class on (po_class.id = ptc.clazz_id)",
        "left join portal_grade_levels pgl on (pgl.has_grade_levels_id = po_class.id and pgl.has_grade_levels_type = 'Portal::Clazz')",
        "left join portal_grades pg on (pg.id = pgl.grade_id)",
        "join portal_offerings po on (po.clazz_id = po_class.id and po.runnable_type = 'ExternalActivity')",
        "join external_activities ea on (ea.id = po.runnable_id)",
        "join taggings t on (t.taggable_type = 'ExternalActivity' and t.taggable_id = ea.id and t.context = 'subject_areas')",
        "join admin_tags at on (at.id = t.tag_id and at.scope = 'subject_areas')",
        "left join portal_student_clazzes psc on (psc.clazz_id = po_class.id)",
        # The "exists" clause is so that portal_learners without runs don't count towards "# students started"
        "left join portal_learners pl on (pl.offering_id = po.id and pl.student_id = psc.student_id
          and exists (select 1 from portal_runs r2 where r2.learner_id = pl.id))",
        "left join portal_students pst on (pst.id = pl.student_id)",
        "left join users stu on (stu.id = pst.user_id)",
        "left join portal_runs run on (run.learner_id = pl.id)",
      ]],
      group_by: "at.id",
      order_by: [{"subject_area", :asc}]
    }
    |> apply_filters(report_filter, user)
  end

  # Query strategy: Start from subject areas (best when no geographic filter)
  defp get_query_from_subject_areas(report_filter, user) do
    %ReportQuery{
      cols: [
        {"trim(at.tag)", "subject_area"},
        {"count(distinct ps.country_id)", "number_of_countries"},
        {"count(distinct ps.state)", "number_of_states"},
        {"count(distinct ps.id)", "number_of_schools"},
        {"count(distinct pt.id)", "number_of_teachers"},
        {"count(distinct po_class.id)", "number_of_classes"},
        {"count(distinct coalesce(stu.primary_account_id, stu.id))", "number_of_students"},
        {"group_concat(distinct pg.name order by cast(pg.name as unsigned) separator ', ')", "class_grade_levels"}
      ],
      from: "admin_tags at",
      join: [[
        "join taggings t on (t.tag_id = at.id and t.context = 'subject_areas' and t.taggable_type = 'ExternalActivity')",
        "join external_activities ea on (ea.id = t.taggable_id)",
        "join portal_offerings po on (po.runnable_id = ea.id and po.runnable_type = 'ExternalActivity')",
        "join portal_clazzes po_class on (po_class.id = po.clazz_id)",
        "left join portal_grade_levels pgl on (pgl.has_grade_levels_id = po_class.id and pgl.has_grade_levels_type = 'Portal::Clazz')",
        "left join portal_grades pg on (pg.id = pgl.grade_id)",
        "join portal_teacher_clazzes ptc on (ptc.clazz_id = po_class.id)",
        "join portal_teachers pt on (pt.id = ptc.teacher_id)",
        "join users u on (u.id = pt.user_id)",
        "left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')",
        "left join portal_schools ps on (ps.id = psm.school_id)",
        "left join portal_countries pc on (pc.id = ps.country_id)",
        "left join portal_student_clazzes psc on (psc.clazz_id = po_class.id)",
        # The "exists" clause is so that portal_learners without runs don't count towards "# students started"
        "left join portal_learners pl on (pl.offering_id = po.id and pl.student_id = psc.student_id
          and exists (select 1 from portal_runs r2 where r2.learner_id = pl.id))",
        "left join portal_students pst on (pst.id = pl.student_id)",
        "left join users stu on (stu.id = pst.user_id)",
        "left join portal_runs run on (run.learner_id = pl.id)",
      ]],
      group_by: "at.id",
      order_by: [{"subject_area", :asc}]
    }
    |> apply_filters(report_filter, user)
  end

  defp apply_filters(report_query = %ReportQuery{},
      %ReportFilter{country: country, state: state, subject_area: subject_area,
        exclude_internal: exclude_internal, start_date: start_date, end_date: end_date}, %User{portal_server: portal_server}) do
    join = []
    # For queries starting from schools, we don't need the scope filter since we're joining to subject areas
    # For queries starting from admin_tags, we need the scope filter
    where = if report_query.from == "admin_tags at" do
      ["at.scope = 'subject_areas'"]
    else
      []
    end

    where = exclude_internal_accounts(exclude_internal, where, portal_server)

    # Country filter - convert "(Unknown)" back to NULL
    {join, where} = if have_filter?(country) do
      where_clause = if Enum.member?(country, -1) do
        # -1 represents "(Unknown)" - check for NULL
        other_countries = Enum.reject(country, fn c -> c == -1 end)
        if length(other_countries) > 0 do
          "(ps.country_id IS NULL OR ps.country_id IN #{list_to_in(other_countries)})"
        else
          "ps.country_id IS NULL"
        end
      else
        "ps.country_id IN #{list_to_in(country)}"
      end
      {join, [where_clause | where]}
    else
      {join, where}
    end

    # State filter - convert "(Unknown)" back to NULL
    {join, where} = if have_filter?(state) do
      where_clause = if Enum.member?(state, "(Unknown)") do
        # "(Unknown)" represents NULL state
        other_states = Enum.reject(state, fn s -> s == "(Unknown)" end)
        if length(other_states) > 0 do
          "(ps.state IS NULL OR ps.state IN #{string_list_to_single_quoted_in(other_states)})"
        else
          "ps.state IS NULL"
        end
      else
        "ps.state IN #{string_list_to_single_quoted_in(state)}"
      end
      {join, [where_clause | where]}
    else
      {join, where}
    end

    # Subject area filter
    {join, where} = if have_filter?(subject_area) do
      {join, ["at.id IN #{list_to_in(subject_area)}" | where]}
    else
      {join, where}
    end

    where = where
    |> apply_start_date(start_date)
    |> apply_end_date(end_date)

    ReportQuery.update_query(report_query, join: join, where: where)
  end
end
