defmodule ReportServer.Reports.Athena.SharedQueriesTest do
  @moduledoc """
  Pins the answer-column shape the CLUE question types depend on.

  `clue_question` and `clue_tile` share one branch in
  `get_columns_for_question/5`, emitting the JSON cell verbatim plus a `_url`
  column lifted out of it. cc-data reads the `res_<n>_<key>_json` name and
  researchers read the `_url` one in a spreadsheet, so both are consumed
  contracts that an edit here would change silently. These tests are what turns
  that into a failure rather than a surprise.
  """
  use ExUnit.Case, async: true

  alias ReportServer.Reports.Athena.SharedQueries

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

  defp columns(type, question_id \\ @key) do
    denormalized = %{questions: %{}, choices: %{}, question_order: []}
    question = %{type: type, prompt: "a prompt", required: false}

    SharedQueries.get_columns_for_question(question_id, question, denormalized, @auth_domain, 1)
  end

  describe "get_columns_for_question/5 for the CLUE question types" do
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
end
