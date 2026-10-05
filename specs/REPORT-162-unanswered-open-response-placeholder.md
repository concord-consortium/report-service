# Blank the Unanswered Open Response Placeholder in Student Answers

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-162

**Status**: **Closed**

## Overview

When a student opens an open response question and leaves it empty, the Student Answers report showed a long block of report-state JSON in that question's `_text` cell instead of an empty cell. This story makes the "no answer" check recognize the placeholder in every form it is actually stored, and also blanks an answer the student typed and then cleared, so skipped questions read as skipped. A text answer's cell is unchanged. An audio-only answer's `_text` cell is blank too, because its stored answer is the placeholder; the `_url` column still links to the audio.

**Why the old check never matched.** The activity player and LARA store the report-state JSON string as the answer for an opened, unanswered question, and the S3 sync (`functions/src/auto-importer.ts`, `scripts/export-answers.js`) `JSON.stringify`s every answer, so the placeholder is stored escaped: `"{\"mode\":\"report\",...`. The Elixir check looked for `"{"mode":"report"`, a quote followed by unescaped JSON, which no writer produces. It was ported in `0765893` from the query-creator's pre-fix form (`d761da5`), and that JS fix (`4de5142`) also matched nothing.

| Form | Writer | Stored prefix |
|---|---|---|
| Activity player, escaped | any sync since 2021-04-21 | `"{\"mode\":\"report\",\"authoredState\":` |
| LARA, escaped | any sync since 2021-04-21 | `"{\"version\":1,\"mode\":\"report\",\"authoredState\":` |
| Either, unencoded | `auto-importer.ts` before `dd423b7` (2021-04-21) | `{"mode":"report",...` or `{"version":1,"mode":"report",...` |
| Cleared answer | the interactive saves `answerText: ""` | `""` |

## Requirements

- An open response `_text` cell is empty when the stored answer is a report-state placeholder: the JSON-encoded form of a report state that starts with the keys a writer emits first, `{"mode":"report","authoredState":` (activity player) or `{"version":1,"mode":"report","authoredState":` (LARA).
- The check recognizes the raw (unencoded) placeholder forms as well, written by the S3 sync before `dd423b7` (2021-04-21), without first measuring whether any survive.
- An answer the student typed and then cleared, stored as the encoded empty string `""`, also shows an empty `_text` cell. Only an answer that is exactly `""` matches.
- Any other answer's `_text` cell is byte-for-byte unchanged. A text answer is blanked only if the student typed one of the full prefixes above, through `"authoredState":`, at the start of the answer.
- A learner with no stored answer for the question still gets `NULL` through the `ELSE` branch. The tests cover this through the expression's shape: their evaluator only accepts a `CASE` whose `ELSE` returns the answer unchanged.
- `shared_queries_test.exs` has a test per recognized form and for real text answers, each running the emitted pattern on stored bytes written out as the writer produces them, so it fails if a form's alternative is removed or its escaping is wrong.
- The pinned default open response column test from REPORT-157 holds the new expression, and the PR description explains the change.
- The code comment above the open response branch describes the placeholder and the stored encoding.
- The generated SQL grows by about 12% per open response question (1,537 to 1,723 characters, measured with `generate_resource_sql/4`). That is accepted, and lowers how many open response questions fit under Athena's 256KB query limit by the same proportion.

## Technical Notes

- **The expression** is one anchored `regexp_like` built in `open_response_text/1` in `shared_queries.ex`. `@report_state_prefixes` holds the two decoded prefixes; `json_string_prefix/1` derives each encoded form with `Jason.encode!/1`, the encoded empty string is appended, and `Regex.escape/1` makes every alternative a literal. Each alternative is a plain literal, and the `""` one is followed by `\z`, so the pattern means the same in Athena's regex engine and Elixir's. The `""` alternative needs the end anchor because an unencoded answer from before April 2021 can start with `""` and continue. It is `\z` rather than `$` because `$` also matches before a trailing newline in both engines (checked in Trino).
- **Tests** read the pattern back out of the generated SQL with a strict regex (a shape change raises `MatchError`) and run it on fixtures byte-identical to Node's `JSON.stringify` and Ruby's `to_json` output.
- **Athena dialect.** Single-quoted literals take backslashes literally and only `''` is an escape. Verified in a throwaway Trino container, Athena's engine.
- **Do not run `mix format`** on `shared_queries.ex` or its test: neither is formatter-clean, and the formatter rewrites about 500 unrelated lines.
- **Dependency on REPORT-157.** The pinned open response test, `get_columns_for_question/6` and the `text_column`/`url_column` split come from REPORT-157 (PR #431). This story's branch is stacked on that branch.
- **Post-processing is unaffected.** `has_audio` and `transcribe_audio` find `_text` columns by name but read the answer from Firestore through `Helpers.get_answer`.
- **Audio-only answers** are blanked too: the activity player's `{merge: true}` write keeps the placeholder saved when the question was first opened, since it omits `answer` for an audio-only response.

## Out of Scope

- `res_<n>_total_num_answers` and `res_<n>_total_percent_complete` still count placeholders as answers.
- Decoding real answers in the `_text` column. Text answers keep their surrounding quotes and JSON escapes.
- The legacy JS query-creator (`query-creator/create-query/steps/aws.js`), which has its own broken form of the check.
- Changing what the activity player or LARA stores for an empty open response, and rewriting existing parquet files.
- Report runs made before the fix keep their CSV output; re-run the report (or re-fetch it in cc-data) to get blank cells.
- An answer document with no `answer` field fails its learner's whole parquet sync (parquetjs throws `missing required field: answer`). Worth its own ticket.

## Decisions

### Fix the writer or the check?
**Context**: The ticket asked to fix the fault at its source if the source is wrong.
**Options considered**:
- A) Fix the SQL check to match the stored encoding
- B) Change the writer to store the placeholder some other way

**Decision**: A. The writer encodes every answer consistently and the text column depends on that encoding. B would leave every existing file unchanged, so the check would still need to handle the escaped form.

---

### Recognize the placeholder by prefix or by structure?
**Context**: There are two key orders, and a student answer can begin with any text.
**Options considered**:
- A) Literal prefixes per writer and encoding, each running through `"authoredState":`
- B) Decode the answer and check for a JSON object with `mode` = `report`

**Decision**: A. No engine with Athena's JSON functions runs in CI (only MySQL), so B's tests could only compare SQL strings, which is how the original bug survived. Literal prefixes mean the same in Athena and Elixir, so the tests can run the real pattern on real bytes. Running through `"authoredState":` keeps a typed answer from matching.

---

### Include the unencoded forms without checking the data?
**Context**: Whether pre-2021 unencoded files survive needs a full-table Athena scan.
**Options considered**:
- A) Run the query first and include the raw alternatives only if rows appear
- B) Include them without checking
- C) Skip them

**Decision**: B (Doug). They cost about 90 characters per question. They can match a real answer only in an unencoded file, and only if the student typed the full prefix through `"authoredState":`.

---

### Keep a LARA test without data showing LARA placeholders exist?
**Context**: LARA's code does not show whether it saves `{}` for an opened, empty open response.
**Options considered**:
- A) Keep a LARA-order test grounded in LARA's serialization
- B) Drop it unless data shows LARA placeholders

**Decision**: A. It pins key-order independence, and fails if the check regresses to a `mode`-first prefix, the mistake the old code made.

---

### Blank a typed-then-cleared answer?
**Context**: It is stored as `""` and showed as two quote characters. It is not a placeholder, but the acceptance criterion reads as if it should be empty.
**Options considered**:
- A) Blank it too
- B) Leave it for a separate ticket

**Decision**: A (Doug).

---

### How do the tests evaluate the SQL?
**Options considered**:
- A) Parse the pattern out of the emitted SQL and run it on stored bytes
- B) Make the prefix list public and test the bytes against it
- C) Add a SQL engine to the test suite

**Decision**: A. B tests the list rather than the SQL, so a broken literal would pass. C adds a CI dependency for one expression, and DuckDB is not Athena's dialect.

---

### Derive the escaped prefixes or write them out?
**Options considered**:
- A) Write the literals out in the Elixir source
- B) Derive them with `Jason.encode!/1`

**Decision**: B. Hand-escaping is the mistake behind this bug, made twice. The pinned test still shows the rendered pattern verbatim.

---

### One `regexp_like` or a `starts_with` per prefix?
**Context**: `AthenaDb.check_query_size/1` rejects queries over 262,144 characters, and master already rejects 10 activities of 15 open responses each.
**Options considered**:
- A) Four `starts_with` calls joined by `OR` (1,923 characters per question)
- B) One anchored `regexp_like` (1,723 with the cleared-answer alternative)

**Decision**: B. A grew each question's SQL by 25% and would have turned some reports that run today into errors. With B the `^` anchor becomes separately losable, so a test with the prefix after leading text pins it.
