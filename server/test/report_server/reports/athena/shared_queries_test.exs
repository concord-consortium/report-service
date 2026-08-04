defmodule ReportServer.Reports.Athena.SharedQueriesTest do
  @moduledoc """
  Pins the answer-column shape the CLUE question types depend on.

  Neither `clue_question` nor `clue_tile` has a branch of its own in
  `get_columns_for_question/5`: both fall through to the catch-all, which already
  emits exactly the single JSON column they need. That keeps the CLUE work out of
  shared query generation entirely, but it also means nothing in the code says
  these types are expected to produce `res_<n>_<key>_json`. cc-data reads that
  column name, so an edit to the catch-all would change a consumed contract
  without touching anything that looks CLUE-related. These tests are what turns
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
      test "#{type} emits one JSON column carrying the cell verbatim" do
        assert [column] = columns(unquote(type))

        assert column.name == "res_1_#{@key}_json"
        assert column.value == "learners_and_answers_1.kv1['#{@key}']"
      end

      test "#{type} takes its header from the question's prompt" do
        assert [column] = columns(unquote(type))

        assert column.header == "activities_1.questions['#{@key}'].prompt"
      end

      test "#{type} emits no url or text sub-columns" do
        ## The cell is a variable-length array, so it is passed through whole
        ## rather than decomposed the way a single text answer can be.
        names = columns(unquote(type)) |> Enum.map(& &1.name)

        refute Enum.any?(names, &String.ends_with?(&1, "_url"))
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

      assert Enum.map(optional, & &1.name) == ["res_1_#{@key}_json"]
      assert Enum.map(required, & &1.name) == ["res_1_#{@key}_json", "res_1_#{@key}_submitted"]
    end

    test "the column name uses the key it is given, so a hex key stays alias-safe" do
      ## A raw questionId would emit res_1_9HzYd-_json here, which is a syntax
      ## error rather than a degraded value, since the alias is unquoted.
      assert [column] = columns("clue_question", "q6e62302d6433")

      assert column.name == "res_1_q6e62302d6433_json"
      assert column.name =~ ~r/^[a-z0-9_]+$/
    end
  end
end
