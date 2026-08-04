defmodule ReportServer.ClueTest do
  @moduledoc """
  Tests for the CLUE Student Answers report path (REPORT-36, both tracks).

  ## These tests do not run yet

  The module is tagged `:pending` and excluded in `test_helper.exs`. Nothing on
  this path is reachable from a test today: the whole pipeline is `defp`,
  `AthenaDB` and `Aws.get_file_stream` are called directly rather than through
  the repo's `Application.get_env` seams, the parse step writes parquet to S3
  unconditionally, and `fetch_resource/3` returns only the structure. Making
  these run is implementation sequencing **step 2**, the testability seam.

  Written ahead of the code deliberately: every assertion here corresponds to a
  rule the spec pins, and several of those rules exist because the natural way
  to write the code produces something else silently (D5 rule 4, D6/VR9, VR18,
  VR20). Fixtures alone do not guard those; assertions do.

  ## The two entry points step 2 must expose

      Clue.answer_sql(learners) :: String.t()

      Clue.parse_answer_csv(url, stream, learners, opts) ::
        {:ok, %{structure: %{questions: map, choices: map, question_order: [String.t()]},
                answers: %{String.t() => [map]}}}

  `opts[:write_answers]` replaces the S3 parquet write with a function of the
  answers map, so answer rows can be asserted without credentials. Half the
  scenarios below assert on answer rows rather than structure, and those are
  the ones guarding silent loss (QR6, the `map_agg` duplicate, VR2's track
  boundary, VR13, VR15, VR23).

  Requirement ids (`QR*`, `BR*`, `XR*`), decisions (`D1`-`D7`) and verification
  findings (`VR1`-`VR23`) refer to
  `specs/REPORT-36-clue-questions-in-student-answers-report/`.
  """
  use ExUnit.Case, async: true

  @moduletag :pending

  import ReportServer.ClueFixtures

  alias ReportServer.Clue

  setup do
    learners = learners_fixture(2)
    {:ok, learners: learners, a: Enum.at(learners, 0), b: Enum.at(learners, 1)}
  end

  ## Parses a CSV built from `rows` and returns the structure plus the answers map.
  defp parse(rows, learners) do
    {:ok, result} =
      Clue.parse_answer_csv(runnable_url(), answer_csv(rows), learners,
        write_answers: fn _answers -> :ok end
      )

    result
  end

  ## The decoded JSON cell for one learner's key, or nil when no answer row was
  ## emitted. QR6 turns on the difference between nil and `[]`.
  defp cell(result, learner, key) do
    case result.answers
         |> Map.get(username(learner), [])
         |> Enum.find(&(&1.question_id == key)) do
      nil -> nil
      row -> Jason.decode!(row.answer)
    end
  end

  defp answer_keys(result, learner) do
    result.answers |> Map.get(username(learner), []) |> Enum.map(& &1.question_id) |> Enum.sort()
  end

  defp count_occurrences(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  describe "answer_sql/1: query shape" do
    ## These assert on the generated SQL text rather than on Athena, so they
    ## pin this round's query decisions without needing credentials or a scan.

    test "reads the partition-projected table with the app and year-floor prune (D7)", %{
      learners: learners
    } do
      sql = Clue.answer_sql(learners)

      assert sql =~ "logs_by_app_and_secure_key"
      refute sql =~ "logs_by_time"
      assert sql =~ ~r/\bapp\b\s*=\s*'CLUE'/
      ## created_at is 2026-03-01 in the fixture, so the floor is 2025 (year - 1).
      assert sql =~ ~r/\byear\b\s*>=\s*2025/
    end

    test "embeds each learner list exactly once, in one base CTE (VR16/D2)", %{
      learners: learners
    } do
      sql = Clue.answer_sql(learners)
      endpoint = hd(learners).run_remote_endpoint
      secure_key = endpoint |> String.split("/") |> List.last()

      ## Repeating these per track is what puts a large report over Athena's
      ## 262,144-byte query-string quota at ~628 learners.
      assert count_occurrences(sql, endpoint) == 1
      assert count_occurrences(sql, secure_key) == 1
    end

    test "treats a missing containerIds as free-standing (VR15)", %{learners: learners} do
      sql = Clue.answer_sql(learners)

      ## Without the COALESCE, `NULL = '[]'` is NULL and every tile-change event
      ## logged before 2025-05-07 is dropped: 85% of the corpus (VR23).
      assert sql =~ "COALESCE"
      assert sql =~ ~r/COALESCE\([^)]*containerIds[^)]*\)\s*=\s*'\[\]'/
    end

    test "matches tile-change events by pattern, not by an event-name list (BR4/VR17)", %{
      learners: learners
    } do
      sql = Clue.answer_sql(learners)

      assert sql =~ "regexp_like"
      assert sql =~ "_TOOL_CHANGE$"
      ## An IN list would have silently dropped 1.27M historical
      ## GRAPH_TOOL_CHANGE events (VR23).
      refute sql =~ "DRAWING_TOOL_CHANGE"
      refute sql =~ "TABLE_TOOL_CHANGE"
      ## The escaped LIKE form cannot survive the SQL heredoc (VR17).
      refute sql =~ "ESCAPE"
    end

    test "formats Track A's answers as varchar so the union types agree (D3/VR17)", %{
      learners: learners
    } do
      sql = Clue.answer_sql(learners)

      ## Bare json_extract is Trino type `json` and the union with the varchar
      ## tracks fails with TYPE_MISMATCH (confirmed live, VR17).
      assert sql =~ ~r/json_format\(\s*json_extract\([^)]*\$\.answers'\s*\)\s*\)/
    end

    test "selects latest-per-key with a window on every track (VR13/VR22)", %{learners: learners} do
      sql = Clue.answer_sql(learners)

      ## Track A must partition on documentKey as well as the learner, or one
      ## learner's second document is silently dropped (VR13).
      assert sql =~ ~r/PARTITION BY.*run_remote_endpoint.*documentKey.*questionId/s
      ## Track C moved off its MAX(time) self-join, which cost a fourth
      ## inlining of the base CTE (VR22).
      refute sql =~ "MAX(\"log1\".\"time\")"
      assert count_occurrences(sql, "ROW_NUMBER") == 3
    end

    test "applies no operation filter to the non-text tile tracks (VR11)", %{learners: learners} do
      sql = Clue.answer_sql(learners)

      ## Drawing never logs `update`, so a symmetric filter would erase every
      ## free-standing Drawing tile. Track C keeps its own filter (BR1).
      assert count_occurrences(sql, "'update'") == 1
    end
  end

  describe "Track A: keys and columns" do
    test "keys questions by the hex encode of questionId (D1)", %{a: a, learners: learners} do
      result = parse([track_a_row(a, "9HzYd-", [{"Text", "an answer"}])], learners)
      key = question_key("9HzYd-")

      assert key == "q39487a59642d"
      assert Map.has_key?(result.structure.questions, key)
      assert result.structure.questions[key].type == "clue_question"
      assert result.structure.questions[key].required == false
      assert answer_keys(result, a) == [key]
    end

    test "keeps ids differing only by case or -/_ in distinct columns (D1, VR7)", %{
      a: a,
      learners: learners
    } do
      ## make_safe_id would fold all three into one key and merge their answers.
      rows =
        for id <- ["ab-cde", "ab_cde", "AB-CDE"],
            do: track_a_row(a, id, [{"Text", "answer #{id}"}])

      result = parse(rows, learners)
      keys = Enum.map(["ab-cde", "ab_cde", "AB-CDE"], &question_key/1)

      assert length(Enum.uniq(keys)) == 3
      assert answer_keys(result, a) == Enum.sort(keys)

      for {id, key} <- Enum.zip(["ab-cde", "ab_cde", "AB-CDE"], keys) do
        assert [%{"text" => text}] = cell(result, a, key)
        assert text == "answer #{id}"
      end
    end

    test "falls back to the raw questionId as the prompt (QR1/DR2)", %{a: a, learners: learners} do
      result = parse([track_a_row(a, "9HzYd-", [{"Text", "x"}])], learners)

      assert result.structure.questions[question_key("9HzYd-")].prompt == "9HzYd-"
    end
  end

  describe "Track A: aggregation and cell contract" do
    test "emits one answer row per (learner, question) with entries in answerTiles order", %{
      a: a,
      learners: learners
    } do
      ## map_agg keeps one value per key and drops duplicates silently on engine
      ## v3 (VR6), so a multi-tile question must be one row holding a JSON list.
      row =
        track_a_row(a, "aB3xK9", [
          {"Text", "first"},
          {"Drawing", nil},
          {"Table", nil}
        ])

      result = parse([row], learners)
      key = question_key("aB3xK9")

      assert length(result.answers[username(a)]) == 1

      assert [
               %{"type" => "Text", "text" => "first"},
               %{"type" => "Drawing"},
               %{"type" => "Table"}
             ] = cell(result, a, key)

      ## `link` is carried per entry in both tracks so cc-data has one parsing
      ## pattern, and non-Text entries carry no `text` field (QR4).
      for entry <- cell(result, a, key) do
        assert entry["link"] =~ "studentDocumentHistoryId=pQ99dWPLmCIvqTUWDr5NH"
      end

      refute Map.has_key?(Enum.at(cell(result, a, key), 1), "text")
    end

    test "flattens multiple answers[] groups in payload order", %{a: a, learners: learners} do
      ## One questionId can yield more than one group when a document holds two
      ## Question tiles with that id.
      row = track_a_row(a, "aB3xK9", [[{"Text", "group one"}], [{"Text", "group two"}]])

      result = parse([row], learners)

      assert [%{"text" => "group one"}, %{"text" => "group two"}] =
               cell(result, a, question_key("aB3xK9"))
    end

    test "reports every learner's answer to a shared questionId (QR1/AC1, VR4)", %{
      a: a,
      b: b,
      learners: learners
    } do
      ## 130 of 193 production questionIds are shared, up to 33 learners on one
      ## id, so a partition missing run_remote_endpoint keeps one and drops the
      ## rest.
      rows = [
        track_a_row(a, "aB3xK9", [{"Text", "learner a"}]),
        track_a_row(b, "aB3xK9", [{"Text", "learner b"}])
      ]

      result = parse(rows, learners)
      key = question_key("aB3xK9")

      assert [%{"text" => "learner a"}] = cell(result, a, key)
      assert [%{"text" => "learner b"}] = cell(result, b, key)
    end

    test "preserves special characters in plainText through the CSV round trip (VR1)", %{
      a: a,
      learners: learners
    } do
      text = ~s(he said "hi", then left\nand came back)
      result = parse([track_a_row(a, "aB3xK9", [{"Text", text}])], learners)

      ## plainText is consumed verbatim; routing it through the text path's
      ## Slate decoder would hit `else -> row_acc.answers` and drop it silently.
      assert [%{"text" => ^text}] = cell(result, a, question_key("aB3xK9"))
    end

    test "reports an answer tile type that emits no tile-change event (VR2)", %{
      a: a,
      learners: learners
    } do
      ## Image is the largest such type (222 distinct in-question tiles). Track A
      ## sees it because getQuestionAnswersAsJSON enumerates every tile; Track B
      ## cannot, because no event is ever logged. This pins which side of the
      ## coverage line each track sits on.
      rows = [track_a_row(a, "aB3xK9", [{"Text", "words"}, {"Image", nil}])]
      result = parse(rows, learners)

      types = cell(result, a, question_key("aB3xK9")) |> Enum.map(& &1["type"])

      assert types == ["Text", "Image"]
      refute Map.has_key?(result.structure.questions, "other_tiles")
    end
  end

  describe "Track A: one learner, one questionId, two documents (VR13/VR20)" do
    ## 15 of 1,220 production learner/question pairs span more than one
    ## document, because an across-document copy preserves questionId. Each
    ## event carries only its own document's answers, so both rows must survive
    ## and merge.

    test "merges both documents into one cell, each entry with its own link", %{
      a: a,
      learners: learners
    } do
      rows = [
        track_a_row(a, "aB3xK9", [{"Text", "in problem doc"}],
          document_key: "-DOCA",
          document_history_id: "histA"
        ),
        track_a_row(a, "aB3xK9", [{"Text", "in learning log"}],
          document_key: "-DOCB",
          document_history_id: "histB"
        )
      ]

      result = parse(rows, learners)
      entries = cell(result, a, question_key("aB3xK9"))

      assert length(result.answers[username(a)]) == 1
      assert Enum.map(entries, & &1["text"]) == ["in problem doc", "in learning log"]
      assert Enum.at(entries, 0)["link"] =~ "studentDocument=-DOCA"
      assert Enum.at(entries, 1)["link"] =~ "studentDocument=-DOCB"
    end

    test "orders payload groups by documentKey regardless of row delivery order", %{
      a: a,
      learners: learners
    } do
      ## The query has no ORDER BY, so without this the cell differs between two
      ## runs over unchanged data, which is the diff noise the cell contract
      ## exists to remove (VR20).
      forward = [
        track_a_row(a, "aB3xK9", [{"Text", "doc a"}], document_key: "-DOCA"),
        track_a_row(a, "aB3xK9", [{"Text", "doc b"}], document_key: "-DOCB")
      ]

      assert cell(parse(forward, learners), a, question_key("aB3xK9")) ==
               cell(parse(Enum.reverse(forward), learners), a, question_key("aB3xK9"))
    end
  end

  describe "Track A: prompt enrichment (DR1/VR18)" do
    ## After CLUE ships the `$.prompt` enrichment, learners on the same question
    ## disagree indefinitely about whether their latest event carries it. A
    ## write-once structure entry makes the header depend on row delivery order.

    for {label, reverse?} <- [{"enriched row first", false}, {"enriched row last", true}] do
      test "uses the enriched prompt when any learner's row has one (#{label})", %{
        a: a,
        b: b,
        learners: learners
      } do
        rows = [
          track_a_row(a, "aB3xK9", [{"Text", "before the deploy"}]),
          track_a_row(b, "aB3xK9", [{"Text", "after the deploy"}],
            prompt: "How much water does the tank need?"
          )
        ]

        rows = if unquote(reverse?), do: Enum.reverse(rows), else: rows
        result = parse(rows, learners)

        assert result.structure.questions[question_key("aB3xK9")].prompt ==
                 "How much water does the tank need?"
      end
    end
  end

  describe "Track A: empty answers are not answers (QR6/D5)" do
    test "emits no answer row and no column for a Placeholder-only question", %{
      a: a,
      learners: learners
    } do
      ## 147 distinct Placeholder tiles across 81 production documents. A
      ## Placeholder means the student put nothing in that slot.
      result = parse([track_a_row(a, "aB3xK9", [{"Placeholder", nil}])], learners)
      key = question_key("aB3xK9")

      assert cell(result, a, key) == nil
      ## The column assertion is the load-bearing one: emitting no answer row
      ## while still creating the column inflates cardinality(questions) for
      ## every learner in the report, which is the distortion QR6 removes.
      refute Map.has_key?(result.structure.questions, key)
      refute key in result.structure.question_order
    end

    test "emits no answer row and no column for empty or whitespace-only text", %{
      a: a,
      learners: learners
    } do
      ## 44% of production Text answer entries are the empty string, plus 27
      ## whitespace-only (VR5).
      for text <- ["", "   ", "\n\t"] do
        result = parse([track_a_row(a, "aB3xK9", [{"Text", text}])], learners)
        key = question_key("aB3xK9")

        assert cell(result, a, key) == nil, "expected no answer row for #{inspect(text)}"
        refute Map.has_key?(result.structure.questions, key)
      end
    end

    test "keeps the column when any learner contributes a surviving entry", %{
      a: a,
      b: b,
      learners: learners
    } do
      ## The drop rules apply to entries, and the structure is a union across
      ## learners, so one real answer keeps the column for everyone.
      rows = [
        track_a_row(a, "aB3xK9", [{"Text", ""}]),
        track_a_row(b, "aB3xK9", [{"Text", "a real answer"}])
      ]

      result = parse(rows, learners)
      key = question_key("aB3xK9")

      assert Map.has_key?(result.structure.questions, key)
      assert cell(result, a, key) == nil
      assert [%{"text" => "a real answer"}] = cell(result, b, key)
    end

    test "drops empty entries but keeps the question when siblings survive", %{
      a: a,
      learners: learners
    } do
      row =
        track_a_row(a, "aB3xK9", [
          {"Placeholder", nil},
          {"Text", ""},
          {"Text", "the only real answer"},
          {"Drawing", nil}
        ])

      result = parse([row], learners)

      assert [%{"type" => "Text", "text" => "the only real answer"}, %{"type" => "Drawing"}] =
               cell(result, a, question_key("aB3xK9"))
    end
  end

  describe "Track B: other_tiles" do
    test "collects a learner's free-standing tiles into one cell (BR2)", %{
      a: a,
      learners: learners
    } do
      rows = [
        track_b_row(a, "TABLE_TOOL_CHANGE", "tool-1"),
        track_b_row(a, "DRAWING_TOOL_CHANGE", "tool-2"),
        track_b_row(a, "DATAFLOW_TOOL_CHANGE", "tool-3")
      ]

      result = parse(rows, learners)

      assert result.structure.questions["other_tiles"].type == "clue_tile"
      assert result.structure.questions["other_tiles"].prompt == "Other tiles"
      assert answer_keys(result, a) == ["other_tiles"]
      assert length(cell(result, a, "other_tiles")) == 3
    end

    test "sorts entries by type then link, stable under shuffled row order", %{
      a: a,
      learners: learners
    } do
      rows = [
        track_b_row(a, "TABLE_TOOL_CHANGE", "tool-1"),
        track_b_row(a, "DRAWING_TOOL_CHANGE", "tool-2"),
        track_b_row(a, "DATAFLOW_TOOL_CHANGE", "tool-3")
      ]

      expected = ["Dataflow", "Drawing", "Table"]

      for order <- [
            rows,
            Enum.reverse(rows),
            [Enum.at(rows, 1), Enum.at(rows, 2), Enum.at(rows, 0)]
          ] do
        types = parse(order, learners) |> cell(a, "other_tiles") |> Enum.map(& &1["type"])
        assert types == expected
      end
    end

    test "derives the tile type from the event name for an unseen event (BR4)", %{
      a: a,
      learners: learners
    } do
      ## An event name that exists in neither the code nor the logs. It must
      ## appear with a derived label, never be dropped and never raise, or the
      ## covered types are hardwired in practice (fixture 8b).
      result = parse([track_b_row(a, "SKETCH_TOOL_CHANGE", "tool-9")], learners)

      assert [%{"type" => "Sketch"}] = cell(result, a, "other_tiles")
    end

    test "labels the retired GRAPH_TOOL_CHANGE as Geometry, not Graph (VR23)", %{
      a: a,
      learners: learners
    } do
      ## 1,270,737 real events across 2019-2024. The Geometry tile logged under
      ## this name until the 2024-02-14 rename, and "Graph" is the registered
      ## name of a different current tile type, so deriving it is wrong rather
      ## than merely inconsistent (fixture 8a).
      result = parse([track_b_row(a, "GRAPH_TOOL_CHANGE", "tool-8")], learners)

      assert [%{"type" => "Geometry"}] = cell(result, a, "other_tiles")
    end

    test "matches Track A's casing for compound and acronym types (D4)", %{
      a: a,
      learners: learners
    } do
      rows = [
        track_b_row(a, "BARGRAPH_TOOL_CHANGE", "tool-1"),
        track_b_row(a, "IFRAME_INTERACTIVE_TOOL_CHANGE", "tool-2")
      ]

      types = parse(rows, learners) |> cell(a, "other_tiles") |> Enum.map(& &1["type"])

      ## Track A takes `type` verbatim from the payload as CLUE's registered
      ## string, so a derived "Bargraph" would render the same tile two ways.
      assert types == ["BarGraph", "IframeInteractive"]
    end

    test "omits other_tiles entirely when no learner has a free-standing non-text tile", %{
      a: a,
      learners: learners
    } do
      result = parse([track_a_row(a, "aB3xK9", [{"Text", "x"}])], learners)

      refute Map.has_key?(result.structure.questions, "other_tiles")
      refute "other_tiles" in result.structure.question_order
    end
  end

  describe "structure ordering (D6/VR9, VR19)" do
    test "puts other_tiles first pre-reverse, so it lands rightmost", %{a: a, learners: learners} do
      ## clue.ex sorts, then prepends; ResourceData reverses unconditionally
      ## (resource_data.ex:149), which makes the prepended key the last column.
      ## Prepending inside the reduce instead lets the sort carry it into
      ## alphabetical position, mid-table.
      rows = [
        track_a_row(a, "aB3xK9", [{"Text", "x"}]),
        track_c_row(a, "zzz title", "text tile"),
        track_b_row(a, "TABLE_TOOL_CHANGE", "tool-1")
      ]

      order = parse(rows, learners).structure.question_order

      assert hd(order) == "other_tiles"
      assert tl(order) == Enum.sort(tl(order))
      assert List.last(Enum.reverse(order)) == "other_tiles"
    end

    test "lists other_tiles exactly once (VR19)", %{a: a, learners: learners} do
      ## The structure contract wants the key in both `questions` and
      ## `question_order`, and D6 prepends it after the sort. Adding it in both
      ## places emits res_1_other_tiles_json twice.
      rows = [
        track_b_row(a, "TABLE_TOOL_CHANGE", "tool-1"),
        track_b_row(a, "DRAWING_TOOL_CHANGE", "tool-2")
      ]

      order = parse(rows, learners).structure.question_order

      assert Enum.count(order, &(&1 == "other_tiles")) == 1
    end

    test "keeps a text tile titled \"Other Tiles\" out of the reserved key (VR19)", %{
      a: a,
      learners: learners
    } do
      ## make_safe_id("Other Tiles") is exactly "other_tiles". Colliding loses
      ## one of the two under map_agg and reads the JSON array cell as
      ## json_extract_scalar(answer, '$.text').
      rows = [
        track_c_row(a, "Other Tiles", "a text tile"),
        track_b_row(a, "TABLE_TOOL_CHANGE", "tool-1")
      ]

      result = parse(rows, learners)

      assert result.structure.questions["other_tiles"].type == "clue_tile"
      assert length(answer_keys(result, a)) == 2
      assert [%{"type" => "Table"}] = cell(result, a, "other_tiles")
    end
  end

  describe "Track C: free-standing text tiles are unchanged (BR1)" do
    test "keys by the sanitized tile title and emits the legacy text/url shape", %{
      a: a,
      learners: learners
    } do
      result = parse([track_c_row(a, "My Notes", "what I noticed")], learners)

      assert result.structure.questions["my_notes"].type == "clue_text_tile"
      assert result.structure.questions["my_notes"].prompt == "My Notes"

      ## The legacy pair, not the JSON array: this key is rendered as
      ## _text + _url and must not change, since the key drives the column name.
      cell = result.answers |> Map.get(username(a)) |> hd() |> Map.get(:answer) |> Jason.decode!()

      assert cell["text"] == "what I noticed"
      assert cell["url"] =~ "studentDocument=-OL0rmfqiDsPlriZks-X"
    end

    test "does not fold toolId into the key (BR3 deferred)", %{a: a, learners: learners} do
      result = parse([track_c_row(a, "My Notes", "x", tool_id: "abc123")], learners)

      assert Map.has_key?(result.structure.questions, "my_notes")
      refute Enum.any?(Map.keys(result.structure.questions), &String.contains?(&1, "abc123"))
    end
  end
end
