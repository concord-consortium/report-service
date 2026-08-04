defmodule ReportServer.ClueFixtures do
  @moduledoc """
  Fixtures for the CLUE Student Answers report path (REPORT-36).

  `clue.ex` reads a CSV that Athena produced from the unioned three-track log
  query, so these fixtures build that CSV rather than mocking Elixir data
  structures. The point is to exercise the real `CSV.decode` -> reduce ->
  structure/answers path, including the quoting and JSON escaping a nested
  `QUESTION_ANSWERS_CHANGE` payload picks up on its way through Athena's CSV
  writer.

  See `specs/REPORT-36-clue-questions-in-student-answers-report/` for the rules
  these fixtures exist to pin. Requirement ids (`QR*`, `BR*`, `XR*`), decisions
  (`D1`-`D7`) and verification findings (`VR1`-`VR23`) are referenced rather
  than restated.
  """

  @portal_site "learn.concord.org"
  @runnable_url "https://collaborative-learning.concord.org/?unit=m2s&problem=4.5"

  ## The union's column set. Columns absent for a track are empty, matching the
  ## query's CAST(NULL AS VARCHAR) padding (D2).
  @columns ~w(track username question_id answers prompt event tool_id tile_title text_value
              document_key document_type document_history_id)

  def runnable_url, do: @runnable_url
  def portal_site, do: @portal_site
  def csv_columns, do: @columns

  @doc """
  Learner maps in the shape `LearnerData` builds (`learner_data.ex:170-191`),
  which is what `Clue.fetch_resource/3` receives. `created_at` is included
  because D7's year floor is derived from it.
  """
  def learners_fixture(count \\ 2) do
    for i <- 1..count do
      user_id = 77_700 + i

      %{
        student_id: 200 + i,
        learner_id: 100 + i,
        class_id: 254,
        class: "Test Class",
        school: "Test School",
        user_id: user_id,
        primary_user_id: user_id,
        offering_id: 588,
        permission_forms: "[]",
        username: "student#{i}",
        student_name: "Student #{i}",
        last_run: ~N[2026-04-20 10:00:00],
        run_remote_endpoint:
          "https://#{@portal_site}/dataservice/external_activity_data/1cf47468-e793-4a54-b457-e4718a2a5dc#{i}",
        runnable_url: @runnable_url,
        teachers: "[]",
        created_at: ~N[2026-03-01 09:00:00]
      }
    end
  end

  def username(learner), do: "#{learner.user_id}@#{@portal_site}"

  @doc """
  Builds the CSV stream `Clue`'s parse step consumes, from a list of row maps
  keyed by the column names in `csv_columns/0`. Missing keys become empty
  fields, so each row helper below only states the columns its track uses.

  Returns a list of CRLF-terminated lines, which is what `Aws.get_file_stream`
  yields and what `CSV.decode/2` expects.
  """
  def answer_csv(rows) do
    header = Enum.join(@columns, ",") <> "\r\n"

    body =
      Enum.map(rows, fn row ->
        @columns
        |> Enum.map(fn col -> row |> Map.get(col, "") |> to_string() |> csv_escape() end)
        |> Enum.join(",")
        |> Kernel.<>("\r\n")
      end)

    [header | body]
  end

  defp csv_escape(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  ## ------------------------------------------------------------------
  ## Track A rows (QUESTION_ANSWERS_CHANGE)
  ## ------------------------------------------------------------------

  @doc """
  A Track A row. `answer_tiles` is a list of `{type, plain_text}` tuples, or a
  list of such lists to produce more than one `answers[]` group, which a single
  `questionId` can legitimately yield when one document holds two Question
  tiles with that id (see the Background's payload description).

  `answers` is JSON-encoded here the same way `json_format(json_extract(...))`
  delivers it (D3, VR17), so the fixture round-trips through `CSV.decode` and
  `Jason.decode` exactly as production data does.
  """
  def track_a_row(learner, question_id, answer_tiles, opts \\ []) do
    groups =
      case answer_tiles do
        [h | _] when is_list(h) -> answer_tiles
        tiles -> [tiles]
      end

    answers =
      groups
      |> Enum.with_index(1)
      |> Enum.map(fn {tiles, gi} ->
        %{
          "tileId" => "question-tile-#{gi}",
          "answerTiles" =>
            tiles
            |> Enum.with_index(1)
            |> Enum.map(fn {{type, plain_text}, ti} ->
              tile = %{"tileId" => "answer-#{gi}-#{ti}", "type" => type}
              if is_nil(plain_text), do: tile, else: Map.put(tile, "plainText", plain_text)
            end)
        }
      end)
      |> Jason.encode!()

    %{
      "track" => "A",
      "username" => username(learner),
      "question_id" => question_id,
      "answers" => answers,
      ## DR1's enrichment is absent from every current event (VR4), so the
      ## default is "" and only the VR18 fixture sets it.
      "prompt" => Keyword.get(opts, :prompt, ""),
      "document_key" => Keyword.get(opts, :document_key, "-OL0rmfqiDsPlriZks-X"),
      "document_type" => Keyword.get(opts, :document_type, "problem"),
      "document_history_id" => Keyword.get(opts, :document_history_id, "pQ99dWPLmCIvqTUWDr5NH")
    }
  end

  ## ------------------------------------------------------------------
  ## Track B rows (non-text *_TOOL_CHANGE, free-standing)
  ## ------------------------------------------------------------------

  @doc """
  A Track B row. `event` is the raw log event name, since the tile type exists
  nowhere else in the payload (VR10) and is derived from it (D4).
  """
  def track_b_row(learner, event, tool_id, opts \\ []) do
    %{
      "track" => "B",
      "username" => username(learner),
      "event" => event,
      "tool_id" => tool_id,
      "document_key" => Keyword.get(opts, :document_key, "-OL0rmfqiDsPlriZks-X"),
      "document_type" => Keyword.get(opts, :document_type, "problem"),
      "document_history_id" => Keyword.get(opts, :document_history_id, "histB-#{tool_id}")
    }
  end

  ## ------------------------------------------------------------------
  ## Track C rows (TEXT_TOOL_CHANGE, free-standing text; BR1, unchanged)
  ## ------------------------------------------------------------------

  @doc """
  A Track C row. `text` is wrapped in the Slate document shape the existing
  text path decodes with `Jason.decode` + `extract_text` (`clue.ex:147-151`),
  because BR1 requires that path unchanged.
  """
  def track_c_row(learner, tile_title, text, opts \\ []) do
    slate =
      %{"document" => %{"children" => [%{"children" => [%{"text" => text}]}]}}
      |> Jason.encode!()

    %{
      "track" => "C",
      "username" => username(learner),
      "tile_title" => tile_title,
      "tool_id" => Keyword.get(opts, :tool_id, "text-tool-1"),
      "text_value" => slate,
      "document_key" => Keyword.get(opts, :document_key, "-OL0rmfqiDsPlriZks-X"),
      "document_history_id" => Keyword.get(opts, :document_history_id, "histC-1")
    }
  end

  @doc """
  D1's key encode, restated here so the tests assert against the pinned
  transform rather than against whatever `clue.ex` happens to do.
  """
  def question_key(question_id), do: "q" <> Base.encode16(question_id, case: :lower)
end
