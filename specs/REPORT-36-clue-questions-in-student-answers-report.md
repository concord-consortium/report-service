# CLUE Questions in Student Answers Report

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-36

**Status**: **Closed**

## Overview

Extend the Student Answers report so CLUE (Collaborative Learning) documents surface student work in a form that resembles the activity-player report. CLUE ships a purpose-built **Question tile** that carries a stable reporting id and fixed prompt; the report aggregates student answers by that id (handling copies), documents each answer tile's type and text, and links to the student's document at the correct history point. This is **additive** to, not a replacement for, reporting on free-standing tiles.

The architecture is log-only throughout: read the Athena log DB, write CLUE answers as parquet into the existing `partitioned-answers/…` layout, let the shared report SQL render them. No Firestore, no document-state reads. Everything works on logs already written.

## Requirements

### Track A: Question tiles (the primary AC1/AC2 mechanism)

- **QR1 (AC1): Aggregate by stable `questionId`**, not by title, so answers to the same authored question align in one column across all students. The column header is the authored prompt when available, falling back to the raw `questionId`. *(Prompt headers are **not yet live** and are gated on CLUE-614; every current column shows the raw 6-character id. The lookup ships inert.)*
- **QR2 (AC2): Copies show both/any answers.** Across-document copies share a `questionId`; within-document copies get a new one and appear as distinct questions. Includes one learner holding one `questionId` in two documents (measured at 1.2% of learner/question pairs), which requires `documentKey` in the window partition.
- **QR3 (AC3): Text answers shown**, surfacing `plainText` as the `text` field of the entry.
- **QR4 (AC4): Non-text answer tiles document their type** (Drawing, Table, Geometry, …) plus a history link and the `documentKey`/`documentType` of their document. Full rendered content is not required.
- **QR5 (AC5): History link** to the student's document at the correct history point. *(Entries whose `documentHistoryId` was missing or the literal `"first"` deliberately omit the parameter. Note the link **position** does not currently work in CLUE; see CLUE-613 below.)*
- **QR6: Empty answers must not be reported as answers.** `Placeholder` entries are dropped entirely, empty/whitespace `plainText` is treated as no answer, and a question that reduces to nothing emits no answer row at all.

### Track B: Free-standing tiles (additive extension of the existing text path)

- **BR1 (no regression): Free-standing text tiles keep their own per-title columns**, unchanged.
- **BR2: Non-text free-standing tiles aggregate into one `Other tiles` column**, rightmost among the answer columns, holding a JSON array of `{type, link, documentKey, documentType}` entries. *(Partial by construction: CLUE registers 22 tile types but only some emit a `*_TOOL_CHANGE` event. Nine emit nothing at all, so free-standing work in them is invisible to any log-only design; tracked as CLUE-615. `IframeInteractive` is additionally excluded because it logs without `documentKey` or `toolId`; tracked as ask 4 of CLUE-614.)*
- **BR3: Same-title collision fix — deferred, affirmatively out of scope.** Folding `toolId` into the title-keyed id would rename every existing free-standing text column, directly conflicting with BR1's "preserved unchanged". If ever pursued it must be a separate, conscious column-name-compatibility decision.
- **BR4: Tile types must be discovered by pattern, never by an enumerated list**, so a newly-logging type appears with no report-service change. Pinned as `regexp_like(event, '_TOOL_CHANGE$')`. The type *label* is derived from the event name with a known-casing override table and a title-case fallback; an unrecognized event must surface with a derived label, never be dropped and never raise.

### Cross-cutting

- **XR1: No double-counting** between the two tracks, enforced by excluding tile-change events with a non-empty `containerIds`, treating a missing key as free-standing.
- **XR2: Real activity name**, replacing the hardcoded `"Test Clue"`.
- **XR3: No regression to non-CLUE reports.** Holds as a fact rather than an argument: no shared code was edited.
- **XR4: Test coverage** for both tracks, which required building a testability seam and new fixtures first.
- **XR5: Works on historical logs**, before any CLUE-side logging change. Any CLUE enrichment is progressive enhancement for new data only.
- **XR6: CLUE completion metrics are approximate.** The structure is discovered from the union of learners' answers rather than an authored question set, so every answer column counts as one "question". The synthetic `other_tiles` entry counts as one too. Accepted as-is; excluding it would require editing the shared query used by all AP/LARA reports.

## Technical Notes

**Primary file is `server/lib/report_server/clue.ex`.** The shared `shared_queries.ex` needed no change: the existing `_ ->` fallback already emits exactly the required `res_<n>_<key>_json` column for any unrecognized question type, so an added branch would have produced byte-identical SQL. The contract is pinned by tests instead of by a branch.

**`questionId` is not a safe SQL identifier.** Column aliases are emitted unquoted, and a raw `questionId` is a nanoid over an alphabet including `-` (~9% of ids), so a raw key produces invalid Presto SQL rather than a degraded value. A lossy `make_safe_id`-style fold would instead silently merge distinct ids.

**Single value per key.** The report aggregates with `map_agg` and reads one value per key, and on Athena engine v3 a duplicate key is silently dropped rather than erroring. So a multi-tile question and the `other_tiles` column must be aggregated Elixir-side into one row per (student, key) whose value is a JSON list.

**A column exists only if the structure declares it**, in both `question_order` and the `questions` map, so aggregating answer rows alone never materializes a column.

**`plainText` is consumed directly** and must not be routed through the text path's Slate decoder, whose failure branch silently drops the answer.

**Performance is a table-selection problem, not a filter-width problem.** The original query read an unpartitioned table with no time bound. Moving to `logs_by_app_and_secure_key`, which projects `app/year/month/secure_key` with `secure_key` injected, prunes to the report's own learners before any row filter runs. The residual costs are wall time (S3 prefix enumeration) and the submitted SQL string length against Athena's 262,144-byte quota, both linear in learner count with no cap in the path; both are handled by a required year floor and a single shared base CTE.

## Out of Scope

- Rendering the **content** of non-text tiles. Only type plus history link are surfaced; full state lives in Firestore, which this pipeline does not read.
- Reading CLUE tile state from Firestore or any source other than the Athena log DB.
- Changing the shared `map_agg` answer aggregation in `shared_queries.ex`.
- Any change to the AP/LARA answer path beyond the guaranteed-inert additive column cases.

## Production verification

Run against MODS PD Spring 2026 on 2026-08-05: 12 learners, 9 resources, 523 answer entries, and **zero skipped rows across all seven skip counters**. Question columns aligned across students, cell shape matched the contract exactly with zero malformed entries, `Other tiles` was rightmost and correctly sorted, and `total_num_questions` equalled the answer-column count for every resource. The copied-`questionId`-across-two-documents case, which no test covered, occurred in this class: 9 cells across 5 learners, all correctly ordered by `documentKey`. A second run produced byte-identical JSON payloads, establishing that column ordering is deterministic rather than incidentally stable.

Two defects were found during verification and filed as REPORT-98 (activity names embed the whole unit URL, ~100 characters wide) and REPORT-99 (`NaN` in `total_percent_complete` when a resource has zero questions). Both are cosmetic and neither affects answer data.

A third was found in CLUE and filed as **CLUE-613**: history links open the correct document but always at the end of its history. CLUE resolves the report's id correctly and then the seek fails on a detached state tree during load. Nothing to change on the report side.

## Not Yet Implemented

- **Prompt-labeled column headers (DR1)** — filed as **CLUE-614**. The `$.prompt` lookup ships inert and headers show the raw `questionId` until CLUE adds the prompt as a top-level key. Confirmed empirically: zero production events carry a prompt field.
- **Tile-change logging for the nine silent tile types (DR3)** — filed as **CLUE-615**. Cannot help this story regardless, because new logging never retrofits events into historical partitions.
- **`IframeInteractive` free-standing coverage** — gated out structurally because the tile logs via bare `Logger.log` and carries no `documentKey`, `toolId` or `containerIds`. Returns automatically if CLUE routes it through `logTileChangeEvent`; filed as ask 4 of CLUE-614.
- **Correct handling of the `"first"` history-id sentinel** — the report omits the parameter rather than passing a value nothing resolves. The better fix is CLUE-side; filed as ask 3 of CLUE-614.
- **BR3 same-title collision fix** — deferred by decision, not by omission. See the Requirements note above.
- **Free-standing work in tile types that emit no change event** — unrecoverable by any log-only design. Measured at 263 of 2,143 distinct in-question answer tiles (12%), with Image the largest gap; the free-standing loss is unmeasurable by construction, since the absence of the event is the problem.

## Decisions

### Track B scope: only Question tiles, or all tiles?
**Context**: CLUE's Question tile is purpose-built for this report. Initially resolved as additive, then briefly reopened when the intent was described as Question tiles rather than making old documents line up like questions.
**Options considered**:
- A) Question tiles only.
- B) All tiles, additive.

**Decision** (Leslie Bondaryk, 2026-07-21): **all tiles, additive.** *"I think you should add all tiles, ones with text should show text others can be seen on a link."* Both tracks ship. The "don't line up like questions" concern is satisfied by the Track B layout decision below, which aggregates rather than aligning per tile.

---

### What is the source of the fixed prompt text for a Question tile's column header?
**Context**: `QUESTION_ANSWERS_CHANGE` has never carried the prompt or a title; the fixed-position prompt tile is excluded at emission. Student documents are seeded by silent snapshot load rather than logged tile copies, so the prompt cannot be reconstructed from create/copy events either. Confirmed empirically: zero production events contain a `prompt` field anywhere in `parameters`.
**Options considered**:
- A) Log reconstruction from create/copy events. Dead: silent seeding means those events are absent from student partitions.
- B) Curriculum lookup by `questionId`. Dead: authored curriculum is mutable, so a lookup returns the *current* prompt, not the point-in-time prompt the student saw.
- C) Read document state at `documentHistoryId`. Sound but out of scope, since it breaks the log-only architecture.
- D) CLUE-side enrichment of the event. Sound and point-in-time correct, new logs only.
- E) Label by raw `questionId`, or by a generic "Question N" ordinal.

**Decision** (Doug Martin, 2026-07-21, with product confirmation from Leslie Bondaryk): **D + E.** Request the CLUE-side enrichment for go-forward data, and label historical columns by the **raw `questionId`**, chosen over an ordinal because the raw id is globally stable and matches the aggregation key whereas an ordinal can renumber between runs. The report prefers the enriched prompt when present and degrades to the id when absent.

---

### How is no-double-counting enforced between the two tracks?
**Context**: A tile inside a Question tile fires both its own `*_TOOL_CHANGE` and the `QUESTION_ANSWERS_CHANGE` that Track A reads, so without a filter it appears twice. Verified necessary rather than defensive: 140 events in a 12-day window carry a non-empty `containerIds`.
**Options considered**:
- A1) Track B drops any tile-change event with a non-empty `containerIds`. No join, trivial SQL. Assumes Question stays the only container tile type.
- A2) Drop tiles whose `containerIds` intersect the set of `QUESTION_ANSWERS_CHANGE.tileId` values. Future-proof against new container types, at the cost of a join.
- B) Drop tileIds appearing as `answerTiles[].tileId`.
- C) Accept overlap and dedup downstream.

**Decision** (Doug Martin, 2026-07-21): **A1**, with a code comment recording the "Question is the only container tile type" assumption so it is revisited if CLUE adds another.

---

### How should free-standing tiles be laid out as columns?
**Context**: The stated product preference was one "document" column for tiles not in a question, with per-tile columns acceptable if that proved too hard.
**Decision** (Doug Martin, 2026-07-21): **a three-way split.** Free-standing text tiles keep their own per-title columns exactly as today; Question tiles get their own columns listing contained tiles as content; all other free-standing tiles aggregate into a **single** `Other tiles` column, each shown as type plus history link. This keeps text behavior stable and avoids mixing text bodies with non-text type/links in one cell.

---

### What is the source of the real CLUE activity name?
**Context**: The name is only a per-resource label column, and the activity is already identified by `res_N_resource_url`. So the requirement is "stop emitting the misleading placeholder", not "build a real name".
**Options considered**:
- A) Derive from the runnable URL's raw `unit` + `problem` values.
- B) URL-derived plus a unit-code to friendly-title lookup. Rejected: requires replicating CLUE's mutable, branch-dependent curriculum-config resolution.
- C) Reuse the runnable URL as the name.

**Decision** (Doug Martin, 2026-07-21): **A, raw URL values only**, with no lookup table, falling back to the unit alone and then to a bare `"CLUE"`. *(In production this produced very wide names when `unit` is itself a URL; filed as REPORT-98.)*

---

### Does "the type will be documented" require rendering non-text tile content?
**Decision**: **No.** Surfacing the tile type plus a history link satisfies it. Non-text tile state lives only in Firestore, which this pipeline does not read.

---

### `questionId` to column key: hex encode with a `q` prefix (D1)
**Context**: The key must be alias-safe, collision-free, and a deterministic function of `questionId` (the last for cross-report column-order stability).
**Options considered**:
- A) `make_safe_id/1`, as the text path uses. Rejected: lossy, folds case and `-`/`_`, so distinct ids could merge silently.
- B) Run-local surrogates (`q1`, `q2`). Rejected: breaks cross-report ordering.
- C) `"q" <> Base.encode16(id, case: :lower)`.

**Decision**: **C.** Satisfies all three constraints at once, and reversibility is a free debugging bonus. Doubling key length is acceptable.

---

### One Athena query with `UNION ALL` over one shared base CTE (D2)
**Context**: Three tracks must be combined, and the learner predicates are large embedded literal lists.
**Decision**: A single query with a `track` discriminator, keeping one query and poll cycle rather than paying Athena startup latency three times. The learner predicates live in **one** `clue_logs` base CTE rather than per track: repeating them triples the literal lists and the report has no learner cap, and measured against the 262,144-byte DML quota a per-track shape fails at ~628 learners against ~1,883 for the shared CTE. This is a query-text fix only and does **not** reduce scans, since Trino inlines CTEs; describing it as a scan reduction would make the year floor look optional again.

---

### Flatten the answers payload in Elixir, not in SQL (D3)
**Options considered**:
- A) SQL-side `CAST(... AS ARRAY(ROW(...)))` with a double `UNNEST`. Verified working.
- B) Select the whole `$.answers` value and flatten with `Jason` in `clue.ex`.

**Decision**: **B.** The single-value-per-key constraint already forces Elixir-side aggregation, so SQL-side flattening would only have to be re-grouped anyway, and it would hardcode the payload shape into SQL where a CLUE change could break it silently. The selected expression is `json_format(json_extract(...))` rather than bare `json_extract`, because the union with the varchar tracks fails on a type mismatch otherwise.

---

### Tile type labels from a known-casing map with a title-case fallback (D4)
**Context**: Tile-change events carry no type field, so the label exists only in the event name. Derivation must be the primary mechanism so new logging types get a correct label with no code change.
**Decision**: Derive by stripping the suffix and title-casing, with an override table for three genuine exceptions: compound names (`BARGRAPH` to `BarGraph`), acronyms (`AI`, which derives to `Ai`), and one **retired** name whose derivation is valid but wrong (`GRAPH` to `Geometry`). An unrecognized event must always fall through and appear, never be dropped and never raise.

---

### Empty answers are suppressed before they reach parquet (D5)
**Decision**: Drop `Placeholder` entries; drop Text entries whose `plainText` is nil, empty or whitespace; if the surviving list is empty emit **no answer row** rather than `[]`. Critically, the structure entry is added only on the first row that yields a *surviving* entry, never on the first row seen: the natural code shape adds it unconditionally and first, which would leave a question with no real answers counting toward `num_questions` for every learner in the report.

---

### `other_tiles` is prepended after the sort (D6)
**Decision**: The prepend must happen in the post-reduce step alongside `Enum.sort`, not inside the reduce, or the sort carries `other_tiles` into alphabetical position and it lands mid-table instead of rightmost. It enters `questions` inside the reduce but `question_order` only at the prepend; doing both duplicates the key and emits the column twice.

---

### All three CTEs move onto `logs_by_app_and_secure_key`, with a required year floor (D7)
**Context**: The original query read an unpartitioned table with no time bound, so every CLUE report already ran an unbounded full-table scan.
**Decision**: Move to the partition-projected table, which prunes to the report's own learners before any row filter. Measured: the full three-track predicate over all history for 40 learners scans **0.67 MB**, against ~24 GB for the unbounded scan the code actually ran. Row-equivalence was checked rather than assumed, since the two tables are physically distinct copies: 11,315,457 rows against 11,315,463, a 6-row difference in 11.3 million with identical backfill depth. The year floor is **required rather than an optional trim**, because prefix-enumeration wall time scales with learner count: an unbounded 1,000-learner report spends about nine minutes listing S3 prefixes while scanning under a megabyte. The floor derives from the learners' own `created_at` less a year, so it cannot undermine historical coverage.

---

### Cells render as a JSON array, not a delimited string
**Context**: A multi-tile question and the `other_tiles` column both need variable-length cells.
**Decision** (Doug Martin, 2026-07-21): a **JSON array** of `{type, text?, link, documentKey, documentType}` entries, chosen over a delimiter-joined human string specifically for machine parseability, since cc-data loads these CSVs and queries them with SQL, and any separator can collide with student text. `link` is carried **per entry** in both tracks (Track A repeats the question's single link) so cc-data has exactly one parsing pattern. `documentKey` and `documentType` were added 2026-08-04 because both tracks aggregate across a learner's documents, making a cell without them ambiguous; `documentTitle` is deliberately omitted as user-editable and therefore not a stable identifier.

---

### Entry order inside a cell is part of the contract
**Context**: Left unpinned, order is nondeterministic: the query has no `ORDER BY` and the reduce prepends. Two runs over unchanged data would differ, which matters because diffing report runs is how a researcher finds what actually changed.
**Decision**: Track A uses document order as tiles appear in the payload, and across payloads orders by `documentKey` ascending via a **stable** sort immediately before encoding. Track B sorts by `type` then `link`. Both sort Elixir-side rather than via SQL, since the reduce must preserve order regardless. Ordering by tile `time` was considered and rejected: more meaningful to a reader, but it re-shuffles the cell whenever a student edits one tile, reintroducing exactly the diff noise this rule removes.

---

### Column order is alphabetical on the stable key, not by event time
**Context**: A report's `question_order` is scoped to the learners in that report, so any time-based order would be computed over a different cohort each time and the same authored question would land in different positions for different classes.
**Decision** (Doug Martin, 2026-07-21): keep the sort on the stable key, which nets out to reverse-alphabetical after the downstream unconditional reverse. Globally stable across classes and reports, though non-semantic. This holds **only** if the key is a deterministic function of `questionId`, which is why run-local surrogates were rejected in D1.

---

### Track A must partition per learner document, not by `questionId` alone
**Context**: The existing text query groups by `toolId`, which is safe only because `toolId` is a globally unique nanoid. `questionId` is the exact opposite: it is deliberately shared across every student's copy, which is the whole AC1 mechanism. Measured: 130 of 193 production ids are shared by more than one learner, with a maximum of 33 learners on one id.
**Decision**: Use `ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, documentKey, questionId ORDER BY time DESC)`. Without the learner key, one arbitrary student's answer would fill a column meant to hold all students'. `documentKey` was added later for the mirror case, one learner holding one id in two documents, measured at 15 of 1,220 pairs.

---

### Track B applies no `operation` filter
**Context**: The existing text path filters `operation = 'update'`, and mirroring it for symmetry is the tempting default. Measurement showed `operation` is a per-tile-type vocabulary rather than a CRUD set: Drawing never logs `update` at all.
**Decision** (Doug Martin, 2026-08-04): **no `operation` filter.** The symmetric filter would silently erase every free-standing Drawing tile and every Table tile whose only event is a `create`. The residual stale-tile risk is accepted and is not addressable through `operation` anyway, since there is no cross-type "tile was deleted" signal.

---

### A missing `containerIds` must be treated as free-standing
**Context**: An early measurement found `containerIds` present on all 21,146 sampled events and concluded no null handling was needed. That measurement was correct and its conclusion wrong: the window sampled was in 2026, and `containerIds` logging began 2025-05-07. Roughly 83% of the CLUE log history predates it.
**Decision**: `COALESCE(json_format(json_extract(parameters,'$.containerIds')), '[]') = '[]'`. Treating an absent key as free-standing is *correct* rather than lenient, because no container tile type existed before 2025-03-20. Without it Track B returns nothing for every pre-2025 class, and the failure is asymmetric in the way that hides it: the free-standing text columns keep working, so only the new column is empty.

---

### Track B gates structurally on `documentKey`, not by event name
**Context**: `IFRAME_INTERACTIVE_TOOL_CHANGE` logs via bare `Logger.log`, bypassing the enrichment path, so on 100% of its events it carries no `toolId`, `documentKey` or `containerIds`.
**Decision** (Doug Martin, 2026-08-04): require a non-null `documentKey` and use `COALESCE(toolId, tileId)` as tile identity. This excludes IframeInteractive today and re-includes it automatically if CLUE routes the logging through `logTileChangeEvent`, so the pattern-discovery requirement still holds. Gating by event name would have hardcoded exactly what BR4 forbids.

---

### The stored prompt is upgraded, not write-once
**Context**: A question has one structure entry but many contributing rows, one per learner. Once the CLUE enrichment ships those rows disagree permanently, since a learner whose latest answer predates the deploy carries no prompt forever. A write-once entry would take whichever row Athena delivered first, so the header could differ between two runs over unchanged data.
**Decision**: When a row carries a non-empty prompt and the stored prompt is still the `questionId` fallback, replace it. The header is then the enriched prompt if **any** contributing row has one. Without this the enrichment would appear per question at random, reading as a CLUE-side bug rather than a report-service one.

---

### `other_tiles` is a reserved key
**Context**: Track A keys, Track B's synthetic key and Track C's `make_safe_id(tile_title)` all share one flat namespace, and `make_safe_id` is lossy: `"Other Tiles"`, `"other tiles"`, `"other-tiles"` and `"OTHER_TILES"` all map to exactly `other_tiles`.
**Decision**: Treat `other_tiles` as reserved and disambiguate the colliding text key. Two silent failures would otherwise coincide: the wrong type wins the structure entry so the array cell reads as null, and both tracks write under one key, hitting the silent `map_agg` drop. This does not breach the no-regression guarantee, because the colliding case is broken today rather than working.

---

### The testability seam lands before the track work, not after
**Context**: An earlier sequencing put the seam after the track steps while also saying tests would grow alongside them. Those are incompatible: nothing on the path is reachable from a test until the seam exists, so every answer-row assertion is unobservable.
**Decision**: Move the seam to step 2, ahead of the track work. It changes module boundaries rather than logic, so it moves at no cost. The named risk was that under time pressure the structure-only assertions get written and the answer-row assertions get dropped.

---

### Track C moves to the same `ROW_NUMBER` window as the other tracks
**Context**: Track C kept the existing `MAX(time)` self-join, which references the relation twice, so the query shape inlined four times rather than three and every wall-time figure understated by a third.
**Decision**: Move Track C to the window too. It removes a scan, retires the duplicate-`time` tie risk at the source rather than depending on a downstream collapse, and leaves all three tracks one shape. It does not breach the no-regression guarantee, whose subject is emitted columns and rows: after aggregation the rows are identical, since the only difference is tie duplicates that were already being discarded.

---

### The `"first"` history-id sentinel is treated as absent
**Context**: CLUE emits the literal `"first"` when a document has no history entry yet, 3.5% of events. Tracing the consumer showed nothing resolves it as a sentinel: the lookup fails, no navigation happens, but the playback UI has already been switched on, so the view appears positioned and is not.
**Decision**: Omit the history parameter when the value is `"first"`, so the document opens honestly rather than at a false position. The report cannot do better, since the true first entry's id is not in the log. This is a **live defect fix** rather than something this story introduced, since the existing text links pass the sentinel through identically. The better fix is CLUE-side.

---

### Wildcard JSON paths cannot be used
**Context**: A review round correctly identified that the answers payload is nested and prescribed `$.answers[*].answerTiles[*].type` as the correct path. Athena engine v3 rejects it outright with `INVALID_FUNCTION_ARGUMENT: Invalid JSON path`. Nothing in the codebase demonstrated the limit, because the existing query only ever used indexed access.
**Decision**: Do not use wildcard path syntax anywhere. Select the whole `$.answers` value and flatten in Elixir.

---

### The `LIKE ... ESCAPE` form cannot survive the SQL heredoc
**Context**: The pinned `LIKE '%\_TOOL\_CHANGE' ESCAPE '\'` emits `LIKE '%_TOOL_CHANGE' ESCAPE ''` from an Elixir heredoc, with no compiler warning. Two independent corruptions: the underscores become wildcards, and the escape string becomes empty. The empty escape fails loudly, but the obvious way to clear that error is to delete the `ESCAPE` clause, which compiles, runs, and quietly changes the predicate's meaning.
**Decision**: Use `regexp_like(event, '_TOOL_CHANGE$')`, which contains nothing either Elixir or SQL needs escaped. Confirmed equivalent to the intended `LIKE` against the real event vocabulary.

---

### Ship the six covered tile types; the coverage gap is accepted
**Context**: The requirement said "all non-text tiles", but only some tile types emit a change event at all. Measured by distinct tile, types with no event account for 263 of 2,143 in-question answer tiles (12%). The free-standing loss is unmeasurable by construction.
**Decision** (Doug Martin, 2026-08-01): ship what logs, record the gap, do not block. The deciding constraint is that the report must work on logs already written: no amount of new CLUE logging retrofits events into historical partitions. "Add all tiles" therefore ships as "all tiles that logged anything", growing on its own as CLUE adds logging.

---

### The synthetic `other_tiles` column counts toward completion totals
**Context**: Adding it to the `questions` map makes it count as one question and one answer.
**Options considered**:
- A) Exclude `clue_tile` from the counters.
- B) Accept the approximation.

**Decision**: **B.** Exclusion is impossible CLUE-locally, because the shared query derives both column emission and counting from the same structures, so any exclusion edits the query used by all AP/LARA answers and usage reports. Blast radius is not justified for a metric that is already approximate: the CLUE structure is discovered from the union of learners' answers, so every answer column already approximates completion, and this is one incremental column rather than a new class of distortion.

---

### The parquet writer splits by offering as well as username
**Context**: Found during implementation. The writer took `resource_link_id` from the first of a username's answer rows and wrote one file per username. A student enrolled in two classes that both assign the runnable shares one username across two offerings, and the path encodes the offering, so both offerings' answers filed under whichever row came first, attributing one class's work to the other.
**Decision**: Group a username's rows by `resource_link_id` and write one file per pair. The rows always carried the right value; only the file they landed in was wrong. Pre-existing rather than introduced by this story.
