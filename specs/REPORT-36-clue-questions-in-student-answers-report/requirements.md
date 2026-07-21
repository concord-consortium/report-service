# CLUE Questions in Student Answers Report

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-36
**Repo**: https://github.com/concord-consortium/report-service
**Status**: **In Development**

## Overview

<!-- Rewritten during Finalization -->
Extend the Student Answers report so CLUE (Collaborative Learning) documents surface student work in a form that resembles the activity-player report. CLUE ships a purpose-built **Question tile** that carries a stable reporting id and fixed prompt; the report should aggregate student answers by that id (handling copies), document each answer tile's type and text, and link to the student's document at the correct history point. This is **additive** to, not a replacement for, reporting on free-standing tiles.

## Project Owner Overview

<!-- Rewritten during Finalization -->
Researchers can already see CLUE **text** answers in the Student Answers report, but little else. CLUE added a **Question tile** specifically to make this report work well: it has a fixed prompt and a stable id that stays the same across every student's copy, so all students' answers to the same authored question line up in one column, exactly like an authored activity. This story makes the report use that mechanism (so copies group correctly and every answer tile is documented by type, with text shown where present), while *also* continuing to report on tiles that aren't inside a Question tile. Each student's entry links to their document at the right moment in its history.

## Background

CLUE runnables are already routed through a dedicated path in the Elixir `server/` app and feed the same Student Answers report AP/LARA runnables use:

`student_answers_report.ex` -> `resource_data.ex` (routes CLUE vs AP via `Clue.is_clue_url?/1`) -> `clue.ex` (queries the Athena **log** DB, builds a denormalized question structure, writes CLUE answers as parquet into the same `partitioned-answers/…` layout AP uses) -> `shared_queries.ex` (`map_agg` by `question_id`, then per-question typed columns).

Today this path only handles **text** tiles: `clue.ex` matches `TEXT_TOOL_CHANGE` and keys questions by `make_safe_id(tile_title)` (`clue.ex:114`), emitting a single `clue_text_tile` type rendered as `_text` + `_url` columns.

**Key discovery (from `collaborative-learning/src`, 2026-07-20):** CLUE has a dedicated **Question tile** built for this report, plus a dedicated log event, `QUESTION_ANSWERS_CHANGE`:

- **Question tile** (`models/tiles/question/question-content.ts`) is a *container* holding a fixed/locked prompt Text tile plus the student's answer tiles. It has a **`questionId`** prop explicitly documented as *"Used in reporting; should be left unchanged for all locked copies of the same question."*
- **Copy semantics** (`question-utils.ts:updateQuestionContentForCopy`): copied **across documents** (author to student) yields `locked=true` with **questionId preserved**, so every student's answers aggregate under one id (real AC1). Copied **within a document** yields a **new questionId**, so it becomes a distinct question (relevant to AC2).
- **`QUESTION_ANSWERS_CHANGE`** (`log-tile-base-event.ts:81`) is logged whenever a tile inside a Question tile changes. Via `getQuestionAnswersAsJSON` it carries **`questionId`**, the Question **`tileId`**, and an **`answers`** array. **`answers` is nested**, not flat: it is `[{ tileId: <questionTileId>, answerTiles: [{ tileId, type, plainText? }] }]`, i.e. one group per Question tile in the document matching this `questionId`, each wrapping its own list of answer tiles (`type`, plus `plainText` for Text tiles; the fixed-position prompt tile is excluded). A single `questionId` can yield **more than one** group, so clue.ex must flatten `answers[*].answerTiles[*]` rather than reading `answers[*]` directly. Because it goes through `logDocumentEvent`, it also carries **`documentKey`** and **`documentHistoryId`** (`log-document-event.ts:110,116`) for the AC5 link, and the standard log envelope (`run_remote_endpoint`, `username`, `time`, `application`) is added by ingest, so it is filterable per learner exactly like `TEXT_TOOL_CHANGE`.

So `QUESTION_ANSWERS_CHANGE` supplies AC1 through AC5 for Question tiles in report-ready form, keyed by the real stable id, all from the log stream this pipeline already reads (no Firestore). The current title-hash text path predates this and is best understood as the *free-standing-tile* fallback.

This reframes the work into two additive tracks (below). It also largely dissolves the earlier "sparse columns" worry **for Question tiles**: their shared stable ids and fixed prompts make columns dense and aligned across students, like an authored activity. The sparsity concern only applies to the free-standing-tile track.

## Requirements

### Track A: Question tiles (primary; the intended AC1/AC2 mechanism)

- **QR1 (AC1): Aggregate by stable questionId.** Aggregate student answers by the Question tile's `questionId` (from `QUESTION_ANSWERS_CHANGE`), not by title. Answers to the same authored question align in one column across all students. The column **header** is the authored prompt when available, falling back to the `questionId` label; prompt availability is new-data-only and gated on the CLUE-side enrichment (see DR1/DR2).
- **QR2 (AC2): Copies show both/any answers.** Across-document copies share a `questionId` (student answers group correctly); within-document copies get a new `questionId` and appear as distinct questions. Neither case collapses or drops an answer.
- **QR3 (AC3): Text answers shown.** Text answer tiles within a question surface their `plainText` from the answers payload, as the `text` field of their entry in the question's JSON answer array (see the "JSON array of `{type, text?, link}`" render decision in the Round 3 Self-Review).
- **QR4 (AC4): Non-text answer tiles document their type.** Each non-text answer tile within a question surfaces its **type** (Drawing, Table, Geometry, etc.) as the `type` field of its entry in the question's JSON answer array, alongside a history `link`; it carries no `text` field. Full rendered content is **not** required.
- **QR5 (AC5): History link.** Each student's question answer links to their CLUE document at the correct history point, using `documentKey` + `documentHistoryId` from the event.

### Track B: Free-standing tiles (additive extension of today's text path)

- **BR1 (AC3, no regression): Free-standing text tiles keep their own columns.** Existing per-title text-tile reporting for tiles not inside a Question tile is preserved unchanged (one column each, as today).
- **BR2 (AC4): Non-text free-standing tiles aggregate into one "other tiles" column.** Broaden beyond `TEXT_TOOL_CHANGE` to the other `*_TOOL_CHANGE` events, and collect all of a student document's non-text, non-Question tiles into a **single aggregated column** whose cell is a JSON array of `{type, link}` entries (one per tile; each tile's own history link, see the render decision in the Round 3 Self-Review). The column is materialized by a synthetic denormalized-structure entry (see the "BR2 / Track A denormalized-structure contract" Technical Note): canonical key `other_tiles`, type `clue_tile`, header/prompt `Other tiles`. This is the only new Track B column, and it appears **last** (rightmost) among the answer columns.
- **BR3 (deferred, not in scope): Same-title collision fix.** Folding `toolId` into the title-keyed id (so two same-title free-standing text tiles don't collide in `map_agg`) is **deferred**: AC2 ("copied question shows both") is fully handled by Track A via `questionId`, and text-tile behavior is otherwise unchanged, so this is a pre-existing latent edge case, not required by this story. It is affirmatively **excluded** here because implementing it would rename every existing free-standing text column (the key drives the `shared_queries` column name), which conflicts directly with BR1's "preserved unchanged." If ever pursued, it must be a separate, conscious column-name-compatibility decision.

### Dependencies / Risks

- **DR1: QR1 prompt-labeled headers depend on an out-of-repo CLUE change (new-data-only).** The fixed prompt is provably absent from `QUESTION_ANSWERS_CHANGE` today (the fixed-position prompt tile is excluded at emission), so labeling columns by the authored prompt is achievable only for **new** data, and only after the "option D" enrichment (adding the prompt to the event) ships in the separate `collaborative-learning` repo. **Recommendation: track that enrichment as its own Jira ticket** in the CLUE project (a `collaborative-learning` story, linked to REPORT-36 as a dependency) with a named owner, rather than relying on the "Slack question #1" thread. This story does **not** block on that ticket: it ships the `questionId` fallback for all current/historical data (see QR1 and DR2), and the report prefers the enriched prompt field automatically once it appears in new logs.
- **DR2: Historical and pre-enrichment data show the raw `questionId` fallback header, which is an opaque 6-character id.** Answer content, tile types, and history links all work on historical logs per XR5; only the column **header** degrades. The fallback is the raw `questionId` (a `uniqueId(6)` string like `aB3xK9`), chosen for global stability over a run-local "Question N" ordinal, so every Track A column in a historical/pre-enrichment report is opaque and a researcher must use the AC5 history link to see the underlying question. Accepted trade-off (Leslie Bondaryk / Doug Martin, 2026-07-21). **Column order** is the same story: Track A columns are ordered by the sanitized `questionId`, netting out to **reverse-alphabetical (descending)**, the combined effect of `clue.ex`'s ascending `Enum.sort` (`:192`) followed by `ResourceData`'s unconditional `Enum.reverse` (`resource_data.ex:149`). This is globally stable across classes/reports but non-semantic; ordering by event `time` was rejected because it would vary per cohort (see Round 3 Self-Review). The order key must be a deterministic function of the `questionId`, not a run-local surrogate. No ordering-pipeline change is needed; the descending net order is accepted as-is (matching today's text-path behavior).

### Cross-cutting

- **XR1: No double-counting.** A tile reported as an answer within a Question tile (Track A) should not *also* appear as a free-standing tile (Track B), and vice versa. The two tracks target disjoint tiles. **Mechanism (resolved):** the Track B log query excludes any tile-change event with a non-empty `containerIds` (Question is currently the only container tile type); see the resolved Open Question and the Track B Technical Note.
- **XR2: Real resource/activity name.** Replace the hardcoded `"Test Clue"` (`clue.ex:20`) with a meaningful CLUE activity name.
- **XR3: No regression to non-CLUE reports.** AP/LARA Student Answers and the Student Assignment Usage report share `shared_queries.ex`; new behavior must be additive (new question-type cases non-CLUE data can never match).
- **XR4: Test coverage.** Add automated tests for the CLUE Student Answers path (both tracks). None exist today: no test exercises `clue.ex`'s query path or the `clue_text_tile` report branch, and the only CLUE test (`job_test.exs`) covers the `ClueLinkToWork` post-processing CSV step, not report generation. Existing fixtures are `TEXT_TOOL_CHANGE`-only, so most of this work is **building new fixtures**, which is a substantial part of the effort, not a tail task. New fixtures must carry the nested `QUESTION_ANSWERS_CHANGE` payload, `containerIds`, and non-text `*_TOOL_CHANGE` events, and cover: AC1 shared-`questionId` alignment across learners (**with ≥2 learners sharing one `questionId`, to catch the per-learner aggregation-grain trap in the Track A Technical Note**); AC2 within-doc (new id) vs across-doc (preserved id) copy; XR1 disjointness via non-empty `containerIds`; the map_agg single-value aggregation for BR2 / multi-answer-tile Track A questions (see the clue.ex single-value-per-key Technical Note); and **a hyphenated `questionId` (plus one differing from another only by case/`-`/`_`) to lock the key-sanitization behavior (see the "not a safe SQL identifier" Technical Note)**; and **a Text answer whose `plainText` contains special characters (embedded double-quotes, commas, newlines) to lock the nested-JSON -> Athena-CSV -> Elixir round-trip**, since the current parser hand-trims surrounding quotes (`clue.ex:148`) rather than trusting the CSV decoder, and `plainText` is consumed verbatim (see the Track A `plainText` Technical Note).
- **XR5: Works on historical logs.** The report must function on logs **already written**, before any CLUE-side logging change we might request. Any CLUE enrichment (e.g. adding a prompt field to `QUESTION_ANSWERS_CHANGE`) can only be a *progressive enhancement* for new data. All **answer content** the report produces must come from data already present in existing Athena partitions. The one accepted degradation for historical logs is the Question-tile **prompt header**, which is not recoverable point-in-time from old logs (see resolved QR1 prompt-source decision) and falls back to the raw `questionId` (an opaque 6-character id) plus the AC5 history link (see DR2).
- **XR6: CLUE completion metrics are approximate; the synthetic `other_tiles` column is not specially excluded.** `res_N_total_num_questions`, `res_N_total_num_answers`, and `res_N_total_percent_complete` are computed generically in `shared_queries.ex` from the denormalized `questions` map (`num_questions = cardinality(questions)` at `:93`; `num_answers` from `array_intersect(map_keys(kv1), map_keys(questions))` at `:79`). Because the CLUE structure is discovered from the **union of learners' answers** (not an authored question set), every answer column already counts as one "question," and a learner is penalized in `percent_complete` for a column another learner created. The synthetic `other_tiles` entry (BR2) therefore also counts as **one** question and, when present, one answer for that learner, even though it aggregates multiple tiles. **Accepted as-is:** CLUE completion totals are explicitly an approximation, and `other_tiles` is one incremental column on top of the pre-existing text-tile approximation, not a new class of distortion. **Excluding `clue_tile` from the counters was considered and rejected** because there is no CLUE-local way to do it: `shared_queries` derives both column emission and the counters from the same `questions`/`question_order` structures, so any exclusion (a `type <> 'clue_tile'` count filter, or a nil-guard to keep `other_tiles` out of the `questions` map) edits the **shared** query generation used by all AP/LARA answers and usage reports, blast radius not justified for a metric that is already approximate. (`Map.get(nil, :type)` raises `BadMapError`, so the "put it in `question_order` but not `questions`" trick is not viable without that shared nil-guard.)

## Technical Notes

- **Primary file (CLUE-only, no shared blast radius):** `server/lib/report_server/clue.ex`
  - Track A: add a log query over `QUESTION_ANSWERS_CHANGE`. **Selecting the latest event must partition per learner document, not by `questionId` alone**: use `ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, questionId ORDER BY time DESC)` (or add `run_remote_endpoint`/`documentKey` to the grouping). Do **not** copy `get_text_tile_answer_sql/1`'s `MAX(time) GROUP BY toolId` self-join verbatim: that query is per-learner only because `toolId` is a globally-unique `nanoid(16)`, whereas `questionId` is deliberately **shared across every student's copy** (`updateQuestionContentForCopy` preserves it across documents, the AC1 mechanism), so grouping by `questionId` alone keeps one arbitrary student's event and silently drops all others. A window function also avoids the `time`-tie duplicate-row risk in the current self-join. Parse the nested `answers` payload (`answers[*].answerTiles[*]`, flattening across the possibly-multiple per-question-tile groups) into answer entries (type + optional text) and a history link from `documentKey`/`documentHistoryId`. Emit a new question type (e.g. `clue_question`) and answer-tile representation. **`plainText` is consumed directly:** it is already plain text (`getQuestionAnswersAsJSON` calls `asPlainText()`), so it must **not** be routed through the text path's Slate-document handling, `Jason.decode(text_trimmed)` + `extract_text` with an `else -> row_acc.answers` fallback (`clue.ex:147-178`). A bare `plainText` string is not decodable as the expected `{"document": {...}}` Slate shape, so reusing that block would hit the fallback and **silently drop every Track A text answer** (no error, cells just come back blank). `QUESTION_ANSWERS_CHANGE` also carries no `operation` field, so do not copy the text query's `operation = 'update'` filter.
  - **`questionId` is not a safe SQL identifier (Track A key sanitization).** `shared_queries.ex` builds each answer column as an **unquoted** alias `res_#{activity_index}_#{question_id}` (`:399`, emitted via `"#{value} AS #{name}"`, `:515`). Today's text key is `make_safe_id`-clean; a raw `questionId` is `nanoid(6)` over nanoid's default alphabet, which includes `-` (~9% of ids), `_`, mixed case, and leading digits, so a raw key produces invalid Presto SQL (e.g. `res_1_xg-MIL_text`, where `-` parses as subtraction). Track A must therefore sanitize `questionId` into an alias-safe key **before** it becomes the `map_agg`/structure key, but not with a lossy character-class replace: `make_safe_id` would fold distinct ids differing only by case or `-`/`_` (e.g. `ab-cde`/`ab_cde`/`AB-CDE`) into one key and silently merge their answers (AC1/AC2 violation). Use a collision-free transform (e.g. hex-encode) or decouple the internal column key (safe surrogate) from the opaque header (the raw `questionId`, per QR1/DR2). See the Round 2 Self-Review for the measured hyphen rate.
  - Track B: broaden `get_text_tile_answer_sql/1` (`clue.ex:39-73`) to the full `*_TOOL_CHANGE` set and carry the event name to a tile type. Emit `clue_tile` for non-text free-standing tiles. **Do not** fold `toolId` into `make_safe_id(tile_title)` (`clue.ex:114`): that is the deferred BR3 change, and it is out of scope here because it would rename **every** existing free-standing text column (`res_1_<title>_text` -> `res_1_<title>_<toolId>_text`, not just colliding ones, since the key drives the column name in `shared_queries`), breaking BR1's "preserved unchanged" guarantee. Keep the free-standing text key as `make_safe_id(tile_title)` exactly as today.
  - **Single-value-per-key constraint (BR2 and multi-tile Track A):** the report aggregates answers with `map_agg(a.question_id, a.answer)` (`shared_queries.ex:24`) and reads one value per key (`kv1['<question_id>']`, `:438`). Today each tile has its own distinct key, so there is never a duplicate. BR2's single "other tiles" column and any Track A question with more than one answer tile therefore cannot be produced by writing one parquet row per tile: they must be aggregated Elixir-side in clue.ex into **one** answer row per (student, key) whose `answer` is a JSON **list** before the parquet write. Each entry has the stable shape `{"type": <friendly tile type>, "text": <plainText, Text tiles only>, "link": <AC5 history link>}` (uniform across Track A and Track B; `link` is carried per entry, see the Round 3 render decision). Reusing one shared key across per-tile rows instead would hit `map_agg`'s duplicate-key de-duplication and lose tiles.
  - **BR2 / Track A denormalized-structure contract (a column only exists if the structure declares it):** `shared_queries.ex` builds an answer column only for keys present in **both** `question_order` and the `questions` map (`:218-219`), so aggregating answer *rows* into parquet is not enough, clue.ex must also add matching `structure.questions` + `question_order` entries. For **Track A**, add one entry per question keyed by the sanitized `questionId` (collision-free safe key), `type: "clue_question"`, `prompt:` the enriched prompt when present else the raw `questionId` (per QR1/DR2), `required: false`. For **BR2**, add a **single synthetic** entry keyed `other_tiles`, `type: "clue_tile"`, `prompt: "Other tiles"`, `required: false`, present whenever any learner in the report has ≥1 non-text free-standing tile. Because it lives in the `questions` map, this entry counts toward the completion totals as one question (and one answer when present); that is accepted as-is per XR6 (excluding it would require a shared `shared_queries` change). **Ordering:** Track A question keys and free-standing text keys interleave in the one sorted `question_order` (they remain separate columns; only their left-to-right position is shared), netting to reverse-alphabetical (DR2). To pin `other_tiles` **last** despite `ResourceData`'s reversal (`resource_data.ex:149`), clue.ex **prepends** `other_tiles` to `question_order` *before* returning (pre-reverse first -> post-reverse last); no `resource_data.ex` change is required.
  - XR2: hardcoded name at `clue.ex:20`.
- **Shared file (additive only):** `server/lib/report_server/reports/athena/shared_queries.ex`
  - `get_columns_for_question/5` (`shared_queries.ex:390`): the `clue_text_tile` branch (`:442-446`) emits `_text` + `_url`. Add branch(es) for the new Track A `clue_question` type and Track B `clue_tile` type. Unlike `clue_text_tile`, each emits a **single** column carrying the JSON answer array verbatim (`%{name: "#{column_prefix}_json", value: answer, header: prompt_header}`, i.e. the existing `_ ->` fallback shape at `:491-494` with a prompt header added, not `json_extract_scalar`-ed `_text`/`_url` sub-columns), since the cell is a variable-length `{type, text?, link}` array meant for cc-data SQL consumption (see the Round 3 render decision). The `_json` suffix is the committed column-name contract for both new branches (matching the fallback), so cc-data and tests should expect `res_<n>_<key>_json`. The legacy `clue_text_tile` `_text`/`_url` pair stays only for Track B free-standing text tiles (BR1). Non-CLUE types never match the new branches, so existing branches (`open_response`, `multiple_choice`, `iframe_interactive`, `image_question`, …) are untouched (XR3). Note the module (`generate_resource_sql`) is shared with the Student Assignment Usage report, but `get_columns_for_question/5` itself is **answers-only** (called only under `if report_type == :answers`, `:210`), so usage reports never exercise the new branches; add **direct answers-path** query-generation tests for the CLUE `clue_question`/`clue_tile` branches, and keep usage-report tests as broad smoke coverage only.
- **Reused unchanged:** `reports/clue/history_link.ex`, the parquet writer + `partitioned-answers` S3 layout (`clue.ex:75-83,196-204`), and the downstream report SQL.
- **CLUE source references:** `question-content.ts` (`questionId`, prompt), `question-utils.ts` (`updateQuestionContentForCopy`, `getQuestionAnswersAsJSON`), `log-tile-base-event.ts:45-83` (`QUESTION_ANSWERS_CHANGE` emission), `log-document-event.ts` (documentKey/historyId).
- **Performance:** the log query scans `logs_by_time`; adding event types widens the scan and runs once per CLUE runnable during resource fetch. Post-REPORT-42 partitioning should bound this; validate scan size on a realistic dataset before marking done.

## Out of Scope

- Rendering the **content** of non-text tiles (drawings, tables, graphs). Only type + history link are surfaced; full state lives in Firestore, which this pipeline does not read.
- Reading CLUE tile state from Firestore or any source other than the Athena log DB.
- Changing the shared `map_agg` answer aggregation in `shared_queries.ex` (rejected high-blast-radius option; see Open Questions).
- Any change to the AP/LARA answer path beyond the guaranteed-inert additive column cases.

## Open Questions

### RESOLVED: Track B scope, only Question tiles or all tiles?
**Context**: CLUE's Question tile is purpose-built for this report (stable `questionId`, fixed prompt, `QUESTION_ANSWERS_CHANGE` event). Initially resolved as additive (Doug Martin, 2026-07-20); briefly re-opened 2026-07-21 when Leslie said the intent was Question tiles, not making old documents line up like questions. Doug asked her directly whether she wanted only Question tiles or all tiles added.
**Decision** (Leslie Bondaryk, 2026-07-21): **all tiles (additive).** *"I think you should add all tiles, ones with text should show text others can be seen on a link."* So both tracks ship: Track A (Question tiles) and Track B (free-standing tiles). Her earlier "don't line up like questions" comment is satisfied by the Track B layout decision below (prefer one per-document column, not per-tile alignment).

### RESOLVED: What is the source of the fixed prompt text for a Question tile's column header? (drives QR1)
**Context**: QR1 columns should be labeled by the question's fixed prompt. Deep dive into CLUE source + git history + a throwaway test dumping the live logger payloads (2026-07-21) established:
- **`QUESTION_ANSWERS_CHANGE` has never carried the prompt or a title.** `git log -S` shows only two commits (both May 2025) ever touched the event; the live payload is `{questionId, tileId, answers: [{tileId, answerTiles: [{tileId, type, plainText?}]}], documentKey, documentHistoryId}` (note the nested `answerTiles`). So answer content is complete for all logs since 2025-05-05; only the prompt header is missing, and always has been.
- **Student docs are seeded by silent snapshot load, not logged tile copies.** `createDocumentModelFromProblemMetadata` -> `openDocument` loads content from the DB; `CREATE_TILE`/`COPY_TILE` fire only on explicit user add/drag. So the prompt/question tiles generally produce **no** create/copy events in a student's `run_remote_endpoint` partition. This kills log-reconstruction of the prompt (old options A/title and B/prompt-join).
- **Curriculum lookup is unsound**: authored curriculum is mutable, so a lookup returns the *current* prompt, not the point-in-time prompt the student saw. Rejected (Doug Martin, 2026-07-21).
- The only in-scope, point-in-time-correct source is the live document at answer time, i.e. the `QUESTION_ANSWERS_CHANGE` event itself. Reading document/Firestore state at `documentHistoryId` would be point-in-time correct but is out of scope (breaks the log-only design).

**Options considered**:
- Log reconstruction from create/copy events: dead (silent seeding; events absent from student partitions).
- Curriculum lookup by `questionId`: dead (mutable, wrong-point-in-time).
- Read document state at `documentHistoryId`: sound but out of scope (would break the log-only architecture).
- CLUE-side enrichment of `QUESTION_ANSWERS_CHANGE`: sound and point-in-time correct, new logs only.
- Label by raw `questionId` (chosen) or a generic "Question N" ordinal: always available; answer content still shown; AC5 history link lets a researcher open the document and read the real prompt in context.

**Product confirmation (Leslie Bondaryk, 2026-07-21):** use the Question tile's prompt as the column header, and *"if we should be storing it somewhere more convenient feel free to make that change"* (an explicit green-light for the CLUE-side enrichment, option D). She also confirmed the historical fallback: *"Your fallback plan of the question id for older unlogged prompts seems fine."*
**Decision** (Doug Martin, 2026-07-21): **D + E.**
- **Go-forward:** request a CLUE-side enrichment adding the prompt to `QUESTION_ANSWERS_CHANGE` (captured live at log time, so point-in-time correct). Slack question #1 to the CLUE dev covers this.
- **Historical:** label columns by the **raw `questionId`** (Doug Martin, 2026-07-21; chosen over a "Question N" ordinal because the raw id is globally stable and matches the aggregation key, whereas an ordinal can renumber between runs). The `questionId` is a 6-character opaque string, so historical/pre-enrichment reports show opaque headers on every Track A column; the answer data is fully present and the AC5 history link is the "what was this question" escape hatch. No curriculum lookup, no create/copy reconstruction, no document-state read.
- The report prefers the enriched prompt field when present and degrades to the `questionId` label when it is absent.

### RESOLVED: How is XR1 (no double-counting) enforced between Track A and Track B?
**Context**: A tile inside a Question tile fires both its own `*_TOOL_CHANGE` (Track B would pick it up) and the `QUESTION_ANSWERS_CHANGE` that Track A reads, so without a filter it appears twice. Verified from code + live logger payloads + git history (2026-07-21):
- A tile inside a question carries `containerIds: ["<questionTileId>"]` on its change event; a top-level tile carries `containerIds: []`. Confirmed for Text (today's Track B path) and Drawing.
- **Question is the only container tile type** currently (only `question-content.ts` composes `RowList`), so non-empty `containerIds` means "inside a question."
- `containerIds` shipped 2025-05-07, effectively alongside `QUESTION_ANSWERS_CHANGE` (2025-05-05), both pre-release, so no historical window has question-contained tiles without `containerIds`. XR5-safe.

**Options considered**:
- A1) Track B drops any `*_TOOL_CHANGE` with non-empty `containerIds`. No join, trivial SQL, correct for current + historical logs. Assumes Question stays the only container type.
- A2) Track B drops tiles whose `containerIds` intersect the set of `QUESTION_ANSWERS_CHANGE.tileId` values. Future-proof against new container types, at the cost of a join.
- B) Drop tileIds that appear as `answerTiles[].tileId` in `QUESTION_ANSWERS_CHANGE`.
- C) Accept overlap, dedup downstream.

**Product confirmation (Leslie Bondaryk, 2026-07-21):** the `containerIds` approach "seems right to me," and confirmed `questionId` tracking / copy semantics.
**Decision** (Doug Martin, 2026-07-21): **A1.** In the Track B log query, exclude any tile-change event whose `containerIds` is non-empty. Add a code comment recording the "Question is the only container tile type" assumption so this is revisited if CLUE adds another container type (which would warrant re-examining this report anyway).

### RESOLVED: How should *free-standing* tiles (Track B) be laid out as columns? (drives BR1, BR2)
**Context**: Leslie's preference (2026-07-21) was one "document" column for tiles not in a question, per-tile columns acceptable if that is too hard. Doug refined this into a concrete three-way split.
**Decision** (Doug Martin, 2026-07-21): **three-way split.**
- Free-standing **text** tiles: their own per-title columns, exactly as today (unchanged).
- **Question** tiles (Track A): their own columns, listing contained tiles as content.
- **All other** free-standing tiles (Drawing, Table, Geometry, Dataflow, Bargraph, IframeInteractive): **aggregated into a single "other tiles" column**, each shown as type + history link.

This keeps text behavior stable, satisfies Leslie's "one column for the other tiles / don't line up like questions" intent, and avoids mixing text bodies with non-text type/links in one cell. The single aggregated column is the only new Track B column.

### RESOLVED: What is the source of the real CLUE activity name? (drives XR2)
**Context**: Verified (2026-07-21) that the name is only a per-resource label column, `res_#{res_index}_name` (`shared_queries.ex:105`). The activity is already identified in output by `res_#{res_index}_resource_url`, and the code already treats a URL as an acceptable name (the nil-resource branch uses `{runnable_url, runnable_url}`, `shared_queries.ex:52`). So the activity name is **not required**; the only defect is that `clue.ex:20` hardcodes `"Test Clue"`, mislabeling every CLUE activity identically. XR2 is therefore "stop emitting the misleading placeholder," not "build a real name." This retires the earlier curriculum/unit-title lookup idea as solving a non-problem.

CLUE runnable URLs reliably encode the activity as `?unit=<code>&problem=<inv.prob>` (e.g. `?unit=m2s&problem=4.5`), confirmed across the staging fixtures in `job_test.exs`.

**Options considered**:
- A) Derive the label from the runnable URL's raw `unit` + `problem` values.
- B) URL-derived plus a unit-code -> friendly-title lookup. Rejected: requires replicating CLUE's mutable, branch-dependent curriculum-config resolution; unnecessary for a label column.
- C) Just reuse the runnable URL as the name (matches the existing nil-resource fallback).

**Decision** (Doug Martin, 2026-07-21): **A, using the raw URL values only.** Parse `unit` and `problem` from the runnable URL and build a label from those raw values (e.g. `"CLUE m2s: Problem 4.5"`; exact format easily adjustable). **No unit-code lookup table in the report code** for different CLUE units. Fall back to a host-based generic (e.g. `"CLUE"`) or the runnable URL when `unit`/`problem` are absent.

### RESOLVED: Does "the type will be documented" (AC4) require rendering non-text tile content?
**Context**: Non-text tiles log only deltas/type, not full state (Firestore-only), and the Question `answers` payload carries only tile id + type.
**Decision**: **No.** AC4 is satisfied by surfacing the tile **type** plus a history link. Rendering non-text content is out of scope.

## Self-Review

Multi-role self-review (2026-07-21). Each issue was verified against the current `report-service` and `collaborative-learning` source before being written here; the "Verified" line records the check performed.

### Senior Engineer

#### RESOLVED: `QUESTION_ANSWERS_CHANGE` payload shape is described as flat, but is actually nested
**Resolution** (2026-07-21): corrected the payload description to the nested `answers[*].answerTiles[*]` shape in the Background, Track A Technical Notes, and the prompt-source RESOLVED note, and added that a single `questionId` may yield more than one group so clue.ex must flatten across groups.

The Background (line ~29), Technical Notes (Track A, line ~62), and the prompt-source RESOLVED note (line ~86) all describe the event's `answers` field as a flat array of answer tiles, e.g. `answers[{tileId, type, plainText?}]`. The real shape is **nested**: `answers` is `IQuestionAnswersForTile[]` = `[{ tileId: <questionTileId>, answerTiles: [{ tileId, type, plainText? }] }]`, i.e. an array of *per-question-tile* groups, each wrapping its own `answerTiles` list. A single `questionId` can also yield **more than one** entry when multiple Question tiles in the same document share that id.

Why it matters: the Track A implementation note says clue.ex will "parse the `answers` array into answer entries (type + optional text)." Following the flat description, an implementer writes the wrong JSON path (`$.answers[*].type`) and extracts nothing; the correct path is `$.answers[*].answerTiles[*].type` / `.plainText`, and the code must also flatten across multiple per-question-tile groups. This is the single most load-bearing payload in Track A, so the spec's own description of it should be exact.

Suggested resolution: correct the payload description in Background, Technical Notes, and the RESOLVED prompt note to the nested shape, and note the "possibly >1 group per questionId" case.

**Verified**: `collaborative-learning/src/models/tiles/question/question-utils.ts:7-16` (interfaces), `:49-77` (`getQuestionAnswersAsJSON` builds `result.push({ tileId, answerTiles })`), and `question-utils.test.ts:78-129` (the "multiple matching Question tiles" test returns two `{tileId, answerTiles}` groups for one `questionId`). Emission at `log-tile-base-event.ts:71-81`.

---

### Data / Performance Engineer

#### RESOLVED: BR2's single aggregated column is a new layout the per-tile write pattern cannot express
**Resolution** (2026-07-21): added a Technical Note under the clue.ex bullets stating that BR2 and multi-answer-tile Track A questions require Elixir-side aggregation into one list-valued `answer` per key before the parquet write, because `map_agg` allows one value per key; noted the matching `clue_tile`/`clue_question` render branches.

The downstream report builds each learner's answers with `map_agg(a.question_id, a.answer) kv1` (`shared_queries.ex:24`) and reads a single value per key as `kv1['<question_id>']` (`:438`): exactly one answer value per `question_id` per learner. Today this is never a problem because the text path gives each tile its **own distinct** key (`question_id = make_safe_id(tile_title)`, `clue.ex:114`; one row per tile via `GROUP BY toolId`, `clue.ex:52`), so each student contributes one row per key and `map_agg` never sees a duplicate. That is precisely why it works: nothing today puts two tiles under one key. (The BR3 same-title case is the lone exception, and it is rare because titles usually differ.)

BR2 asks for the one thing that architecture does not do: **many tiles in a single column**, i.e. many tiles under **one** `question_id`. This cannot be produced by reusing the per-tile write pattern:
- Give each non-text tile its own key (mirroring text) and you get one *column per tile*, the opposite of BR2's single aggregated column.
- Force the single column by writing several rows under one shared synthetic key and `map_agg` de-duplicates that key, keeping one arbitrary value or erroring (which, depends on the Athena engine version; not pinned in `config/`), losing tiles.

So BR2's single column requires clue.ex to emit **one** answer row per (student, synthetic "other tiles" key) whose `answer` value is a JSON **list** of all the non-text tiles (type + history link each), built Elixir-side before the parquet write. The same shape applies to a Track A question that contains several answer tiles: all of its flattened `answerTiles` pack into the **one** `answer` value for that `questionId`.

Why it matters: the layout BR2 specifies is architecturally new, not a small extension of the text path, and the only correct implementation aggregates in Elixir. If that is not stated, an implementer either produces per-tile columns (wrong layout) or reaches for the shared-key shortcut (tile loss).

Suggested resolution: add a Technical Note stating that BR2 (and multi-answer-tile Track A questions) require clue.ex to aggregate the tiles into a single list-valued `answer` per key before writing parquet, because `map_agg` allows only one value per key; and that `shared_queries.ex` needs matching `clue_tile` / `clue_question` branches that render that list.

**Verified**: `shared_queries.ex:24` (`map_agg`), `:438` (`kv1['#{question_id}']`); `clue.ex:52,114` (distinct key per tile today); `clue.ex:104-204` (current per-CSV-row write). Athena engine version not pinned in `config/`, so `map_agg` duplicate-key behavior (drop-one vs error) is engine-dependent; either way the shared-key shortcut is unsafe.

---

### QA Engineer

#### RESOLVED: XR4 understates test scope, no fixtures exercise Question tiles or the report path
**Resolution** (2026-07-21): expanded XR4 to note zero report-path coverage today, that fixture-building is a substantial part of the effort, and to enumerate the required scenarios (AC1 alignment, AC2 copy semantics, XR1 containerIds disjointness, BR2 map_agg aggregation).

XR4 says "add automated tests; none exist today," which is accurate but incomplete. There is **no** test today over clue.ex's query path or the `clue_text_tile` report branch; the only CLUE test, `job_test.exs`, exercises the `ClueLinkToWork` post-processing CSV step, not report generation. More consequentially, every existing CLUE fixture carries only `TEXT_TOOL_CHANGE` events (staging offering 588, unit m2s / problem 4.5). Track A (AC1-AC5) and Track B non-text tiles cannot be exercised at all without **new hand-authored fixtures** carrying the nested `QUESTION_ANSWERS_CHANGE` payload, `containerIds`, and non-text `*_TOOL_CHANGE` events, plus possibly no real historical `QUESTION_ANSWERS_CHANGE` logs exist for any live end-to-end validation.

Why it matters: "add tests" reads as a small tail task, but the fixture construction (nested payloads, containerIds, the XR1 disjointness case, the map_agg aggregation case) is a substantial, easy-to-underestimate piece of the work, and it is the only way most of the ACs are checkable before release.

Suggested resolution: expand XR4 to explicitly include building `QUESTION_ANSWERS_CHANGE` and non-text `*_TOOL_CHANGE` fixtures covering: AC1 shared-questionId alignment across learners, AC2 within-doc vs across-doc copy, XR1 disjointness (containerIds), and the map_agg single-value aggregation for BR2.

**Verified**: `find test` shows no test referencing `get_columns_for_question`, `ReportServer.Clue`, `query_for_text_tile`, or `clue_text_tile`; `job_test.exs:26-62` fixtures are `TEXT_TOOL_CHANGE`-only.

---

### Product Manager / DevOps

#### RESOLVED: QR1 prompt-labeled columns depend on an out-of-repo CLUE change, tracked only inside a RESOLVED note
**Resolution** (2026-07-21): added a **Dependencies / Risks** section (DR1/DR2) recommending the CLUE enrichment be tracked as its own Jira ticket in the CLUE project (linked to REPORT-36 as a dependency, with a named owner), stating that prompt headers are new-data-only and this story does not block on it, and that historical data uses the questionId fallback. Annotated QR1 to reference DR1/DR2.

QR1's intended end state (columns labeled by the question's fixed prompt) is provably unachievable from data that exists today: the prompt is never carried by `QUESTION_ANSWERS_CHANGE` (the fixed-position prompt tile is excluded at emission). It becomes achievable only for **new** data, and only after a code change lands in the separate `collaborative-learning` repo (the "option D" enrichment). That cross-repo dependency currently lives only inside the prompt-source RESOLVED note as "Slack question #1 to the CLUE dev," with no acceptance criterion, no linked CLUE ticket, and no owner in this story.

Why it matters: a reader of the Requirements section reasonably assumes QR1 ships prompt-labeled columns as part of this story. In reality this story ships questionId-labeled columns for all current data and only becomes "prompt-labeled" later, contingent on another team's change. That contingency belongs in the open, not buried in a decision log.

Suggested resolution: add an explicit **Dependency / Risk** note (or a requirement) stating: (a) prompt-labeled headers are new-data-only and gated on a CLUE-side enrichment tracked by its own ticket; (b) for this story's deliverable, historical and pre-enrichment data show the questionId fallback; (c) everything else (answer content, types, links) works on historical data per XR5.

**Verified**: `question-utils.ts:64` excludes the fixed-position prompt tile from `answerTiles`; `log-tile-base-event.ts:71-81` emits only `{questionId, tileId, answers}`; spec RESOLVED note (line ~86) already states "has never carried the prompt or a title."

---

### Education Researcher

#### RESOLVED: historical-data column headers are opaque 6-character ids, worth surfacing as a conscious trade-off
**Resolution** (2026-07-21): committed the historical fallback to the **raw `questionId`** (chosen by Doug Martin over a "Question N" ordinal, for global stability and to match the aggregation key), and made the opaque-header cost explicit in DR2, XR5, and the QR1 prompt-source decision. AC5 history link is the escape hatch.

The accepted fallback labels each Track A column by its `questionId`. That id is `uniqueId(6)` (a 6-character non-semantic string like `aB3xK9`), not an ordinal or anything human-meaningful. Because the prompt enrichment is new-data-only, effectively **all** current data renders with opaque headers, and a researcher cannot tell which authored question a column corresponds to without opening each student's document through the AC5 history link. Leslie accepted the questionId fallback, so this is not a reversal, but the spec frames it mildly ("label by questionId (or generic 'Question N')") without making the historical-data legibility cost explicit.

Why it matters: a researcher-facing report whose columns are all opaque ids for existing datasets is a real usability degradation, and "Question N" (a stable ordinal over `question_order`) may be materially more legible than the raw id at no extra data cost. The choice between raw id and ordinal deserves to be an explicit, recorded decision rather than an "or".

Suggested resolution: state explicitly that historical/pre-enrichment columns are opaque; decide between raw `questionId` vs a stable "Question N" ordinal (derived from `question_order`) and record the rationale; confirm the AC5 link is presented prominently enough to serve as the "what was this question" escape hatch.

**Verified**: `question-utils.ts:22-24` (`generateQuestionId` = `uniqueId(6)`), `question-utils.test.ts:35` asserts the id matches `/^.{6}$/`.

---

### Security Engineer (no issue)

Reviewed the new history links (Track A/B) for data exposure. The AC5 links embed `documentKey`, `user_id`, `class_id`, and `offering_id` regardless of `hide_names`, but this is identical to the existing AP `model_url` behavior (`shared_queries.ex:406-419`) and to today's CLUE text-tile links (`clue.ex:139-145`); the report already exposes this data to the same authorized audience. No new exposure is introduced by this story, so no issue is raised.

---

## Self-Review, Round 2 (2026-07-21)

Second multi-role pass focused on implementation traps not covered by Round 1. Each issue below was verified against the current `report-service` and `collaborative-learning` source (and, where noted, a throwaway runtime test) before being recorded; the "Verified" line records the check performed.

### Data / Senior Engineer

#### RESOLVED: Track A's "latest per questionId" aggregation must partition by learner document, or every student's column collapses to one student's answer
**Resolution** (2026-07-21): rewrote the Track A Technical Note to require a per-learner partition (`ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, questionId ORDER BY time DESC)`), to warn explicitly against copying `get_text_tile_answer_sql/1`'s `MAX(time) GROUP BY toolId` (safe only because `toolId` is globally unique, unlike the deliberately-shared `questionId`), and to note the window also removes the `time`-tie duplicate risk. Reinforced the XR4 AC1 fixture to require ≥2 learners sharing one `questionId`.

The Track A Technical Note says the log query is "latest per `questionId` per learner document, keyed by `questionId`," and points at `get_text_tile_answer_sql/1` as the model. That existing query computes latest-change as `MAX("time") ... GROUP BY json_extract_scalar(parameters, '$.toolId')` (`clue.ex:44-52`) with **no** `run_remote_endpoint` (per-learner) key, then self-joins the log back on `tileId = toolId AND time = last_changes.time` (`clue.ex:62-64`). That pattern is only correct because `toolId` is a globally-unique `nanoid(16)` (`js-utils.ts:63-66`), so each `toolId` belongs to exactly one learner and `MAX(time) GROUP BY toolId` is already per-learner by accident of key uniqueness.

`questionId` is the **exact opposite**: `updateQuestionContentForCopy` preserves it unchanged on every across-document (author to student) copy (`question-utils.ts:33-39`), which is the whole point of AC1. So a single `questionId` is shared by *every* student in the run. If Track A mirrors the text query, keying the "latest" CTE on `questionId` alone, `MAX(time) GROUP BY questionId` returns **one** row per `questionId` across the entire learner batch, the join keeps only the globally-latest student's event, and every other student's answer to that question is dropped. The report would show one arbitrary student's answer in a column that is supposed to hold all students', a plausible-looking, silent AC1 failure that a small fixture (one learner) would not catch.

Why it matters: the spec states the correct grain in words ("per learner document") but presents it as a mechanical adaptation of a query whose grouping omits the per-learner key, and the property that makes the source query safe (globally-unique keys) is precisely the property `questionId` is *designed to lack*. The safe grain must be made explicit.

Suggested resolution: state that Track A's latest-answer selection must partition per learner document, e.g. `PARTITION BY run_remote_endpoint, questionId ORDER BY time DESC` (a window/`ROW_NUMBER` picks a single unambiguous row and also sidesteps the `time`-tie duplicate-row risk in the existing self-join), or at minimum add `run_remote_endpoint` (and/or `documentKey`) to the `last_changes` grouping. Note explicitly that the text query is safe *only* because `toolId` is globally unique and `questionId` is not. Keep the "AC1 alignment across multiple learners" fixture (Round 1 XR4) as the regression guard, and make sure it carries at least two learners sharing one `questionId`.

**Verified**: `clue.ex:44-52` (`last_changes` groups by `toolId` only), `:62-64` (self-join on `time`); `question-utils.ts:35` (`acrossDocuments ? content.questionId : generateQuestionId()`, i.e. preserved across documents); `js-utils.ts:63-66` (`uniqueId`/`toolId` = `nanoid(16)`, effectively globally unique). `QUESTION_ANSWERS_CHANGE` carries `documentKey` and rides the same `logDocumentEvent` envelope as `TEXT_TOOL_CHANGE` (`log-document-event.ts:95-125`, `log-tile-base-event.ts:71-83`), so `run_remote_endpoint` is available to partition on.

---

### Senior / Data Engineer

#### RESOLVED: A raw `questionId` is not a legal SQL identifier, so the `res_N_<questionId>` column alias is invalid ~9% of the time; naive sanitizing risks silently merging distinct questions
**Resolution** (2026-07-21): added a Track A Technical Note requiring `questionId` to be sanitized into an alias-safe **and** collision-free internal key before it becomes the `map_agg`/structure key (collision-free transform, e.g. hex-encode, or decouple the internal key from the raw-`questionId` header per QR1/DR2), explicitly rejecting a lossy `make_safe_id`-style fold. Added an XR4 fixture covering a hyphenated `questionId` and one differing from another only by case/`-`/`_`.

`shared_queries.ex` builds each answer column's name from the question key: `column_prefix = "res_#{activity_index}_#{question_id}"` (`:399`), and the column is emitted as an **unquoted** alias via `select_from_column`, `"#{value} AS #{name}"` (`:515`). For today's `clue_text_tile` path the key is `make_safe_id(tile_title)`, which is forced to `[a-z0-9_]` (`clue.ex:214-219`), so the alias is always legal. Track A instead keys on the raw `questionId`, which is `generateQuestionId()` = `nanoid(6)` (`question-utils.ts:22-24`, `js-utils.ts:63-66`) over nanoid 3.x's default URL-safe alphabet `useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict`, which **contains `-` and `_`** and is mixed-case (no `customAlphabet` anywhere in CLUE; version pinned `^3.3.4`, resolves to the installed `3.3.11`).

A `questionId` containing `-` yields an alias like `res_1_xg-MIL_text`, where Presto/Athena parses the `-` as subtraction: a hard SQL syntax error, not a degraded value. A throwaway run of CLUE's actual installed `nanoid` over 200k samples put `-` in **9.01%** of ids (`-` or `_` in 17.45%; 15.5% start with a digit). Per report the odds compound: with 5 Track A questions the chance at least one column breaks is ~38%, with 10 questions ~61%. The map-key uses (`kv1['#{question_id}']`, `activities_table.questions['#{question_id}'].prompt`) are quoted string literals and tolerate `-`; only the **alias** breaks, but one broken alias fails the whole query.

The obvious fix, run `questionId` through `make_safe_id` like the text path, trades a hard failure for a silent one: `make_safe_id` lowercases and maps every non-`[a-z0-9]` char to `_`, so distinct `questionId`s that differ only by case or by `-`/`_` (e.g. `ab-cde`, `ab_cde`, `AB-CDE`) collapse to the same key and their answers merge in `map_agg`, an AC1/AC2 correctness violation. Cross-question collisions require two such ids in one report so are rare, but they are invisible when they happen.

Why it matters: the spec treats `questionId` as usable verbatim as the aggregation key (and even shows raw mixed-case ids as example headers) without noting it is also consumed as a SQL identifier by `shared_queries`, so the current plan generates invalid SQL for a large fraction of real reports, and the naive remedy can silently merge questions.

Suggested resolution: sanitize `questionId` into an alias-safe **and** collision-free key before it becomes the `map_agg`/structure key, e.g. a reversible/among-unique encoding rather than a lossy character-class replace (hex-encode, or prefix + strip only after verifying uniqueness within the run), so `-`, `_`, case, and leading digits are all handled without folding two distinct ids together. Alternatively, decouple the human/opaque header (`questionId`, per DR2) from the internal column key (a safe surrogate id). Add a fixture with a hyphenated `questionId` (and one differing from another only by case/`-`/`_`) to lock both halves.

**Verified**: `shared_queries.ex:399` (`column_prefix`), `:515` (`"#{value} AS #{name}"`, unquoted alias); `clue.ex:214-219` (`make_safe_id` forces `[a-z0-9_]`, lowercases, maps others to `_`); `question-utils.ts:22-24` + `js-utils.ts:63-66` (`nanoid(6)`); `node_modules/nanoid/url-alphabet/index.js` (default alphabet includes `-`/`_`); no `customAlphabet` in `collaborative-learning/src`; throwaway run of CLUE's installed `nanoid` (3.3.11): 9.01% of 200k `nanoid(6)` ids contain `-`.

---

## Self-Review, Round 3 (2026-07-21)

Third multi-role pass (Senior/Data Engineer, QA, Product, Education Researcher). Before this round, the load-bearing Track A assumptions were re-verified against source and **hold**: `getQuestionAnswersAsJSON` re-reads all answer tiles' current content on every fire, so each `QUESTION_ANSWERS_CHANGE` is a complete snapshot, not a delta (`question-utils.ts:49-77`), and the emission logs the event *after* deletions (`log-tile-base-event.ts:36-40`), so "latest event per learner wins" (Round 2's `ROW_NUMBER` strategy) is correct; `documentKey`/`documentHistoryId` are attached to every document log event with `documentHistoryId` falling back to `"first"`, never null (`log-document-event.ts:92-125`), so AC5 is safe; the event carries no `operation` field (`log-tile-base-event.ts:71-81`), so Track A must not copy the text path's `operation='update'` filter. Each issue below was verified against current source; the "Verified" line records the check.

### Education Researcher

#### RESOLVED: Track A column *order* is arbitrary (reverse-alphabetical by opaque key); keep alphabetical for cross-report stability, reject time-based ordering
**Resolution** (Doug Martin, 2026-07-21): **keep today's alphabetical (then reversed) ordering; do not order by event `time`.** The deciding factor is **cross-report / cross-class consistency.** A report's `question_order` is scoped to the learners in that report (clue.ex reduces over the CSV queried for this report's `run_remote_endpoints`), so any `MIN(time)`-based order would be computed over a different cohort each time: the *same* authored question would render in different column positions for different classes (Class A first-answered Q2, Class B first-answered Q1 -> mismatched layouts for two teachers comparing the same CLUE problem). Alphabetical order does **not** have this problem: the sort key is a deterministic function of the `questionId`, and `questionId` is globally stable across every copy (`updateQuestionContentForCopy` preserves it across documents, the AC1 mechanism), so the same authored question sorts to the same relative position in every report and every class, for whatever subset of questions a class answered. Since there is no authored-position signal anywhere in the log stream (silent seeding, per the resolved prompt-source note), alphabetical-on-stable-`questionId` is the best available basis for cross-report comparison, not merely the default. Accepted trade-off, recorded alongside DR2: Track A historical/pre-enrichment columns have opaque headers **and** a stable-but-non-semantic order; the AC5 history link remains the "what was this question" escape hatch. Track B free-standing text tiles keep today's title-based ordering.

**Implementation constraint (ties to the Round 2 key-sanitization issue):** this cross-report stability holds only if the ordering/column key is a **deterministic function of the `questionId`** (e.g. the collision-free hex-encoded safe key from the Round 2 note). If an implementer instead decouples the internal column key into a **run-local surrogate** (e.g. `q1`, `q2` assigned per run), the same question gets different keys in different reports and the cross-report order consistency is silently lost. So the two decisions must agree: the safe key must be derived from the `questionId`, not assigned per run.

Rounds 1/2 addressed the opaque *header* (DR2) but not column *order*. Full-pipeline trace: `clue.ex:190-192` sorts `question_order` alphabetically (its comment: *"CLUE answers have no natural order, so just sort alphabetically"*), then `resource_data.ex:149` **reverses** it. For the text path this is reverse-alphabetical by title (mildly meaningful). For Track A the sort key is the *sanitized `questionId`*, so headers are opaque, but per the resolution the relative order is globally stable.

**Verified**: `clue.ex:190-192` (`Enum.sort(structure.question_order)`), `:104-193` (single global `structure` reduced over all learners' rows, scoped to this report's `run_remote_endpoints`), `resource_data.ex:133-135` (CLUE branch returns clue's structure verbatim), `:149` (`question_order: Enum.reverse(...)`); `shared_queries.ex:93` (one `activity_structure` row per `query_id` drives the column list), `:210-230` (columns built once, uniform across all rows); `question-utils.ts:35` (`acrossDocuments ? content.questionId : generateQuestionId()`, i.e. `questionId` preserved across documents -> globally stable sort key).

---

### Product Manager / QA Engineer

#### RESOLVED: Multi-tile Track A questions and the BR2 "other tiles" column render as a JSON array of `{type, text?, link}` entries
**Resolution** (Doug Martin, 2026-07-21): each such cell is a **JSON array of answer-tile entries**, one column per Track A question and one BR2 "other tiles" column, rendered by passing the Elixir-built JSON list through as-is (`value: answer`, `header: prompt_header`), which makes the new `clue_question`/`clue_tile` branch essentially the existing `_ ->` fallback shape (a single `_json`-style column) rather than fragile string concatenation. JSON was chosen over a delimiter-joined human string specifically for **machine parseability**: the sibling `cc-data-cli` (REPORT-77) loads these report CSVs into local datasets and queries them with SQL, so a structured cell lets it `json_extract` fields (type/text/link) instead of parsing a lossy separator that student text could collide with. It is also idiomatic: the report already stores CLUE answers as JSON internally (`clue.ex:151` writes `{"text":…, "url":…}`); the text path only decomposes it into `_text`/`_url` columns because a single text tile fits fixed columns, which a variable-length multi-tile question cannot.

**Entry shape (stable, documented for cc-data SQL consumption):**
```json
[
  {"type": "Text",    "text": "the student's answer", "link": "https://…historyId=…"},
  {"type": "Drawing", "link": "https://…historyId=…"},
  {"type": "Table",   "link": "https://…historyId=…"}
]
```
- `type` — the tile type, friendly-cased (e.g. `"Drawing"`), always present.
- `text` — present only for Text tiles (from `plainText`); omitted otherwise.
- `link` — the AC5 history link, carried **per entry** (uniform shape).

**Link granularity (the one real Track A vs Track B asymmetry, resolved to a uniform shape):** Track A answer tiles all come from one `QUESTION_ANSWERS_CHANGE` event, so they share a single `documentHistoryId`; Track B free-standing tiles each have their own last-change event and thus their own `documentHistoryId`. Rather than hoist a single question-level link for Track A (which would force cc-data to handle two different cell shapes), the link is carried **per entry** in both tracks: for Track A every entry repeats the question's one link (harmless redundancy), for Track B each entry has its tile's own link. cc-data therefore has exactly one parsing pattern across both column families.

Single-value Text tiles inside a Question tile still render as the array entry (`{"type":"Text","text":…,"link":…}`), not the legacy `_text`/`_url` pair; the legacy pair remains only for Track B free-standing text tiles (BR1, unchanged).

**Verified**: `shared_queries.ex:440-495` (per-type fixed columns; no `clue_question`/`clue_tile` branch today; `_ ->` default at `:491-494` already emits `value: answer` as a single `_json` column, which the new branches mirror with a prompt header); `clue.ex:151` (answers already stored as JSON internally); resolved "free-standing tile layout" Open Question fixed the columns but not the cell contents, which this closes.

---

### Senior Engineer

#### RESOLVED: Track A `plainText` must bypass the text path's Slate extractor, or text answers are silently dropped
**Resolution** (2026-07-21): threaded two changes into the body: (1) a Track A Technical Note stating `plainText` is consumed directly and must not route through the text path's Slate `Jason.decode`/`extract_text` decode-or-silently-drop block; (2) an XR4 fixture with special characters in `plainText` to lock the nested-JSON -> Athena-CSV -> Elixir round-trip.

`plainText` from `QUESTION_ANSWERS_CHANGE` is already plain text (`question-utils.ts:67`, `textContent.asPlainText()`). The existing text path instead treats the answer as a Slate document: `Jason.decode(text_trimmed)` then `extract_text` (`clue.ex:147-151`), and on **any** decode failure falls to `else -> row_acc.answers` (`clue.ex:176-177`), a silent drop with no error. An implementer who reuses that pipeline on a bare `plainText` string would silently lose every Track A text answer (a bare string is not decodable as the expected `{"document": {...}}` shape).

Why it matters: the failure is invisible (no error, answer just absent), so it would likely survive to production and present as "Track A text answers are blank" with no signal why.

**Verified**: `clue.ex:147-178` (decode-or-silently-drop `else` branch), `:148` (manual quote-trim), `question-utils.ts:67` (`plainText` already plain via `asPlainText()`).

---

## External Review (2026-07-21)

External development review of `requirements.md` (LLM pass with throwaway `mix run --no-start` checks against the Elixir report pipeline; no files modified). Five findings, all accepted and threaded into the Requirements / Technical Notes body; each was re-verified against current source before applying. Three (the naming, usage-guard, and precision half of the ordering finding) corrected inaccuracies introduced during Round 3.

### RESOLVED (MEDIUM): Track A column ordering was contradictory (DR2 "alphabetical" vs Round 3 "alphabetical then reversed")
`clue.ex:192` sorts ascending, then `resource_data.ex:149` reverses unconditionally, so the CLUE net output is **reverse-alphabetical (descending)**. DR2 understated this as "alphabetical." Fixed: DR2 now states the net descending order explicitly (combined sort + reverse), notes no ordering-pipeline change is needed, and keeps the cross-report-stability rationale. **Verified**: `resource_data.ex:149` (unconditional `Enum.reverse`); reviewer throwaway check returned `["c","b","a"]` for input `["a","b","c"]`.

### RESOLVED (MEDIUM): BR2 "other tiles" column lacked a denormalized-structure contract
`shared_queries.ex:218-219` emits an answer column only for keys present in both `question_order` and the `questions` map, so aggregating parquet answer rows alone never materializes the BR2 column. Fixed: added the "BR2 / Track A denormalized-structure contract" Technical Note (synthetic `other_tiles` key, `type: clue_tile`, prompt `Other tiles`, `required: false`, plus the parallel Track A entries) and specified placement (interleaved stable sort for Track A + text keys; `other_tiles` pinned last via a pre-reverse prepend in clue.ex, no `resource_data.ex` change). BR2 requirement updated to reference it. **Verified**: `shared_queries.ex:210-230`; reviewer check showed a denormalized `other_tiles` question emits `res_1_other_tiles_json` while omitting it emits no such column.

### RESOLVED (MEDIUM): JSON column-name contract conflicted (`res_<n>_<key>` vs `res_<n>_<key>_json`)
A Round 3 Technical-Note edit wrote a bare `#{column_prefix}` name, but the `_ ->` fallback (`shared_queries.ex:491-494`) and Round 3 both use `#{column_prefix}_json`. Fixed: the `get_columns_for_question` note now commits to `#{column_prefix}_json` for both new branches and states `res_<n>_<key>_json` as the cc-data/test-facing contract. **Verified**: `shared_queries.ex:491-494` (`_json` fallback); reviewer check emitted `res_1_other_tiles_json`, not bare `res_1_other_tiles`.

### RESOLVED (LOW): Student Assignment Usage named as a guard for a function it does not reach
`get_columns_for_question/5` is called only under `if report_type == :answers` (`shared_queries.ex:210`), so usage reports never exercise the new branches. Fixed: reworded the Technical Note to say the module (`generate_resource_sql`) is shared but `get_columns_for_question/5` is answers-only, requiring direct answers-path tests for the new CLUE branches, with usage tests as broad smoke coverage only. **Verified**: `shared_queries.ex:210,220` (`:answers`-gated call); reviewer check found `res_1_other_tiles_json` in `:answers` SQL but not `:usage` SQL.

### RESOLVED (LOW): XR1 still called the no-double-counting mechanism "an open question"
The mechanism was resolved to A1 (Track B drops events with non-empty `containerIds`), but XR1 still read "(Mechanism is an open question; see below.)". Fixed: XR1 now states the `containerIds` filter directly and points to the resolved Open Question and Track B Technical Note. **Verified**: spec-internal contradiction (Decision A1 recorded in the Open Questions section); no code mismatch.

### External Review, second batch (2026-07-21)

Two further findings from a follow-up external pass, both accepted.

#### RESOLVED (MEDIUM): the Track B note mandated the optional BR3 `toolId` fold, which would also break BR1
BR3 is optional/deferred, but the Track B Technical Note instructed folding `toolId` into `make_safe_id(tile_title)`. Since that key drives the `shared_queries` column name (`clue.ex:114` -> `res_<n>_<key>_text/_url`), doing it would rename **every** existing free-standing text column, breaking BR1's "preserved unchanged." Fixed: the Track B note now says **do not** fold `toolId` (keep `make_safe_id(tile_title)` as today), and BR3 is reworded from "optional" to "deferred, not in scope" with the column-name-break reason recorded. **Verified**: `clue.ex:114` (title-derived key); reviewer throwaway `SharedQueries.generate_resource_sql/4` check confirmed changing the key `same_title` -> `same_title_tool_123` renamed the emitted columns.

#### RESOLVED (MEDIUM): the synthetic `other_tiles` column affects completion totals; accepted as an approximation, exclusion rejected as shared blast radius
Adding `other_tiles` to the denormalized `questions` map makes it count as one question/answer in `num_questions`/`num_answers`/`percent_complete`. Fixed: added **XR6** documenting the counter semantics as an accepted approximation (CLUE structure is discovered from the union of answers, so all answer columns already approximate completion; `other_tiles` is one incremental column), and recording that excluding `clue_tile` from the counters was rejected because it is impossible CLUE-locally, `shared_queries` couples column emission and counting to the same structures, so any exclusion edits the shared query used by all AP/LARA reports. Cross-referenced from the structure-contract Technical Note. **Verified**: `shared_queries.ex:93` (`cardinality(questions)`), `:79` (`array_intersect(map_keys(kv1), map_keys(questions))`); `Map.get(nil, :type)` raises `BadMapError` (throwaway `elixir -e` run), ruling out the question-order-only trick; reviewer throwaway `mix run --no-start` confirmed `other_tiles` in `questions` both emits `res_1_other_tiles_json` and enters the counters.
