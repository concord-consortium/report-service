defmodule ReportServer.Reports.Athena.LearnerData do
  require Logger

  # NOTE: no struct definition but the shape of the learner data is a map whose keys are generated UUIDs
  # used to group learners by their runnable_url and the values are lists of maps representing the learner data

  import ReportServer.Reports.ReportUtils

  alias ReportServer.Accounts.User
  alias ReportServer.{PortalDbs, AthenaDB}
  alias ReportServer.Reports.{ReportFilter, ReportQuery}

  def fetch_and_upload(report_filter = %ReportFilter{}, user = %User{}) do
    with {:ok, learner_data} <- fetch(report_filter, user),
         {:ok, learner_data} <- upload(learner_data) do
      {:ok, learner_data}
    else
      error -> error
    end
  end

  def fetch(%ReportFilter{cohort: cohort, school: school, teacher: teacher, assignment: assignment, permission_form: permission_form,
        exclude_internal: exclude_internal, start_date: start_date, end_date: end_date}, user = %User{}) do
    portal_query = %ReportQuery{
      cols: [
        {"DISTINCT rl.learner_id", "learner_id"},
        {"rl.student_id", "student_id"},
        {"rl.class_id", "class_id"},
        {"rl.class_name", "class"},
        {"rl.school_name", "school"},
        {"rl.user_id", "user_id"},
        {"rl.offering_id", "offering_id"},
        {"rl.username", "username"},
        {"rl.student_name", "student_name"},
        {"rl.last_run", "last_run"},
        {"rl.teachers_id", "teachers_id"},
        {"rl.permission_forms_id", "permission_forms_id"},
        {"ea.url", "runnable_url"},
        {"pl.secure_key", "secure_key"},
        {"pl.created_at", "created_at"}
      ],
      from: "report_learners rl",
      join: [[
        "JOIN portal_learners pl ON (rl.learner_id = pl.id)",
        "JOIN portal_offerings po ON (po.id = rl.offering_id)",
        "JOIN external_activities ea on (po.runnable_type = 'ExternalActivity' AND po.runnable_id = ea.id)",
        "JOIN portal_student_clazzes psc ON (psc.student_id = rl.student_id)",
        "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id AND rl.class_id = ptc.clazz_id)",
        "LEFT JOIN portal_runs run on (run.learner_id = pl.id)",
      ]]
    }

    join = []
    where = []

    allowed_project_ids = PortalDbs.get_allowed_project_ids(user)
    {join, where} = if allowed_project_ids == :all do
      {join, where}
    else
      {
        [
          "join admin_cohort_items aci_teacher on (aci_teacher.item_type = 'Portal::Teacher' AND aci_teacher.item_id = ptc.teacher_id)",
          "join admin_cohort_items aci_assignment on (aci_assignment.item_type = 'ExternalActivity' AND aci_assignment.item_id = po.runnable_id)",
          "join admin_cohorts ac_teacher ON (ac_teacher.id = aci_teacher.admin_cohort_id)",
          "join admin_cohorts ac_assignment ON (ac_assignment.id = aci_assignment.admin_cohort_id)"
          | join
        ],
        [
          "ac_teacher.project_id IN #{list_to_in(allowed_project_ids)}",
          "ac_assignment.project_id IN #{list_to_in(allowed_project_ids)}"
          | where
        ]
      }
    end

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
          "pspf.portal_permission_form_id IN #{list_to_in(permission_form)} AND pspf.signed = true"
          | where
        ]
      }
    else
      {join, where}
    end

    {join, where} = if exclude_internal do
      {
        [
          "JOIN portal_teachers pt ON (pt.id = ptc.teacher_id)",
          "JOIN users u ON u.id = pt.user_id"
          | join,
        ],
        [
          "u.email NOT LIKE '%@concord.org'"
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
      |> apply_start_date(start_date)
      |> apply_end_date(end_date)

    with {:ok, portal_query} <- ReportQuery.update_query(portal_query, join: join, where: where),
         {:ok, sql} <- ReportQuery.get_sql(portal_query),
         {:ok, result} <- PortalDbs.query(user.portal_server, sql),
         {:ok, learner_data} <- map_learner_data(result, user) do
      {:ok, learner_data}
    else
      error -> error
    end
  end

  def upload(learner_data) do
    learner_data
      |> Map.keys()
      |> Enum.each(fn query_id ->
        path = "learners/#{query_id}/#{UUID.uuid4()}.json"
        contents = learner_data[query_id]
          |> Enum.map(&(Jason.encode!/1))
          |> Enum.join("\n")
        Logger.info("Uploading learners to #{path}")
        AthenaDB.put_file_contents(path, contents)
      end)

    {:ok, learner_data}
  end

  defp map_learner_data(result = %MyXQL.Result{}, user = %User{}) do
    rows = PortalDbs.map_columns_on_rows(result)

    teacher_ids = get_unique_ids(rows, :teachers_id)
    permission_form_ids = get_unique_ids(rows, :permission_forms_id)

    with {:ok, rows} <- ensure_not_empty(rows, "No learner data found"),
         {:ok, teacher_map} <- get_teacher_map(teacher_ids, user),
         {:ok, permission_form_map } <- get_permission_form_map(permission_form_ids, user) do

      result = rows
        |> Enum.map(fn row ->
          teachers = get_info_by_ids(teacher_map, row.teachers_id)
          permission_forms = get_info_by_ids(permission_form_map, row.permission_forms_id)
          run_remote_endpoint = "https://#{user.portal_server}/dataservice/external_activity_data/#{row.secure_key}"

          # use same format as api
          %{
            student_id: row.student_id,
            learner_id: row.learner_id,
            class_id: row.class_id,
            class: row.class,
            school: row.school,
            user_id: row.user_id,
            offering_id: row.offering_id,
            permission_forms: permission_forms,
            username: row.username,
            student_name: row.student_name,
            last_run: row.last_run,
            run_remote_endpoint: run_remote_endpoint,
            runnable_url: row.runnable_url,
            teachers: teachers,
            created_at: row.created_at
          }
        end)
        |> group_by_runnable_url_with_uuid()

      {:ok, result}

    else
      error -> error
    end
  end

  defp get_unique_ids(rows, key) do
    rows
      |> Enum.map(&(split_id_list(Map.get(&1, key, ""))))
      |> List.flatten()
      |> Enum.reject(&(String.length(&1 || "") == 0))
      |> Enum.uniq()
  end

  def get_info_by_ids(_id_map, ""), do: []
  def get_info_by_ids(_id_map, nil), do: []
  def get_info_by_ids(id_map, ids) do
    ids
    |> split_id_list()
    |> Enum.map(&Map.get(id_map, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp split_id_list(id_list) do
    id_list
      |> String.split(",")
  end

  def key_by_id(maps) do
    Enum.reduce(maps, %{}, fn map, acc ->
      Map.put(acc, map[:id], map)
    end)
  end

  defp get_teacher_map([], _user = %User{}), do: {:ok, %{}}
  defp get_teacher_map(teacher_ids, user = %User{}) do
    portal_query = %ReportQuery{
      cols: [
        {"pt.id", "user_id"},  # note: not a bug, the portal api returns the teacher_id as user_id
        {"CONCAT(u.first_name, ' ', u.last_name)", "name"},
        {"pd.name", "district"},
        {"pd.state", "state"},
        {"u.email", "email"}
      ],
      from: "portal_teachers pt",
      join: [[
        "JOIN users u ON (u.id = pt.user_id)",
        "left join portal_school_memberships psm on (psm.member_id = pt.id and psm.member_type = 'Portal::Teacher')",
        "left join portal_schools ps on (ps.id = psm.school_id)",
        "left join portal_districts pd on (pd.id = ps.district_id)",
      ]],
      where: [
        "pt.id IN #{numeric_string_list_to_in(teacher_ids)}"
      ]
    }

    with {:ok, sql} <- ReportQuery.get_sql(portal_query),
         {:ok, result} <- PortalDbs.query(user.portal_server, sql) do

      teacher_map = result
        |> PortalDbs.map_columns_on_rows()
        |> Enum.reduce(%{}, fn cur, acc ->
          Map.put(acc, "#{cur[:user_id]}", cur)
        end)

      {:ok, teacher_map}
    else
      error -> error
    end
  end

  defp get_permission_form_map([], _user = %User{}), do: {:ok, %{}}
  defp get_permission_form_map(permission_form_ids, user = %User{}) do
    portal_query = %ReportQuery{
      cols: [
        {"ppf.id", "id"},
        {"ppf.name", "name"},
        {"ap.name", "project_name"},
      ],
      from: "portal_permission_forms ppf",
      join: [[
        "LEFT JOIN admin_projects ap ON (ppf.project_id = ap.id)",
      ]],
      where: [
        "ppf.id IN #{numeric_string_list_to_in(permission_form_ids)}"
      ]
    }

    with {:ok, sql} <- ReportQuery.get_sql(portal_query),
         {:ok, result} <- PortalDbs.query(user.portal_server, sql) do

      permission_form_map = result.rows
        |> Enum.reduce(%{}, fn [id, name, project_name], acc ->
          value = if project_name != nil do
            "#{project_name}: #{name}"
          else
            name
          end
          Map.put(acc, "#{id}", value)
        end)

      {:ok, permission_form_map}
    else
      error -> error
    end
  end

  def group_by_runnable_url_with_uuid(rows) do
    Enum.reduce(rows, %{url_to_uuid: %{}, grouped_rows: %{}}, fn row, %{url_to_uuid: url_to_uuid, grouped_rows: grouped_rows} ->
      runnable_url = Map.get(row, :runnable_url)

      {url_to_uuid, uuid} = if uuid = Map.get(url_to_uuid, runnable_url) do
        {url_to_uuid, uuid}
      else
        uuid = UUID.uuid4()
        {Map.put(url_to_uuid, runnable_url, uuid), uuid}
      end

      grouped_rows =
        Map.update(grouped_rows, uuid, [row], fn existing_rows ->
          [row | existing_rows]
        end)

      %{url_to_uuid: url_to_uuid, grouped_rows: grouped_rows}
    end)
    |> Map.get(:grouped_rows)
    |> Enum.map(fn {uuid, rows} ->
      {uuid, Enum.reverse(rows)}
    end)
    |> Enum.into(%{})
  end

  # to use during development/debugging
  def get_fake_learner_data() do
    {:ok, %{
      "3a27cdb4-1828-4096-ad74-1748d3170c2d" => [
        %{
          username: "done",
          class: "Doug's Test Class",
          school: "Buckland-shelburne Reg",
          teachers: [
            %{
              name: "Doug Martin",
              state: "MA",
              user_id: 264,
              email: "dmartin@concord.org",
              district: "Mohawk Trail"
            }
          ],
          permission_forms: ["Test: Test",
           "Precipitating Change: Coastal Erosion (AK): TEST", "Test: Test Form2"],
          run_remote_endpoint: "https://learn.concord.org/dataservice/external_activity_data/6040b7fe-478f-499a-8c04-4d03c67a2486",
          student_id: 73333,
          learner_id: 213661,
          class_id: 481,
          user_id: 77701,
          offering_id: 16798,
          student_name: "DougTest One",
          last_run: nil,
          runnable_url: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org%2Fapi%2Fv1%2Factivities%2F8806.json",
          created_at: ~N[2018-06-20 10:03:51]
        }
      ],
      "aa4a2fc5-936c-44fc-bb77-21dfe8f6bebc" => [
        %{
          username: "done",
          class: "Doug's Test Class",
          school: "Buckland-shelburne Reg",
          teachers: [
            %{
              name: "Doug Martin",
              state: "MA",
              user_id: 264,
              email: "dmartin@concord.org",
              district: "Mohawk Trail"
            }
          ],
          permission_forms: ["Test: Test",
           "Precipitating Change: Coastal Erosion (AK): TEST", "Test: Test Form2"],
          run_remote_endpoint: "https://learn.concord.org/dataservice/external_activity_data/073594bf-4032-4b0d-bb50-721538363759",
          student_id: 73333,
          learner_id: 211738,
          class_id: 481,
          user_id: 77701,
          offering_id: 16522,
          student_name: "DougTest One",
          last_run: ~N[2024-12-16 14:31:57],
          runnable_url: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org%2Fapi%2Fv1%2Factivities%2F7247.json",
          created_at: ~N[2018-05-29 18:36:33]
        },
        %{
          username: "jstudent",
          class: "Doug's Test Class",
          school: "Buckland-shelburne Reg",
          teachers: [
            %{
              name: "Doug Martin",
              state: "MA",
              user_id: 264,
              email: "dmartin@concord.org",
              district: "Mohawk Trail"
            }
          ],
          permission_forms: [],
          run_remote_endpoint: "https://learn.concord.org/dataservice/external_activity_data/fac6ca0a-0105-4de2-98d5-b30b04bb84e4",
          student_id: 50,
          learner_id: 212105,
          class_id: 481,
          user_id: 104,
          offering_id: 16522,
          student_name: "Jen Student",
          last_run: ~N[2018-05-30 18:09:51],
          runnable_url: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org%2Fapi%2Fv1%2Factivities%2F7247.json",
          created_at: ~N[2018-05-30 18:09:10]
        },
        %{
          username: "dtwo",
          class: "Doug's Test Class",
          school: "Buckland-shelburne Reg",
          teachers: [
            %{
              name: "Doug Martin",
              state: "MA",
              user_id: 264,
              email: "dmartin@concord.org",
              district: "Mohawk Trail"
            }
          ],
          permission_forms: [],
          run_remote_endpoint: "https://learn.concord.org/dataservice/external_activity_data/cf8e5bce-04ab-4030-9ddf-8b1cc16a70e4",
          student_id: 73334,
          learner_id: 212110,
          class_id: 481,
          user_id: 77702,
          offering_id: 16522,
          student_name: "DougTest Two",
          last_run: ~N[2018-05-30 18:19:05],
          runnable_url: "https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.concord.org%2Fapi%2Fv1%2Factivities%2F7247.json",
          created_at: ~N[2018-05-30 18:17:19]
        }
      ]
    }}
  end

end
