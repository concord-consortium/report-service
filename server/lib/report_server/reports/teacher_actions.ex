defmodule ReportServer.Reports.TeacherActions do
  use ReportServer.Reports.Report, type: :athena

  alias ReportServer.PortalDbs

  def get_query(report_filter = %ReportFilter{start_date: start_date, end_date: end_date}, user = %User{}) do

    with {:ok, usernames} <- get_usernames(report_filter, user),
         {:ok, activities } <- get_activities(report_filter, user) do

      have_usernames = !Enum.empty?(usernames)
      have_activities = !Enum.empty?(activities)

      if have_usernames || have_activities do
        where = []

        where = if have_usernames do
          ["log.username IN #{string_list_to_single_quoted_in(usernames)}" | where]
        else
          where
        end

        where = if have_activities do
          ["log.activity IN #{string_list_to_single_quoted_in(activities)}" | where]
        else
          where
        end

        where = where
          |> apply_log_start_date(start_date)
          |> apply_log_end_date(end_date)

        {:ok, %ReportQuery{
          cols: ReportQuery.get_log_cols(),
          from: "\"#{ReportQuery.get_log_db_name()}\".\"logs_by_time\" log",
          where: where
        }}
      else
        {:error, "No teachers or activities found to match the requested filter(s)."}
      end
    else
      error -> error
    end
  end

  defp get_usernames(%ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment}, user = %User{portal_server: portal_server}) do
    portal_query = %ReportQuery{
      # logged usernames are in the form <userid>@<portal>, eg 1777@learn.concord.org
      cols: [{"DISTINCT pt.user_id", "user_id"}, {"CONCAT(pt.user_id,'@#{portal_server}')", "username"}],
      from: "portal_teachers pt",
      join: [[
        "JOIN portal_teacher_clazzes ptc on (ptc.teacher_id = pt.id)",
        "JOIN portal_clazzes pc on (pc.id = ptc.clazz_id)",
        "JOIN portal_offerings po on (po.clazz_id = pc.id)",
        "LEFT JOIN portal_school_memberships psm ON (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')"
      ]]
    }

    join = []
    where = []

    {join, where} = if have_filter?(cohort) do
      {
        ["LEFT JOIN admin_cohort_items aci_teacher ON (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = pt.id)" | join],
        ["aci_teacher.admin_cohort_id IN #{list_to_in(cohort)}" | where]
      }
    else
      {join, where}
    end

    where = where
      |> apply_where_filter(school, "psm.school_id IN #{list_to_in(school)}")
      |> apply_where_filter(teacher, "pt.id IN #{list_to_in(teacher)}")
      |> apply_where_filter(assignment, "po.runnable_id IN #{list_to_in(assignment)}")

    with {:ok, portal_query} <- ReportQuery.update_query(portal_query, join: join, where: where),
         {:ok, sql} <- ReportQuery.get_sql(portal_query),
         {:ok, result} <- PortalDbs.query(user.portal_server, sql) do

      usernames = result.rows |> Enum.map(fn [_id, username] -> username end)

      {:ok, usernames}
    end
  end

  defp get_activities(%ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment}, user = %User{}) do
    portal_query = %ReportQuery{
      cols: [{"DISTINCT ea.id", "id"}, {"ea.url", "url"}],
      from: "external_activities ea",
      join: [[
        "join portal_offerings po on (po.runnable_id = ea.id)",
        "join portal_clazzes pc on (pc.id = po.clazz_id)",
        "join portal_teacher_clazzes ptc on (ptc.clazz_id = pc.id)",
        "join portal_teachers pt on (pt.id = ptc.teacher_id)",
        "left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')",
        "left join portal_schools ps on (ps.id = psm.school_id)",
        "left join report_learners rl on (rl.class_id = pc.id and rl.runnable_id = ea.id and rl.last_run is not null)"
      ]]
    }

    join = []
    where = []

    {join, where} = if have_filter?(cohort) do
      {
        [
          "left join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id)",
          "left join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id)"
          | join
        ],
        [
          "aci_teacher.admin_cohort_id in #{list_to_in(cohort)}",
          "aci_assignment.admin_cohort_id in #{list_to_in(cohort)} and aci_assignment.item_id = po.runnable_id"
          | where
        ]
      }
    else
      {join, where}
    end

    where = where
      |> apply_where_filter(school, "psm.school_id IN #{list_to_in(school)}")
      |> apply_where_filter(teacher, "pt.id IN #{list_to_in(teacher)}")
      |> apply_where_filter(assignment, "po.runnable_id IN #{list_to_in(assignment)}")

    with {:ok, portal_query} <- ReportQuery.update_query(portal_query, join: join, where: where),
         {:ok, sql} <- ReportQuery.get_sql(portal_query),
         {:ok, result} <- PortalDbs.query(user.portal_server, sql) do

      activities = result.rows |> Enum.reduce([], fn [_id, uri], acc ->
        url = URI.parse(uri)

        # first check for pre-LARA 2 urls
        case matches_sequence_or_activity(url.path) do
          [_, type, id] ->
            # pre-LARA 2 activities non-AP activities logged the activity as type: ID
            [type_and_id(type, id) | acc]

          _ ->
            # AP logs the url passed in the sequence or activity param to AP.  Since we can't be sure of the domain of
            # the AP we verify that the param looks like an url to the sequence or activity structure api endpoint.
            # We also add the older pre-LARA 2 activity/sequence: ID as this may be an activity that was migrated
            # from LARA and has logs in the older format.
            params = Plug.Conn.Query.decode(url.query || "")
            sequence_or_activity = params["sequence"] || params["activity"]
            case matches_sequence_or_activity(sequence_or_activity) do
              [_, type, id] ->
                [sequence_or_activity, type_and_id(type, id) | acc]

              _ ->
                [uri | acc]
            end
        end
      end)

      {:ok, activities}
    end
  end

  defp matches_sequence_or_activity(nil), do: nil
  defp matches_sequence_or_activity(path), do: Regex.run(~r/\/(sequences|activities)\/(\d+)/, path)

  defp type_and_id("sequences", id), do: "sequence: #{id}"
  defp type_and_id(_, id), do: "activity: #{id}"
end
