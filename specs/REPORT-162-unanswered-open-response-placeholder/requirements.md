# Blank the Unanswered Open Response Placeholder in Student Answers

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-162
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

When a student opens an open response question and leaves it empty, the Student Answers report shows a long block of report-state JSON in that question's `_text` cell instead of an empty cell. This story makes the existing "no answer" check recognize the placeholder in every form it is actually stored, and also blanks an answer the student typed and then cleared, so skipped questions read as skipped.

## Project Owner Overview

Researchers read the `res_<n>_<question_id>_text` column to see what each student wrote. When a student opened a question but wrote nothing, the cell holds an encoded copy of the question's settings, which looks like an answer and has to be decoded before anyone can tell it is not one. The report has code meant to blank these cells, but it looks for the placeholder in a shape no writer produces, so it has never blanked one since the report moved to the current server.

After this change, a skipped question's cell is empty, and so is the cell for an answer the student typed and then deleted, which today shows as two quote characters. A real answer's cell is unchanged. Nothing else in the report changes.

## Background

**How an unanswered open response gets stored.** The activity player saves an answer document to Firestore whenever an interactive reports state. When an open response question reports `{}` (opened, nothing typed or recorded), the state has no `answerType`, so `getAnswerWithMetadata` (`activity-player/src/utilities/embeddable-utils.ts`) falls through to the generic branch and stores the report-state JSON string as `answer`. LARA does the same for its `interactive_state` type (`lara/app/models/interactive_run_state.rb`, `result[:answer] = result[:report_state]`).

**How it reaches Athena.** `syncToS3` in `functions/src/auto-importer.ts` writes each learner's answers to parquet with `answer.answer = JSON.stringify(answer.answer)`, and `scripts/export-answers.js` (the bulk exporter) does the same. Stringifying a string wraps it in quotes and escapes its inner quotes, so every answer in `partitioned_answers.answer` is JSON-encoded: a text answer is stored as `"This is DougTest Two's text answer"`, quotes included, and the placeholder as `"{\"mode\":\"report\",...`. This matches the production evidence in the ticket (learners 73333 and 73334).

**Why the check misses.** `get_columns_for_question/5` in `server/lib/report_server/reports/athena/shared_queries.ex` emits

```sql
CASE WHEN starts_with(<answer>, '"{"mode":"report"') THEN '' ELSE (<answer>) END
```

Athena string literals treat backslashes literally, so this looks for a quote followed by unescaped JSON. No writer produces that: stringifying a string always escapes the inner quotes, and an unstringified value has no leading quote. The history explains it. The check was added to the legacy JS query-creator in `d761da5` (2023-10-13) in this same form, "fixed" for escaping in `4de5142` (2023-10-17), and then ported to Elixir in `0765893` from the pre-fix form. Rendering the JS fix's template literal shows it produces `"{\"mode":\"report\"`, which also matches nothing, so the check has likely never worked in either codebase.

**Stored forms.** Built with the real writers' serialization and checked against the current SQL in DuckDB (throwaway, deleted), none is blanked today:

| Form | Writer | Stored prefix | Blanked now |
|---|---|---|---|
| AP, escaped | activity player, any sync since 2021-04-21 | `"{\"mode\":\"report\",...` | no |
| LARA, escaped | LARA runtime, any sync since 2021-04-21 | `"{\"version\":1,\"mode\":\"report\",...` | no |
| AP or LARA, raw | `auto-importer.ts` before `dd423b7` (2021-04-21) stored the string unencoded | `{"mode":"report",...` or `{"version":1,"mode":"report",...` | no |

The AP key order (`mode` first) has been stable since `embeddable-utils.ts` was written (checked at `5ef28e9` and `ac43dbf`). LARA's Ruby hash puts `version` first, so a prefix check on `mode` would miss LARA placeholders even when correctly escaped. A parquet file is rewritten whenever any of that learner's answers for the resource changes, so whether raw-form files survive is a question for the data (see Open Questions).

**Where the fault is.** The writer is correct: it encodes every answer the same way, and the text column's existing output depends on that encoding (real answers keep their quotes). The fault is the SQL check, so the fix belongs there rather than in the writer, which would also leave every existing parquet file unchanged.

## Requirements

- An open response `_text` cell is empty when the stored answer is a report-state placeholder: the JSON-encoded form of a report state that starts with the keys a writer emits first, `{"mode":"report","authoredState":` (activity player) or `{"version":1,"mode":"report","authoredState":` (LARA).
- The check recognizes the raw (unencoded) placeholder forms as well, written by the S3 sync before `dd423b7` (2021-04-21), without first measuring whether any survive.
- An answer the student typed and then cleared, stored as the encoded empty string `""`, also shows an empty `_text` cell.
- Any other answer's `_text` cell is byte-for-byte unchanged. A text answer is blanked only if the student typed one of the full prefixes above, through `"authoredState":`, which is not a plausible answer.
- A learner with no stored answer for the question still gets the same cell as today (Athena `NULL` through the `ELSE` branch). The tests cover this through the expression's shape: their evaluator only accepts a `CASE` whose `ELSE` returns the answer unchanged. A separate Elixir test would have to imitate SQL `NULL` handling and could not fail.
- `shared_queries_test.exs` gains a test per recognized form and one for a real text answer. Each test checks stored bytes, written out as the writer produces them, against the emitted SQL, so it fails if the clause for that form is removed or if its escaping is wrong. A test that only compares the emitted SQL to an expected string is not enough: that is the kind of test the query-creator has for the same check, and it pinned the broken escaping in place.
- The pinned default open response column test that REPORT-157 adds is updated to the new expression deliberately, and the PR description explains the change.
- The code comment above the open response branch describes the placeholder and the stored encoding accurately.
- The generated SQL grows by about 12% per open response question (1,537 to 1,721 characters, measured with `generate_resource_sql/4`). That is accepted. It lowers how many open response questions fit under Athena's 256KB query limit by the same proportion.

## Technical Notes

- **Dependency on REPORT-157.** The pinned open response test the acceptance criteria name is added by REPORT-157 (PR #431, open, worktree `~/projects/report-service.worktrees/REPORT-157`), which also changes `get_columns_for_question` to `/6` and splits the open response branch into `text_column`/`url_column` locals. This story's code lands on master after #431 merges; the specs do not depend on it.
- **Only the `_text` expression changes.** The `_url` column, the `_submitted` column, and the other question types are untouched. `iframe_interactive` and the CLUE types emit the raw answer elsewhere and are not open responses.
- **Post-processing is unaffected.** `has_audio` and `transcribe_audio` locate `_text` columns by name but read the answer from Firestore through `Helpers.get_answer`, not from the cell.
- **Athena dialect.** Single-quoted literals take backslashes literally and only `''` is an escape, so the escaped prefix appears in the SQL exactly as stored. In Elixir source each stored `\"` needs writing as `\\\"`, which is the escaping the port lost. Checked in a throwaway Trino container (Athena's engine): `length('\"')` is 2, and a prefix check rendered from Elixir with `Jason.encode!/1` blanks all four stored forms in the table above, leaves a real answer and an answer beginning `"{\"mode\":\"report\"` unchanged, and keeps `NULL` for a learner with no stored answer.
- **cc-data** reads the report CSV but does nothing with `_text` cell contents (checked in `cc-data-cli/internal/duck/views.go`).

## Out of Scope

- `res_<n>_total_num_answers` and `res_<n>_total_percent_complete` count every stored answer, placeholders included (`cardinality(array_intersect(map_keys(kv1), ...))`), so a learner who opened and skipped a question is counted as having answered it. Changing those counts is a separate decision.
- Decoding real answers in the `_text` column. Text answers keep their surrounding quotes and JSON escapes, as they do today.
- The legacy JS query-creator (`query-creator/create-query/steps/aws.js`), which carries its own broken form of the same check.
- Changing what the activity player or LARA stores for an empty open response, and rewriting existing parquet files.
- Report runs made before the fix keep their CSV output; a researcher re-runs the report (or re-fetches it in cc-data) to get blank cells.
- An answer document with no `answer` field would fail its learner's whole parquet sync: `JSON.stringify(undefined)` leaves the required `answer` column unset and parquetjs throws `missing required field: answer` (checked with throwaway code against `functions/node_modules/parquetjs`). The activity player omits `answer` for an audio-only open response, but its `{merge: true}` write keeps any earlier `answer`, so this only happens if no placeholder was saved first. Worth its own ticket; not changed here.
- REPORT-157's spec (closed) describes the escaped-placeholder leak as an accepted state; it is a record of that story and is not edited.

## Open Questions

### RESOLVED: Judgment call: fix the writer or the check?
**Context**: The ticket asks to fix the fault at its source if the source is wrong.
**Options considered**:
- A) Fix the SQL check to match the stored encoding
- B) Change the writer to store the placeholder some other way (or not at all)

**Decision**: A. The writer encodes every answer consistently and the text column already depends on that encoding; the check is what is wrong. B would also leave every existing file unchanged, so the check would still have to handle the escaped form.

### RESOLVED: Judgment call: recognize the placeholder by prefix or by structure?
**Context**: There are two key orders, and a student answer can begin with any text.
**Options considered**:
- A) Prefixes: one per writer and encoding, each running through `"authoredState":`
- B) Decode the answer and check that it is a JSON object with `mode` = `report`

**Decision**: A (revised in self-review, see QA Engineer). B is key-order independent, but no engine with Athena's JSON functions runs in CI (the report-server workflow has only MySQL), so its tests could only compare SQL strings, which is how the current bug survived. An anchored alternation of literal prefixes means the same thing in Athena's `regexp_like` and in Elixir's `Regex`, so a test can run the emitted pattern on real stored bytes (the implementation spec explains why one `regexp_like` rather than one `starts_with` per prefix). Running each prefix through `"authoredState":` keeps a typed answer from matching.

### RESOLVED: Do raw (unencoded) placeholders exist in `partitioned_answers`?
**Context**: Before `dd423b7` (2021-04-21) the auto-importer wrote string answers unencoded. Whether any of those files survive decides whether the raw-form clause and its test are needed. Answering it needs an Athena query over the whole table, which is not run without Doug's go. Ready to run:

```sql
SELECT
  CASE
    WHEN starts_with(answer, '"{\"mode\":\"report\"') THEN 'ap_escaped'
    WHEN starts_with(answer, '"{\"version\":1,\"mode\":\"report\"') THEN 'lara_escaped'
    WHEN starts_with(answer, '{"mode":"report"') THEN 'ap_raw'
    WHEN starts_with(answer, '{"version":1,"mode":"report"') THEN 'lara_raw'
    ELSE 'other'
  END AS form,
  question_type,
  count(*) AS n
FROM "report-service"."partitioned_answers"
WHERE strpos(answer, 'mode') > 0 AND strpos(answer, 'report') > 0
GROUP BY 1, 2
ORDER BY 1, 2
```

**Options considered**:
- A) Run the query; include the raw clause only if `ap_raw` or `lara_raw` rows appear among open response answers
- B) Include the raw clause without checking (one extra `OR`, harmless to real answers, which always start with `"`)
- C) Skip raw forms

**Decision**: B (Doug). The query is not run. The unencoded alternatives cost about 90 characters per open response question and cannot match a real answer, which is always stored with a leading `"`.

### RESOLVED: Low confidence: do LARA-written placeholders reach open response columns?
**Context**: LARA stores the report state as the answer for an `interactive_state` answer, but whether LARA ever saved `{}` for an opened, empty open response (rather than saving nothing) is not visible in its code. The structural check covers LARA placeholders either way.
**Options considered**:
- A) Keep a LARA-order test, grounded in the writer's serialization
- B) Drop it unless the data query finds LARA placeholders

**Decision**: A. The test's job is to pin key-order independence, which is a property of the requirement whatever the data holds: it fails if the check regresses to a `mode`-first prefix, which is the mistake the current code already makes. The fixture is built from LARA's real serialization (`{version: 1, mode: 'report', ...}.to_json`), not invented.

## Self-Review

Roles: Senior Engineer, QA Engineer, Education Researcher, Data Engineer (Athena and the answer pipeline).

### QA Engineer

#### RESOLVED: The structural check could not be tested against stored values in CI
The draft required tests that evaluate the emitted expression, and chose a structural check built on Athena JSON functions. Nothing in CI can run those: `.github/workflows/report-server.yml` has only a MySQL service, and `server/mix.exs` has no Trino or DuckDB dependency. Tests would fall back to comparing strings, which is how the query-creator's test kept the broken escaping. Fixed by switching the judgment call to prefixes, whose `starts_with` semantics an Elixir test can reproduce exactly.

---

### Senior Engineer

#### RESOLVED: An audio-only answer is affected the same way as a skipped one
The activity player writes answers with `batch.set(..., {merge: true})` (`activity-player/src/firebase-db.ts`) and leaves `answer` undefined for an audio-only open response, so the placeholder saved when the question was first opened stays as the stored answer. Those cells leak today and are blanked by this fix, which is what REPORT-157 assumed. No requirement change; recorded so the audio-only case is in the tests' scope.

#### RESOLVED: A typed-then-cleared answer shows `""`
When a student types and then deletes their text, the interactive saves `answerText: ""` (`question-interactives/packages/open-response/src/components/runtime.tsx`), which is stored as `""` and shows as two quote characters. It is not a placeholder, so the ticket does not cover it, but the acceptance criterion "an unanswered open response question shows an empty `_text` cell" reads as if it should. Options: A) blank `""` too (one more case and a test); B) leave it for a separate ticket. Decision: A (Doug). Added as a requirement.

---

### Education Researcher

#### RESOLVED: Earlier report runs are not corrected
Report output is a CSV written per run, so runs made before the fix still hold the placeholder. Added to Out of Scope with the remedy (re-run or re-fetch).
