# Implementation Plan: Blank the Unanswered Open Response Placeholder in Student Answers

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-162
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

The plan is written against the code as REPORT-157 (PR #431) leaves it: `get_columns_for_question/6`, the open response branch split into `text_column` and `url_column`, and the pinned default open response test. Start the branch from master once #431 has merged. Against today's master the change is the same, but the pinned test does not exist yet.

The code below was built and run in a throwaway worktree on the REPORT-157 branch: `shared_queries_test.exs` passes (24 tests) and so does the full server suite (1058 tests, 0 failures, 7 skipped). Do not run `mix format` on either file: neither is formatter-clean at the REPORT-157 head, and the formatter rewrites about 500 unrelated lines of `shared_queries.ex`.

### Blank the report-state placeholder and the cleared answer

**Summary**: Replace the open response `_text` expression with one anchored `regexp_like` built from the two writers' leading keys, in encoded and unencoded form, plus the encoded empty string, and test it against the stored bytes. One commit: the expression, its tests and the pinned value change together, and none is reviewable without the others.

**Files affected**:
- `server/lib/report_server/reports/athena/shared_queries.ex`: add `@report_state_prefixes`, `open_response_text/1` and `json_string_prefix/1`; use them for the `_text` column; rewrite the branch comment's first three lines.
- `server/test/report_server/reports/athena/shared_queries_test.exs`: update the pinned default value, add a placeholder `describe` block, extend the moduledoc.

**Estimated diff size**: 87 lines added, 5 removed (measured on the throwaway build).

#### `shared_queries.ex`

Above `get_columns_for_question/6`:

```elixir
  # The keys each writer puts first in an unanswered open response's report state: the activity player, then LARA.
  @report_state_prefixes [~s({"mode":"report","authoredState":), ~s({"version":1,"mode":"report","authoredState":)]

  defp open_response_text(answer) do
    # A cleared answer is stored as the encoded empty string, and no other encoded string starts with it.
    pattern =
      @report_state_prefixes
      |> Enum.flat_map(&[json_string_prefix(&1), &1])
      |> Enum.concat([Jason.encode!("")])
      |> Enum.map_join("|", &Regex.escape/1)

    "CASE WHEN regexp_like(#{answer}, '#{ReportUtils.escape_single_quote("^(?:#{pattern})")}') THEN '' ELSE (#{answer}) END"
  end

  # The opening of the JSON string that encodes a value starting with `prefix`.
  defp json_string_prefix(prefix) do
    prefix |> Jason.encode!() |> String.slice(0..-2//1)
  end
```

`Jason.encode!/1` of the decoded prefix gives exactly what the S3 sync's `JSON.stringify` stores, minus the closing quote, and `Regex.escape/1` makes each prefix a literal, so no escaping is typed by hand (typing it is how both the JS fix and the Elixir port got it wrong). `escape_single_quote/1` is the Presto-safe helper this module already uses. The rendered expression is:

```sql
CASE WHEN regexp_like(<answer>, '^(?:"\{\\"mode\\":\\"report\\",\\"authoredState\\":|\{"mode":"report","authoredState":|"\{\\"version\\":1,\\"mode\\":\\"report\\",\\"authoredState\\":|\{"version":1,"mode":"report","authoredState":|"")') THEN '' ELSE (<answer>) END
```

`regexp_like` rather than four `starts_with` calls keeps the generated SQL inside Athena's 256KB limit for as many questions as possible (see Self-Review, Operator). Each alternative is a plain literal, so the pattern means the same thing in Athena's regex engine and in Elixir's, which the tests rely on. The `""` alternative needs no end anchor: in JSON, a string whose first two characters are `""` is the empty string.

In the open response branch, the first three comment lines become:

```elixir
          # Opening an open response question without answering it saves the question's report state as the answer.
          # Every answer is JSON-encoded on its way to S3, so the placeholder arrives as an encoded string
          # (or, in parquet files written before April 2021, unencoded) and is blanked here, as is an answer the
          # student typed and then cleared.
```

The remaining `note:` lines about `conditional_model_url` and audio-only answers stay. The `text_column` line becomes:

```elixir
          text_column = %{name: "#{column_prefix}_text", value: open_response_text(answer), header: prompt_header}
```

#### `shared_queries_test.exs`

The pinned `_text` value in "by default emits the text and the single-question link" becomes the literal rendered SQL. `~S` keeps the backslashes as written, which is the point of the pin; the key is written out because `~S` does not interpolate, and the pattern line uses `~S[...]` because the pattern contains `|`:

```elixir
                 value:
                   ~S|CASE WHEN regexp_like(learners_and_answers_1.kv1['q39487a59642d'], '| <>
                     ~S[^(?:"\{\\"mode\\":\\"report\\",\\"authoredState\\":|\{"mode":"report","authoredState":|"\{\\"version\\":1,\\"mode\\":\\"report\\",\\"authoredState\\":|\{"version":1,"mode":"report","authoredState":|"")] <>
                     ~S|') THEN '' ELSE (learners_and_answers_1.kv1['q39487a59642d']) END|,
```

The moduledoc gains a paragraph after the open response one:

```elixir
  The text is blanked when the stored answer is the report-state placeholder
  saved for an opened, unanswered question, or a cleared answer. The SQL only renders here, so those
  tests read the `regexp_like` pattern back out of it and run it on the answer
  bytes the writers store, which is what catches an escaping mistake.
```

A new `describe` block goes before `generate_resource_sql/4 with remove_open_response_urls`:

```elixir
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
```

The fixtures are the writers' real output, not hand-escaped: `@activity_player` is byte-identical to Node's `JSON.stringify(JSON.stringify(reportState))` for the production placeholder's shape, and `@lara` to Ruby's `to_json` followed by the same encoding (both compared with `cmp` in the throwaway run). `blanked?/1` raises `MatchError` rather than answering if the expression's shape changes, so it cannot silently go vacuous.

**What each test catches** (each mutation run against the throwaway build):

| Mutation | Failing tests |
|---|---|
| Restore the current expression | activity player, LARA, unencoded, pinned value |
| Drop the LARA prefix | LARA, unencoded, pinned value |
| Drop the unencoded forms | unencoded, pinned value |
| Shorten the prefixes to end at `"report"` | "begins like a report state", pinned value |
| Drop the `^` anchor | "quotes a report state after other text", pinned value |
| Drop the cleared-answer alternative | "typed and then cleared", pinned value |

**Engine check**: the expression rendered by this code, run in a throwaway Trino container over the four stored forms, a cleared answer, a real answer, both look-alike answers, an answer starting with escaped quotes and `NULL`, blanks exactly the four placeholders and the cleared answer and returns the others unchanged (`NULL` stays `NULL`). That agrees with `blanked?/1` on every row.

**PR description notes**: explain the pinned value change (the old literal matched no stored form, the new one is derived from the writers' encoding), list the stored forms with their writers, mention the cleared-answer case, give the measured SQL growth, and say that earlier report runs need re-running to pick it up.

## Open Questions

### RESOLVED: Judgment call: how do the tests evaluate the SQL?
**Options considered**:
- A) Parse the pattern out of the emitted SQL in the test and run it on stored bytes
- B) Make `@report_state_prefixes` (or the encoded list) public and test that the stored bytes start with one of them
- C) Add a SQL engine to the test suite

**Decision**: A. B tests the list, not the SQL, so a broken literal (wrong quoting, a dropped `OR`) would pass; it also turns an internal into an API. C means a Trino or DuckDB dependency in CI for one expression, and DuckDB is not Athena's dialect anyway. A reads what Athena would read, and the strict regexes make a shape change fail loudly.

### RESOLVED: Judgment call: derive the escaped prefixes or write them out?
**Options considered**:
- A) Write the four literals out in the Elixir source
- B) Derive the encoded form with `Jason.encode!/1`

**Decision**: B. Hand-escaping is the exact mistake behind this bug, made twice. The pinned test still shows the rendered pattern verbatim, so a reviewer sees the result without running anything.

## Self-Review

Roles: Operator (Athena limits), Commit Reviewer, Test Writer, Senior Engineer (comment audit).

### Operator

#### RESOLVED: Four `starts_with` calls cost 25% more SQL per open response question
`AthenaDb.check_query_size/1` rejects a query over 262,144 characters ("The resulting query is too large for Athena to process"). Measured with throwaway code over `generate_resource_sql/4`, each open response question costs 1,537 characters on master, 1,923 with the four-call draft and 1,718 with one `regexp_like` (1,721 once the cleared-answer alternative was added). Master already rejects 10 activities of 15 open responses each (268,157 characters), so the draft would have turned some reports that run today into errors. Fixed by switching to the single anchored `regexp_like`, verified in Trino on every stored form. The remaining 12% growth is accepted in the requirements.

---

### Test Writer

#### RESOLVED: Dropping the regex anchor passed every behavior test
With `regexp_like` the anchor is a separate thing that can be lost, and only the pinned string noticed. Added "keeps a text answer that quotes a report state after other text", whose stored bytes contain the escaped prefix after a leading word. It fails without the `^`.

#### RESOLVED: `mix format` would bury the change
Neither file is formatter-clean at the REPORT-157 head (`mix format --check-formatted` exits 1 on both), and running the formatter rewrote about 500 lines of `shared_queries.ex` and three unrelated test hunks. Recorded at the top of the plan: edit by hand, no formatter.

---

### Commit Reviewer

No findings. The step is one commit that compiles and passes alone. Its only dependency is #431 having merged, stated at the top of the plan.

---

### Senior Engineer

No findings. The new and rewritten comments pass the comment audit: each describes the data or the code as it stands, not the change.
