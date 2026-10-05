defmodule ReportServer.Reports.Athena.SharedQueriesTest do
  @moduledoc """
  Pins the answer-column shape the CLUE and open response question types depend
  on.

  `clue_question` and `clue_tile` share one branch in
  `get_columns_for_question/6`, emitting the JSON cell verbatim plus a `_url`
  column lifted out of it. cc-data reads the `res_<n>_<key>_json` name and
  researchers read the `_url` one in a spreadsheet, so both are consumed
  contracts that an edit here would change silently. These tests are what turns
  that into a failure rather than a surprise.

  An open response emits its text and a link to the portal report's
  single-question view, unless the report filter's `remove_open_response_urls`
  drops the link. The default pair is pinned exactly, since a report made
  without the option must not change.

  The text is blanked when the stored answer is the report-state placeholder
  saved for an opened, unanswered question, or a cleared answer. The SQL only
  renders here, so those tests read the `regexp_like` pattern back out of it and
  run it on the answer bytes the writers store, which is what catches an
  escaping mistake.
  """
  use ExUnit.Case, async: true

  alias ReportServer.Reports.Athena.SharedQueries
  alias ReportServer.Reports.ReportFilter

  @auth_domain "https://learn.concord.org"
  @key "q39487a59642d"

  ## The :athena config is only set for dev and for released environments, and
  ## the column builder reads a source key out of it. Set here rather than in the
  ## test config so no other test's behaviour depends on it.
  setup do
    previous = Application.get_env(:report_server, :athena)
    Application.put_env(:report_server, :athena, source_key: "authoring.concord.org")

    on_exit(fn ->
      if previous do
        Application.put_env(:report_server, :athena, previous)
      else
        Application.delete_env(:report_server, :athena)
      end
    end)
  end

  defp columns(type, question_id \\ @key, opts \\ []) do
    {required, column_opts} = Keyword.pop(opts, :required, false)
    denormalized = %{questions: %{}, choices: %{}, question_order: []}
    question = %{type: type, prompt: "a prompt", required: required}

    SharedQueries.get_columns_for_question(question_id, question, denormalized, @auth_domain, 1, column_opts)
  end

  describe "get_columns_for_question/6 for the CLUE question types" do
    for type <- ["clue_question", "clue_tile"] do
      test "#{type} emits the JSON cell verbatim, then a url column" do
        assert [json_column, url_column] = columns(unquote(type))

        assert json_column.name == "res_1_#{@key}_json"
        assert json_column.value == "learners_and_answers_1.kv1['#{@key}']"

        assert url_column.name == "res_1_#{@key}_url"
      end

      test "#{type} takes the url from the first entry, leaving the array untouched" do
        ## Entries built from one event share a link, so element 0 stands for the
        ## whole cell. The array itself is passed through unchanged, which is what
        ## keeps the multi-document case navigable.
        assert [json_column, url_column] = columns(unquote(type))

        assert url_column.value ==
                 "json_extract_scalar(learners_and_answers_1.kv1['#{@key}'], '$[0].link')"

        refute json_column.value =~ "json_extract"
      end

      test "#{type} takes both headers from the question's prompt" do
        assert [json_column, url_column] = columns(unquote(type))

        assert json_column.header == "activities_1.questions['#{@key}'].prompt"
        assert url_column.header == "activities_1.questions['#{@key}'].prompt"
      end

      test "#{type} emits no text sub-column" do
        ## The cell is a variable-length array, so unlike a single text answer
        ## there is no one text value to decompose it into.
        names = columns(unquote(type)) |> Enum.map(& &1.name)

        refute Enum.any?(names, &String.ends_with?(&1, "_text"))
      end
    end

    test "the free-standing text type keeps its legacy text and url pair" do
      names = columns("clue_text_tile") |> Enum.map(& &1.name)

      assert names == ["res_1_#{@key}_text", "res_1_#{@key}_url"]
    end

    test "a required question adds a submitted column, an optional one does not" do
      denormalized = %{questions: %{}, choices: %{}, question_order: []}

      optional =
        SharedQueries.get_columns_for_question(
          @key,
          %{type: "clue_question", prompt: "p", required: false},
          denormalized,
          @auth_domain,
          1
        )

      required =
        SharedQueries.get_columns_for_question(
          @key,
          %{type: "clue_question", prompt: "p", required: true},
          denormalized,
          @auth_domain,
          1
        )

      assert Enum.map(optional, & &1.name) == ["res_1_#{@key}_json", "res_1_#{@key}_url"]

      assert Enum.map(required, & &1.name) == [
               "res_1_#{@key}_json",
               "res_1_#{@key}_url",
               "res_1_#{@key}_submitted"
             ]
    end

    test "the column names use the key they are given, so a hex key stays alias-safe" do
      ## A raw questionId would emit res_1_9HzYd-_json here, which is a syntax
      ## error rather than a degraded value, since the alias is unquoted.
      assert [json_column, url_column] = columns("clue_question", "q6e62302d6433")

      assert json_column.name == "res_1_q6e62302d6433_json"
      assert url_column.name == "res_1_q6e62302d6433_url"

      for name <- [json_column.name, url_column.name] do
        assert name =~ ~r/^[a-z0-9_]+$/
      end
    end
  end

  describe "get_columns_for_question/6 for open_response" do
    test "by default emits the text and the single-question link" do
      assert columns("open_response") == [
               %{
                 name: "res_1_#{@key}_text",
                 value:
                   ~S|CASE WHEN regexp_like(learners_and_answers_1.kv1['q39487a59642d'], '| <>
                     ~S[^(?:"\{\\"mode\\":\\"report\\",\\"authoredState\\":|\{"mode":"report","authoredState":|"\{\\"version\\":1,\\"mode\\":\\"report\\",\\"authoredState\\":|\{"version":1,"mode":"report","authoredState":|"")] <>
                     ~S|') THEN '' ELSE (learners_and_answers_1.kv1['q39487a59642d']) END|,
                 header: "activities_1.questions['#{@key}'].prompt"
               },
               %{
                 name: "res_1_#{@key}_url",
                 value: "CONCAT('https://portal-report.concord.org/branch/master/?auth-domain=https%3A%2F%2Flearn.concord.org&firebase-app=report-service-pro&sourceKey=authoring.concord.org&iframeQuestionId=#{@key}&class=https%3A%2F%2Flearn.concord.org%2Fapi%2Fv1%2Fclasses%2F', CAST(learners_and_answers_1.class_id AS VARCHAR), '&offering=https%3A%2F%2Flearn.concord.org%2Fapi%2Fv1%2Fofferings%2F', CAST(learners_and_answers_1.offering_id AS VARCHAR), '&studentId=', CAST(learners_and_answers_1.user_id AS VARCHAR), '&answersSourceKey=', COALESCE(learners_and_answers_1.source_key['#{@key}'], IF(COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)) = 'activity-player-offline.concord.org', 'activity-player.concord.org', COALESCE(url_extract_parameter(learners_and_answers_1.resource_url, 'answersSourceKey'), url_extract_host(learners_and_answers_1.resource_url)))))",
                 header: "activities_1.questions['#{@key}'].prompt"
               }
             ]
    end

    test "emits only the text when the filter removes the link" do
      [text_column] = columns("open_response", @key, remove_open_response_urls: true)

      assert text_column == hd(columns("open_response"))
    end

    test "a required question keeps its submitted column when the link is removed" do
      names =
        columns("open_response", @key, required: true, remove_open_response_urls: true)
        |> Enum.map(& &1.name)

      assert names == ["res_1_#{@key}_text", "res_1_#{@key}_submitted"]
    end

    test "the other question types keep their url column when the open response link is removed" do
      for type <- ["iframe_interactive", "clue_text_tile", "clue_question", "clue_tile"] do
        names = columns(type, @key, remove_open_response_urls: true) |> Enum.map(& &1.name)

        assert "res_1_#{@key}_url" in names, "#{type} lost its url column"
      end
    end
  end

  describe "the open response text column with a stored report-state placeholder" do
    ## Stored bytes as the writers produce them: the activity player and LARA save
    ## the report state string as the answer, and the S3 sync JSON-encodes it.
    ## The unencoded forms are parquet files written before that encoding began.
    @activity_player ~S|"{\"mode\":\"report\",\"authoredState\":\"{\\\"version\\\":1,\\\"questionType\\\":\\\"open_response\\\",\\\"audioEnabled\\\":true}\",\"interactiveState\":\"{}\",\"interactive\":{\"id\":\"managed_interactive_360221\",\"name\":\"\"},\"version\":1}"|
    @lara ~S|"{\"version\":1,\"mode\":\"report\",\"authoredState\":\"{\\\"version\\\":1,\\\"questionType\\\":\\\"open_response\\\"}\",\"interactiveState\":\"{}\"}"|
    @activity_player_unencoded ~S|{"mode":"report","authoredState":"{\"version\":1}","interactiveState":"{}","version":1}|
    @lara_unencoded ~S|{"version":1,"mode":"report","authoredState":"{\"version\":1}","interactiveState":"{}"}|

    ## Evaluates the emitted CASE against a stored answer as Athena would: the
    ## regexp_like pattern is read back out of the SQL and run on the bytes.
    defp blanked?(stored) do
      answer = Regex.escape("learners_and_answers_1.kv1['#{@key}']")
      [text_column | _] = columns("open_response")

      [_, pattern] =
        Regex.run(
          ~r/\ACASE WHEN regexp_like\(#{answer}, '((?:[^']|'')*)'\) THEN '' ELSE \(#{answer}\) END\z/,
          text_column.value
        )

      pattern |> String.replace("''", "'") |> Regex.compile!() |> Regex.match?(stored)
    end

    test "blanks the activity player placeholder" do
      assert blanked?(@activity_player)
    end

    test "blanks the LARA placeholder, which puts version before mode" do
      assert blanked?(@lara)
    end

    test "blanks both placeholders when stored unencoded" do
      assert blanked?(@activity_player_unencoded)
      assert blanked?(@lara_unencoded)
    end

    test "blanks an answer the student typed and then cleared" do
      assert blanked?(~S|""|)
    end

    test "keeps a text answer" do
      refute blanked?(~S|"This is DougTest Two's text answer"|)
    end

    test "keeps a text answer that quotes a report state after other text" do
      refute blanked?(~S|"see \"{\"mode\":\"report\",\"authoredState\":\" in the log"|)
    end

    test "keeps a text answer that begins like a report state" do
      refute blanked?(~S|"{\"mode\":\"report\" is what I typed"|)
    end
  end

  describe "generate_resource_sql/4 with remove_open_response_urls" do
    @open_response "qopenresponse1"
    @interactive "qinteractive1"

    defp answers_sql(report_filter) do
      denormalized = %{
        questions: %{
          @open_response => %{type: "open_response", prompt: "p", required: false},
          @interactive => %{type: "iframe_interactive", prompt: "p", required: false}
        },
        choices: %{},
        question_order: [@open_response, @interactive]
      }

      resource_data = [
        %{
          runnable_url: "https://activity-player.concord.org/branch/master?activity=1",
          query_id: "q1",
          resource: nil,
          denormalized: denormalized
        }
      ]

      {:ok, query} = SharedQueries.generate_resource_sql(:answers, report_filter, resource_data, @auth_domain)
      query.raw_sql
    end

    defp alias_count(sql, name), do: length(Regex.scan(~r/ AS #{name}\b/, sql))

    test "the open response link is in the prompt, correct-answer and data rows by default" do
      sql = answers_sql(%ReportFilter{})

      assert alias_count(sql, "res_1_#{@open_response}_url") == 3
      assert alias_count(sql, "res_1_#{@interactive}_url") == 3
    end

    test "the open response link is in no row when the filter removes it" do
      sql = answers_sql(%ReportFilter{remove_open_response_urls: true})

      assert alias_count(sql, "res_1_#{@open_response}_url") == 0
      assert alias_count(sql, "res_1_#{@open_response}_text") == 3
      assert alias_count(sql, "res_1_#{@interactive}_url") == 3
    end
  end
end
