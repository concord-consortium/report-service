defmodule ReportServer.Reports.Athena.SharedQueries do

  alias ReportServer.{ReportService, PortalReport}
  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.{ReportUtils, ReportFilter, ReportQuery}

  # NOTE: this module is a bit of a mess, but it's a direct port of the old Athena query generation code
  # so it looks a like a lot like JavaScript in Elixir.

  def get_usage_or_answers_athena_query(report_type, report_filter = %ReportFilter{}, resource_data, auth_domain) do
    has_resource = Enum.any?(resource_data, &(not is_nil(&1.resource)))

    if has_resource do
      generate_resource_sql(report_type, report_filter, resource_data, auth_domain)
    else
      generate_no_resource_sql(report_filter, resource_data)
    end
  end

  def generate_resource_sql(report_type, %ReportFilter{hide_names: hide_names}, resource_data, auth_domain) do

    # The source_key map is just used to add an answersSourceKey to the interactive urls
    # It might be possible there will be some answers with different source_keys but after the LARA migration to AP this is probably not needed
    answer_maps = "map_agg(a.question_id, a.answer) kv1, map_agg(a.question_id, a.submitted) submitted, map_agg(a.question_id, a.source_key) source_key"

    # the resource data is reduced over to fill this map which is then set to query_info and used to generate the sql
    query_info_acc = %{
      denormalized_resources: [],
      activities_queries: [],
      grouped_answer_queries: [],
      learner_and_answer_queries: [],
      activities_tables: [],
      learners_and_answers_tables: [],
      resource_columns: [],
    }

    query_info = resource_data
      |> Enum.with_index(1)
      |> Enum.reduce(query_info_acc, fn {%{runnable_url: runnable_url, query_id: query_id, resource: resource, denormalized: denormalized}, res_index}, acc ->
        %{
          denormalized_resources: denormalized_resources,
          activities_queries: activities_queries,
          grouped_answer_queries: grouped_answer_queries,
          learner_and_answer_queries: learner_and_answer_queries,
          activities_tables: activities_tables,
          learners_and_answers_tables: learners_and_answers_tables,
          resource_columns: resource_columns
        } = acc

        {url, name} =
          case resource do
            nil -> {runnable_url, runnable_url}
            _ -> {Map.get(resource, "url"), Map.get(resource, "name")}
          end

        escaped_url = String.replace(url, ~r/[^a-z0-9]/, "-")
        student_name_col = if hide_names, do: "student_id as student_name", else: "student_name"

        denormalized_resources = [denormalized | denormalized_resources]

        grouped_answer_queries = [
          """
          grouped_answers_#{res_index} AS (
            SELECT l.run_remote_endpoint remote_endpoint, #{answer_maps}
            FROM \"report-service\".\"learners\" l
            LEFT JOIN \"report-service\".\"partitioned_answers\" a
            ON (l.query_id = '#{ReportUtils.escape_single_quote(query_id)}' AND l.run_remote_endpoint = a.remote_endpoint)
            WHERE a.escaped_url = '#{ReportUtils.escape_single_quote(escaped_url)}'
            GROUP BY l.run_remote_endpoint
          )
          """
          | grouped_answer_queries
        ]

        learner_and_answer_queries = [
          """
          learners_and_answers_#{res_index} AS (
            SELECT run_remote_endpoint remote_endpoint, runnable_url as resource_url, learner_id, student_id, user_id, offering_id, #{student_name_col}, #{maybe_hash_username(hide_names, "username", false)}, school, class, class_id, permission_forms, last_run, teachers, grouped_answers_#{res_index}.kv1 kv1, grouped_answers_#{res_index}.submitted submitted, grouped_answers_#{res_index}.source_key source_key,
            IF (kv1 is null, 0, cardinality(array_intersect(map_keys(kv1), map_keys(activities_#{res_index}.questions)))) num_answers,
            cardinality(filter(map_values(activities_#{res_index}.questions), x -> x.required=TRUE)) num_required_questions,
            IF (submitted is null, 0, cardinality(filter(map_values(submitted), x -> x=TRUE))) num_required_answers
            FROM \"report-service\".\"learners\" l
            LEFT JOIN activities_#{res_index} ON 1=1
            LEFT JOIN grouped_answers_#{res_index}
            ON l.run_remote_endpoint = grouped_answers_#{res_index}.remote_endpoint
            WHERE l.query_id = '#{ReportUtils.escape_single_quote(query_id)}'
          )
          """
          | learner_and_answer_queries
        ]

        activities_queries = [
          "activities_#{res_index} AS (SELECT *, cardinality(questions) AS num_questions FROM \"report-service\".\"activity_structure\" WHERE structure_id = '#{ReportUtils.escape_single_quote(query_id)}')"
          | activities_queries
        ]

        activities_tables = ["activities_#{res_index}" | activities_tables]
        learners_and_answers_tables = ["learners_and_answers_#{res_index}" | learners_and_answers_tables]

        resource_columns = [
          # note: this is flattened in the final result
          [
            %{name: "res_#{res_index}_name", value: "'#{ReportUtils.escape_single_quote(name)}'"},
            %{name: "res_#{res_index}_offering_id", value: "learners_and_answers_#{res_index}.offering_id"},
            %{name: "res_#{res_index}_learner_id", value: "learners_and_answers_#{res_index}.learner_id"},
            %{name: "res_#{res_index}_remote_endpoint", value: "learners_and_answers_#{res_index}.remote_endpoint"},
            %{name: "res_#{res_index}_resource_url", value: "learners_and_answers_#{res_index}.resource_url"},
            %{name: "res_#{res_index}_last_run", value: "learners_and_answers_#{res_index}.last_run"},
            %{name: "res_#{res_index}_total_num_questions", value: "activities_#{res_index}.num_questions"},
            %{name: "res_#{res_index}_total_num_answers", value: "learners_and_answers_#{res_index}.num_answers"},
            %{name: "res_#{res_index}_total_percent_complete", value: "round(100.0 * learners_and_answers_#{res_index}.num_answers / activities_#{res_index}.num_questions, 1)"},
            %{name: "res_#{res_index}_num_required_questions", value: "learners_and_answers_#{res_index}.num_required_questions"},
            %{name: "res_#{res_index}_num_required_answers", value: "learners_and_answers_#{res_index}.num_required_answers"}
          ]
          | resource_columns
        ]

        %{acc |
          denormalized_resources: denormalized_resources,
          activities_queries: activities_queries,
          grouped_answer_queries: grouped_answer_queries,
          learner_and_answer_queries: learner_and_answer_queries,
          activities_tables: activities_tables,
          learners_and_answers_tables: learners_and_answers_tables,
          resource_columns: resource_columns
        }
      end)
    # reverse the order of the lists
    |> then(fn %{
        denormalized_resources: denormalized_resources,
        activities_queries: activities_queries,
        grouped_answer_queries: grouped_answer_queries,
        learner_and_answer_queries: learner_and_answer_queries,
        activities_tables: activities_tables,
        learners_and_answers_tables: learners_and_answers_tables,
        resource_columns: resource_columns
      } ->
      %{
        denormalized_resources: Enum.reverse(denormalized_resources),
        activities_queries: Enum.reverse(activities_queries),
        grouped_answer_queries: Enum.reverse(grouped_answer_queries),
        learner_and_answer_queries: Enum.reverse(learner_and_answer_queries),
        activities_tables: Enum.reverse(activities_tables),
        learners_and_answers_tables: Enum.reverse(learners_and_answers_tables),
        resource_columns: Enum.reverse(resource_columns) |> List.flatten()
      }
    end)

    # extract the values from the map
    %{
      denormalized_resources: denormalized_resources,
      activities_queries: activities_queries,
      grouped_answer_queries: grouped_answer_queries,
      learner_and_answer_queries: learner_and_answer_queries,
      activities_tables: activities_tables,
      learners_and_answers_tables: learners_and_answers_tables,
      resource_columns: resource_columns
    } = query_info

    query_ids = resource_data |> Enum.map(&(&1.query_id))

    unique_user_class_query =
      """
      unique_user_class AS
        (SELECT class_id,
          user_id,
          arbitrary(primary_user_id) as primary_user_id,
          arbitrary(student_id) as student_id,
          arbitrary(#{if hide_names, do: "student_id", else: "student_name"}) as student_name,
          arbitrary(#{maybe_hash_username(hide_names, "username", true)}) as username,
          arbitrary(school) as school,
          arbitrary(class) as class,
          arbitrary(permission_forms) as permission_forms,
          array_join(transform(arbitrary(teachers), teacher -> teacher.user_id), ',') AS teacher_user_ids,
          array_join(transform(arbitrary(teachers), teacher -> teacher.name), ',') AS teacher_names,
          array_join(transform(arbitrary(teachers), teacher -> teacher.district), ',') AS teacher_districts,
          array_join(transform(arbitrary(teachers), teacher -> teacher.state), ',') AS teacher_states,
          array_join(transform(arbitrary(teachers), teacher -> teacher.email), ',') AS teacher_emails FROM \"report-service\".\"learners\" l WHERE l.query_id IN #{ReportUtils.string_list_to_single_quoted_in(query_ids)}
          GROUP BY class_id, user_id
        )
      """

    # allows for the left joins of activities even if one or more are empty
    one_row_table_for_join = "one_row_table_for_join as (SELECT null AS empty)"

    default_columns = [
      "student_id",
      "user_id",
      "primary_user_id",
      "student_name",
      "username",
      "school",
      "class",
      "class_id",
      "permission_forms",
      "teacher_user_ids",
      "teacher_names",
      "teacher_districts",
      "teacher_states",
      "teacher_emails"
    ] |> Enum.map(fn col -> %{name: col, value: col} end)
    all_columns = default_columns ++ resource_columns

    grouped_answers = Enum.join(grouped_answer_queries, ",\n\n")
    learners_and_answers = Enum.join(learner_and_answer_queries, ",\n\n")
    activities = Enum.join(activities_queries, ",\n\n")
    selects = []
    questions_columns = []

    {selects, questions_columns} = if report_type == :answers do
      questions_columns = denormalized_resources
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {denormalized_resource, activity_index}, acc ->
          if denormalized_resource do
            questions = Map.get(denormalized_resource, :questions, %{})
            denormalized_resource
            |> Map.get(:question_order)
            |> Enum.reduce(acc, fn question_id, acc2 ->
              question = Map.get(questions, question_id)
              question_columns = get_columns_for_question(question_id, question, denormalized_resource, auth_domain, activity_index)
              [[question_columns] | acc2]
            end)
          else
            acc
          end
        end)
        |> Enum.reverse()
        |> List.flatten()

      all_columns = all_columns ++ questions_columns

      header_row_select =
        all_columns
        |> Enum.with_index()
        |> Enum.map(fn {column, idx} ->
          value = if idx == 0, do: "'Prompt'", else: Map.get(column, :header) || "null"
          "#{value} AS #{Map.get(column, :name)}"
        end)
        |> Enum.join(",\n  ")

      secondary_header_select =
        all_columns
        |> Enum.with_index()
        |> Enum.map(fn {column, idx} ->
          value = if idx == 0, do: "'Correct answer'", else: Map.get(column, :second_header) || "null"
          "#{value} AS #{Map.get(column, :name)}"
        end)
        |> Enum.join(",\n  ")

      joins = activities_queries
        |> Enum.with_index(1)
        |> Enum.map(fn {_, index} -> "LEFT JOIN activities_#{index} ON 1=1" end)
        |> Enum.join("\n")

      selects = selects ++ [
        """
        SELECT
          #{header_row_select}
        FROM one_row_table_for_join
        #{joins}
        """,

        """
        SELECT
          #{secondary_header_select}
        FROM one_row_table_for_join
        #{joins}
        """
      ]

      {selects, questions_columns}
    else
      {selects, questions_columns}
    end

    selects = selects ++ [
      """
      SELECT
        unique_user_class.student_id,
        unique_user_class.user_id,
        unique_user_class.primary_user_id,
        unique_user_class.student_name,
        unique_user_class.username,
        unique_user_class.school,
        unique_user_class.class,
        unique_user_class.class_id,
        unique_user_class.permission_forms,
        unique_user_class.teacher_user_ids,
        unique_user_class.teacher_names,
        unique_user_class.teacher_districts,
        unique_user_class.teacher_states,
        unique_user_class.teacher_emails,
        #{Enum.map(resource_columns, &select_from_column/1) |> Enum.join(",\n")}#{if length(questions_columns) > 0, do: ",", else: ""}
        #{Enum.map(questions_columns, &select_from_column/1) |> Enum.join(",\n")}
      FROM unique_user_class
      #{Enum.map(activities_tables, fn t -> "LEFT JOIN #{t} ON 1=1 -- activities may be empty so we can't fully join them and they don't have any common columns with unique_user_class thus the 1=1" end) |> Enum.join("\n")}
      #{Enum.map(learners_and_answers_tables, fn t -> "LEFT JOIN #{t} ON unique_user_class.user_id = #{t}.user_id AND unique_user_class.class_id = #{t}.class_id" end) |> Enum.join("\n")}
      """
    ]

    {:ok, %ReportQuery{raw_sql: """
      WITH #{Enum.join([activities, grouped_answers, learners_and_answers, unique_user_class_query, one_row_table_for_join], ",\n\n")}
      #{Enum.join(selects, "\nUNION ALL\n")}
      ORDER BY class NULLS FIRST, username
      """
    }}
  end

  def generate_no_resource_sql(%ReportFilter{hide_names: hide_names}, resource_data) do
    query_ids = resource_data |> Enum.map(&(&1.query_id))

    metadata_column_names = [
      "student_id",
      "user_id",
      "primary_user_id",
      "student_name",
      "username",
      "school",
      "class",
      "class_id",
      "learner_id",
      "resource_url",
      "last_run",
      "permission_forms"
    ]

    metadata_columns_for_grouping =
      Enum.map(metadata_column_names, fn md ->
        cond do
          md == "student_name" and hide_names ->
            %{name: md, value: "arbitrary(l.student_id)"}

          md == "username" ->
            %{name: md, value: "arbitrary(#{maybe_hash_username(hide_names, "l.username", true)})"}

          md == "resource_url" ->
            %{name: md, value: "null"}

          true ->
            %{name: md, value: "arbitrary(l.#{md})"}
        end
      end)

    grouping_select_metadata_columns =
      metadata_columns_for_grouping
      |> Enum.map(&select_from_column/1)
      |> Enum.join(", ")

    grouping_select = "l.run_remote_endpoint remote_endpoint, #{grouping_select_metadata_columns}, arbitrary(l.teachers) teachers"

    teacher_metadata_column_definitions = [
      {"teacher_user_ids", "user_id"},
      {"teacher_names", "name"},
      {"teacher_districts", "district"},
      {"teacher_states", "state"},
      {"teacher_emails", "email"}
    ]

    metadata_columns =
      Enum.map(metadata_column_names, fn md ->
        %{name: md, value: md}
      end)

    teacher_metadata_columns =
      Enum.map(teacher_metadata_column_definitions, fn {column_name, field} ->
        %{name: column_name, value: "array_join(transform(teachers, teacher -> teacher.#{field}), ',')"}
      end)

    all_columns =
      metadata_columns ++
        [%{name: "remote_endpoint", value: "remote_endpoint"}] ++
        teacher_metadata_columns

    select_fields = Enum.map(all_columns, &select_from_column/1) |> Enum.join(",\n  ")
    in_query_ids = ReportUtils.string_list_to_single_quoted_in(query_ids)

    {:ok, %ReportQuery{raw_sql: """
      SELECT #{select_fields}
      FROM
      ( SELECT #{grouping_select}
        FROM "report-service"."learners" l
        WHERE l.query_id IN #{in_query_ids}
        GROUP BY l.run_remote_endpoint )
      """}}
  end

  def get_columns_for_question(question_id, question, denormalized_resource, auth_domain, activity_index) do
    source_key = AthenaConfig.get_source_key()
    type = Map.get(question, :type)
    is_required = Map.get(question, :required) || false

    activities_table = "activities_#{activity_index}"
    learners_and_answers_table = "learners_and_answers_#{activity_index}"

    prompt_header = "#{activities_table}.questions['#{question_id}'].prompt"
    column_prefix = "res_#{activity_index}_#{question_id}"

    portal_report_url = PortalReport.get_url()
    firebase_app = ReportService.get_firebase_app()

    model_url = fn answers_source_key ->
      "CONCAT('#{portal_report_url}" <>
        "?auth-domain=#{URI.encode_www_form(auth_domain)}" <>
        "&firebase-app=#{firebase_app}" <>
        "&sourceKey=#{source_key}" <>
        "&iframeQuestionId=#{question_id}" <>
        "&class=#{URI.encode_www_form("#{auth_domain}/api/v1/classes/")}'," <>
        " CAST(#{learners_and_answers_table}.class_id AS VARCHAR), " <>
        "'&offering=#{URI.encode_www_form("#{auth_domain}/api/v1/offerings/")}'," <>
        " CAST(#{learners_and_answers_table}.offering_id AS VARCHAR), " <>
        "'&studentId='," <>
        " CAST(#{learners_and_answers_table}.user_id AS VARCHAR), " <>
        "'&answersSourceKey='," <>
        " #{answers_source_key})"
    end

    # returns url when there is an answer present
    conditional_model_url = fn answer, answers_source_key ->
      "CASE WHEN #{answer} IS NULL THEN '' ELSE #{model_url.(answers_source_key)} END"
    end

    # source key from answer, only exists if there is an answer
    answers_source_key = "#{learners_and_answers_table}.source_key['#{question_id}']"

    # source key from extracted from the runnable url (selected as resource_url in query), either as answersSourceKey parameter or the host (normally activity-player.concord.org)
    runnable_url = "#{learners_and_answers_table}.resource_url"
    source_key_from_runnable_url =
      "COALESCE(url_extract_parameter(#{runnable_url}, 'answersSourceKey'), url_extract_host(#{runnable_url}))"

    answers_source_key_with_no_answer_fallback =
      "COALESCE(#{answers_source_key}, IF(#{source_key_from_runnable_url} = 'activity-player-offline.concord.org', 'activity-player.concord.org', #{source_key_from_runnable_url}))"

    answer = "#{learners_and_answers_table}.kv1['#{question_id}']"

    columns =
      case type do
        "image_question" ->
          [
            %{name: "#{column_prefix}_image_url", value: "json_extract_scalar(#{answer}, '$.image_url')", header: prompt_header},
            %{name: "#{column_prefix}_text", value: "json_extract_scalar(#{answer}, '$.text')", header: prompt_header},
            %{name: "#{column_prefix}_answer", value: answer, header: prompt_header}
          ]

        "open_response" ->
          # When there is no answer to an open_response question the report state JSON is saved as the answer in Firebase.
          # This detects if the answer looks like the report state JSON and if so returns an empty string to show there was
          # no answer to the question.
          # note: conditional_model_url.() is not used here as students can answer with only audio responses and in that
          # case the answer does not exist as open response answers are only the text of the answer due to the
          # question type being ported from the legacy LARA built in open response questions which only saved the text
          [
            %{name: "#{column_prefix}_text", value: "CASE WHEN starts_with(#{answer}, '\"{\"mode\":\"report\"') THEN '' ELSE (#{answer}) END", header: prompt_header},
            %{name: "#{column_prefix}_url", value: model_url.(answers_source_key_with_no_answer_fallback), header: prompt_header}
          ]

        "multiple_choice" ->
          question_has_correct_answer =
            Map.get(denormalized_resource, "choices", %{})
            |> Map.get(question_id, %{})
            |> Enum.any?(fn {_choice_id, choice} -> Map.get(choice, "correct") || false end)

          answer_score =
            if question_has_correct_answer do
              "IF(#{activities_table}.choices['#{question_id}'][x].correct, ' (correct)', ' (wrong)')"
            else
              "''"
            end

          choice_ids_as_array = "CAST(json_extract(#{answer}, '$.choice_ids') AS ARRAY(VARCHAR))"

          [
            %{name: "#{column_prefix}_choice", value: "array_join(transform(#{choice_ids_as_array}, x -> CONCAT(#{activities_table}.choices['#{question_id}'][x].content, #{answer_score})), ', ')", header: prompt_header, second_header: "#{activities_table}.questions['#{question_id}'].correctAnswer"}
          ]

        "iframe_interactive" ->
          [
            %{name: "#{column_prefix}_json", value: answer, header: prompt_header},
            %{name: "#{column_prefix}_url", value: conditional_model_url.(answer, answers_source_key), header: prompt_header}
          ]

        _ ->
          [
            %{name: "#{column_prefix}_json", value: answer, header: prompt_header}
          ]
      end

    if is_required do
      columns ++ [%{name: "#{column_prefix}_submitted", value: "COALESCE(#{learners_and_answers_table}.submitted['#{question_id}'], false)"}]
    else
      columns
    end
  end

  defp maybe_hash_username(false, col, _), do: col
  defp maybe_hash_username(true, col, skip_as?) do
    hide_username_hash_salt = AthenaConfig.get_hide_username_hash_salt()
    fragment = "TO_HEX(SHA1(CAST(('#{hide_username_hash_salt}' || #{col}) AS VARBINARY)))"
    if skip_as? do
      fragment
    else
      "#{fragment} AS username"
    end
  end

  defp select_from_column(%{name: name, value: value}), do: "#{value} AS #{name}"

end
