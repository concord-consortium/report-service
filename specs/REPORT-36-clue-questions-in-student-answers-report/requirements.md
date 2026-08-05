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
- **`QUESTION_ANSWERS_CHANGE`** (`log-tile-base-event.ts:81`) is logged whenever a tile inside a Question tile changes. Via `getQuestionAnswersAsJSON` it carries **`questionId`**, the Question **`tileId`**, and an **`answers`** array. **`answers` is nested**, not flat: it is `[{ tileId: <questionTileId>, answerTiles: [{ tileId, type, plainText? }] }]`, i.e. one group per Question tile in the document matching this `questionId`, each wrapping its own list of answer tiles (`type`, plus `plainText` for Text tiles; the fixed-position prompt tile is excluded). A single `questionId` can yield **more than one** group, so clue.ex must flatten across `answers[].answerTiles[]` rather than reading `answers[]` directly. (That is a description of the payload's *shape*; it is **not** a usable JSONPath. Athena rejects `[*]` wildcards, so see VR1 and the Track A Technical Note for how to express the flattening.) Because it goes through `logDocumentEvent`, it also carries **`documentKey`** and **`documentHistoryId`** (`log-document-event.ts:110,116`) for the AC5 link, and the standard log envelope (`run_remote_endpoint`, `username`, `time`, `application`) is added by ingest, so it is filterable per learner exactly like `TEXT_TOOL_CHANGE`.

So `QUESTION_ANSWERS_CHANGE` supplies AC1 through AC5 for Question tiles in report-ready form, keyed by the real stable id, all from the log stream this pipeline already reads (no Firestore). The current title-hash text path predates this and is best understood as the *free-standing-tile* fallback.

This reframes the work into two additive tracks (below). It also largely dissolves the earlier "sparse columns" worry **for Question tiles**: their shared stable ids and fixed prompts make columns dense and aligned across students, like an authored activity. The sparsity concern only applies to the free-standing-tile track.

## Requirements

### Track A: Question tiles (primary; the intended AC1/AC2 mechanism)

- **QR1 (AC1): Aggregate by stable questionId.** Aggregate student answers by the Question tile's `questionId` (from `QUESTION_ANSWERS_CHANGE`), not by title. Answers to the same authored question align in one column across all students. The column **header** is the authored prompt when available, falling back to the `questionId` label; prompt availability is new-data-only and gated on the CLUE-side enrichment (see DR1/DR2). "When available" means **when any learner's contributing row carries it**, not when the first row processed happens to: a column's learners can permanently disagree about whether the prompt is present, so the structure entry's prompt must be upgraded rather than written once (VR18).
- **QR2 (AC2): Copies show both/any answers.** Across-document copies share a `questionId` (student answers group correctly); within-document copies get a new `questionId` and appear as distinct questions. Neither case collapses or drops an answer. **Includes the case where a single learner holds one `questionId` in more than one document** (measured at 1.2% of learner/question pairs), which requires `documentKey` in Track A's window partition; see VR13, and VR20 for the cross-document entry ordering that follows from it.
- **QR3 (AC3): Text answers shown.** Text answer tiles within a question surface their `plainText` from the answers payload, as the `text` field of their entry in the question's JSON answer array (see the "JSON array of `{type, text?, link}`" render decision in the Round 3 Self-Review).
- **QR4 (AC4): Non-text answer tiles document their type.** Each non-text answer tile within a question surfaces its **type** (Drawing, Table, Geometry, etc.) as the `type` field of its entry in the question's JSON answer array, alongside a history `link` and the `documentKey`/`documentType` of the document it sits in; it carries no `text` field. Full rendered content is **not** required.
- **QR5 (AC5): History link.** Each student's question answer links to their CLUE document at the correct history point, using `documentKey` + `documentHistoryId` from the event. Verified available on **every** production event: zero null `documentKey` and zero null `documentHistoryId` across all 8,600 events, with 299 (3.5%) using the `"first"` fallback (VR4). **Those 299 omit the history parameter rather than passing the sentinel through (VR24):** nothing in CLUE resolves `"first"`, so passing it opens the playback UI at a position it never navigated to, which reads as positioned and is not. Omitting it opens the document honestly. Fixing this properly is a CLUE-side one-liner and is filed, but does not block.
- **QR6 (new, VR5): Empty answers must not be reported as answers.** Production data is dominated by non-answers: **44% of Text answer entries (4,737 of 10,803) are the empty string** (plus 27 whitespace-only), and **208 entries are `Placeholder` tiles**, CLUE's empty-slot tile, which means the student put nothing in that slot. Reported verbatim, a Track A cell would read `[{"type":"Placeholder","link":…}]` or carry an empty `text`, presenting "no answer" as an answer and inflating the XR6 completion counters. Required behavior: **drop `Placeholder` entries entirely**, and treat empty/whitespace-only `plainText` as no answer for that tile. If a question's answer tiles reduce to nothing under those rules, emit **no answer row for that (student, question)** rather than an empty array, so the learner is not counted as having answered it. This rule is new in the 2026-08-01 verification round; it was not visible from source reading because it is a property of the data, not the code.

### Track B: Free-standing tiles (additive extension of today's text path)

- **BR1 (AC3, no regression): Free-standing text tiles keep their own columns.** Existing per-title text-tile reporting for tiles not inside a Question tile is preserved unchanged (one column each, as today).
- **BR2 (AC4): Non-text free-standing tiles aggregate into one "other tiles" column.** Broaden beyond `TEXT_TOOL_CHANGE` to the other `*_TOOL_CHANGE` events, and collect a student document's free-standing tiles **of the tile types that emit a change event** into a **single aggregated column**. **Coverage limit (VR2): this is not "all non-text tiles."** CLUE registers 22 tile types but defines only seven `*_TOOL_CHANGE` events (`logger-types.ts:36-43`): BarGraph, Geometry, Drawing, Table, Text, Dataflow, IframeInteractive. Image, Graph, DataCard, Simulator, AI, Numberline, Expression, Diagram and Timeline emit **no** tile-change event, so free-standing work in them is invisible to the log stream and cannot be reported by any log-only design. Measured over all production `QUESTION_ANSWERS_CHANGE` data, tile types with no change event account for **263 of 2,143 distinct answer tiles (12%)**, with Image the largest single gap at 222 tiles across 51 documents (VR2). BR2's own new contribution, measured free-standing, is roughly **258 non-text tiles per 12-day window, 86% of it Table**. **Substantially understated for historical data (VR23):** that window is in 2026. Across all history there are ~4.43M non-text tile-change events, **85% of them before 2025**, and the largest historical contributor is the Geometry tile logging under its retired `GRAPH_TOOL_CHANGE` name. Historical Track B coverage is therefore much richer than this figure implies, and it is unlocked entirely by VR15's `COALESCE`. How much free-standing work in the silent types is lost cannot be measured, because the absence of the event is the problem. Track A is unaffected, because `getQuestionAnswersAsJSON` enumerates every tile in a Question regardless of type. BR2 therefore ships covering whatever types currently log **usably**, with the gap recorded as a known limitation. **Narrowed by VR25:** `IFRAME_INTERACTIVE_TOOL_CHANGE` logs via bare `Logger.log` and carries no `toolId`, `documentKey` or `containerIds` at all, so it cannot produce an identifiable tile or a working link; Track B gates it out structurally (non-null `documentKey` required) rather than by name, and it returns automatically if CLUE routes that logging through `logTileChangeEvent`. **The six are a description of today's data, not a list to encode: see BR4, which requires pattern-based discovery so newly-logging types appear with no code change** whose cell is a JSON array of `{type, link, documentKey, documentType}` entries (one per tile; each tile's own history link and its own document, since one learner's free-standing tiles can span their problem document, learning log and personal documents; see the render decision in the Round 3 Self-Review). The column is materialized by a synthetic denormalized-structure entry (see the "BR2 / Track A denormalized-structure contract" Technical Note): canonical key `other_tiles`, type `clue_tile`, header/prompt `Other tiles`. This is the only new Track B column, and it appears **last** (rightmost) among the answer columns.
- **BR4 (adaptivity, required): BR2 must discover tile types by pattern, never by an enumerated list.** The six currently-covered types are an artifact of what CLUE happens to log today, not a design decision, and DR3 may add more at any time. The report must pick up a newly-logging tile type **with no report-service code change**. Two mechanisms are involved and they differ:
  - **Discovery is free.** The Track B log query must match the event by **pattern** (with `TEXT_TOOL_CHANGE` explicitly excluded, since free-standing text is BR1's per-title columns) rather than an `IN (…)` list of event names. Verified working: a pattern query returned all five event types present in a sample window without naming any of them. **Do not** hardcode the seven known event names in the SQL. **Pinned by VR17 as `regexp_like(event, '_TOOL_CHANGE$')`, not `LIKE '%\_TOOL\_CHANGE' ESCAPE '\'`:** the `LIKE` form cannot survive `clue.ex`'s SQL heredoc (Elixir silently drops the `\_` backslashes and turns `ESCAPE '\'` into an empty escape string), and the natural way to clear the resulting Trino error is to drop the `ESCAPE` clause, which leaves the underscores as wildcards. `regexp_like` has nothing to escape. Either form satisfies BR4's pattern-not-list requirement.
  - **The type label is not free, and needs a fallback.** Tile-change events carry **no tile-type field**; the type exists only inside the event name (verified: the full parameter key set is `args, containerIds, documentChanges, documentHistoryId, documentKey, documentProperties, documentTitle, documentType, documentUid, documentVisibility, operation, path, sectionId, tileId, tileTitle, toolId`, and `documentType` is the *document's* type, not the tile's). So clue.ex must derive the label from the event name: strip the `_TOOL_CHANGE` suffix and map through a small known-casing table for the current seven, falling back to title-casing for **any unrecognized event**. An unrecognized event must therefore surface with a derived label, never be dropped and never raise. The known-casing table is a cosmetic refinement for genuinely new types, but **not** for retired ones: per VR23, `GRAPH_TOOL_CHANGE` is not a hypothetical unknown, it is 1.27M real historical events from the Geometry tile's old event name, and its derived label `"Graph"` is the registered name of a different current tile type, so it needs a table entry for correctness rather than cosmetics. (Earlier drafts used `GRAPH_TOOL_CHANGE` as the example of a harmless unknown; that example was wrong.)
  - **Casing must match Track A.** Track A takes its `type` verbatim from the payload, which carries CLUE's registered tile-type strings (`"BarGraph"`, `"IframeInteractive"`). A naive title-case of `BARGRAPH_TOOL_CHANGE` yields `"Bargraph"`, so the same tile type would render differently in a Track A cell and a Track B cell. The known-casing table exists primarily to prevent that inconsistency; new types will be cosmetically off until added to it, which is acceptable and must not block their data from appearing.
  - **Retrospective evidence (VR23):** pattern discovery is not only future-proofing. The event vocabulary has already churned, so an `IN (...)` list of today's seven names would silently drop **1.27M historical `GRAPH_TOOL_CHANGE` events** (the Geometry tile's retired name, renamed 2024-02-14), and Dataflow, Geometry, BarGraph and IframeInteractive each appear only from a particular year onwards. A retired name also needs an override entry when its derivation is a valid-but-wrong label, which is why `"GRAPH" => "Geometry"` joins the known-casing table.
  - **Convention dependency (feeds DR3):** this adaptivity holds only while CLUE names new tile-change events `<TYPE>_TOOL_CHANGE`. The DR3 ticket should **explicitly require that naming convention**, so new tile logging flows into this report with no report-service change at all. An event named e.g. `IMAGE_UPLOAD` would not be picked up.

- **BR3 (deferred, not in scope): Same-title collision fix.** Folding `toolId` into the title-keyed id (so two same-title free-standing text tiles don't collide in `map_agg`) is **deferred**: AC2 ("copied question shows both") is fully handled by Track A via `questionId`, and text-tile behavior is otherwise unchanged, so this is a pre-existing latent edge case, not required by this story. It is affirmatively **excluded** here because implementing it would rename every existing free-standing text column (the key drives the `shared_queries` column name), which conflicts directly with BR1's "preserved unchanged." If ever pursued, it must be a separate, conscious column-name-compatibility decision.

### Dependencies / Risks

- **DR1: QR1 prompt-labeled headers depend on an out-of-repo CLUE change (new-data-only).** The fixed prompt is provably absent from `QUESTION_ANSWERS_CHANGE` today (the fixed-position prompt tile is excluded at emission), so labeling columns by the authored prompt is achievable only for **new** data, and only after the "option D" enrichment (adding the prompt to the event) ships in the separate `collaborative-learning` repo. **Track that enrichment as its own Jira ticket** in the CLUE project (a `collaborative-learning` story, linked to REPORT-36 as a dependency) with a named owner, rather than relying on the "Slack question #1" thread. **Filing that ticket is a deliverable of REPORT-36** (decided 2026-08-04), because the report ships an inert lookup bound to the field name the ticket specifies, and **the ticket must require the prompt be added as a top-level `prompt` key in the event `parameters`** (the same way DR3/BR4 must require the `<TYPE>_TOOL_CHANGE` event-naming convention). A different name, or nesting the prompt inside `answers[]`, silently leaves headers on the `questionId` fallback with no error. This story does **not** block on the ticket being *worked*: it ships the `questionId` fallback for all current/historical data (see QR1 and DR2), and the report prefers the enriched prompt automatically once it appears in new logs. **"Prefers" requires the upgrade rule in VR18:** after the enrichment ships, a column's learners can disagree indefinitely about whether their latest event carries the prompt, so a write-once structure entry would apply the enrichment per question at random.
- **DR2: Historical and pre-enrichment data show the raw `questionId` fallback header, which is an opaque 6-character id.** Answer content, tile types, and history links all work on historical logs per XR5; only the column **header** degrades. The fallback is the raw `questionId` (a `uniqueId(6)` string like `aB3xK9`), chosen for global stability over a run-local "Question N" ordinal, so every Track A column in a historical/pre-enrichment report is opaque and a researcher must use the AC5 history link to see the underlying question. Accepted trade-off (Leslie Bondaryk / Doug Martin, 2026-07-21). **Column order** is the same story: Track A columns are ordered by the sanitized `questionId`, netting out to **reverse-alphabetical (descending)**, the combined effect of `clue.ex`'s ascending `Enum.sort` (`:192`) followed by `ResourceData`'s unconditional `Enum.reverse` (`resource_data.ex:149`). This is globally stable across classes/reports but non-semantic; ordering by event `time` was rejected because it would vary per cohort (see Round 3 Self-Review). The order key must be a deterministic function of the `questionId`, not a run-local surrogate. No ordering-pipeline change is needed; the descending net order is accepted as-is (matching today's text-path behavior).

- **DR3: Tile-change logging for the silent tile types (future, non-blocking, new-data-only).** Nine registered CLUE tile types emit no tile-change event at all, so free-standing work in them is invisible to any log-only report (VR2). Image, Simulator, Numberline and Expression contain no logging code whatsoever; Graph logs only `TILE_UNLINK`. Adding `*_TOOL_CHANGE` events for them in the `collaborative-learning` repo would widen BR2 **automatically, with no report-service change**, provided the new events follow the `<TYPE>_TOOL_CHANGE` naming convention (BR4). The DR3 ticket must state that convention as a requirement, otherwise the report will not pick the new events up. **It cannot help this story**, for the same reason as DR1: XR5 requires the report to work on logs already written, and new logging never retrofits events into historical partitions. Track this as its own CLUE ticket alongside the DR1 prompt enrichment (both are cross-repo, new-data-only, owner-needed); neither is a dependency of REPORT-36. Note the cost/benefit is unusual here: BR2 is simultaneously the **expensive** track (its `*_TOOL_CHANGE` scan measured ~20x Track A's over the same window, VR8) and the **incomplete** one, delivering roughly 258 non-text free-standing tiles per 12-day window, 86% of it Table.

### Cross-cutting

- **XR1: No double-counting.** A tile reported as an answer within a Question tile (Track A) should not *also* appear as a free-standing tile (Track B), and vice versa. The two tracks target disjoint tiles. **Mechanism (resolved):** the Track B log query excludes any tile-change event with a non-empty `containerIds` (Question is currently the only container tile type); see the resolved Open Question and the Track B Technical Note. **Verified live (VR3):** `containerIds` is present on **all** 21,146 tile-change events sampled (zero absent), and the filter is necessary rather than defensive, since 140 events in a 12-day window carry a non-empty value, i.e. tiles inside Question tiles really do fire their own change events and would double-count without it. **Corrected by VR15:** VR3's sample was a 2026 window, and presence is a function of *when* the event was logged. `containerIds` logging began 2025-05-07, so a missing key is the normal case for 83% of the log history and the filter **must** treat it as free-standing (`COALESCE(…, '[]') = '[]'`) or Track B silently returns nothing for every pre-2025 class, which is an XR5 failure. Treating it as free-standing is correct rather than lenient: no container tile type existed before 2025-03-20.
- **XR2: Real resource/activity name.** Replace the hardcoded `"Test Clue"` (`clue.ex:20`) with a meaningful CLUE activity name.
- **XR3: No regression to non-CLUE reports.** AP/LARA Student Answers and the Student Assignment Usage report share `shared_queries.ex`; new behavior must be additive (new question-type cases non-CLUE data can never match).
- **XR4: Test coverage.** Add automated tests for the CLUE Student Answers path (both tracks). **This requires a testability seam before any fixture can be used** (added 2026-08-04): the whole path is private, `AthenaDB` and `Aws.get_file_stream` are called directly rather than through the repo's existing `Application.get_env` seams, the parse function writes parquet to S3 unconditionally, and `fetch_resource/3` returns only the structure, so every answer-row assertion is currently unobservable. See implementation.md sequencing step 2. **Written 2026-08-04, ahead of the code:** `server/test/support/fixtures/clue_fixtures.ex` and `server/test/report_server/clue_test.exs` (34 tests, tagged `:pending` and excluded from the default run, so `mix test` stays green; `mix test --include pending` runs them). They fail only on the two seam functions step 2 must expose, `Clue.answer_sql/1` and `Clue.parse_answer_csv/4`, whose contracts the test moduledoc states. Before that, none existed: no test exercised `clue.ex`'s query path or the `clue_text_tile` report branch, and the only CLUE test (`job_test.exs`) covers the `ClueLinkToWork` post-processing CSV step, not report generation. Existing fixtures are `TEXT_TOOL_CHANGE`-only, so most of this work is **building new fixtures**, which is a substantial part of the effort, not a tail task. New fixtures must carry the nested `QUESTION_ANSWERS_CHANGE` payload, `containerIds`, and non-text `*_TOOL_CHANGE` events, and cover: AC1 shared-`questionId` alignment across learners (**with ≥2 learners sharing one `questionId`, to catch the per-learner aggregation-grain trap in the Track A Technical Note**); AC2 within-doc (new id) vs across-doc (preserved id) copy; XR1 disjointness via non-empty `containerIds`; the map_agg single-value aggregation for BR2 / multi-answer-tile Track A questions (see the clue.ex single-value-per-key Technical Note); and **a hyphenated `questionId` (plus one differing from another only by case/`-`/`_`) to lock the key-sanitization behavior (see the "not a safe SQL identifier" Technical Note)**; and **a Text answer whose `plainText` contains special characters (embedded double-quotes, commas, newlines) to lock the nested-JSON -> Athena-CSV -> Elixir round-trip**, since the current parser hand-trims surrounding quotes (`clue.ex:148`) rather than trusting the CSV decoder, and `plainText` is consumed verbatim (see the Track A `plainText` Technical Note). **Added by the 2026-08-01 verification round:** a `Placeholder`-only question and a question whose Text answers are empty/whitespace, both asserting **no answer row is emitted** (QR6); an answer tile of a type with no `*_TOOL_CHANGE` event (e.g. `Image` or `Simulator`) asserting Track A reports it while Track B does not (VR2); and a `map_agg` regression guard proving no duplicate (student, key) rows reach parquet, since v3 drops duplicates silently (VR6). **Added 2026-08-04 (VR15):** a `*_TOOL_CHANGE` fixture with **no `containerIds` key at all**, asserting the tile still appears in `other_tiles`; every other fixture is modelled on today's payloads where the key is always present, so nothing else guards the pre-2025-05-07 history. Note the round-trip fixture is now a regression guard rather than a live risk: a `plainText` of `he said "hi", then left` was verified to survive `json_extract_scalar` byte-identical (VR1).
- **XR5 scope note (2026-08-05): the consuming project wants Spring 2026 data only.** The report is being built for the MODS project, and MODS wants the Spring 2026 PD work. XR5 stands as a design constraint, since a log-only report should not silently depend on when a class ran, and every historical protection below is correct and free. But the historical-coverage findings are lower value than their measured size suggests, and should not be read as blocking or as needing production verification: **VR15**'s `containerIds` `COALESCE` covers events logged before May 2025, **VR23**'s `GRAPH_TOOL_CHANGE` override covers 2019 to 2024, and neither touches Spring 2026 data. The one historical measurement that does pay off here is **VR16**'s year floor, which prunes a Spring 2026 report to 2025 onwards. If a later project asks for older cohorts, the protections are already in place and the two above become load-bearing again.
- **XR5: Works on historical logs.** The report must function on logs **already written**, before any CLUE-side logging change we might request. **Confirmed there is historical data to work on (VR4):** production holds **8,600** `QUESTION_ANSWERS_CHANGE` events spanning **232 documents**, **193 distinct `questionId`s** and 1,208 question/learner pairs. This closes the QA reviewer's open worry that no real events might exist for end-to-end validation. Any CLUE enrichment (e.g. adding a prompt field to `QUESTION_ANSWERS_CHANGE`) can only be a *progressive enhancement* for new data. All **answer content** the report produces must come from data already present in existing Athena partitions. The one accepted degradation for historical logs is the Question-tile **prompt header**, which is not recoverable point-in-time from old logs (see resolved QR1 prompt-source decision) and falls back to the raw `questionId` (an opaque 6-character id) plus the AC5 history link (see DR2).
- **XR6: CLUE completion metrics are approximate; the synthetic `other_tiles` column is not specially excluded.** `res_N_total_num_questions`, `res_N_total_num_answers`, and `res_N_total_percent_complete` are computed generically in `shared_queries.ex` from the denormalized `questions` map (`num_questions = cardinality(questions)` at `:93`; `num_answers` from `array_intersect(map_keys(kv1), map_keys(questions))` at `:79`). Because the CLUE structure is discovered from the **union of learners' answers** (not an authored question set), every answer column already counts as one "question," and a learner is penalized in `percent_complete` for a column another learner created. The synthetic `other_tiles` entry (BR2) therefore also counts as **one** question and, when present, one answer for that learner, even though it aggregates multiple tiles. **Sharpened by VR5:** the approximation is worse than this section originally assumed, because 44% of Text answer entries are empty and 208 entries are `Placeholder` tiles. QR6's drop rules are the mitigation: with empty answers suppressed and no answer row emitted for a question that reduces to nothing, `num_answers` reflects real answers rather than visited slots. Completion totals remain approximate (the CLUE structure is still discovered from the union of learners' answers), but they are no longer inflated by non-answers. **Accepted as-is:** CLUE completion totals are explicitly an approximation, and `other_tiles` is one incremental column on top of the pre-existing text-tile approximation, not a new class of distortion. **Excluding `clue_tile` from the counters was considered and rejected** because there is no CLUE-local way to do it: `shared_queries` derives both column emission and the counters from the same `questions`/`question_order` structures, so any exclusion (a `type <> 'clue_tile'` count filter, or a nil-guard to keep `other_tiles` out of the `questions` map) edits the **shared** query generation used by all AP/LARA answers and usage reports, blast radius not justified for a metric that is already approximate. (`Map.get(nil, :type)` raises `BadMapError`, so the "put it in `question_order` but not `questions`" trick is not viable without that shared nil-guard.)

## Technical Notes

- **Primary file (CLUE-only, no shared blast radius):** `server/lib/report_server/clue.ex`
  - Track A: add a log query over `QUESTION_ANSWERS_CHANGE`. **Selecting the latest event must partition per learner document, not by `questionId` alone**: use `ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, questionId ORDER BY time DESC)` (or add `run_remote_endpoint`/`documentKey` to the grouping). Do **not** copy `get_text_tile_answer_sql/1`'s `MAX(time) GROUP BY toolId` self-join verbatim: that query is per-learner only because `toolId` is a globally-unique `nanoid(16)`, whereas `questionId` is deliberately **shared across every student's copy** (`updateQuestionContentForCopy` preserves it across documents, the AC1 mechanism), so grouping by `questionId` alone keeps one arbitrary student's event and silently drops all others. A window function also avoids the `time`-tie duplicate-row risk in the current self-join (real duplicate rows at identical `time` values were observed in production; see VR3). Parse the nested `answers` payload, flattening across the possibly-multiple per-question-tile groups, into answer entries (type + optional text) and a history link from `documentKey`/`documentHistoryId`. **Do not express that flattening as a wildcard JSON path.** `$.answers[*].answerTiles[*].type` is rejected by Athena engine v3 with `INVALID_FUNCTION_ARGUMENT: Invalid JSON path` (verified live, VR1); `json_extract`'s JSONPath subset supports field access and *indexed* array access (`$.args[0].text`, as the existing text query uses) but not `[*]`. Use either `json_extract(parameters, '$.answers')` to pull the whole nested structure as one value and flatten it with `Jason` in `clue.ex` (**recommended**, since the single-value-per-key constraint below already forces Elixir-side aggregation), or a SQL-side `CAST(json_extract(parameters,'$.answers') AS ARRAY(ROW(tileId VARCHAR, answerTiles ARRAY(ROW(tileId VARCHAR, type VARCHAR, plainText VARCHAR)))))` with a double `UNNEST`. Both are verified working (VR1). Emit a new question type (e.g. `clue_question`) and answer-tile representation. **`plainText` is consumed directly:** it is already plain text (`getQuestionAnswersAsJSON` calls `asPlainText()`), so it must **not** be routed through the text path's Slate-document handling, `Jason.decode(text_trimmed)` + `extract_text` with an `else -> row_acc.answers` fallback (`clue.ex:147-178`). A bare `plainText` string is not decodable as the expected `{"document": {...}}` Slate shape, so reusing that block would hit the fallback and **silently drop every Track A text answer** (no error, cells just come back blank). `QUESTION_ANSWERS_CHANGE` also carries no `operation` field, so do not copy the text query's `operation = 'update'` filter.
  - **`questionId` is not a safe SQL identifier (Track A key sanitization).** `shared_queries.ex` builds each answer column as an **unquoted** alias `res_#{activity_index}_#{question_id}` (`:399`, emitted via `"#{value} AS #{name}"`, `:515`). Today's text key is `make_safe_id`-clean; a raw `questionId` is `nanoid(6)` over nanoid's default alphabet, which includes `-` (~9% of ids), `_`, mixed case, and leading digits, so a raw key produces invalid Presto SQL (e.g. `res_1_xg-MIL_text`, where `-` parses as subtraction). Track A must therefore sanitize `questionId` into an alias-safe key **before** it becomes the `map_agg`/structure key, but not with a lossy character-class replace: `make_safe_id` would fold distinct ids differing only by case or `-`/`_` (e.g. `ab-cde`/`ab_cde`/`AB-CDE`) into one key and silently merge their answers (AC1/AC2 violation). Use a collision-free transform (e.g. hex-encode) or decouple the internal column key (safe surrogate) from the opaque header (the raw `questionId`, per QR1/DR2). See the Round 2 Self-Review for the measured hyphen rate. **Calibrated by VR7:** the *invalid-SQL* half is confirmed against production (hyphenated ids like `9HzYd-` and `nb0-d3` exist in real data, and `res_1_9HzYd-_json` is a syntax error, not a degraded value), so sanitization is mandatory. The *collision* half is currently theoretical: folding all 193 distinct production `questionId`s through a `make_safe_id`-style lowercase-and-replace yields **193 distinct keys with zero collisions**. Hex-encoding remains the recommendation because it is cheap, satisfies Round 3's "deterministic function of `questionId`" constraint, and fails safe as the authored-question corpus grows, but the Round 2 wording "would silently merge" should be read as *could*, at a rate not yet observed.
  - Track B: broaden `get_text_tile_answer_sql/1` (`clue.ex:39-73`) from the single hardcoded `"log1"."event" = 'TEXT_TOOL_CHANGE'` equality to a **pattern match** (`regexp_like(event, '_TOOL_CHANGE$')` with `TEXT_TOOL_CHANGE` excluded; see VR17 for why not the `LIKE … ESCAPE` form), **not** an `IN (…)` list of the seven known names, and derive the tile type from the event name with a title-cased fallback for unrecognized events. **Do not carry over the text path's `operation = 'update'` filter (VR11):** `operation` is a per-tile-type vocabulary, and Drawing never logs `update` at all, so the symmetric filter would erase every free-standing Drawing tile. This is required by **BR4**: the set of logging tile types is expected to grow via DR3, and the report must absorb that without a code change. Emit `clue_tile` for non-text free-standing tiles. **Do not** fold `toolId` into `make_safe_id(tile_title)` (`clue.ex:114`): that is the deferred BR3 change, and it is out of scope here because it would rename **every** existing free-standing text column (`res_1_<title>_text` -> `res_1_<title>_<toolId>_text`, not just colliding ones, since the key drives the column name in `shared_queries`), breaking BR1's "preserved unchanged" guarantee. Keep the free-standing text key as `make_safe_id(tile_title)` exactly as today.
  - **Single-value-per-key constraint (BR2 and multi-tile Track A):** the report aggregates answers with `map_agg(a.question_id, a.answer)` (`shared_queries.ex:24`) and reads one value per key (`kv1['<question_id>']`, `:438`). Today each tile has its own distinct key, so there is never a duplicate. BR2's single "other tiles" column and any Track A question with more than one answer tile therefore cannot be produced by writing one parquet row per tile: they must be aggregated Elixir-side in clue.ex into **one** answer row per (student, key) whose `answer` is a JSON **list** before the parquet write. Each entry has the stable shape `{"type": <friendly tile type>, "text": <plainText, Text tiles only>, "link": <AC5 history link>}` (uniform across Track A and Track B; `link` is carried per entry, see the Round 3 render decision). Reusing one shared key across per-tile rows instead would hit `map_agg`'s duplicate-key de-duplication and lose tiles. **Duplicate-key behavior is now pinned (VR6):** every report-service workgroup runs **Athena engine version 3** (Trino), and on v3 `map_agg` over a duplicated key **silently keeps the first value and drops the rest** with no error (`map_agg` over `('a',1),('a',2),('b',3)` returns `{a=1, b=3}`). Earlier drafts hedged this as engine-dependent "drop-one vs error"; it is the drop, i.e. the invisible failure mode, which makes the one-row-per-(student, key) rule load-bearing rather than defensive.
  - **BR2 / Track A denormalized-structure contract (a column only exists if the structure declares it):** `shared_queries.ex` builds an answer column only for keys present in **both** `question_order` and the `questions` map (`:218-219`), so aggregating answer *rows* into parquet is not enough, clue.ex must also add matching `structure.questions` + `question_order` entries. For **Track A**, add one entry per question keyed by the sanitized `questionId` (collision-free safe key), `type: "clue_question"`, `prompt:` the enriched prompt when present else the raw `questionId` (per QR1/DR2), `required: false`. For **BR2**, add a **single synthetic** entry keyed `other_tiles`, `type: "clue_tile"`, `prompt: "Other tiles"`, `required: false`, present whenever any learner in the report has ≥1 non-text free-standing tile. Because it lives in the `questions` map, this entry counts toward the completion totals as one question (and one answer when present); that is accepted as-is per XR6 (excluding it would require a shared `shared_queries` change). **Ordering:** Track A question keys and free-standing text keys interleave in the one sorted `question_order` (they remain separate columns; only their left-to-right position is shared), netting to reverse-alphabetical (DR2). To pin `other_tiles` **last** despite `ResourceData`'s reversal (`resource_data.ex:149`), clue.ex **prepends** `other_tiles` to `question_order` (pre-reverse first -> post-reverse last); no `resource_data.ex` change is required. **Sequencing is load-bearing (VR9): the prepend must happen *after* `clue.ex`'s `Enum.sort` at `:191-193`, not inside the reduce where the other structure keys are added.** Prepending at that natural spot lets the sort move `other_tiles` into alphabetical position, and it lands mid-table rather than last: for keys `["zzz_text","abc_text","m1k2j3_json"]`, prepending before the sort yields `["zzz_text","other_tiles","m1k2j3_json","abc_text"]` (second of four), while prepending after the sort yields `[…,"other_tiles"]` as required. Verified by direct execution.
  - XR2: hardcoded name at `clue.ex:20`.
- **Shared file: no change required (verified 2026-08-04).** `server/lib/report_server/reports/athena/shared_queries.ex` was expected to need new branches; it does not, so this story touches **only** `clue.ex`. Earlier wording in this note assumed the branches were what materialized the column; that is wrong, and is retained below only to describe the required column shape.
  - `get_columns_for_question/5` (`shared_queries.ex:390`): the `clue_text_tile` branch (`:442-446`) emits `_text` + `_url`. The new Track A `clue_question` and Track B `clue_tile` types need **no branch of their own**: the existing `_ ->` fallback (`:491-494`) already emits exactly the required column for any unrecognized type, `prompt_header` included, so an added branch would produce byte-identical SQL (verified by calling the function directly; VR9 saw the fall-through without drawing the conclusion). The contract is pinned by the XR4 answers-path query-generation test instead of by a branch. Unlike `clue_text_tile`, each emits a **single** column carrying the JSON answer array verbatim (`%{name: "#{column_prefix}_json", value: answer, header: prompt_header}`, i.e. the existing `_ ->` fallback shape at `:491-494` with a prompt header added, not `json_extract_scalar`-ed `_text`/`_url` sub-columns), since the cell is a variable-length `{type, text?, link}` array meant for cc-data SQL consumption (see the Round 3 render decision). The `_json` suffix is the committed column-name contract for both new types (delivered by the fallback), so cc-data and tests should expect `res_<n>_<key>_json`. The legacy `clue_text_tile` `_text`/`_url` pair stays only for Track B free-standing text tiles (BR1). XR3 now holds as a fact rather than an argument: no shared code is edited at all, so every existing branch (`open_response`, `multiple_choice`, `iframe_interactive`, `image_question`, …) is untouched by construction. Note the module (`generate_resource_sql`) is shared with the Student Assignment Usage report, but `get_columns_for_question/5` itself is **answers-only** (called only under `if report_type == :answers`, `:210`), so usage reports never exercise the CLUE types; add **direct answers-path** query-generation tests asserting `res_<n>_<key>_json` for `clue_question`/`clue_tile`, and keep usage-report tests as broad smoke coverage only. Those tests matter more now that no branch documents the behavior.
- **Reused unchanged:** `reports/clue/history_link.ex`, the parquet writer + `partitioned-answers` S3 layout (`clue.ex:75-83,196-204`), and the downstream report SQL.
- **CLUE source references:** `question-content.ts` (`questionId`, prompt), `question-utils.ts` (`updateQuestionContentForCopy`, `getQuestionAnswersAsJSON`), `log-tile-base-event.ts:45-83` (`QUESTION_ANSWERS_CHANGE` emission), `log-document-event.ts` (documentKey/historyId).
- **Performance (discharged by VR12; VR8's conclusion superseded):** the log query today reads `logs_by_time`, which has **no partitions**, with **no time bound**, so it is an unbounded full-table scan before this story widens anything. VR8 measured, over a 12-day window, **24.7 MB** for `QUESTION_ANSWERS_CHANGE` against **489 MB** for `event LIKE '%TOOL_CHANGE'` (about 20x) and concluded Track B's broadening was the cost centre. **VR12 shows that conclusion is an artifact of the table.** Moving to `logs_by_app_and_secure_key` (partition-projected on `app/year/month/secure_key`, the table `report_query.ex:100-121` already uses for this exact access pattern) prunes to the report's own learners before any row filter runs: the **full three-track predicate over all history for 40 learners scans 0.67 MB**. Track B therefore adds no meaningful scan cost. **Bounded by VR16:** the byte-scan conclusion holds, but VR12's "no per-runnable re-validation needed" was a 40-learner measurement, and the two residual costs (S3 prefix-enumeration wall time, and the length of the submitted SQL string against Athena's 262,144-byte quota) are both linear in learner count with no cap anywhere in the path. Both are now handled in the design rather than deferred: a **required** year floor derived from the learners' own `created_at`, and a single `clue_logs` base CTE holding the learner predicates once instead of once per track. See implementation.md **D2** and **D7**.

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

Why it matters: the Track A implementation note says clue.ex will "parse the `answers` array into answer entries (type + optional text)." Following the flat description, an implementer writes the wrong JSON path (`$.answers[*].type`) and extracts nothing, and the code must also flatten across multiple per-question-tile groups. This is the single most load-bearing payload in Track A, so the spec's own description of it should be exact. **(Partly superseded by VR1: the diagnosis here is correct, but this finding's originally prescribed replacement, `$.answers[*].answerTiles[*].type`, does not run either, because Athena engine v3 rejects `[*]` wildcards outright. Do not use wildcard path syntax; see VR1 for the two verified working approaches.)**

Suggested resolution: correct the payload description in Background, Technical Notes, and the RESOLVED prompt note to the nested shape, and note the "possibly >1 group per questionId" case.

**Verified**: `collaborative-learning/src/models/tiles/question/question-utils.ts:7-16` (interfaces), `:49-77` (`getQuestionAnswersAsJSON` builds `result.push({ tileId, answerTiles })`), and `question-utils.test.ts:78-129` (the "multiple matching Question tiles" test returns two `{tileId, answerTiles}` groups for one `questionId`). Emission at `log-tile-base-event.ts:71-81`.

---

### Data / Performance Engineer

#### RESOLVED: BR2's single aggregated column is a new layout the per-tile write pattern cannot express
**Resolution** (2026-07-21): added a Technical Note under the clue.ex bullets stating that BR2 and multi-answer-tile Track A questions require Elixir-side aggregation into one list-valued `answer` per key before the parquet write, because `map_agg` allows one value per key; noted the matching `clue_tile`/`clue_question` render branches.

The downstream report builds each learner's answers with `map_agg(a.question_id, a.answer) kv1` (`shared_queries.ex:24`) and reads a single value per key as `kv1['<question_id>']` (`:438`): exactly one answer value per `question_id` per learner. Today this is never a problem because the text path gives each tile its **own distinct** key (`question_id = make_safe_id(tile_title)`, `clue.ex:114`; one row per tile via `GROUP BY toolId`, `clue.ex:52`), so each student contributes one row per key and `map_agg` never sees a duplicate. That is precisely why it works: nothing today puts two tiles under one key. (The BR3 same-title case is the lone exception, and it is rare because titles usually differ.)

BR2 asks for the one thing that architecture does not do: **many tiles in a single column**, i.e. many tiles under **one** `question_id`. This cannot be produced by reusing the per-tile write pattern:
- Give each non-text tile its own key (mirroring text) and you get one *column per tile*, the opposite of BR2's single aggregated column.
- Force the single column by writing several rows under one shared synthetic key and `map_agg` de-duplicates that key, keeping one arbitrary value or erroring (which, depends on the Athena engine version; not pinned in `config/`), losing tiles. **(Superseded by VR6: the engine is v3 and it silently keeps the first value, never errors. The conclusion stands and is strengthened, since the failure is invisible.)**

So BR2's single column requires clue.ex to emit **one** answer row per (student, synthetic "other tiles" key) whose `answer` value is a JSON **list** of all the non-text tiles (type + history link each), built Elixir-side before the parquet write. The same shape applies to a Track A question that contains several answer tiles: all of its flattened `answerTiles` pack into the **one** `answer` value for that `questionId`.

Why it matters: the layout BR2 specifies is architecturally new, not a small extension of the text path, and the only correct implementation aggregates in Elixir. If that is not stated, an implementer either produces per-tile columns (wrong layout) or reaches for the shared-key shortcut (tile loss).

Suggested resolution: add a Technical Note stating that BR2 (and multi-answer-tile Track A questions) require clue.ex to aggregate the tiles into a single list-valued `answer` per key before writing parquet, because `map_agg` allows only one value per key; and that `shared_queries.ex` needs matching `clue_tile` / `clue_question` branches that render that list.

**Verified**: `shared_queries.ex:24` (`map_agg`), `:438` (`kv1['#{question_id}']`); `clue.ex:52,114` (distinct key per tile today); `clue.ex:104-204` (current per-CSV-row write). Athena engine version not pinned in `config/`, so `map_agg` duplicate-key behavior (drop-one vs error) is engine-dependent; either way the shared-key shortcut is unsafe. **(Superseded by VR6: all workgroups run engine v3, where the duplicate is dropped silently. The version is unpinned in `config/` because it is resolved from the portal-issued workgroup at runtime, `token_service.ex:31`, not because it is unknown.)**

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

#### RESOLVED: Multi-tile Track A questions and the BR2 "other tiles" column render as a JSON array of `{type, text?, link, documentKey, documentType}` entries
**Resolution** (Doug Martin, 2026-07-21): each such cell is a **JSON array of answer-tile entries**, one column per Track A question and one BR2 "other tiles" column, rendered by passing the Elixir-built JSON list through as-is (`value: answer`, `header: prompt_header`), which makes the new `clue_question`/`clue_tile` branch essentially the existing `_ ->` fallback shape (a single `_json`-style column) rather than fragile string concatenation. JSON was chosen over a delimiter-joined human string specifically for **machine parseability**: the sibling `cc-data-cli` (REPORT-77) loads these report CSVs into local datasets and queries them with SQL, so a structured cell lets it `json_extract` fields (type/text/link) instead of parsing a lossy separator that student text could collide with. It is also idiomatic: the report already stores CLUE answers as JSON internally (`clue.ex:151` writes `{"text":…, "url":…}`); the text path only decomposes it into `_text`/`_url` columns because a single text tile fits fixed columns, which a variable-length multi-tile question cannot.

**Entry shape (stable, documented for cc-data SQL consumption):**
```json
[
  {"type": "Text",    "text": "the student's answer", "link": "https://…historyId=…",
   "documentKey": "-OL0rmfqiDsPlriZks-X", "documentType": "problem"},
  {"type": "Drawing", "link": "https://…historyId=…",
   "documentKey": "-OK7YQig6OxOLf9F84zu", "documentType": "learningLog"}
]
```
- `type`: the tile type, friendly-cased (e.g. `"Drawing"`), always present.
- `text`: present only for Text tiles (from `plainText`); omitted otherwise.
- `link`: the AC5 history link, carried **per entry** (uniform shape).
- `documentKey`, `documentType`: which of the learner's documents the tile is in (**added 2026-08-04**). Both tracks aggregate across a learner's documents, so a cell without them is ambiguous about a question researchers genuinely ask, and parsing the key out of the `link` URL is not a contract a cc-data query should rely on. `documentType` (`problem`, `learningLog`, `personal`, …) is the category a reader wants; `documentKey` is the identity and join key. CLUE attaches both to every document log event (`log-document-event.ts:91-118`), so no CLUE-side change is needed and the two tracks stay uniform. `documentTitle` is available on the same events and deliberately omitted as user-editable and therefore not a stable identifier.

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

---

## Verification Round (2026-08-01, live data + source)

Prior rounds verified this spec against **source code**. This round verified it against the **running system**: eight Athena queries on the production log DB (`log_ingester_production`, workgroup `dmartin-concord-org-iwEisHLkbj2z4VSACNS6`, engine v3) plus targeted reads of `collaborative-learning`. Total ~3.2 GB scanned; every table query was bounded by `time` and, where it did not need aggregates, by `LIMIT`. Two findings **invalidated spec guidance**, two are **new requirements**, four **confirmed** load-bearing assumptions, and one **softened** an earlier claim. Findings are labelled VR1-VR8 and cross-referenced from the body.

The general lesson: every issue below was invisible to source review. Two are properties of the query **engine** and four are properties of the **data**, neither of which a reading of `clue.ex` and `question-utils.ts` can reveal. Further self-review rounds on this document would not have found any of them.

### VR1 (INVALIDATES GUIDANCE): the prescribed wildcard JSON path does not run on Athena

The Round 1 Self-Review correctly identified that `answers` is nested and that a naive `$.answers[*].type` extracts nothing, but prescribed `$.answers[*].answerTiles[*].type` as "the correct path." Athena engine v3 rejects it outright:

```
INVALID_FUNCTION_ARGUMENT: Invalid JSON path: '$.answers[*].answerTiles[*].type'
```

`json_extract`'s JSONPath subset supports field access and *indexed* array access but not `[*]` wildcards. The existing text query only ever exercises indexed access (`$.args[0].text`, `clue.ex:60`), so nothing in the codebase demonstrated the limit. An implementer following the spec verbatim would have hit a hard query failure.

Two replacements verified working (both zero bytes scanned, against a literal):
- `json_extract(parameters, '$.answers')` returns the nested structure intact for Elixir-side flattening with `Jason`. **Recommended**, because the single-value-per-key constraint already forces Elixir-side aggregation.
- `CAST(json_extract(parameters,'$.answers') AS ARRAY(ROW(tileId VARCHAR, answerTiles ARRAY(ROW(tileId VARCHAR, type VARCHAR, plainText VARCHAR)))))` with a double `UNNEST` returned `Text|hi` and `Drawing|null`, flattening across groups correctly.

Also settled here: a `plainText` of `he said "hi", then left` survived `json_extract_scalar` **byte-identical**, so the XR4 special-character fixture is a regression guard, not a live risk. **Threaded into**: the Track A Technical Note, XR4.

### VR2 (NEW LIMITATION): BR2 cannot see roughly a quarter of student work

BR2 said "all of a student document's non-text, non-Question tiles" and proposed the `*_TOOL_CHANGE` event set as the mechanism. Those are not the same set. CLUE registers **22** tile types but defines only **seven** `*_TOOL_CHANGE` events (`logger-types.ts:36-43`). Confirmed by direct inspection that Graph, Image, DataCard, Numberline, Expression, Simulator and Timeline contain **zero** references to `logTileChangeEvent` or `*_TOOL_CHANGE`.

Answer-tile types across all production events, with event coverage:

| Type | Entries | Emits `*_TOOL_CHANGE`? |
|---|---:|---|
| Text | 10,803 | yes |
| **Image** | **4,395** | **no** |
| Drawing | 3,468 | yes |
| Dataflow | 1,203 | yes |
| **Simulator** | **463** | **no** |
| Placeholder | 208 | n/a (empty slot) |
| Table | 149 | yes |
| **AI** | **97** | **no** |
| **Graph** | **39** | **no** |
| Geometry | 32 | yes |
| **Expression** | **1** | **no** |

Types with no change event are 4,995 of 20,858 **entries**, but that figure is entry-weighted and overstates the loss: each `QUESTION_ANSWERS_CHANGE` event re-lists every answer tile in the question, so tiles sitting beside frequently-edited text are counted repeatedly (Image averages ~20 entries per tile against Text's ~6.6). Measured by **distinct `tileId`**, the honest figure is **263 of 2,143 real answer tiles (12%)**, excluding `Placeholder`. Image is still the largest single gap at 222 distinct tiles across 51 documents, second only to Text overall.

Distinct answer tiles by type, full history: Text 1,630 (165 docs), **Image 222 (51)**, Drawing 180 (92), Placeholder 147 (81), Dataflow 60 (44), **Simulator 26 (25)**, **AI 11 (9)**, Table 8 (8), **Graph 3 (2)**, Geometry 2 (1), **Expression 1 (1)**. Bold types emit no change event. Track A is unaffected: `getQuestionAnswersAsJSON` walks the Question's `tileIds` and returns `tile.content?.type` for any type, excluding only fixed-position prompt tiles (`question-utils.ts:60-70`). So the same Image tile is reported inside a Question and invisible free-standing.

**These tiles are silent, not differently-named (checked 2026-08-01):** the gap is not a matter of BR2 watching for the wrong event name. `src/components/tiles/image`, `src/plugins/simulator`, `src/plugins/numberline` and `src/plugins/expression` contain **no logging code whatsoever** (zero files referencing `logTile*`, `Logger.log`, `logDocumentEvent` or `LogEventName`), and `src/plugins/graph` logs only `TILE_UNLINK`, a linking event rather than a content change. **Qualified by VR23:** that is true of *current* code only. The Geometry tile logged under the name `GRAPH_TOOL_CHANGE` until a 2024-02-14 rename, so 1.27M historical `GRAPH_TOOL_CHANGE` events exist and are Geometry tiles, not modern Graph tiles. This table is derived from `QUESTION_ANSWERS_CHANGE`, which only exists from 2025-05, so it says nothing about historical free-standing coverage. There is therefore **no log-only design** that can report free-standing work in these tiles, and no broadening of the event filter will recover them. Reporting them would require reading document state, which is out of scope per the log-only architecture.

**What BR2 does deliver, measured (12-day window):** distinct *free-standing* tiles by type are Text 3,275 (already covered by BR1, unchanged), **Table 222**, **Drawing 34**, Dataflow 1, Geometry 1. So BR2's genuinely new contribution is roughly **258 non-text free-standing tiles per 12 days, 86% of it Table**.

The free-standing gap remains **unmeasurable by construction**, since the absence of the event is precisely the problem. Critically, **the in-question type mix is a poor proxy for the free-standing mix**, so it cannot be used to estimate the loss: Table appears on only 8 distinct tiles inside questions but 222 free-standing, while Image appears on 222 inside questions. The two contexts are used for different things (Image reads as an answer-capture tile, Table as a workspace tile), so "51% of in-question non-text tiles are invisible types" does **not** transfer to the free-standing population. The honest answer to "how much is lost?" is that it cannot be measured from logs, only bounded below by zero and above by the total free-standing population. **Resolved** (Doug Martin, 2026-08-01): **ship the six covered types; the gap is accepted and does not block.** The deciding constraint is XR5: the report must work on logs **already written**. Adding tile-change logging to the silent types is a legitimate future improvement but cannot help this story, because no amount of new CLUE logging retrofits events into historical partitions. Leslie's 2026-07-21 "add all tiles" therefore ships as "all tiles that logged anything," with Track A covering every tile type inside Question tiles and BR2 covering whatever free-standing types emit change events, which is six today and grows on its own as CLUE adds logging (BR4). See **DR3** for the future enhancement. **Threaded into**: BR2, DR3.

### VR3 (CONFIRMS): the XR1 `containerIds` filter is both safe and necessary

Across 21,146 `*_TOOL_CHANGE` events in a 12-day window, `containerIds` was **never absent** (zero nulls). ~~so the filter needs no null handling.~~ **That conclusion is wrong and is corrected by VR15:** the window sampled was in 2026, `containerIds` logging began 2025-05-07, and a missing key is the normal case for 83% of the log history, so the filter must `COALESCE` it to `'[]'` or Track B silently returns nothing for every pre-2025 class. It is also load-bearing rather than defensive: 140 of those events carry a **non-empty** `containerIds` (Text 34, Drawing 9, Dataflow 97), i.e. tiles inside Question tiles really do fire their own change events and would double-count without the exclusion. Only five of the seven `*_TOOL_CHANGE` types appeared in the window (Table 12,015; Text 5,900; Drawing 3,064; Dataflow 126; Geometry 41); BarGraph and IframeInteractive did not occur. Duplicate rows at identical `time` values were also observed, confirming the Round 2 tie-risk argument for `ROW_NUMBER` over the existing `MAX(time)` self-join.

### VR4 (CONFIRMS): AC1's mechanism, AC5's link data, and DR1's prompt absence all hold

- **AC1 is real and the Round 2 trap is severe.** Of 193 distinct production `questionId`s, **130 are shared by more than one learner**, with a maximum of **33 learners on a single id**. A naive `MAX(time) GROUP BY questionId` would keep one row and silently discard the other 32 students' answers, exactly as Round 2 predicted, now with a measured worst case.
- **AC5 is safe.** Zero null `documentKey` and zero null `documentHistoryId` across all 8,600 events; 299 (3.5%) use the `"first"` fallback.
- **DR1 is confirmed empirically.** **Zero** events contain a `prompt` field anywhere in `parameters`. The prompt is not merely excluded from `answerTiles`; it is absent from the payload entirely, so prompt-labeled headers are strictly new-data-only.
- **Corpus size**: 8,600 events, 232 documents, 193 questions, 1,208 question/learner pairs. Real historical data exists for end-to-end validation (closes the QA reviewer's worry).

### VR5 (NEW REQUIREMENT): most "answers" in the data are not answers

**44% of Text answer entries (4,737 of 10,803) are the empty string**, plus 27 whitespace-only, and **208 entries are `Placeholder`** tiles. Reported verbatim these present "no answer" as an answer and inflate the XR6 counters. Non-Text types always carry null `plainText`, consistent with `getQuestionAnswersAsJSON`. This produced the new **QR6** and sharpened **XR6**.

### VR6 (PINS AN OPEN HEDGE): `map_agg` drops duplicate keys silently on engine v3

All report-service workgroups report `Athena engine version 3` (Trino), so the spec's repeated "engine version not pinned in `config/`" is now answered. On v3, `map_agg` over `('a',1),('a',2),('b',3)` returns `{a=1, b=3}`: it keeps the first value and drops the rest **without erroring**. Of the two possibilities the spec hedged between, this is the invisible one, which makes the one-row-per-(student, key) rule load-bearing. **Threaded into**: the single-value-per-key Technical Note.

### VR7 (SOFTENS): `questionId` sanitization is required for SQL validity, but collisions are not yet observed

The invalid-SQL half is confirmed against production: hyphenated ids (`9HzYd-`, `nb0-d3`) exist in real data and `res_1_9HzYd-_json` is a Presto syntax error. The collision half is currently theoretical: folding all **193** distinct production ids through a `make_safe_id`-style lowercase-and-replace yields **193 distinct keys, zero collisions**. Hex-encoding remains the recommendation (cheap, deterministic per Round 3, fails safe as the corpus grows), but Round 2's "would silently merge" should be read as *could*. **Threaded into**: the key-sanitization Technical Note.

### VR8 (QUANTIFIES): Track B's broadening, not Track A, is where scan cost lives

Over an identical 12-day window, the `QUESTION_ANSWERS_CHANGE` filter scanned **24.7 MB** while `event LIKE '%TOOL_CHANGE'` scanned **489 MB**, about **20x**. Full event history on the Track A filter scanned 666 MB to 1.33 GB depending on columns referenced. This inverts the natural assumption that the new Question-tile query would be the expensive addition. **Threaded into**: the Performance Technical Note.

### VR9 (IMPLEMENTATION TRAP): the `other_tiles` prepend must follow clue.ex's sort, not precede it

The structure contract says clue.ex prepends `other_tiles` to `question_order` so that `ResourceData`'s unconditional `Enum.reverse` (`resource_data.ex:149`) leaves it rightmost. Confirmed the surrounding sequence is sort (`clue.ex:191-193`) then reverse (`resource_data.ex:149`), which makes *where* the prepend happens decisive. Prepending at the natural spot, inside the reduce where the other structure keys are added, lets the sort carry `other_tiles` into alphabetical position: for keys `["zzz_text","abc_text","m1k2j3_json"]` it emerges as `["zzz_text","other_tiles","m1k2j3_json","abc_text"]`, second of four rather than last. Prepending after the sort produces the required trailing position. Verified by direct execution. The earlier external review proved the column *materializes*; nobody had checked its *position*. **See also VR19:** `other_tiles` must enter `question_order` *only* at that post-sort prepend and not also inside the reduce, or the column is emitted twice; and `other_tiles` is a reserved key, since `make_safe_id("Other Tiles")` produces it.

Also confirmed in the same pass, via `mix run --no-start` against the real `SharedQueries.get_columns_for_question/5`: a hyphenated `questionId` emits the unquoted alias `res_1_9HzYd-_json` (VR7), and the `_json` suffix contract holds, since an unrecognized `clue_question` type falls through to the `_ ->` branch today.

### VR10 (ADAPTIVITY): tile-change events carry no type field, so only discovery adapts for free

Prompted by the question "does this hard-wire the six types?" (Doug Martin, 2026-08-01), which it did. Two findings:

- **Discovery adapts for free.** `event LIKE '%\_TOOL\_CHANGE'` returned all five event types present in a sample window without enumerating any of them, so the Track B query never needs a list of known event names. Verified live.
- **The type label does not.** Tile-change events carry **no tile-type field**. Verified against production: the complete parameter key set is `args, containerIds, documentChanges, documentHistoryId, documentKey, documentProperties, documentTitle, documentType, documentUid, documentVisibility, operation, path, sectionId, tileId, tileTitle, toolId`, and `documentType` is the document's type (e.g. `problem`), not the tile's. Confirmed in source too: `processTileBaseEventParams` adds `sectionId`, `tileTitle` and `containerIds` but no type. The tile type therefore exists **only** in the event name, so a new logging type needs a derived label, and the derivation must fail soft (title-case) rather than drop the row.

A third consequence surfaced from comparing the two tracks: Track A takes `type` verbatim from the payload as CLUE's registered tile-type string (`"BarGraph"`), while a naive derivation from `BARGRAPH_TOOL_CHANGE` yields `"Bargraph"`, so the same tile type would render with different casing in Track A and Track B cells. This produced **BR4**, and gave DR3 a concrete requirement to carry: new tile logging must follow the `<TYPE>_TOOL_CHANGE` convention or the report will not see it.

### VR11 (INVALIDATES A SYMMETRY): Track B must apply no `operation` filter, because Drawing never logs `update`

Added 2026-08-04, during the requirements/implementation cross-reference. Neither doc had said anything about `operation` for Track B: Track A correctly omits it (`QUESTION_ANSWERS_CHANGE` carries no such field, VR10) and Track C inherits `operation = 'update'` from today's text query, leaving Track B's behavior unstated. The tempting default, mirroring Track C for symmetry, is **wrong**, and only measurement showed it.

Measured over a 12-day spring window (2026-04-20 to 2026-05-02, chosen because summer windows are near-empty for a classroom product), non-text `*_TOOL_CHANGE` events carry **35 distinct (operation, event) pairs** across just three event types. `operation` is a **per-tile-type vocabulary, not a CRUD set**:

| Event | Operations observed (top by volume) |
|---|---|
| `TABLE_TOOL_CHANGE` | `update` 16,741 / 659 tiles, `create` 4,000 / 460, `delete` 497 / 132 |
| `DRAWING_TOOL_CHANGE` | `addObject` 1,751, `rotateMaybeCopy` 1,741, `repositionObject` 710, `setOffset` 633, `deleteObjects` 300, `addAndSelectObject` 170, … (**no `update` at all**) |
| `GEOMETRY_TOOL_CHANGE` | `update` 845 / 45 tiles, `create` 403 / 40, `delete` 57 / 13 |

So `operation = 'update'` would silently erase **every free-standing Drawing tile** (133 distinct in the window, the second-largest type BR2 delivers) and every Table tile whose only event is a `create`. Exactly the invisible-loss failure mode BR2 exists to avoid.

**Decision** (Doug Martin, 2026-08-04): Track B applies **no** `operation` filter.

The stale-tile risk this leaves is accepted and is in any case not addressable through `operation`: there is no cross-type "the tile was deleted" signal. `delete` on Table/Geometry appears to be content-level rather than tile removal (`table-change.ts:40` types a table change's action as `create | update | delete | import-data`), Drawing's analogue `deleteObjects` removes objects *inside* the tile, and the only tile-destruction candidate, `beforeDestroy`, is 4 events across 3 tiles. So a tile a student later deleted can remain its `toolId`'s latest event and appear in `other_tiles`. **Threaded into**: the Track B Technical Note, implementation.md's Track B CTE.

*Method note:* this query ran against `logs_by_time` (379 MB scanned) when it should have used the partition-projected `logs_by_app`; future verification queries should partition-prune on app/year/month.

### VR12 (RETIRES THE PERFORMANCE RISK): the scan cost was the table, not the event filter

Added 2026-08-04, during the implementation-spec self-review. VR11's method note treated `logs_by_time` as a verification-query mistake. It is also what **the shipping code does**: `clue.ex:42-72` reads `logs_by_time` and has **no predicate on `time` at all**, so every CLUE report already runs an unbounded scan of an unpartitioned table.

Confirmed from Glue metadata (free, no scan): `logs_by_time` has `PartitionKeys: null` and points at `s3://log-ingester-production/processed_logs_with_id/`, while `logs_by_app` projects `app/year/month` and `logs_by_app_and_secure_key` projects `app/year/month/secure_key` with `secure_key` **injected**. Only the last matches CLUE's access pattern, and `report_query.ex:100-121` already uses it that way, deriving secure keys from the same `run_remote_endpoint` list `clue.ex` builds.

Measured on `logs_by_app_and_secure_key`, 40 real CLUE learners from April 2026, the **full three-track predicate** (`QUESTION_ANSWERS_CHANGE` plus every `*_TOOL_CHANGE`) with **no time bound**:

| Query | Table | Bytes scanned |
|---|---|---:|
| Track A only, 12-day window (VR8) | `logs_by_time` | 24.7 MB |
| Tile-change filter, 12-day window (VR8) | `logs_by_time` | 489 MB |
| Unbounded, as the code actually runs | `logs_by_time` | ~24 GB (observed in practice) |
| **All three tracks, unbounded, 40 learners** | **`logs_by_app_and_secure_key`** | **0.67 MB** |

So **VR8's central conclusion is inverted**: Track B's broadening is not the cost centre, and never was. Once the scan prunes to the report's own learners' S3 prefixes, the width of the event predicate is close to irrelevant. Returned counts for those learners: `QUESTION_ANSWERS_CHANGE` 1,689 / 40 learners, `DRAWING_TOOL_CHANGE` 1,275 / 29, `TEXT_TOOL_CHANGE` 660 / 40, `TABLE_TOOL_CHANGE` 184 / 3.

Residual, wall time only: with `secure_key` injected and `year`/`month` projected over 2014-2050, an unbounded query enumerates ~17,700 S3 prefixes. Measured 24.2 s unbounded against 17.5 s with `year >= 2025`, **identical bytes**. A year floor is an optional latency trim, not a correctness or cost requirement. **Threaded into**: the Performance Technical Note, implementation.md **D7**.

### VR13 (NEW TRAP, mirror of Round 2): a learner can hold one `questionId` in more than one document

Added 2026-08-04, during the implementation-spec self-review. Round 2 established that Track A must partition on `run_remote_endpoint` because one `questionId` is shared by many learners. The mirror case was never considered: **one learner holding the same `questionId` in two documents.**

That is the AC2 copy path itself. `updateQuestionContentForCopy` preserves `questionId` whenever `acrossDocuments` is true (`question-utils.ts:33-39`); it is registered as the Question tile's `updateContentForCopy` hook (`question-registration.ts:19`) and invoked from `document-content.ts:399-400` with `isCrossingDocuments`. So copying a Question tile into a learning log or personal document, or copying a whole document, puts that `questionId` in two documents under one `run_remote_endpoint`. Because `getQuestionAnswersAsJSON` walks a single document (`question-utils.ts:52-53`), neither event contains the other document's answers, and a `PARTITION BY run_remote_endpoint, questionId` window keeps only the globally-latest one.

Measured over the full production corpus (`app='CLUE'`, `year IN (2025,2026)`, 61.8 MB scanned):

| Documents per (learner, questionId) | Pairs |
|---|---:|
| 1 | 1,205 |
| 2 | 14 |
| 3 | 1 |

So 15 of 1,220 pairs (1.2%) would silently lose answers, 16 documents' worth in total, in exactly the case QR2 says must not "collapse or drop an answer." Rare but invisible, and the fix is free: adding `documentKey` to the partition produces extra rows that the Elixir-side reduce already merges into one entry list, with each entry carrying its own history link. **Threaded into**: implementation.md's Track A CTE and XR4 fixture 2b.

*Incidental confirmation of VR12:* this full-corpus query scanned **61.8 MB in 3.8 s** on `logs_by_app`, against VR8's 666 MB to 1.33 GB for the same logical filter on `logs_by_time`.

### VR14 (CONFIRMS D7): the two log tables are row-equivalent, and the cost gap is a single measurement

Added 2026-08-04. VR12 justified moving off `logs_by_time` on partitioning and cost. Because Glue reports **different `LOCATION`s** (`processed_logs_with_id/` against `logs_by_app_and_secure_key/`), the two are physically distinct copies produced by the ingester, not views over one dataset, so XR5 required checking that the swap does not lose historical rows.

Every CLUE row in both tables, counted by year:

| Year | `logs_by_app` | `logs_by_time` | Delta |
|---|---:|---:|---:|
| 2018 | 98,949 | 98,949 | 0 |
| 2019 | 2,654,776 | 2,654,776 | 0 |
| 2020 | 850,969 | 850,969 | 0 |
| 2021 | 782,710 | 782,710 | 0 |
| 2022 | 1,169,173 | 1,169,173 | 0 |
| 2023 | 2,454,320 | 2,454,426 | -106 |
| 2024 | 1,418,504 | 1,418,398 | +106 |
| 2025 | 1,261,476 | 1,261,476 | 0 |
| 2026 | 624,580 | 624,586 | -6 |
| **Total** | **11,315,457** | **11,315,463** | **-6** |

**6 rows differ out of 11.3 million (0.00005%)**, and backfill depth is identical (both reach 2018). The 2023/2024 delta nets to zero, so it is year attribution, not loss: `logs_by_app` uses the ingester-assigned `year` partition while the `logs_by_time` side derived year from `year(from_unixtime(time))`. The remaining 6 rows sit at the head of the current year, consistent with ingest lag into the derived copy, and are immaterial for a report over completed classwork. **D7 is safe as written.**

The same pair of queries also restates the cost case as one measurement: this count cost **0 bytes and 23 s** on `logs_by_app` (answered from partition metadata) against **15.46 GB and 3.4 minutes** on the unpartitioned `logs_by_time`.

### VR15 (INVALIDATES GUIDANCE): the XR1 `containerIds` filter drops 83% of the log history unless a missing key is treated as free-standing

Added 2026-08-04, during the second implementation-spec self-review. VR3 measured `containerIds` "present on all 21,146 tile-change events sampled (zero absent)" and both docs concluded the Track B filter "needs no null handling." VR3's measurement is correct and its conclusion is wrong, because the window it sampled was in 2026 and the property it was testing is a function of **when the event was logged**.

`containerIds` was introduced by exactly one commit in `collaborative-learning`, `1efa1efb` **2025-05-07** ("Logging updates for moves and deletes"): `git log -S containerIds --reverse -- src/` returns that commit and no other. Every `*_TOOL_CHANGE` event logged before that release therefore carries no `containerIds` key, so `json_extract(parameters,'$.containerIds')` returns SQL `NULL`, `json_format(NULL)` is `NULL`, and the pinned predicate `… = '[]'` evaluates to `NULL`, i.e. the row is silently dropped.

VR14's by-year counts size the loss: **9,429,401 of 11,315,457 CLUE rows (83.3%) predate 2025**, plus the January-to-early-May slice of 2025's 1,261,476. So for any report over a class from 2018 through April 2026, Track B returns **nothing**. The failure is asymmetric in the way that hides it: Track C (free-standing text) carries no `containerIds` filter, so the text columns a reviewer would eyeball keep working, and only the new `other_tiles` column is empty.

Treating an absent `containerIds` as free-standing is **correct**, not merely defensive. The Question tile first landed 2025-03-20, `questionId` 2025-04-30, `QUESTION_ANSWERS_CHANGE` 2025-05-05 (`4c90c5ca`), `containerIds` 2025-05-07. No container tile type existed before 2025-03-20, so every tile in that history genuinely was free-standing, and the window in which a Question-contained tile could log a change event without `containerIds` is the two days from 2025-05-05 to 2025-05-07, both pre-release per the resolved XR1 Open Question.

**Fix**: `COALESCE(json_format(json_extract(parameters,'$.containerIds')), '[]') = '[]'`.

**Payoff measured by VR23**: roughly **3.75 million of 4.43 million** non-text tile-change events (85%) predate 2025 and so carry no `containerIds`. Pre-2025-05 every tile is free-standing by construction, so that is Track B's historical yield, dropped in its entirety without this fix.

**Threaded into**: XR1, XR4, implementation.md's Track B CTE and XR4 fixture 3b.

### VR16 (BOUNDS VR12): the residual wall time and the query-text ceiling are both linear in learner count

Added 2026-08-04, during the second implementation-spec self-review. VR12 closed the performance item outright on a 40-learner measurement. The byte-scan conclusion holds and is not reopened; what does not hold is the generalization to report scale, because both remaining costs scale with the number of learners in the report and nothing in the path caps that number.

**Wall time.** Under the injected `secure_key` projection Athena enumerates `1 app x 37 years x 12 months x N secure_keys` S3 prefixes. VR12's own timings (24.2 s unbounded, 17.5 s with `year >= 2025`, at 40 learners) fit a 17.1 s fixed cost plus **0.399 ms per prefix**, reproducing both points to 0.1 s and VR12's prefix count exactly. Trino inlines CTEs, so the implementation's three track CTEs each enumerate separately (three, not four, only because VR22 moved Track C off its two-reference `MAX(time)` self-join):

| learners | unbounded, 1 scan | unbounded, 3 scans | 2-year floor, 3 scans |
|---:|---:|---:|---:|
| 40 | 24 s (= VR12) | 38 s | 18 s |
| 300 | 70 s | 176 s | 26 s |
| 1000 | 194 s | 548 s | 46 s |

So VR12's "a year floor is an optional latency trim, not a correctness or cost requirement" understates it twice: the ~7 s is the 40-learner single-scan figure, and what the floor removes is 35 of 37 projected years, the term that grows with the report. Unbounded, a 1,000-learner CLUE report spends about nine minutes listing prefixes per runnable while scanning under a megabyte. The floor is derivable from data already in hand (`learner_data.ex:186,188` carry `created_at` and `last_run`), so it is now **required**, not deferred.

**Query-text length.** Separately, repeating the learner predicates per track triples the two embedded literal lists. Measured against AWS's documented 262,144-byte DML query-string quota with real endpoint and UUID secure-key lengths: today's query fits to about 1,311 learners, a per-track shape to about **628**, a shared base CTE to about 1,883. `group_learners_by_runnable_url` puts every class assigning the same CLUE problem URL into one `fetch_resource/3` call, so cohort-scoped reports aggregate across classes and 628 is reachable; exceeding the quota is a hard Athena error. Hoisting the predicates into one base CTE fixes this even though the CTE is inlined, because the quota applies to the submitted string rather than the plan.

**Threaded into**: the Performance Technical Note, implementation.md **D2**, **D7** and sequencing step 1.

### VR17 (INVALIDATES TWO PINNED EXPRESSIONS): the planned SQL cannot be written as it reads

Added 2026-08-04, during the second implementation-spec self-review. Two literal-level defects in expressions both docs had pinned as settled. Neither is a design flaw; both would have been discovered as errors during the Track A or Track B step, and one of them has a natural "fix" that is silently wrong.

**1. `LIKE '%\_TOOL\_CHANGE' ESCAPE '\'` does not survive `clue.ex`'s SQL heredoc.** Written into a `"""` heredoc as pinned, Elixir emits `LIKE '%_TOOL_CHANGE' ESCAPE ''`, with **no compiler warning**. Verified by throwaway execution of the three candidate forms. Two independent corruptions: `\_` loses its backslash (so the underscores become single-character `LIKE` wildcards), and `\'` is a valid Elixir escape for `'`, so the escape string becomes empty, which Trino rejects. The empty `ESCAPE` fails loudly, but the obvious way to clear that error is to delete the `ESCAPE` clause, which compiles, runs, and quietly changes the predicate's meaning. Fixes: double the backslashes, use `~S"""`, or (**pinned**) use `regexp_like(event, '_TOOL_CHANGE$')`, which contains nothing that either Elixir or SQL needs escaped.

**2. Track A's `json_extract` and Track C's `json_extract_scalar` cannot be unioned.** `json_extract` returns Trino type `json`; `json_extract_scalar` returns `varchar`; Trino does not implicitly coerce between them in a `UNION`, so the three-track union fails on incompatible types. VR1 verified `json_extract(parameters,'$.answers')` in isolation against a literal, which is why this was invisible: the union is the new context. Fix: `json_format(json_extract(parameters,'$.answers'))`, and `CAST(NULL AS VARCHAR)` for the union's padded columns so no column's type depends on which branch supplies a value.

**Both items are confirmed live** (2026-08-04, four queries on `log_ingester_production`, workgroup `dmartin-concord-org-iwEisHLkbj2z4VSACNS6`, engine v3, **0 bytes scanned each** since all four run against literals):

| Query | Result |
|---|---|
| `json_extract(...) UNION ALL json_extract_scalar(...)` | `FAILED` / `TYPE_MISMATCH: line 1:94: column 1 in UNION query has incompatible types: json, varchar` |
| the same with `json_format(json_extract(...))` | `SUCCEEDED`, nested payload returned intact as varchar next to the scalar branch |
| `... LIKE '%_TOOL_CHANGE' ESCAPE ''` | `FAILED` / `INVALID_FUNCTION_ARGUMENT: Escape string must be a single character` |
| `regexp_like(e,'_TOOL_CHANGE$')` against the escaped and corrupted `LIKE` forms | `regexp_like` and the correctly-escaped `LIKE` agree on all four probes; the corrupted form additionally matches `XTOOLYCHANGE` |

So the union failure is a hard `TYPE_MISMATCH` rather than a coercion, `json_format` is the fix, the empty `ESCAPE` is rejected outright, and the wildcard divergence the half-fix introduces is demonstrable rather than theoretical. `regexp_like` is confirmed equivalent to the intended `LIKE` on the real event vocabulary.

**Threaded into**: BR4, the Track B Technical Note, implementation.md **D2**, **D3**, the Track B CTE and the Track A sequencing step.

### VR18 (IMPLEMENTATION TRAP): the prompt header is decided by row order unless the structure entry upgrades it

Added 2026-08-04, during the second implementation-spec self-review. QR1 says the header is the enriched prompt when available, else the `questionId`. That is well defined for one row and ambiguous for a column, because a Track A question has one structure entry and many contributing rows, one per learner (and per document, after VR13), each carrying that learner's own latest `QUESTION_ANSWERS_CHANGE`.

Once the DR1 enrichment ships, those rows **disagree**: a learner whose latest answer predates the deploy carries no `$.prompt`, one who answered after it does. `clue.ex:121-131` writes the structure entry only when the key is new (`new_question = not Map.has_key?(...)`) and never revisits it, and the query has no `ORDER BY`, so the header for the entire column is whichever row Athena delivered first, and it can differ between two runs of the same report over unchanged data.

The disagreement is **permanent**, not a transition-window artifact: a student who answered a question once before the deploy and never returned keeps a prompt-less latest event forever, so a long-running class holds both shapes for the same question indefinitely.

This matters because the enriched header is DR1's entire payoff, and filing the DR1 ticket is a deliverable of this story precisely so that the shipped lookup binds to the right field. As written the enrichment would take effect per question at random, presenting as "the prompt only appeared on some columns", which reads as a CLUE-side bug rather than a report-service one.

**Fix**: the stored prompt is upgraded, not write-once. When a row carries a non-empty `$.prompt` and the stored prompt for that key is still the `questionId` fallback, replace it, so the header is the enriched prompt if **any** contributing row has one. One extra branch. Same class of finding as VR9 and D5 rule 4: the docs state the correct end state and the natural code shape produces a different one invisibly. **Threaded into**: QR1, DR1, implementation.md's Structure section, D5 rule 4, XR4 fixture 1.

### VR19 (IMPLEMENTATION TRAP, low severity): the three key families share one namespace, and two structure rules both add `other_tiles`

Added 2026-08-04, during the second implementation-spec self-review. Two small items, both verified by throwaway execution, both recorded because their failure mode is silent rather than because they are likely.

**Reserved-key collision.** Track A keys (hex, collision-free within Track A), Track B's single `other_tiles`, and Track C's `make_safe_id(tile_title)` all live in one flat `map_agg`/structure namespace, and `make_safe_id` is lossy. `make_safe_id` maps `"Other Tiles"`, `"other tiles"`, `"other-tiles"` and `"OTHER_TILES"` all to exactly `other_tiles`, so a free-standing text tile with any of those titles collides with the synthetic Track B key. The consequence is two silent failures at once: `clue.ex:121-137` keeps whichever `type` was written first, so if `clue_text_tile` wins, the array cell is read as `json_extract_scalar(answer,'$.text')` and returns NULL; and both tracks write answer rows under one key, which is VR6's silent `map_agg` drop. Fix: treat `other_tiles` as reserved and disambiguate the Track C key on collision. This does not breach BR1's "preserved unchanged", because the colliding case is broken today rather than working. Also verified and deliberately **left unguarded**: `make_safe_id` prepends `q` to a digit-leading title, which is D1's own prefix, so `make_safe_id("39487a59642d") == "q39487a59642d"`, the key for `questionId` `9HzYd-`. Real, but it needs a tile titled with the exact hex of a `questionId` in the same report, and no `[a-z0-9_]` key scheme is collision-proof against a lossy transform over arbitrary titles.

**Duplicated `other_tiles` column.** The structure contract ("a column exists only if the key is in both `question_order` and `questions`") invites adding the synthetic key to both inside the reduce; VR9's rule then prepends it to the sorted `question_order` unconditionally afterwards. Doing both duplicates the key, and `question_order` is iterated directly to build columns, so the report emits `res_1_other_tiles_json` twice. Verified by running the real `SharedQueries.get_columns_for_question/5` over a `question_order` of `["other_tiles", "abc_text", "other_tiles"]`. Not an error, just a silently duplicated column in a researcher-facing CSV. Fix: state that `other_tiles` enters `questions` in the reduce and `question_order` only in the post-sort step.

**Threaded into**: implementation.md's Structure section, **D6**, XR4 fixture 5.

### VR20 (INTERACTION BETWEEN TWO FIXES): the `documentKey` partition reopens the cell-order determinism it was landed beside

Added 2026-08-04, during the second implementation-spec self-review. VR13 (add `documentKey` to Track A's window partition) and the Round 1 cell-order decision (pin entry order so a re-run does not produce diff noise) were both applied in the same pass, and their interaction was not checked.

The cell contract pins Track A entry order as "document order, as the tiles appear in `answers[].answerTiles[]`, flattened across groups in payload order", which is well defined for **one** payload. The VR13 change exists precisely to make a `{learner, questionId}` yield **more than one** row, one per document, each its own payload merged Elixir-side into one entry list. Order *between* those payloads is Athena's row delivery order, and the query has no `ORDER BY`, so the 15 of 1,220 learner/question pairs VR13 measured (14 spanning two documents, one spanning three) get a cell whose entry order can differ between two runs of the same report over unchanged data. That is the same failure the cell-order decision removed for Track B, reintroduced for 1.2% of pairs, and XR4 fixture 2b (added as VR13's own regression guard) is the test that would flake on it.

**Fix**: pin cross-payload order as ascending `documentKey`, sorted Elixir-side before flattening rather than via an `ORDER BY` in the CTE, since the reduce must preserve order regardless. Feed fixture 2b's rows in both orders. **Threaded into**: implementation.md's Cell contract and XR4 fixture 2b.

### VR21 (SEQUENCING): the testability seam sat after the code it exists to make testable

Added 2026-08-04, during the second implementation-spec self-review. Not a data or engine finding, a self-consistency one, recorded because the ordering it corrects is what decides whether XR4's answer-row assertions actually get written.

The 2026-08-04 round added the testability seam as sequencing step 6, with tests at step 7 noted as growing "alongside 3 and 4" (Track A and Track B). Those two statements are incompatible: the Tests section states that nothing on this path is reachable from a test and that every answer-row assertion is unobservable until the seam lands, so tests cannot grow alongside the track steps while the seam follows them. The same round's QA resolution had already named the consequence ("under time pressure ... the structure-only assertions get written and the answer-row assertions ... get dropped") and then left the ordering that produces it.

The seam is independent of every track step (it changes module boundaries, not query or parse logic), so it moves at no cost. **Fix**: seam ahead of the track work, as step 2, with the remaining steps renumbered. This matters more after this review round than before it, because the answer-row group has grown to include VR15's missing-`containerIds` case, VR18's both-orders prompt assertion, VR19's reserved key and VR20's cross-document ordering. **Threaded into**: XR4, implementation.md's Tests section and Suggested sequencing.

### VR22 (CORRECTS VR16, and retires the last VR3 tie): Track C's self-join costs a fourth scan, so it moves to the `ROW_NUMBER` window too

Added 2026-08-04, in the re-review after Round 2's findings were applied. VR16's wall-time table and D7's residual both stated a three-scan multiplier, counting one inlining of the base CTE per track. That undercounted: Track C keeps today's `MAX(time)` self-join, which references the relation **twice** (`clue.ex:43-53` builds `last_changes`, `:61-64` joins the main select back to it), so the shape inlines four times and every three-scan figure understated by a third.

Rather than restate the number, the fourth reference is removed. Track C now uses the **same `ROW_NUMBER` window** as Track A and Track B. Earlier drafts kept the self-join because BR1 requires that path unchanged and because VR3's duplicate-`time` rows are inert there (`map_agg` collapses the duplicate). Both remain true, and the swap is still right: it removes a scan, retires the VR3 tie at the source instead of depending on a downstream collapse, and leaves all three tracks one shape. It does not breach BR1, whose guarantee is about emitted columns and rows: after aggregation the rows are identical, since the only difference is tie duplicates `map_agg` was already discarding. That is the same reading of "unchanged" applied when D7 moved Track C's source table.

**Threaded into**: VR16's table, implementation.md's Track C CTE, Track B CTE and **D7**.

### VR23 (INVALIDATES A LABEL, AND SIZES VR15): the log event vocabulary has churned, and `GRAPH_TOOL_CHANGE` is the Geometry tile's retired name

Added 2026-08-04, running the query proposed as a product question ("now that VR15 unlocks historical Track B coverage, is there anything in it?"). The answer is yes, and it came with a correctness finding.

Non-text `*_TOOL_CHANGE` **events** by year, all CLUE history (`logs_by_app`, partition-pruned, 225 MB, 8.4 s):

| Year | Events | Notes |
|---|---:|---|
| 2019 | 680,642 | Graph 462,269 / Table 138,520 / Drawing 79,853 |
| 2020 | 245,891 | |
| 2021 | 159,688 | |
| 2022 | 625,819 | Dataflow appears |
| 2023 | 1,501,957 | Drawing 960,956 |
| 2024 | 536,465 | Geometry and BarGraph appear, Graph ends |
| 2025 | 440,503 | |
| 2026 | 237,539 | IframeInteractive appears |

**Sizing VR15**: roughly **3.75 million of 4.43 million** non-text tile-change events (85%) predate 2025 and therefore carry no `containerIds`. Without VR15's `COALESCE` all of it is dropped silently. Pre-2025-05 every tile is free-standing by construction, since the Question tile did not exist, so this is Track B's historical yield directly, and it is far larger than VR2's 12-day 2026 window (258 tiles, 86% Table) suggested.

**The correctness finding**: `GRAPH_TOOL_CHANGE` accounts for **1,270,737 events across 2019-2024** and then stops, while `GEOMETRY_TOOL_CHANGE` starts in 2024 and continues. `collaborative-learning` commit `310b03c8b` (2024-02-14, "Pushing progress for logging dataset linking") is the cause: a one-line rename of the enum entry `GRAPH_TOOL_CHANGE` to `GEOMETRY_TOOL_CHANGE`. So every `GRAPH_TOOL_CHANGE` event in the logs is a **Geometry** tile under the event's old name.

BR4's derivation yields `"Graph"` for it, and that is not a cosmetic miss like `"Bargraph"`: `"Graph"` is the registered name of a **different, real, current** tile type (`graph-types.ts:6`, the XY plot in `src/plugins/graph`), which per VR2 emits no change event at all. A report over a 2022 class would label its geometry tiles `Graph` while a report over a 2025 class labels the same tile type `Geometry`, and the wrong label names something else that exists. **Fix**: add `"GRAPH" => "Geometry"` to the known-casing override map, with the rename recorded in the comment. `BARGRAPH` is unaffected (its stem is `BARGRAPH`). Watch item: if the modern Graph tile ever logs, it reuses the retired name and this entry needs revisiting.

**Two further corrections follow.** (a) BR4's pattern-discovery requirement now has **retrospective** evidence, not just the prospective DR3 argument: an `IN (...)` list of today's seven event names would silently drop 1.27M historical Graph events, and the vocabulary has churned in both directions (Dataflow from 2022, Geometry and BarGraph from 2024, IframeInteractive only from 2026). "Seven types" is a 2026 snapshot of a moving target. (b) VR2's "Graph logs only `TILE_UNLINK`" is true of **current** code and false of the log history; VR2's coverage table is derived from `QUESTION_ANSWERS_CHANGE`, which only exists from 2025-05, so it cannot speak to historical free-standing coverage at all.

**Threaded into**: BR2, BR4, VR2, VR15, implementation.md **D4** and XR4 fixture 8 (whose premise was wrong: it called `GRAPH_TOOL_CHANGE` "an event the code has never seen" and asserted the label `"Graph"`, so it is now split into a retired-name guard and a genuinely-unknown-event adaptivity guard).

### VR24 (FIXES A LIVE DEFECT): the `"first"` history-id sentinel resolves to nothing in CLUE

Added 2026-08-04, closing the last loose end from the readiness assessment. QR5 relied on `documentHistoryId` being present on every event, which VR4 confirmed (zero nulls across 8,600 events, 299 of them the string `"first"`, 3.5%). What nobody had checked is what the *consumer* does with that value.

CLUE emits the literal `"first"` when a document has no history entry at log time, i.e. the student's first change to a brand-new document (`log-document-event.ts:51-53`). Traced end to end through `collaborative-learning`: `initialize-app.tsx:119` -> `stores.ts:196` -> `sorted-documents.ts:95` -> `canvas.tsx:107-124` -> `playback.tsx:25-26` -> `firestore-history-manager.ts:291-299`, where

```js
const entry = this.treeManager.findHistoryEntryIndex(historyId);
if (entry >= 0) { this.treeManager.goToHistoryEntry(entry); }
else { console.warn("Did not find history entry with id: ", historyId); }
```

and `findHistoryEntryIndex/1` is a plain `findIndex(entry => entry.id === historyEntryId)` (`tree-manager.ts:166-168`). Grepping all of `src/` for `"first"` returns only the emitter's comment and the line producing it, so **nothing consumes it as a sentinel**. The lookup fails, no navigation happens, and because `canvas.tsx:114-121` has already called `setShowPlaybackControls(true)`, the playback UI opens anyway and the document renders at playback's default. The researcher sees a history view that appears positioned and is not, with the only signal a console warning.

That is mildly misleading rather than harmless: `"first"` means the change happened at the very start of the document's life, so by the time the link is opened the document may hold much later work that a reader could attribute to that early moment.

**This is a live defect in the shipped report, not something REPORT-36 introduces**: `TEXT_TOOL_CHANGE` rides the same `logDocumentEvent`, so today's free-standing text links pass the sentinel through identically.

**Fix (report side)**: treat `"first"` as absent when building the link. `HistoryLink.format_link_to_work/1` already omits the parameter for a nil history id (`history_link.ex:23`), so no history request is made, the playback controls stay closed, and the document opens normally, which is honest about not being positioned. The report cannot do better: the true first entry's id is not in the log. This changes Track C's link output for the affected rows, which is a defect fix rather than a BR1 breach (BR1 guarantees columns and keys), but it is the only change in this story reaching outside Tracks A and B.

**Better fix (CLUE side, non-blocking)**: have `moveToHistoryEntryAfterLoad` treat `"first"` as index 0, which makes these links land correctly with no report change. Filed as ask 3 of the CLUE ticket set.

**Threaded into**: QR5, implementation.md's row contract and the history-link section.

### VR25 (NARROWS BR2 BY ONE TYPE): IframeInteractive logs outside the enrichment path, so Track B gates structurally

Added 2026-08-04. Affects **Track B only**; Track A and every AC are unchanged.

Measured per event type over 2025-2026, `documentHistoryId` is absent on 11.7% of `TABLE_TOOL_CHANGE`, 10.4% of `DRAWING_TOOL_CHANGE`, 9.1% of `TEXT_TOOL_CHANGE` and 5.4% of `GEOMETRY_TOOL_CHANGE` events, against **zero** for `QUESTION_ANSWERS_CHANGE`. VR4's "zero nulls" was a Track A measurement and does not carry to Track B. Those entries keep a working document link; only the history position is unavailable, so VR24's guard is generalized to nil, empty and `"first"`.

`IFRAME_INTERACTIVE_TOOL_CHANGE` is worse and different: on 100% of its 19,110 events it carries **no `toolId`, no `documentKey` and no `containerIds`** (9 learners, 5 distinct tiles, 2026 only). The cause is that `iframe-interactive-tile.tsx:352-359` calls `Logger.log` directly instead of `logTileChangeEvent`, bypassing `processTileChangeEvent` (which sets `toolId`), `processTileBaseEventParams` (`containerIds`, `tileTitle`) and `processDocumentEventParams` (`documentKey`, `documentType`, `documentHistoryId`) in one go. It is also the only tile-change event that carries an explicit `tileType`, which makes VR10's "tile-change events carry no tile-type field" true of every event except this one; VR3 confirms IframeInteractive did not occur in the window VR10 sampled.

Left unhandled it would fail silently in two ways: a null partition key collapses all of a learner's iframe events into one entry regardless of tile count, and a null `documentKey` emits a link that cannot open anything.

**Decision** (Doug Martin, 2026-08-04): gate Track B **structurally**, not by event name, so BR4 still holds: require a non-null `documentKey` (the only source of the link and of the `documentKey`/`documentType` cell fields), and use `COALESCE(toolId, tileId)` as the tile identity (free, since `logTileChangeEvent` sets them equal). This excludes IframeInteractive today and re-includes it automatically if CLUE routes it through `logTileChangeEvent`, which is filed as a CLUE ask. Five tiles in a tile type that began logging this year, recorded alongside the nine types that log nothing at all (VR2), so BR2's coverage reads "whatever types log **usably**" rather than "whatever types log". Not escalated as a product question: it is an edge of the additive Track B, not of the ticket's acceptance criteria.

**Threaded into**: BR2, implementation.md's Track B CTE and the history-link section.

### Still open after this round

1. ~~**Key sanitization** remains an "or" (hex-encode vs decoupled surrogate); pin it in `implementation.md`.~~ **Pinned** in implementation.md as **D1**: `"q" <> Base.encode16(id, case: :lower)`. Verified 2026-08-04 that hex encoding is order-preserving for equal-length ids, so DR2's cross-report column-order stability survives it.
2. ~~**BR2 coverage** needs a product decision from Leslie given VR2.~~ **Resolved 2026-08-01**: ship the six covered types, gap accepted, driven by XR5; future logging tracked as DR3.
3. **DR1's CLUE-side enrichment ticket** is still unfiled and unowned. As of 2026-08-04 filing it is a **deliverable of this story** (see DR1), because the shipped `$.prompt` lookup binds to the field name that ticket specifies. It is now **sequencing step 0** in implementation.md, ahead of all code, so it is tracked as work rather than as prose.

Nothing else is open. The 2026-08-04 implementation-spec self-review closed seven findings plus one raised against its own D7 change; see implementation.md's Self-Review section for the decision log, and VR12-VR14 above for the measurements taken during it.
