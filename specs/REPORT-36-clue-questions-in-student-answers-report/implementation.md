# CLUE Questions in Student Answers Report: Implementation

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-36
**Requirements**: [requirements.md](./requirements.md)
**Status**: **Draft**

## Scope

Implements Track A (Question tiles, keyed by `questionId`) and Track B (free-standing tiles) in the CLUE branch of the Student Answers report. Everything here is constrained by the requirements doc; where requirements left a choice open, this document **pins** it. Requirement ids (`QR*`, `BR*`, `DR*`, `XR*`) and verification findings (`VR1`-`VR10`) are referenced rather than restated.

The architecture is unchanged: read the Athena **log** DB, write CLUE answers as parquet into the existing `partitioned-answers/…` layout, let the shared report SQL render them. No Firestore, no document-state reads (XR5).

## Decisions pinned here

### D1: `questionId` -> column key is a lowercase hex encode with a `q` prefix

```elixir
def question_key(question_id), do: "q" <> Base.encode16(question_id, case: :lower)
```

Public rather than private (2026-08-04, during implementation): sequencing step 3 calls for unit tests, and a `defp` is unreachable from one. It also has to be reachable in the step that introduces it, before Track A calls it, or the compiler flags it as unused under `--warnings-as-errors`. The same applies to `tile_type_from_event/1` in D4.

`"9HzYd-"` -> `q39487a59642d` -> column `res_1_q39487a59642d_json`.

Satisfies all three constraints simultaneously: alias-safe (leading letter, only `[a-z0-9]`, verified necessary by VR7 since `res_1_9HzYd-_json` is a Presto syntax error), collision-free (hex is injective, so the `make_safe_id` folding risk cannot occur even as the corpus grows past today's 193 ids), and a **deterministic function of `questionId`** as Round 3 requires for cross-report column-order stability. Reversibility is a free bonus for debugging: `Base.decode16!(key, case: :lower)` recovers the raw id.

**Do not** use `make_safe_id/1` for Track A (lossy, folds case and `-`/`_`), and **do not** assign run-local surrogates like `q1`, `q2` (breaks cross-report ordering, explicitly rejected by Round 3).

Doubling the key length is acceptable: 6-char ids become 13-char keys, so `res_1_<key>_json` stays around 25 characters.

### D2: one Athena query with `UNION ALL`, over one shared base CTE

Track A and Track B are computed as separate CTEs and combined with `UNION ALL` under a `track` discriminator column, so `fetch_resource/3` keeps a **single** `AthenaDB.query` + `AthenaQueryPoller.wait_for` cycle and a single CSV parse. Two sequential queries would double per-runnable Athena startup latency for no benefit, and this path already runs once per CLUE runnable during resource fetch.

The two selects have different natural columns, so the union pads: columns absent for a track are selected as `CAST(NULL AS VARCHAR)`. See the row contract in "Query" below.

**The learner predicates live in one `clue_logs` base CTE, not repeated per track (VR16).** All three tracks share the same `app`, `secure_key`, `run_remote_endpoint` and year-floor predicates, and only their event predicate differs. Writing those per-track triples the two large embedded literal lists, and the report has no learner cap: measured against AWS's documented 262,144-byte DML query-string quota, a per-track shape exceeds it at about **628 learners** against today's ~1,311, while hoisting them into one base CTE reaches about 1,883. That matters because `group_learners_by_runnable_url` puts every learner sharing a runnable URL into one `fetch_resource/3` call, and a CLUE problem URL such as `?unit=m2s&problem=4.5` is the same URL for every class that assigns it, so cohort- and project-scoped reports aggregate across classes. Exceeding the quota is a hard Athena error, not a degradation.

```sql
WITH clue_logs AS (
  SELECT username, event, time, parameters, run_remote_endpoint
  FROM "#{log_db_name}"."logs_by_app_and_secure_key" log
  WHERE log.app = 'CLUE'
    AND log.year >= #{year_floor}                     -- D7
    AND log.secure_key IN #{...}
    AND log.run_remote_endpoint IN #{...}
    AND (log.event = 'QUESTION_ANSWERS_CHANGE' OR regexp_like(log.event, '_TOOL_CHANGE$'))
),
track_a AS (SELECT … FROM clue_logs WHERE …),
track_b AS (SELECT … FROM clue_logs WHERE …),
track_c AS (SELECT … FROM clue_logs WHERE …)
SELECT … FROM track_a UNION ALL SELECT … FROM track_b UNION ALL SELECT … FROM track_c
```

**This is a fix for the query-text ceiling only, and does not reduce the number of table scans.** Trino inlines CTEs rather than materializing them, so `clue_logs` is expanded at each of its three references and the table is still scanned three times. That is fine once D7's year floor is in place (see the D7 wall-time table); a genuinely single-scan shape would mean computing all three tracks' `ROW_NUMBER` windows over one relation and selecting per track, which is possible but not worth the complexity here. Do not describe the base CTE as a scan reduction, or the year floor will look optional again.

Also `Enum.uniq()` the endpoint list before building either list. `clue.ex:29` omits it today; `report_query.ex:104` has it.

### D3: flatten `answers` in Elixir, not in SQL

Per VR1, `$.answers[*].answerTiles[*]` does not run on Athena engine v3. The query selects the whole `$.answers` value as one string column and `clue.ex` decodes it with `Jason` and flattens across groups.

**The selected expression is `json_format(json_extract(parameters,'$.answers'))`, not bare `json_extract` (VR17).** `json_extract` returns Trino type `json`, while Track C's `json_extract_scalar` returns `varchar`, and Trino does not implicitly coerce `json` to `varchar` in a `UNION`. Confirmed live, 0 bytes scanned: the union fails with `TYPE_MISMATCH: column 1 in UNION query has incompatible types: json, varchar`, and the same query with `json_format` wrapped around the Track A value succeeds and returns the nested payload intact. VR1 verified `json_extract(parameters,'$.answers')` in isolation against a literal, never inside a union with the varchar tracks, which is why this was invisible until now. For the same reason every `NULL`-padded column in the union is written `CAST(NULL AS VARCHAR)` rather than bare `NULL`, so no column's type depends on which branch happens to supply a concrete value. The SQL-side `CAST(... AS ARRAY(ROW(...)))` + double `UNNEST` alternative is verified working but rejected here: the single-value-per-key constraint already forces Elixir-side aggregation, so SQL-side flattening would just have to be re-grouped in Elixir anyway, and it hardcodes the payload shape into the SQL where a CLUE change would break it silently.

### D4: tile type labels come from a known-casing map with a title-case fallback

Required by BR4, because tile-change events carry no type field (VR10) and the set of logging types is expected to grow (DR3).

Derivation is the primary mechanism and the override table holds only genuine exceptions:

```elixir
## Derivation handles everything except three shapes. Two are cases the uppercased
## event name has flattened beyond recovery: compound names (CLUE registers
## "BarGraph", the event says BARGRAPH) and acronyms (registered "AI", derivation
## yields "Ai"). The third is a RETIRED event name whose derivation is a valid but
## wrong label: GRAPH_TOOL_CHANGE is the Geometry tile's old event name, renamed to
## GEOMETRY_TOOL_CHANGE on 2024-02-14 (collaborative-learning 310b03c8b), so every
## GRAPH_TOOL_CHANGE event in the logs is a Geometry tile. Deriving "Graph" would
## label it as a different, real, current tile type (src/plugins/graph).
## Watch items: WaveRunner derives correctly from WAVE_RUNNER_TOOL_CHANGE but not
## from WAVERUNNER_TOOL_CHANGE, so it needs an entry only if CLUE names it that way;
## and if the modern Graph tile ever starts logging it would reuse the retired name,
## at which point this entry needs revisiting.
@tile_type_overrides %{"BARGRAPH" => "BarGraph", "AI" => "AI", "GRAPH" => "Geometry"}

def tile_type_from_event(event) do
  stem = String.replace_suffix(event, "_TOOL_CHANGE", "")
  Map.get_lazy(@tile_type_overrides, stem, fn ->
    stem |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end)
end
```

Verified 2026-08-04 by running the function above against **every** registered CLUE tile-type string, not a sample. Of today's seven logging types it reproduces **six** exactly (`Geometry`, `Drawing`, `Table`, `Text`, `Dataflow`, and `IFRAME_INTERACTIVE` -> `IframeInteractive`), missing only `BARGRAPH` -> `Bargraph`. Across the full registered list it also gets `DATA_CARD` -> `DataCard`, `NUMBERLINE` -> `Numberline`, `IMAGE` -> `Image`, `SIMULATOR` -> `Simulator`, `TIMELINE` -> `Timeline`, `DIAGRAM` -> `Diagram`, `EXPRESSION` -> `Expression` and `WAVE_RUNNER` -> `WaveRunner`. (`GRAPH` -> `Graph` was listed here as a correct derivation; per VR23 it is the one case where deriving the *registered* name is wrong, because the event belongs to the Geometry tile, so it is now an override.)

The full sweep found one miss the earlier sample hid: **`AI_TOOL_CHANGE` derives to `Ai` against a registered `AI`** (`ai-types.ts:1`). That is not a speculative type. VR2 measured **97 entries across 11 distinct AI answer tiles** in production, so it is in active classroom use and a plausible near-term DR3 candidate, and when it starts logging, the same tile would read `AI` in a Track A cell and `Ai` in a Track B cell, silently. Hence the second override entry.

**Event names are not stable over time, which is a third override case the earlier drafts had no concept of (VR23).** Measured against production: `GRAPH_TOOL_CHANGE` accounts for **1,270,737 events across 2019-2024** and stops there, while `GEOMETRY_TOOL_CHANGE` starts in 2024 and continues. `310b03c8b` (2024-02-14) is the rename, one line in `logger-types.ts`. So the derivation's `"Graph"` is not a harmless cosmetic miss like `"Bargraph"`: it labels 1.27M historical Geometry tiles as `Graph`, which is the registered name of a **different, real, current** tile type (`src/plugins/graph/graph-types.ts:6`), one that emits no change event at all (VR2). A researcher comparing a 2022 cohort with a 2025 cohort would see the same tile type under two names, one of which belongs to something else. Hence the third entry. `BARGRAPH` is unaffected, since its stem is `BARGRAPH` rather than `GRAPH`.

This matters because it makes adaptivity the default rather than something maintained. A new logging tile type gets a correct label with **no code change at all**, and the override map only grows for compound names. Casing consistency with Track A is the point: Track A takes `type` verbatim from the payload as the registered string, so a Track B label of `"Bargraph"` would render the same tile type two ways in the JSON cells that cc-data queries. An unrecognized event must always fall through and appear, never be dropped and never raise.

### D5: empty answers are suppressed before they reach parquet (QR6)

Applied in this order when building a Track A question's entry list:

1. Drop any answer tile whose `type` is `"Placeholder"` (147 distinct tiles across 81 documents in production).
2. For `Text` tiles, drop the entry when `plainText` is nil, `""`, or trims to `""` (44% of Text entries).
3. If the surviving list is **empty**, emit **no answer row** for that (student, question), and do not count it. Do not emit `[]`.

Rule 3 is what keeps `num_answers` honest: an emitted row counts as an answer in the shared completion counters (XR6) whether or not it has content.

Note rules 1-2 apply to *entries*; a question keeps its column as long as any learner in the report contributes a surviving entry, since the structure is a union across learners.

**Rule 4 (sequencing, load-bearing): the structure entry is added only on the first row that yields a surviving entry, never on the first row seen.** This is the same trap shape as VR9: the plan states the end state, and the natural place to write the code produces a different one, silently.

Today's reduce adds the structure entry **unconditionally and first** (`clue.ex:121-137`, `new_question = not Map.has_key?(...)` then `Map.put`), and only afterwards builds the answer in a `with` whose `else -> row_acc.answers` drops it (`:147-178`). An implementer extending that shape in place inherits the wrong order for free, and rules 1-3 then buy nothing: a question whose answer tiles are all `Placeholder` or empty text still lands in `structure.questions`, `shared_queries.ex:93` counts it via `cardinality(questions)`, and it becomes a question **for every learner in the report** while contributing an answer to none, inflating the `percent_complete` denominator for the whole class. That is exactly the distortion QR6 and the sharpened XR6 exist to remove, and per VR5 (44% of Text entries empty, 208 `Placeholder` entries) questions that reduce to nothing for *every* learner are likely, not rare.

So the drop rules must run **before** the structure update, and the "any learner" scope means the decision is per row-with-survivors rather than per row: the entry is added the first time some learner contributes a survivor, and never at all if none does. The same applies to `other_tiles`, which the structure contract already implies with "present whenever any learner has >= 1 non-text free-standing tile."

Note that the entry is created once but its `prompt` is **not** write-once: per VR18 (see the Structure section) a later row carrying a non-empty `$.prompt` upgrades a stored `questionId` fallback. "Added on the first row with a survivor" governs *existence*, not the field values.

### D6: `other_tiles` is prepended **after** the sort

Per VR9. The prepend must happen in the post-reduce step alongside `Enum.sort`, not inside the reduce where the other structure keys accumulate, or the sort carries `other_tiles` into alphabetical position and it lands mid-table.

```elixir
result = Map.update!(result, :structure, fn structure ->
  sorted = Enum.sort(structure.question_order)
  order = if has_other_tiles?, do: ["other_tiles" | sorted], else: sorted
  Map.put(structure, :question_order, order)
end)
```

`ResourceData`'s unconditional `Enum.reverse` (`resource_data.ex:149`) then makes it rightmost. No `resource_data.ex` change.

**`other_tiles` goes into `questions` inside the reduce but into `question_order` only here (VR19).** `has_other_tiles?` is therefore `Map.has_key?(structure.questions, "other_tiles")`, and the reduce must **not** also push the key onto `question_order`. The structure contract's "a column exists only if the key is in both" invites adding it to both in the reduce, and combined with this unconditional prepend that duplicates the key. `question_order` is iterated directly to build columns, so the report then emits `res_1_other_tiles_json` **twice**: verified by running the real column builder over `["other_tiles", "abc_text", "other_tiles"]`. Not an error, just a silently duplicated column in a researcher-facing CSV. Same trap family as VR9 and D5 rule 4: two individually correct rules that conflict where they meet.

### D7: all three CTEs move off `logs_by_time` onto `logs_by_app_and_secure_key`

Today's query reads `"#{log_db_name}"."logs_by_time"` with **no predicate on `time`** (`clue.ex:42-72`), and `logs_by_time` has **no partitions at all**. So every CLUE report already runs an unbounded full-table scan, and Track B's ~20x wider event predicate would multiply it. This is table selection, not tuning, and it is the single largest cost item in the story.

`server/README.md:210-253` documents `logs_by_app_and_secure_key`, partition-projected on `app/year/month/secure_key` with `secure_key` as an **injected** projection, and `report_query.ex:100-121` already uses it for exactly CLUE's access pattern: it derives secure keys from the same `run_remote_endpoint` list `clue.ex` builds (`run_remote_endpoint |> String.split("/") |> List.last()`) and filters `log.secure_key IN (...)`. Because `secure_key` is injected, the predicate prunes to this report's learners' S3 prefixes **before** any row filter runs, which is why the event predicate's width stops mattering.

```
FROM "#{log_db_name}"."logs_by_app_and_secure_key" log
WHERE log.app = 'CLUE'
  AND log.year >= #{year_floor}           -- required, see the residual below
  AND log.secure_key IN #{ReportUtils.string_list_to_single_quoted_in(secure_keys)}
  AND log.run_remote_endpoint IN #{...}   -- kept as the correctness filter
```

These predicates appear **once**, in D2's `clue_logs` base CTE, not once per track.

Keep `run_remote_endpoint IN (...)`: `secure_key` is the pruning key, not a substitute for the exact learner match. The DDL carries every column this path needs (`username`, `event`, `time`, `parameters`, `run_remote_endpoint`, and an `id` the current query does not select).

**Measured 2026-08-04 (VR12):** the full three-track predicate (`QUESTION_ANSWERS_CHANGE` plus every `*_TOOL_CHANGE`), over **all history with no time bound**, for 40 real CLUE learners, scanned **0.67 MB**. Against VR8's *windowed* 489 MB and the 24 GB an unbounded `logs_by_time` scan has actually cost, this retires the performance risk outright: **VR8's "Track B's broadening is the cost centre" is an artifact of the table, not of the event filter.** Track B costs nothing measurable once the scan is pruned to the report's own learners.

**Row-equivalence confirmed (VR14).** The two tables are physically distinct copies (different Glue `LOCATION`s), so the swap was checked rather than assumed: every CLUE row in both, by year, came to **11,315,457** in `logs_by_app` against **11,315,463** in `logs_by_time`, a 6-row difference in 11.3 million, with identical backfill depth to 2018. The only residual is a handful of current-year rows not yet propagated into the derived copy, immaterial for a report over completed classwork.

One residual, and it is **required work, not an optional trim (VR16)**: because `secure_key` is injected and `year`/`month` are projected over 2014-2050, omitting a year bound makes Athena enumerate `37 x 12 x N_learners` S3 prefixes, which costs **wall time, not bytes** (bytes are identical either way). VR12's own two timings, 24.2 s unbounded against 17.5 s with `year >= 2025` at 40 learners, fit a 17.1 s fixed cost plus 0.399 ms per prefix to within 0.1 s on both points, and the prefix term is the one that scales with the report:

| learners | unbounded, 1 scan | unbounded, 3 scans | 2-year floor, 3 scans |
|---:|---:|---:|---:|
| 40 | 24 s (= VR12) | 38 s | 18 s |
| 300 | 70 s | 176 s | 26 s |
| 600 | 123 s | 336 s | 34 s |
| 1000 | 194 s | 548 s | 46 s |

The three-scan column is the shipping shape, since Trino inlines D2's `clue_logs` CTE at each of its references and there are three of them, one per track. That holds **only** with Track C on a `ROW_NUMBER` window: its old `MAX(time)` self-join references the relation twice, making four inlinings and adding a third to every figure in that column (VR22). So an unbounded 1,000-learner CLUE report spends roughly nine minutes listing S3 prefixes per runnable, inside `fetch_resource/3`, on a query that scans well under a megabyte. With the floor the same report costs about 46 s and the scan multiplication stops mattering, which is why the floor is the lever and the CTE shape is not.

**Deriving the floor needs no new data and no learner date range.** The learner maps already in `clue.ex`'s hands carry `created_at` and `last_run` (`learner_data.ex:186,188`), and a learner cannot log before their learner record exists, so `year(min(created_at)) - 1` is a sound floor. The one-year slack covers both clock skew and the year-attribution drift VR14 observed (the `year` partition is ingester-assigned and disagreed with `year(from_unixtime(time))` on 106 rows at the 2023/2024 boundary).

Because the floor is derived from **this report's own learners**, it cannot undermine XR5: a report over a 2019 class yields a 2018 floor and keeps that class's full history in scope. It prunes years no learner in the report could have logged in, which is what makes it free. Emit `log.year >= <floor>` in the base CTE. Add `log.year <= year(max(last_run)) + 1` only if measurement later shows the upper half is worth it; the lower bound is where all of the 35-of-37-years saving is.

## Changes by file

### `server/lib/report_server/clue.ex` (primary, no shared blast radius)

**Query** (`get_text_tile_answer_sql/1`, currently `:39-73`). Rename to reflect its widened role and restructure into a `clue_logs` base CTE plus three track CTEs unioned into one result set (D2). The base CTE reads `logs_by_app_and_secure_key`, **not** `logs_by_time`, and carries the `app` + year-floor + `secure_key` + `run_remote_endpoint` prune once for all three tracks (D7); the track CTEs select from it and differ only in their event predicate and their window.

*Track A CTE.* Filter `event = 'QUESTION_ANSWERS_CHANGE'`, `run_remote_endpoint IN (…)`. Select the latest event per learner **per question** with

```sql
ROW_NUMBER() OVER (
  PARTITION BY run_remote_endpoint,
               json_extract_scalar(parameters,'$.documentKey'),
               json_extract_scalar(parameters,'$.questionId')
  ORDER BY time DESC) AS rn
```

and keep `rn = 1`. Partitioning on `run_remote_endpoint` is mandatory (VR4 measured up to **33 learners sharing one `questionId`**; `MAX(time) GROUP BY questionId` would keep one and silently drop 32).

**`documentKey` is mandatory too, for the mirror-image reason (VR13).** An across-document copy preserves `questionId` (`question-utils.ts:33-39`, wired at `question-registration.ts:19`, called from `document-content.ts:399-400`), so one learner can hold the same `questionId` in two documents (copying a Question tile into a learning log, or copying a whole document). `getQuestionAnswersAsJSON` scopes each payload to a single document (`question-utils.ts:52-53`), so neither event carries the other's answers, and partitioning on `run_remote_endpoint, questionId` alone would keep the globally-latest document and silently drop the rest. Measured across the full production corpus: **14 learner/question pairs span 2 documents and 1 spans 3**, of 1,220 total, so the naive partition loses 16 documents' worth of answers, exactly the "copies must not drop an answer" case QR2 names. Adding `documentKey` costs nothing downstream: it yields more than one row per `{username, question_key}`, which D3's Elixir reduce already merges into one entry list, and each entry already carries its own `link` per the cell contract.

The window also resolves the real duplicate-timestamp rows observed in production (VR3). Do **not** apply an `operation = 'update'` filter: `QUESTION_ANSWERS_CHANGE` has no `operation` field.

Selected columns: `username`, `questionId`, `json_format(json_extract(parameters,'$.answers'))` as a raw JSON string (D3), `documentKey`, `documentType`, `documentHistoryId`.

*Track B CTE.* Match the event by **pattern**, never an `IN (…)` list of event names (BR4), **excluding** `TEXT_TOOL_CHANGE`, plus the XR1 disjointness filter. Carry `event` through so the type label can be derived (D4).

**The pattern is pinned as `regexp_like(log.event, '_TOOL_CHANGE$')`, not `LIKE … ESCAPE` (VR17).** The `LIKE` form earlier drafts pinned, `event LIKE '%\_TOOL\_CHANGE' ESCAPE '\'`, cannot be written into `get_text_tile_answer_sql/1`'s `"""` heredoc as it reads. Elixir emits:

```
AND log.event LIKE '%_TOOL_CHANGE' ESCAPE ''
```

Two independent corruptions, **with no compiler warning**: `\_` loses its backslash, so the underscores revert to single-character `LIKE` wildcards, and `\'` is a valid Elixir escape for `'`, so the escape string becomes empty, which Trino rejects. The empty `ESCAPE` at least fails loudly; the half-fix does not. **Deleting the `ESCAPE` clause to clear that error is not a valid simplification**: it leaves `LIKE '%_TOOL_CHANGE'`, which compiles, runs, and silently means "any character" where the author wrote "underscore" (confirmed live: the corrupted form matches `XTOOLYCHANGE`, which neither the escaped `LIKE` nor `regexp_like` does). `regexp_like` avoids the whole class of problem because its pattern contains no backslashes and no quotes. If `LIKE` is used anyway, the literal must be doubled (`'%\\_TOOL\\_CHANGE' ESCAPE '\\'`) or the heredoc made `~S"""`.

**The disjointness filter must treat a missing `containerIds` as free-standing (VR15), not drop the row:**

```sql
AND COALESCE(json_format(json_extract(parameters,'$.containerIds')), '[]') = '[]'
```

Without the `COALESCE` this is not a defensive nicety, it is a silent XR5 failure over most of the corpus. `containerIds` was introduced by one commit, 2025-05-07, so every earlier tile-change event carries no such key, `json_extract` returns SQL `NULL`, and `NULL = '[]'` evaluates to `NULL`, dropping the row. 83% of CLUE log rows predate 2025 (VR14's by-year counts), so for any report over a class from 2018 through April 2026 Track B would return **nothing** while Track C kept working normally: the report looks healthy and is silently missing its new column. VR3's "present on all 21,146 events, zero absent" is true and misleading, because it sampled a 2026 window and can only see post-release data.

Treating the absent key as free-standing is **correct**, not merely safe. No container tile type existed before the Question tile landed 2025-03-20, so every tile in that history genuinely was free-standing, and the window in which a Question-contained tile could log without `containerIds` is the two days between `QUESTION_ANSWERS_CHANGE` (2025-05-05) and `containerIds` (2025-05-07), both pre-release per the resolved XR1 decision.

**Apply no `operation` filter** (VR11). Track C filters `operation = 'update'` and mirroring that here would be actively destructive: `operation` is a per-tile-type vocabulary, not a CRUD set, and **Drawing never logs `update` at all** (`addObject`, `rotateMaybeCopy`, `repositionObject`, `setOffset`, …), so the symmetric filter erases every free-standing Drawing tile plus the Table tiles whose only event is `create`. Accepted consequence: a tile the student later deleted can still be its `toolId`'s latest event and appear in `other_tiles`. That is not fixable through `operation` anyway, since no cross-type tile-deletion signal exists (VR11).

Latest-per-tile uses the **same window shape as Track A**, `ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, COALESCE(json_extract_scalar(parameters,'$.toolId'), json_extract_scalar(parameters,'$.tileId')) ORDER BY time DESC)` keeping `rn = 1`, **not** today's `MAX(time) GROUP BY toolId` self-join.

**Track B also requires a non-null `documentKey`, and the tile identity falls back to `tileId` (VR25).** Both are structural gates rather than event-name filters, so BR4's no-enumerated-lists rule still holds and a future event that logs correctly is picked up with no code change. `documentKey` is required because it is the only source of both the history link and the `documentKey`/`documentType` cell fields, so a row without it cannot produce a contract-conforming entry. `COALESCE(toolId, tileId)` costs nothing, since `logTileChangeEvent` sets `toolId = tileId` (`log-tile-change-event.ts:23`) whenever both exist.

Today this excludes exactly one event type: `IFRAME_INTERACTIVE_TOOL_CHANGE` logs through bare `Logger.log` (`iframe-interactive-tile.tsx:352-359`) rather than `logTileChangeEvent`, so it bypasses every parameter-enrichment step and carries no `toolId`, no `documentKey` and no `containerIds` on 100% of its 19,110 production events (9 learners, 5 distinct tiles, 2026 only). Without the gates it would silently collapse to one entry per learner (null partition key) and emit an unusable link. It is recorded as a known limitation next to the tile types that log nothing at all, and a CLUE ask to route it through `logTileChangeEvent` is filed; if that lands, these events flow in automatically. (Per VR22 Track C now uses this shape too, so all three tracks match.) The per-learner half of the Track A trap genuinely does not apply here (`toolId` is a globally-unique `nanoid(16)`, so it belongs to one learner), but the **tie** half does: VR3 observed real duplicate rows at identical `time` values, and the self-join matches on `time`, so a tie returns two rows for one tile. Today that is inert, because Track C writes one answer row per key and `map_agg` collapses the duplicate. Under Track B it stops being inert: entries accumulate Elixir-side into a single JSON array, so a tie appends the same `{type, link}` entry twice and nothing downstream dedupes it, surfacing as a tile listed twice in an `other_tiles` cell. The window picks one unambiguous row at the same cost as Track A.

*Track C CTE (unchanged behavior).* Today's `TEXT_TOOL_CHANGE` query for BR1's free-standing text columns. Keep the `tileTitle` null/empty/`<no title>` guards and the `operation = 'update'` filter exactly as they are, and keep `make_safe_id(tile_title)` as the key. "Unchanged" is about emitted rows and column keys, not about which table they are read from or how latest-per-tile is selected; D7 is row-identical by construction (see the D7 equivalence check).

**Track C's `MAX(time)` self-join is replaced by the same `ROW_NUMBER` window Track A and Track B use (VR22).** Earlier drafts kept the self-join on the grounds that BR1 requires this path unchanged and that VR3's duplicate-`time` rows are inert here because `map_agg` collapses the duplicate. Both are true, and the swap is still worth making for two reasons. First, the self-join references the relation **twice** (`last_changes`, then the main select joining back to it), so under D2's base CTE it costs a fourth inlining of `clue_logs` and a fourth prefix enumeration; the window costs one. Second, it retires the VR3 tie at the source instead of depending on a downstream collapse, and leaves all three tracks one shape, which is one fewer thing for a future reader to reason about. Rows are identical after aggregation, since the only difference is tie duplicates `map_agg` was already discarding, so this is the same reading of "unchanged" D7 already applied to the `FROM` clause.

**Row contract.** Union the three with a `track` discriminator and `CAST(NULL AS VARCHAR)`-padded columns. The column names are part of the contract, because the parse reads them by name and the XR4 fixtures build a CSV with exactly this header:

| Column | Track A | Track B | Track C |
|---|---|---|---|
| `track` | `'A'` | `'B'` | `'C'` |
| `username` | `log.username` | same | same |
| `run_remote_endpoint` | `log.run_remote_endpoint` | same | same |
| `question_id` | `$.questionId`, **raw** (D1 encodes it in Elixir) | null | null |
| `answers` | `json_format(json_extract(parameters,'$.answers'))` (D3) | null | null |
| `prompt` | `$.prompt` (DR1, absent from all current data) | null | null |
| `event` | null | `log.event` (the only carrier of tile type, VR10) | null |
| `tool_id` | null | `$.toolId` | `$.toolId` |
| `tile_title` | null | null | `$.tileTitle` |
| `text_value` | null | null | `$.args[0].text` |
| `document_key` | `$.documentKey` | same | same |
| `document_type` | `$.documentType` | same | null (BR1: Track C's cell is unchanged) |
| `document_history_id` | `$.documentHistoryId` | same | same |

`run_remote_endpoint` is what identifies the learner for a row, **not** `username` (added 2026-08-04 during implementation review). A student enrolled in two classes that both assign the same CLUE runnable appears as two learner rows sharing one `user_id`, and therefore one `username`, with different `offering_id` and `run_remote_endpoint`. Keying the parse's learner lookup on the username makes the choice between them arbitrary, and `offering_id` becomes the parquet `resource_link_id` and the history link's `resourceLinkId`, so an arbitrary choice is a misattributed row. The endpoint is already in the base CTE, so carrying it through costs one column and removes the ambiguity. The username is still split for `user_id` and `portal_site`.

Track C's `tool_id` is selected but unused: BR3's fold into the column key is deferred, and an XR4 assertion checks it is ignored rather than folded. `document_history_id` is **not** passed to the history link verbatim: nil, empty and the literal `"first"` are all treated as absent (VR24). The empty case is not hypothetical: 5% to 12% of each non-text tile-change event type carries no `documentHistoryId` at all (VR25), against zero for `QUESTION_ANSWERS_CHANGE`.

**Reference accounting, since D7's wall-time table depends on it:** with all three tracks on windows, `clue_logs` is inlined **three** times, one per track. Keeping Track C's self-join makes it four, and every figure in the three-scan column understates by a third.

**Add a code comment** at the `containerIds` filter recording both assumptions it rests on, so either one changing triggers a re-read: "Question is currently the only container tile type" (required by the resolved XR1 decision), and "a missing `containerIds` means free-standing, because no container tile type existed before 2025-03-20 and `containerIds` logging began 2025-05-07" (VR15). The second one is what stops a later reader from simplifying the `COALESCE` away as dead defensive code.

**Parsing** (`parse_text_tile_answer_csv/3`, currently `:104-210`). Branch on `track`:

- *Track C* keeps the existing path untouched, including the Slate `Jason.decode` + `extract_text` handling and `make_safe_id(tile_title)` keys. **Do not** fold `toolId` into that key (BR3 is deferred; doing so renames every existing column and breaks BR1).
- *Track A* decodes the raw `$.answers` string with `Jason.decode`, flattens `answers[].answerTiles[]` across groups, applies D5's drop rules, maps each survivor to `{"type", "text"?, "link"}`, and accumulates **one** entry list per `{username, question_key}`. **`plainText` is consumed verbatim** and must not be routed through the Slate `extract_text` path, whose `else -> row_acc.answers` fallback would silently drop every Track A text answer.
- *Track B* maps each row to `{"type" => tile_type_from_event(event), "link" => history_link}` and accumulates all of a learner's entries under the single `other_tiles` key.

**Malformed input is dropped loudly, not silently.** A Track A row whose `answers` value fails `Jason.decode`, or decodes to something other than the documented list-of-groups shape, contributes no entries. This is the one place the plan inherits a genuinely ambiguous choice from Track C, whose `else -> row_acc.answers` drops any undecodable row with no signal at all (`clue.ex:176-177`), and an implementer extending that shape in place inherits the silence for free. Since a malformed payload means CLUE changed the event's shape, which would zero out Track A across the board while the report still rendered, the row must be skipped **and** logged at error level with the `username` and `questionId`, so the failure is visible in the server logs rather than as universally blank cells. Do not raise: one bad row must not fail a whole report. The same applies to a `track` value the parse does not recognize.

**Aggregation.** Track A and Track B both need many tiles under one key, which the per-tile write pattern cannot express: `map_agg` allows one value per key and on engine v3 **silently drops** duplicates (VR6). So accumulate entry lists in the reduce and `Jason.encode` **one** answer row per `{username, key}` before the parquet write.

**Structure.** Add matching `questions` + `question_order` entries, since a column exists only if the key is in both (`shared_queries.ex:218-219`):

| Track | Key | `type` | `prompt` |
|---|---|---|---|
| A | `question_key(questionId)` (D1) | `clue_question` | enriched prompt when present, else raw `questionId` (QR1/DR2) |
| B | `other_tiles` | `clue_tile` | `Other tiles` |
| C | `make_safe_id(tile_title)` | `clue_text_tile` (unchanged) | tile title |

All `required: false`.

**The three key families share one flat namespace, and `other_tiles` is a reserved key (VR19).** D1 makes Track A collision-free within Track A, but nothing separates it from Track C's lossy `make_safe_id(tile_title)` keys, and collisions there are silent in both directions: the structure entry keeps whichever `type` was written first (so an array cell read as `json_extract_scalar(answer,'$.text')` returns NULL), and both tracks write answer rows under one key, which is VR6's silent `map_agg` drop. One collision is plausible enough to guard: `make_safe_id` maps `"Other Tiles"`, `"other tiles"`, `"other-tiles"` and `"OTHER_TILES"` all to exactly `other_tiles`. Treat `other_tiles` as reserved and disambiguate the Track C key when it collides (a suffix is enough); that does not breach BR1, because the colliding case is broken today rather than working.

Noted but deliberately **not** guarded: `make_safe_id` prepends `q` to a digit-leading title (`clue.ex:218`), which is D1's own prefix, so `make_safe_id("39487a59642d") == question_key("9HzYd-") == "q39487a59642d"`. Verified real, but it needs a tile titled with exactly the hex of a `questionId` in the same report, and no `[a-z0-9_]` key scheme can be made collision-proof against a lossy transform over arbitrary titles. The reserved-key check above is where the cost/benefit is.

**The Track A prompt field is pinned to `$.prompt` at the top level of `parameters`.** It does not exist yet (DR1; VR4 found zero occurrences anywhere in production `parameters`), so the lookup ships inert: read `json_extract_scalar(parameters,'$.prompt')`, use it when non-null and non-empty, else fall back to the raw `questionId` (QR1/DR2). Every current and historical report therefore renders the fallback, and the enrichment starts working with **no report-service change** the day CLUE ships it.

**The stored prompt must be *upgraded*, not only created (VR18).** A question has one structure entry but many contributing rows, one per learner (and per document, after the VR13 partition change), each carrying that learner's own latest event. Once CLUE ships the enrichment those rows **disagree**: a learner whose latest answer predates the deploy carries no `$.prompt`, one who answered after it does. Today's shape decides that by row order and never revisits it (`clue.ex:121-131`: `new_question = not Map.has_key?(...)`, entry written only when new), and the query has no `ORDER BY`, so the header for the whole column is whichever row Athena happened to deliver first, and it can differ between two runs over unchanged data.

The disagreement is permanent rather than a transition-window artifact: a student who answered once before the deploy and never returned keeps a prompt-less latest event forever, so a long-running class holds both shapes for the same question indefinitely.

Required rule: when a row carries a non-empty `$.prompt` and the stored prompt for that key is still the `questionId` fallback, **replace it**. One extra branch in the same `if new_question` region, and it makes the header a deterministic function of the data (enriched if *any* contributing row has it) rather than of delivery order. Without it the enrichment takes effect per question at random, which presents as "the prompt only appeared on some columns" and reads as a CLUE-side bug rather than a report-service one, on the deliverable that makes filing the DR1 ticket sequencing step 0.

That only holds if CLUE uses this exact name, so **filing the DR1 ticket is a deliverable of this story, not a floating open item**, and the ticket must state both constraints it needs to carry:

1. the prompt is added to `QUESTION_ANSWERS_CHANGE` as a top-level `prompt` key in the event parameters (this decision), and
2. any new tile-change events follow the `<TYPE>_TOOL_CHANGE` naming convention (BR4, also required by DR3).

If CLUE ships a different name or nests it inside `answers[]`, the lookup is dead code that looks live: headers keep showing `questionId` and nothing errors. Pinning the name is what converts that silent failure into a stated contract on the ticket. Should the ticket come back with a different shape, adapting is a two-line change in `clue.ex`.

**Ordering.** D6.

**XR2**, `clue.ex:20`. Replace `"Test Clue"` by parsing `unit` and `problem` from the runnable URL. No unit-code lookup table. Exposed as `Clue.resource_name(url)` so it is assertable, since this was otherwise the only changed behavior with no regression guard.

**The fallback chain is pinned to three cases, and the runnable-URL fallback is dropped:**

| Runnable URL query | Label |
|---|---|
| `?unit=m2s&problem=4.5` | `CLUE m2s: Problem 4.5` |
| `?unit=m2s`, no `problem` | `CLUE m2s` |
| neither present | `CLUE` |

Earlier wording left this as "falling back to `CLUE` then the runnable URL", which cannot be asserted. The URL is dropped as a fallback on XR2's own reasoning: the activity is already identified in the output by `res_N_resource_url` (`shared_queries.ex:78`), so a name repeating it adds a redundant wide column and no information. `"CLUE"` is a less useful label than the parsed form but is never *misleading*, which is all XR2 asks for. A test also asserts the label is never `"Test Clue"`, so the actual defect cannot regress.

**The `"first"` history-id sentinel is dropped rather than passed through (VR24).** CLUE emits the literal string `"first"` as `documentHistoryId` when a document had no history entry at log time, i.e. the student's first change to a brand-new document: 299 of 8,600 production events, 3.5%, and never null (VR4). Traced through CLUE, it resolves to nothing: `findHistoryEntryIndex/1` is a plain `findIndex(entry => entry.id === historyEntryId)` (`tree-manager.ts:166-168`), no code anywhere in `collaborative-learning/src` special-cases the value, and `moveToHistoryEntryAfterLoad/1` falls to `console.warn("Did not find history entry with id: ", historyId)` without navigating (`firestore-history-manager.ts:291-299`). But `canvas.tsx:114-121` has already called `setShowPlaybackControls(true)` by then, so the playback UI opens and the document renders at playback's default. The researcher gets a history view that looks positioned and is not, with the only signal a console warning.

So build the link with `maybe_document_history_id: nil` when the value is `"first"`, empty, or missing. The empty case matters at scale, not just in principle: measured over 2025-2026, `documentHistoryId` is absent on 11.7% of `TABLE_TOOL_CHANGE`, 10.4% of `DRAWING_TOOL_CHANGE`, 9.1% of `TEXT_TOOL_CHANGE` and 5.4% of `GEOMETRY_TOOL_CHANGE` events, against **zero** for `QUESTION_ANSWERS_CHANGE` (VR25), and Athena renders a SQL null as an empty CSV field, which is truthy in Elixir and would emit a dangling `&studentDocumentHistoryId=`. Those entries keep their link, which still opens the right document; only the history position is unavailable. `HistoryLink.format_link_to_work/1` already omits the parameter for nil (`history_link.ex:23`), which means no history request is made, the playback controls stay closed, and the document opens normally: an honest "here is the document" rather than a false position. The report cannot do better, because the true first entry's id is not in the log.

This also changes **Track C**'s links for those rows, since `TEXT_TOOL_CHANGE` rides the same `logDocumentEvent` and today's shipped report passes the sentinel through in exactly the same way. That is fixing a live defect rather than breaching BR1, whose guarantee is about emitted columns and keys, but it is the one behavior change in this story that reaches outside Tracks A and B and it should be called out in review. The better fix is CLUE-side, having `moveToHistoryEntryAfterLoad` treat `"first"` as index 0, which would make these links land correctly with no report change; that is filed as ask 3 of the CLUE ticket set and does not block this story.

**Housekeeping.** `clue.ex:139` rebinds the local `url` to the history link inside the reduce, so `resource_url: url` at `:160` writes the history link into the parquet's `resource_url` column. This is latent rather than breaking, because the report takes `resource_url` from the learners table (`runnable_url as resource_url`, `shared_queries.ex:78`) and not from the answers parquet. Rename the local to `history_url` while touching this function so Track A and Track B do not propagate the confusion.

### `server/lib/report_server/reports/athena/shared_queries.ex` (**no change needed**)

Earlier drafts (and the requirements Technical Note) called for adding `clue_question` and `clue_tile` branches to `get_columns_for_question/5`. **Verified unnecessary 2026-08-04:** the existing `_ ->` fallback (`:491-494`) already produces exactly the required column for any unrecognized type, `prompt_header` included, so those branches would emit byte-identical SQL. Calling the real function:

```
clue_question -> ["res_1_q39487a59642d_json"]  value: learners_and_answers_1.kv1['q39487a59642d']
clue_tile     -> ["res_1_q39487a59642d_json"]  value: learners_and_answers_1.kv1['q39487a59642d']
clue_text_tile-> ["res_1_…_text", "res_1_…_url"]   (legacy pair, Track C only)
```

So `res_<n>_<key>_json` is delivered by the fallback and remains the committed contract for cc-data and tests. This makes the story **zero-blast-radius**: only `clue.ex` changes, and XR3 holds as a fact rather than an argument, since no shared code is touched at all. (VR9 observed the fall-through but did not draw this conclusion.)

The contract is pinned by test rather than by a branch: XR4's direct **answers-path** query-generation test asserts `res_<n>_<key>_json` for both new types, so an edit to the fallback that changed CLUE's cell format would fail a test rather than pass silently. That test is required precisely because the behavior is now implicit.

### Not changed

`shared_queries.ex` (above), `reports/clue/history_link.ex`, the `partitioned-answers` layout, `resource_data.ex`, and the downstream report SQL.

**One exception, found during implementation (2026-08-04): the parquet writer splits by offering as well as username.** It previously took `resource_link_id` from `List.first()` of a username's answer rows and wrote one file per username. Because a student enrolled in two classes that both assign this runnable shares one username across two `offering_id`s, and the parquet path encodes the offering, that filed both offerings' answers under whichever row happened to be first, attributing one class's work to the other. The rows themselves always carried the right `resource_link_id`; only the file they landed in was wrong. The writer now groups a username's rows by `resource_link_id` and writes one file per pair. This is the same defect as the learner-lookup ambiguity in the row contract note, one level further down, and it is pre-existing rather than introduced by this story.

## Cell contract

Uniform across Track A and Track B, for cc-data SQL consumption:

```json
[
  {"type": "Text",    "text": "the student's answer", "link": "https://…historyId=…",
   "documentKey": "-OL0rmfqiDsPlriZks-X", "documentType": "problem"},
  {"type": "Drawing", "link": "https://…historyId=…",
   "documentKey": "-OK7YQig6OxOLf9F84zu", "documentType": "learningLog"}
]
```

`type` always present. `text` only for Text tiles with surviving content. `link` carried **per entry** in both tracks: Track A repeats the question's single link on each entry (harmless redundancy) so cc-data has exactly one parsing pattern.

**`documentKey` and `documentType` are surfaced per entry (decided 2026-08-04).** Both tracks aggregate across a learner's documents, so without them a cell is ambiguous about something a researcher genuinely asks. Track B collects every free-standing tile a learner has in *any* document (problem document, learning log, personal document) into the one `other_tiles` cell, and Track A can span documents too after the VR13 partition change. Document identity was technically recoverable, since each entry's `link` embeds `studentDocument=<documentKey>`, but only by string-parsing a URL, which is not a contract a cc-data query should have to rely on.

- `documentKey` is the unambiguous identity and the join key: two entries are in the same document exactly when it matches.
- `documentType` is the category a researcher actually wants (`problem`, `learningLog`, `personal`, …), which answers "was this work in their assigned document or their own notebook" without opening anything.

Both are attached by CLUE to **every** document log event, `QUESTION_ANSWERS_CHANGE` and every `*_TOOL_CHANGE` alike (`log-document-event.ts:91-118`, `processDocumentEventParams`), and VR10's measured parameter set confirms them in production, so the two tracks stay uniform and no CLUE-side change is needed.

`documentTitle` is available on the same events and is deliberately **not** surfaced: it is user-editable and can change after the fact, so it is not a stable identifier, and `documentType` plus the link cover the reader's need. Add it later if researchers ask for the student's own name for a learning log.

This widens the cell rather than changing it, so a consumer reading `type`/`text`/`link` is unaffected. Track C is untouched: its cell stays the legacy `{"text": …, "url": …}` pair (BR1).

**Entry order is part of the contract, not incidental.** Left unpinned it is nondeterministic for Track B, because the query has no `ORDER BY`, Athena's row order is arbitrary, and today's reduce prepends (`clue.ex:174`). Verified by throwaway execution: the same three tiles fed through a prepending reduce in two row orders produced `["Dataflow","Drawing","Table"]` and `["Table","Dataflow","Drawing"]`. Two runs of the same report over unchanged data would then differ, which matters because cc-data consumes these cells and because diffing two report runs is how a researcher finds what actually changed. It also makes any assertion on cell contents order-dependent, surfacing as intermittent test failures blamed on fixtures.

- **Track A**: document order, as the tiles appear in `answers[].answerTiles[]`, flattened across groups in payload order. The flatten and the accumulation must preserve it (accumulate then `Enum.reverse` at the end, or append), which is the opposite of today's prepend-and-keep pattern. **Across payloads, order by `documentKey` ascending (VR20).** The VR13 partition change means a `{learner, questionId}` can contribute more than one row, one per document, each its own payload, and payload-order is only defined *within* a payload; the order *between* them is Athena's row delivery, which is unordered. Order a question's payload groups by `documentKey`, Elixir-side rather than via an `ORDER BY` in the CTE, for the reason this section already gives for Track B: the reduce has to preserve order anyway, so ordering at the point of use does not depend on how Athena delivers rows.

**Mechanism, surfaced while writing the tests:** "sort the rows before flattening" is not directly available, because the parse is a single `Enum.reduce` over the CSV stream and cannot sort rows it has not seen yet. Carry `documentKey` on each accumulated entry, then **stable**-sort the entry list by it immediately before `Jason.encode`. A stable sort is what preserves the within-payload `answerTiles` order underneath the cross-document order. Earlier wording had this field dropped before encoding; now that `documentKey` is part of the cell contract it simply stays, so the sort key and the emitted field are the same thing. The alternative, materializing and sorting the Track A rows ahead of the reduce, works but costs a pass and buys nothing.
- **Track B**: sort entries by `type`, then `link`, immediately before `Jason.encode`. An Elixir-side sort is used rather than an SQL `ORDER BY` because the reduce would have to preserve the SQL order anyway; sorting at the encode point is stable without depending on Athena's row delivery. (Ordering by tile `time` was considered and rejected: more meaningful to a reader, but it re-shuffles the cell whenever a student edits one tile, reintroducing the diff noise this rule exists to remove.)

## Tests (XR4)

**Written, committed and currently pending (2026-08-04).** The fixtures and assertions now exist in the repo rather than only in this plan:

- `server/test/support/fixtures/clue_fixtures.ex` builds the unioned three-track CSV that Athena would emit, with row helpers per track, so tests exercise the real `CSV.decode` -> reduce -> structure/answers path rather than mocked Elixir structures.
- `server/test/report_server/clue_test.exs` holds 34 tests, tagged `:pending` and excluded in `test_helper.exs`, so `mix test` stays green. Run them with `mix test --include pending`.

They currently fail with exactly two causes, `Clue.answer_sql/1` (7 tests) and `Clue.parse_answer_csv/4` (27), which are the two entry points sequencing step 2 must expose; the test moduledoc states their contracts, including the `write_answers` option that replaces the S3 parquet write. Nothing fails for a fixture or wiring reason, verified by running them.

Seven of the 34 assert on the **generated SQL text** rather than on Athena, which pins VR15's `COALESCE`, VR16's single base CTE and year floor, VR17's `regexp_like` and `json_format`, VR13's partition and VR22's three windows without needing credentials or a scan. The fixture round trip was verified separately: a `plainText` of `he said "hi", then left` plus an embedded newline survives `Jason.encode` -> CSV quoting -> `CSV.decode` -> `Jason.decode` byte-identical, and the newline never appears literally in the CSV field because JSON escapes it, which is what the discarded-non-issue note about `deps/csv` assumed.

No test exercised `clue.ex`'s query path or the `clue_text_tile` branch before this, and every pre-existing fixture is `TEXT_TOOL_CHANGE`-only, so **fixture construction was a substantial part of the work**, not a tail task. The scenario list below is what those files implement.

**Fixtures are necessary but not sufficient: sequencing step 2, the testability seam, must land first.** Nothing on this path is currently reachable from a test (all `defp`, no Athena or S3 seam, an unconditional S3 parquet write, and `fetch_resource/3` returns only the structure). That last point decides how the scenarios below split:

- **Structure assertions** (reachable through `fetch_resource/3` once the query and CSV read are stubbed): 1, 3, 5, 6, 8, plus the "no column emitted" half of 7.
- **Answer-row assertions** (require the answer map to be observable, i.e. step 2's parquet-write injection or an extended return value): 2b, 4, 7, 9, and the `map_agg` duplicate guard.

Half the scenarios, including every one guarding a silent-loss failure mode (QR6 suppression, duplicate-key drops, the VR2 track boundary, the VR13 two-document case), sit in the second group. If step 2 slips or is skipped, those are the ones that quietly do not get written.

Fixtures must carry nested `QUESTION_ANSWERS_CHANGE` payloads, `containerIds`, and non-text `*_TOOL_CHANGE` events, covering:

1. **AC1 alignment** with **at least two learners sharing one `questionId`**, the regression guard for the partition trap. Extend the same fixture for **VR18**: give one of the two learners' rows a non-empty `$.prompt` and the other none, feed them in **both** orders, and assert the column header is the enriched prompt both times. This is the only test that distinguishes an upgrading structure write from a write-once one, and it is the same trap shape as fixture 4's shuffled Track B rows.
2. **AC2 copies**: within-document (new id, distinct question) and across-document (preserved id, aggregated).
2b. **One learner, one `questionId`, two `documentKey`s** (VR13): assert both documents' answer tiles appear in the single cell, each with its own history link. This is the regression guard for the `documentKey` half of the Track A partition, and fixture 2 does not cover it (it copies between learners, not between one learner's documents). **Feed the two documents' rows in both orders and assert the same cell** (VR20), mirroring what fixture 4 does for Track B: the cross-document entry order is the half of the cell contract the VR13 change put at risk, and an assertion that only matches the input order would pass against the nondeterministic implementation.
3. **XR1 disjointness** via non-empty `containerIds`.
3b. **Pre-2025-05-07 event with no `containerIds` key at all** (VR15): assert the tile still appears in `other_tiles`. No other fixture covers this, because every fixture is modelled on today's payloads, where the key is always present; and the failure it guards is the largest silent-loss surface in the plan (Track B empty for 83% of the log history, with the text columns still populated so nothing looks wrong).
4. **Multi-tile aggregation** for a Track A question and for `other_tiles`, asserting one row per (student, key), **and asserting entry order** per the cell contract: Track A in `answerTiles` document order, Track B sorted by `type` then `link`. Feed the Track B fixture rows in a shuffled order and assert the cell is unchanged, since an assertion that only happens to match the input order would pass against the nondeterministic implementation.
5. **Key sanitization**: a hyphenated `questionId`, plus two ids differing only by case or `-`/`_`, asserting distinct columns. Plus the **VR19** reserved-key case: a free-standing text tile titled `"Other Tiles"` alongside at least one non-text free-standing tile, asserting two distinct columns rather than one, and that the `other_tiles` cell still parses as a JSON array.
6. **Special characters** in `plainText` (embedded quotes, commas, newlines). Regression guard rather than live risk: verified surviving `json_extract_scalar` byte-identical (VR1).
6b. **Malformed `answers` payload**: one row whose `answers` value does not decode, alongside a valid row for the same question from another learner, asserting the bad row contributes nothing, the good row is unaffected, and the column survives. Guards the drop-loudly rule above against inheriting Track C's silent `else`.
7. **QR6**: a `Placeholder`-only question and an empty/whitespace Text question, both asserting **no answer row is emitted** and, where no learner in the fixture contributes a survivor, that **no column is emitted either** (D5 rule 4). The second assertion is the one that matters: "no answer row" alone is satisfied by the broken implementation that still creates the column and inflates `num_questions` for every learner.
8. **BR4 adaptivity**, in two parts, since VR23 showed the original single fixture was built on a false premise (it called `GRAPH_TOOL_CHANGE` "an event the code has never seen" and asserted the label `"Graph"`; it is 1.27M real historical events and `"Graph"` is the wrong label):
   - **8a, the retired-name case**: a real `GRAPH_TOOL_CHANGE` fixture asserting it appears as `"Geometry"`, not `"Graph"`. This is a historical-data correctness guard, not an adaptivity one.
   - **8b, the adaptivity case**: a fixture with an event name that genuinely does not exist in the code or the logs (e.g. `SKETCH_TOOL_CHANGE`), asserting it appears as `"Sketch"` rather than being dropped or raising. This is the test that stops the covered types getting hardwired, and it needs a name no override entry can satisfy.
9. **VR2 track boundary** (XR4): an answer tile of a type that emits no `*_TOOL_CHANGE` event (`Image`, the largest real case at 222 distinct in-question tiles, or `Simulator`) inside a Question tile, asserting Track A **does** report it and Track B does **not**. Cheap to add, since fixture 4 already carries a multi-tile question: one extra `answerTiles` entry plus the paired assertions. It is the only test pinning which side of the VR2 coverage line each track sits on, so a later "filter Track A to known tile types" change cannot silently drop the silent types.

Plus direct **answers-path** query-generation tests asserting `get_columns_for_question/5` emits `res_<n>_<key>_json` for `clue_question` and `clue_tile`. These no longer test a new branch (there is none, see the `shared_queries.ex` section), they pin a contract currently delivered by the `_ ->` fallback, which is exactly why they are required. Usage-report tests stay broad smoke coverage only.

## Suggested sequencing

Each step should be independently reviewable:

0. **File the CLUE-side enrichment ticket (DR1)**, first rather than last. It is the only non-code deliverable of this story, it is the item most likely to be blocked on someone else's availability, and the `$.prompt` lookup shipped in step 4 binds to the field name it specifies. The ticket must state **both** constraints: the prompt is added to `QUESTION_ANSWERS_CHANGE` as a **top-level `prompt` key** in the event parameters, and any new tile-change events follow the **`<TYPE>_TOOL_CHANGE`** naming convention (BR4/DR3, which may ride the same ticket). Completion evidence is the linked ticket id, not a Slack thread. Filed last, or filed without both constraints, the failure is silent: headers stay on the `questionId` fallback and nothing errors.
1. **D7 table move plus the D2 base CTE**, on their own: repoint today's query at `logs_by_app_and_secure_key`, introduce `clue_logs` carrying the `app` + year-floor + `secure_key` + `run_remote_endpoint` prune (with `Enum.uniq()` on the endpoint list), and have today's `TEXT_TOOL_CHANGE` path select from it, switching its `MAX(time)` self-join to the `ROW_NUMBER` window (VR22) so the base CTE is inlined once per track from the start. No behavior change to emitted rows. Isolating it means the ~36,000x scan reduction is independently reviewable and independently revertible, every later step is measured against the cheap baseline rather than the 24 GB one, and the base CTE exists before Track A and Track B are added to it rather than being retrofitted around three duplicated predicate blocks.
2. **Testability seam**, before any track work rather than after it (VR21). Not optional and not part of the tests step: as it stands, nothing on this path is reachable from a test, so every answer-row assertion in the Tests section is unwritable until this lands. Route `AthenaDB` through the existing `Application.get_env(:report_server, :athena_db, AthenaDB)` seam (`resource_data.ex:67` and six other modules use it) **including inside `AthenaQueryPoller`**, which calls `AthenaDB.get_query_info` directly (`athena_query_poller.ex:12`) and would otherwise defeat the stub; route the CSV read through `Application.get_env(:report_server, :aws_file_store, ReportServerWeb.Aws)` (`jobs_file.ex:4`, stubbed by `AwsFileStoreStub`); and expose the two entry points the committed tests call, which pin what this step must deliver:

```elixir
Clue.answer_sql(learners) :: String.t()

Clue.resource_name(runnable_url) :: String.t()

Clue.parse_answer_csv(url, stream, learners, opts) ::
  {:ok, %{structure: %{questions: map, choices: map, question_order: [String.t()]},
          answers: %{String.t() => [map]}}}
```

**The parquet write is injected via `opts[:write_answers]`**, a function of the answers map defaulting to today's S3 write, rather than the alternative of returning the answer map from `fetch_resource/3`. Earlier drafts left that an open "or"; it is pinned because the answer-row assertions are written against this shape, and `fetch_resource/3` keeps returning only the structure so `resource_data.ex` is untouched. `AthenaDBStub` and `AwsFileStoreStub` already exist and are used by `report_controller_test.exs` and `report_job_controller_test.exs`, so this is routine. It is also independent of every track step (it touches module boundaries, not query or parse logic), so putting it here costs nothing and is what makes "tests grow alongside the track steps" true rather than aspirational.
3. Key encoding (D1) + `tile_type_from_event` (D4) with unit tests. Pure functions, no query changes.
4. Track A: query CTE, parsing, structure entries, aggregation. The bulk of the value. The two VR17 SQL-literal items (the `json`/`varchar` union incompatibility and its `json_format` fix) are **confirmed live**, so this step has no outstanding precondition.
5. Track B: query broadening, `containerIds` filter (with the VR15 `COALESCE`), `other_tiles` synthesis, D6 ordering.
6. XR2 and the `history_url` rename (no `shared_queries` change; its contract test belongs with the tests step).
7. Fixtures and tests. With the seam at step 2 these genuinely do grow alongside steps 4 and 5, which is the point of the reordering: every silent-loss guard in the Tests section is an answer-row assertion, and that group has grown over this review to include the VR15 missing-`containerIds` case, VR18's both-orders prompt assertion, VR19's reserved key and VR20's cross-document ordering.

## Self-Review (2026-08-04)

Multi-role self-review of this implementation spec (Senior Engineer, Data/Query Engineer, Performance Engineer, QA Engineer, Education Researcher, Product Manager). Every issue below was verified against current `report-service` and `collaborative-learning` source before being written, and three were verified by throwaway execution. The "Verified" line records the check.

Three candidate issues were investigated and **discarded** as non-issues, recorded here so they are not re-raised: (a) the `_ ->` fallback in `shared_queries.ex:491-494` does emit `%{name: "#{prefix}_json", value: answer, header: prompt_header}`, so the "no shared change needed" claim holds; (b) embedded newlines in `plainText` cannot break the CSV round trip, because `deps/csv` 3.x explicitly "expects line or variable size byte stream input" and reassembles escaped sequences across chunks, and D3's `json_extract` keeps newlines JSON-escaped anyway; (c) the always-nil `id` field on the answer row writes a `:null`-dtype parquet column against a `string` Glue column, but that is pre-existing (the SELECT has never selected `id`) and unchanged by aggregation.

### Performance Engineer

#### RESOLVED: the query targets an undocumented, unpruned log table and has no time bound, so Track B's broadening multiplies a full-history scan
**Resolution** (2026-08-04): accepted and pinned as **D7**, with the move made its own first sequencing step. Verified live (VR12) rather than left as a re-check: `logs_by_time` has `PartitionKeys: null` in Glue and points at the unpartitioned `processed_logs_with_id/` prefix, while `logs_by_app_and_secure_key` projects `app/year/month/secure_key`. On the pruned table the full three-track predicate over all history for 40 real learners scans **0.67 MB** against VR8's windowed 489 MB and the 24 GB an unbounded `logs_by_time` scan has cost in practice. The Performance open item is closed rather than deferred.

Every CTE in the plan inherits today's `FROM "#{log_db_name}"."logs_by_time"`, and today's query has **no predicate on `time` at all** (`clue.ex:42-72`): it filters only on `application`, `event`, `operation` and `run_remote_endpoint`. So each report run already scans the full history of that table, and the plan then adds a second scan whose predicate is ~20x wider (VR8's `LIKE '%TOOL_CHANGE'`), plus a third for Track C.

VR8's headline numbers are all **windowed** (24.7 MB and 489 MB over 12 days), so they describe a query shape this code does not use. VR8's own unbounded figure is the relevant one: 666 MB to 1.33 GB for the *narrow* Track A filter over full history. Track B's filter over the same unbounded range is the number nobody has measured, and it is the one this story ships.

The repo already contains the right table. `server/README.md:210-253` documents `logs_by_app_and_secure_key`, partition-projected on `app/year/month/secure_key` with `secure_key` as an **injected** projection, and `report_query.ex:100-121` uses it for exactly CLUE's access pattern: it derives `secure_keys` from the same `run_remote_endpoint` list CLUE builds (`List.last(String.split(&1, "/"))`) and filters `log.secure_key IN (...)`. Against that table, a report's scan is pruned to the S3 prefixes of its own learners before any row predicate runs, which makes the event predicate's width nearly irrelevant and removes Track B's cost problem rather than measuring it. `logs_by_time` is not documented in the README at all, and VR11's own method note already flagged using it as the mistake ("future verification queries should partition-prune on app/year/month").

Why it matters: "Performance ... measured but not final ... Re-check per-runnable during implementation" reads as a tuning task, but the underlying issue is table selection, not tuning, and it is cheapest to fix while the query is being rewritten anyway. Shipping on `logs_by_time` bakes an unbounded full-history scan into a per-runnable, per-report code path.

Suggested resolution: move all three CTEs to `logs_by_app_and_secure_key`, filtering `application = 'CLUE'` (or the `app` partition) and `secure_key IN (<derived from run_remote_endpoints>)`, mirroring `report_query.ex:102-122`. Keep `run_remote_endpoint IN (...)` as the correctness filter. Confirm the column set matches (the README DDL lists `username`, `event`, `time`, `parameters`, `run_remote_endpoint`, so it does) and re-measure Track A and Track B against both tables before closing the performance open item.

**Verified**: `clue.ex:42-72` (no `time` predicate); `server/README.md:210-253` (`logs_by_app_and_secure_key` DDL, injected `secure_key` projection), `:255-295` (`logs_by_app`); no `logs_by_time` DDL anywhere in the repo docs; `report_query.ex:100` (`from` uses `logs_by_app_and_secure_key`), `:102-107` (secure keys from run_remote_endpoints), `:121` (`log.secure_key IN`); `grep logs_by_time lib/` returns only `clue.ex` and `teacher_actions_report.ex`.

---

### Data / Query Engineer

#### RESOLVED: Track A's window partition drops a learner's second document, which is the AC2 copy case
**Resolution** (2026-08-04): accepted. The Track A window now partitions by `run_remote_endpoint, documentKey, questionId`, and XR4 fixture 2b was added as the regression guard. Confirmed live rather than argued (VR13): across the full production corpus, **14 learner/question pairs span 2 documents and 1 spans 3**, of 1,220, so the naive partition would silently drop 16 documents' worth of answers. Small (1.2% of pairs) but silent, and the fix is free because the Elixir reduce already merges the extra rows.


The plan pins `ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, questionId ORDER BY time DESC)` and keeps `rn = 1`. That is correct against the Round 2 trap (one question shared by many learners) but introduces its mirror image one level down: **one learner holding the same `questionId` in two documents**.

That is not hypothetical, it is the copy path AC2 names. `updateQuestionContentForCopy` preserves `questionId` unchanged whenever `acrossDocuments` is true (`question-utils.ts:33-39`), and it is wired as the Question tile's `updateContentForCopy` hook (`question-registration.ts:19`), invoked from `document-content.ts:399-400` with `isCrossingDocuments`. So a student who copies a Question tile from their problem document into a learning log or personal document (or copies the whole document) ends up with that `questionId` live in two documents. Both fire `QUESTION_ANSWERS_CHANGE`, both under the same `run_remote_endpoint`, and `getQuestionAnswersAsJSON` scopes each payload to **one** document (`question-utils.ts:52-53`, `doc.getTilesOfType`), so neither event contains the other document's answers.

With the pinned partition, only the globally-latest of those two events survives and the other document's answers vanish, silently, in the exact scenario QR2 says must not "collapse or drop an answer."

The fix is nearly free because the aggregation already accommodates it: adding `documentKey` to the partition yields two rows for the same `{username, question_key}`, and D3/D5's Elixir-side reduce merges them into one entry list, with each entry already carrying its own per-entry `link` (the D-cell contract). No downstream change, and it removes an asymmetry where Track B partitions on a genuinely globally-unique key while Track A partitions on one deliberately designed not to be.

Why it matters: it is the same class of failure as the Round 2 finding (plausible output, silent loss, invisible to a one-document fixture), and the current XR4 fixture list has no scenario that would catch it: fixture 2 covers across-document copies between *learners*, not one learner across two documents.

Suggested resolution: partition Track A by `run_remote_endpoint, documentKey, questionId`; state in D-notes that a learner may legitimately contribute more than one row per question and that the reduce merges them; add an XR4 fixture with one learner holding one `questionId` in two `documentKey`s, asserting both documents' answer tiles appear in the cell with their own links.

**Verified**: `question-utils.ts:33-39` (`acrossDocuments ? content.questionId : generateQuestionId()`), `:49-77` (`getQuestionAnswersAsJSON` walks a single `doc`); `question-registration.ts:19` (`updateContentForCopy` hook); `document-content.ts:399-400` (`isCrossingDocuments` call site); implementation.md's Track A CTE and XR4 fixture list.

---

### QA Engineer

#### RESOLVED: none of the nine XR4 scenarios can be executed against `clue.ex` as written, and the plan budgets fixtures but not the seam
**Resolution** (2026-08-04): accepted. Added sequencing step 6 covering the `athena_db` and `aws_file_store` seams (including inside `AthenaQueryPoller`, which would otherwise defeat the stub), an injectable parquet write or extended return value, and exposing the parse function; and added a Tests-section split marking which scenarios assert on structure and which on answer rows. Five of the ten scenarios, including every silent-loss guard, are in the answer-row group and are unobservable until the seam lands. (Round 2's VR21 later moved that step ahead of the track work, where it is now step 2; the step numbers in this finding's body refer to the ordering as it stood when it was written.)


XR4 and the Tests section treat fixture construction as "the bulk of this work." Fixtures are necessary but not sufficient: there is currently **nothing to hand them to**.

- The whole path is private. `ReportServer.Clue` exports only `is_clue_url?/1`, `fetch_resource/3` and `extract_text/1`; `query_for_text_tile_answers/3`, `get_text_tile_answer_sql/1`, `read_text_tile_answer_csv/3`, `parse_text_tile_answer_csv/3` and `make_safe_id/1` are all `defp`.
- There is no seam for Athena. `clue.ex:31` calls `AthenaDB.query` through a direct alias, and `AthenaQueryPoller.wait_for/1` calls `AthenaDB.get_query_info` directly too (`athena_query_poller.ex:12`), so even the existing `Application.get_env(:report_server, :athena_db, AthenaDB)` stub swap would not intercept the poll loop.
- There is no seam for S3 reads. `clue.ex:98` calls `Aws.get_file_stream` directly, while the repo's idiomatic form is `Application.get_env(:report_server, :aws_file_store, ReportServerWeb.Aws)` (`jobs_file.ex:4`, stubbed by `AwsFileStoreStub`).
- The parse path **writes to S3 unconditionally**. `parse_text_tile_answer_csv/3` ends by writing one parquet per learner to an `FSS.S3` path built from `SERVER_ACCESS_KEY_ID`/`ATHENA_REPORT_BUCKET` (`clue.ex:75-83,196-204`), so it cannot be called in a test without either credentials or an injectable writer.
- Even with all that, `fetch_resource/3` returns only `%{"denormalized" => data.structure}` (`clue.ex:17-22`); the answer rows are never returned. At least five of the nine scenarios assert on answer rows rather than structure (4 "one row per (student, key)", 7 "no answer row is emitted", 9 "Track A does, Track B does not", the map_agg duplicate guard, and the D5 drop rules), so they are unobservable through the only public entry point.

The repo's existing pattern makes the fix routine (`resource_data.ex:67` and six other modules use the `athena_db()` seam; `report_controller_test.exs` and `report_job_controller_test.exs` show both stub styles in use), so this is scope, not risk.

Why it matters: the sequencing lists tests as step 5 "though in practice these grow alongside 2 and 3," which is only true if the code is reachable from a test. As written, step 5 silently contains a refactor of the module's boundaries, and the most likely outcome under time pressure is that the structure-only assertions get written and the answer-row assertions, which is where QR6, the map_agg guard and VR2's track boundary all live, get dropped.

Suggested resolution: add an explicit sequencing step before the tests, covering: route `AthenaDB` and `Aws.get_file_stream` through the existing `Application.get_env` seams (including inside `AthenaQueryPoller`, or bypass the poller in the CLUE path); make the parquet write injectable or return the answer map alongside the structure so it can be asserted without S3; and expose the parse function to tests. Note in the Tests section which scenarios assert on structure and which on answer rows.

**Verified**: `clue.ex:10-26` (public surface), `:28-37,39-73,97-102,104-210,214-219` (all `defp`), `:31` (direct `AthenaDB.query`), `:98` (direct `Aws.get_file_stream`), `:75-83,196-204` (S3 parquet write), `:17-22` (returns structure only); `athena_query_poller.ex:12` (direct `AthenaDB.get_query_info`); `resource_data.ex:67`, `jobs_file.ex:4` (existing seams); `test/support/athena_db_stub.ex`, `test/support/aws_file_store_stub.ex`; `find test` shows no test referencing `ReportServer.Clue`.

---

### Education Researcher

#### RESOLVED: entry order inside an aggregated cell is nondeterministic, so the same report produces different cells on re-run
**Resolution** (2026-08-04): accepted. Entry order is now part of the cell contract: Track A in `answerTiles` document order (accumulate then reverse, or append, rather than today's prepend-and-keep), Track B sorted by `type` then `link` at the encode point. Time-based ordering was considered and rejected because it reshuffles the cell on any single-tile edit. XR4 fixture 4 now feeds Track B rows shuffled and asserts the cell is unchanged.


The cell contract fixes the entry *shape* but never the entry *order*. For Track B that order is determined by the order Athena returns rows (the plan's query has no `ORDER BY`) combined with the direction of the Elixir accumulation, and today's reduce prepends (`clue.ex:174`, `[answer_row | Map.get(...)]`). Two runs of the same report over the same data can therefore emit `[Table, Dataflow, Drawing]` and `[Dataflow, Drawing, Table]` for the same learner's `other_tiles`.

Verified by throwaway execution: feeding the same three tiles through a prepending reduce in two different row orders produced `["Dataflow", "Drawing", "Table"]` and `["Table", "Dataflow", "Drawing"]`, not equal.

Track A is partly protected (one payload, so `answerTiles` arrive in document order) but only if the flatten preserves order across groups and the accumulation does not reverse it, which the plan does not say.

Why it matters on a researcher-facing report: cc-data is explicitly a consumer of these cells (the Round 3 render decision), and a report re-run to pick up new answers will show diffs in rows whose answers did not change, which is exactly the signal a researcher uses to find what changed. It also makes any XR4 assertion on cell contents order-dependent and therefore flaky, which will surface as intermittent CI failures blamed on the fixtures.

Suggested resolution: pin a deterministic entry order in the cell contract. Track A: document order as it appears in `answers[].answerTiles[]`, with the flatten and accumulation stated to preserve it (build with `Enum.reverse` at the end, or append). Track B: sort entries before encoding, by `type` then `link`, or add an explicit `ORDER BY` to the Track B CTE and preserve it through the reduce. Add an assertion for stable ordering to XR4 fixture 4.

**Verified**: implementation.md "Cell contract" and "Aggregation" sections (no ordering statement); implementation.md Track B CTE (no `ORDER BY`); `clue.ex:174` (prepending accumulation); throwaway Elixir run of a prepending reduce over two row orderings, cells not equal.

---

### Senior Engineer

#### RESOLVED: D4's override map is missing `AI`, a tile type that already exists in production data
**Resolution** (2026-08-04): accepted. Seeded the map as `%{"BARGRAPH" => "BarGraph", "AI" => "AI"}`, restated the rule in the code comment (compound names and acronyms need an entry, everything else derives), recorded `WAVERUNNER` as a watch item, and corrected the D4 verification note to say the derivation was checked against the full registered-type list rather than a sample.


D4 claims the derivation "produces the right answers for types that do not log yet: `GRAPH` -> `Graph`, `DATA_CARD` -> `DataCard`, `NUMBERLINE` -> `Numberline`, all matching CLUE's registered names." That is true for the three listed, but the sample is incomplete. Ran the pinned `tile_type_from_event/1` against **every** registered CLUE tile-type string:

| Event | Derived | Registered | |
|---|---|---|---|
| `AI_TOOL_CHANGE` | `Ai` | `AI` | **miss** |
| `BARGRAPH_TOOL_CHANGE` | `BarGraph` (override) | `BarGraph` | ok |
| `WAVERUNNER_TOOL_CHANGE` | `Waverunner` | `WaveRunner` | **miss** (only if CLUE names it without the underscore; `WAVE_RUNNER_TOOL_CHANGE` derives correctly) |

All fourteen others derive exactly, including `Diagram`, `Timeline`, `Expression`, `Image`, `Simulator`, so the six-of-seven claim for today's logging types is accurate and the derivation-first design is sound. The gap is that `AI` is not a speculative type: VR2 measured **97 entries across 11 distinct AI answer tiles** in production, so it is in active classroom use and is a plausible near-term DR3 candidate. When it starts logging, Track A cells will say `AI` and Track B cells will say `Ai` for the same tile type, which is precisely the cross-track inconsistency D4 exists to prevent, and it will ship silently because nothing errors.

Why it matters: the override map is described as holding "only genuine exceptions," and `AI` is one, discoverable today for the cost of one map entry. Waiting for it to appear in a report means a researcher sees two spellings first.

Suggested resolution: seed the map as `%{"BARGRAPH" => "BarGraph", "AI" => "AI"}`, and add a code comment stating the rule (acronyms and compound names need an entry; everything else derives). Optionally note `WAVERUNNER` as a watch item. Extend the D4 verification note to say the derivation was checked against the full registered-type list, not a sample.

**Verified**: throwaway Elixir run of the pinned `tile_type_from_event/1` over all registered tile-type strings; registered strings grepped from `collaborative-learning/src`: `ai-types.ts:1` (`kAITileType = "AI"`), `bar-graph-types.ts:1`, `data-card-types.ts:1`, `graph-types.ts:6`, `numberline-tile-constants.ts:1`, `iframe-interactive-tile-types.ts:1`, `wave-runner-types.ts:1`, `timeline-types.ts:3`, `diagram-types.ts:1`, `simulator-types.ts:1`, `image-content.ts:10`, `table-content.ts:26`, `text-content.ts:14`, `geometry-types.ts:3`; `logger-types.ts:36-43` (the seven events); VR2's production AI counts.

#### RESOLVED: D5's suppression is defeated unless the structure entry is also gated on survivors, and the natural code shape adds it first
**Resolution** (2026-08-04): accepted. Added **D5 rule 4** requiring the drop rules to run before the structure update, with the entry added on the first row that yields a survivor rather than the first row seen, and noting the same for `other_tiles`. Strengthened XR4 fixture 7 to assert **no column** is emitted, not merely no answer row, since the previous wording was satisfied by the broken implementation.


D5 rule 3 says an all-empty question emits no answer row, and a note adds that "a question keeps its column as long as any learner in the report contributes a surviving entry." That second sentence is the requirement, but nothing in the plan says how it is enforced, and the shape of the code it is being added to actively works against it.

In today's reduce the structure entry is added **unconditionally and first** (`clue.ex:121-137`: `new_question = not Map.has_key?(...)`, then `Map.put(question_id, %{type:, prompt:, required:})`), and the answer is built **afterwards** in a `with` whose `else -> row_acc.answers` drops it (`:147-178`). So the existing code already creates columns for rows that contribute no answer, and an implementer extending it in place inherits that ordering for free.

The consequence is that D5 does not achieve what QR6 asked for. A question whose answer tiles are all `Placeholder` or empty text still lands in `structure.questions` for every learner who touched it, and `shared_queries.ex:93` computes `num_questions = cardinality(questions)`, so it counts as a question for **every learner in the report** while contributing an answer to none. That inflates the denominator of `percent_complete` for the entire class, which is the specific distortion QR6 and the sharpened XR6 exist to remove. Given VR5's measurements (44% of Text entries empty, 208 `Placeholder` entries), questions that reduce to nothing for every learner are likely, not rare.

This is the same failure shape as VR9: the plan states the correct end state, the natural place to write the code produces a different one, and the difference is invisible in the output.

Suggested resolution: state explicitly that a Track A question's structure entry is added only when that row yields **at least one surviving entry** after D5's rules, so the drop check precedes the structure update rather than following it, and note that the same applies to the `other_tiles` entry (it must be added only if some learner has a surviving free-standing tile, which the plan already implies with "present whenever any learner ... has >= 1"). Add an XR4 assertion to fixture 7 that the suppressed question produces **no column**, not merely no answer row, since the current wording is satisfied by the broken version.

**Verified**: `clue.ex:121-137` (unconditional structure update), `:147-178` (`with`/`else` answer drop, ordered after); `shared_queries.ex:93` (`cardinality(questions) AS num_questions`), `:79` (`array_intersect(map_keys(kv1), map_keys(questions))` for `num_answers`), `:212-222` (columns emitted from `question_order` x `questions`); implementation.md D5 and the Structure table; requirements QR6, XR6, VR5.

---

### Product Manager

#### RESOLVED: filing the DR1 ticket is called a deliverable but has no step in the sequencing
**Resolution** (2026-08-04): accepted. Added as sequencing **step 0**, ahead of all code, with both required constraints stated inline and the linked ticket id as completion evidence. DR3's naming-convention requirement may ride the same ticket.


The Structure section states that "filing the DR1 ticket **is** a deliverable of this story, not a floating open item," and Open items repeats it, with a specific payload: the ticket must require a top-level `prompt` key in the event parameters and the `<TYPE>_TOOL_CHANGE` naming convention. The "Suggested sequencing" section then lists five steps, all code, and the ticket appears in neither.

Why it matters: the story ships an inert `$.prompt` lookup that is bound to a field name only that ticket pins. If the ticket is never filed, or is filed without both constraints, the failure mode is exactly the one the doc describes: headers stay on the `questionId` fallback, nothing errors, and the binding is discovered later by someone wondering why enrichment did not take effect. A deliverable that is stated only in prose is the one that gets dropped when the code steps are done and the story looks finished. It is also the item most likely to be blocked on someone else's availability, so it benefits from being started first rather than last.

Suggested resolution: add it as an explicit first sequencing step ("File the CLUE-side enrichment ticket, with both constraints stated"), and treat the linked ticket id as the completion evidence. Optionally fold DR3's naming-convention requirement into the same ticket, as Open items already contemplates.

**Verified**: implementation.md "Structure" (the `$.prompt` pinning and deliverable claim), "Suggested sequencing" (five code-only steps), "Open items"; requirements DR1 (same deliverable claim, 2026-08-04), and the still-open item 3 in the verification round ("DR1's CLUE-side enrichment ticket is still unfiled and unowned").

---

### Re-review after applying the seven findings (2026-08-04)

Re-read of the updated document. Two items, one editorial (fixed in place: the Track C CTE described itself as "verbatim" after D7 had changed its `FROM` clause, now reworded so "unchanged" refers to emitted rows and column keys rather than the source table). One substantive, below.

#### RESOLVED: D7 swaps the source table for a physically different copy of the data, and nothing yet proves the two are row-equivalent
**Resolution** (2026-08-04): measured, not deferred. **VR14** compared every CLUE row in both tables by year: **11,315,457 rows in `logs_by_app` against 11,315,463 in `logs_by_time`, a difference of 6 rows in 11.3 million (0.00005%)**, with identical backfill depth to 2018 and byte-identical counts in five of nine years. The one apparent gap (+/-106 at the 2023/2024 boundary) nets to zero and is year-attribution, not loss. D7 is safe as written; the residual 6-row head lag is noted in D7 and needs no handling for a report over completed classwork. No acceptance criterion is needed on sequencing step 1.


D7 is the largest change in this review and it was justified on partitioning and cost. Both are verified. What is **not** verified is that the two tables contain the same rows.

They are not two views over one dataset. Glue reports different `LOCATION`s: `logs_by_time` reads `s3://log-ingester-production/processed_logs_with_id/`, while `logs_by_app` and `logs_by_app_and_secure_key` both read `s3://log-ingester-production/logs_by_app_and_secure_key/`. So they are separate physical copies produced by the ingester, and a difference in backfill depth, retention, or ingest lag between them would silently change what the CLUE report returns. Under XR5 ("the report must work on logs already written") that is exactly the class of risk worth closing, and it is a risk this review introduced.

The available evidence is encouraging but circumstantial:

- `report_query.ex:100-121` already builds the **main** Athena log report on `logs_by_app_and_secure_key`, so it is trusted for a primary production surface, not a side table.
- VR13's full-corpus count on `logs_by_app` returned **1,220** learner/question pairs, against VR4's **1,208** measured on `logs_by_time` three days earlier. More, not fewer, so there is no sign of truncation, and the small delta is consistent with new data.
- VR12 returned plausible CLUE counts across all three tracks for a real class.

None of that is an equivalence proof, and the failure mode (older partitions absent from the app-partitioned copy) would not show up in either measurement, since both sampled recent data.

Suggested resolution: make a one-time equivalence check the acceptance criterion for sequencing step 1, before any Track A or Track B work builds on it. Compare, for a fixed set of secure keys spanning the **oldest** available CLUE data as well as recent data, the row counts and `min(time)`/`max(time)` per event between the two tables. If they diverge, D7 still stands for cost but needs a documented statement of which table is authoritative and from what date. Record the result as VR14 either way, so the table swap is backed by measurement rather than by inference from a `LOCATION` string.

**Verified**: `aws glue get-table` on all three tables (differing `LOCATION`s, `PartitionKeys` null for `logs_by_time`); `report_query.ex:100-121`; VR12 and VR13 measurements above; VR4's corpus counts in requirements.md.

---

## Self-Review, Round 2 (2026-08-04)

Second multi-role pass over this document, run after the seven Round 1 findings were applied. Roles: Data / Query Engineer, Performance Engineer, Senior Engineer, QA Engineer, Education Researcher. Each issue below was verified against current `report-service` and `collaborative-learning` source before being written, and four were verified by throwaway execution (`elixir` scripts and `mix run --no-start` against the real `SharedQueries.get_columns_for_question/5`). The "Verified" line records the check.

Four Round 1 claims were re-checked and **hold**, recorded so they are not re-litigated: (a) the `_ ->` fallback really does emit `res_1_q39487a59642d_json` with `header: activities_1.questions['…'].prompt` for both `clue_question` and `clue_tile`, byte-identical to a dedicated branch, so `shared_queries.ex` needs no change; (b) D1's hex encoding is order-preserving, so DR2's cross-report column order survives it (`sort` of the encoded keys decodes back to `sort` of the raw ids); (c) D4's derivation plus the two overrides reproduces all seven real `*_TOOL_CHANGE` types exactly, including `IFRAME_INTERACTIVE_TOOL_CHANGE -> IframeInteractive`, and the one non-tile event in the same enum family, `TEXT_LINK_DISPLAY_CHANGE` (`logger-types.ts:41`), does not match the Track B pattern; (d) `toolId` is present on every tile-change event and always equals `tileId` (`log-tile-change-event.ts:23`, `legacyChangeProps = { toolId: tileId, … }`), so Track B's `toolId` partition key is safe for all tile types, not just Text.

### Data / Query Engineer

#### RESOLVED: Track B's `containerIds` filter silently drops every tile-change event logged before 2025-05-07, which is more than 83% of the CLUE log history
**Resolution** (2026-08-04): accepted. The Track B CTE now pins `COALESCE(json_format(json_extract(parameters,'$.containerIds')), '[]') = '[]'`, with the reasoning stated inline rather than left as a comment-worthy aside, and the required code comment extended to record *why* a missing key means free-standing so the `COALESCE` is not later simplified away as dead defensive code. Added XR4 fixture 3b (an event with no `containerIds` key). Recorded as **VR15** in requirements.md, with the dating evidence, since this is a property of the log history that no source reading of `clue.ex` could reveal and that VR3's 2026 sample structurally could not see.

The Track B CTE pins the XR1 disjointness filter as `json_format(json_extract(parameters,'$.containerIds')) = '[]'` and dismisses null handling: "`containerIds` is present on every tile-change event (VR3), so no null branch is needed, though writing the predicate to treat a hypothetical null as 'free-standing' is harmless insurance."

It is not hypothetical and it is not insurance. `containerIds` was introduced by a single commit, `1efa1efb` **2025-05-07** ("Logging updates for moves and deletes"), which is the first appearance of the string anywhere in `collaborative-learning/src`. Every `*_TOOL_CHANGE` event logged before that release carries no `containerIds` key at all, so `json_extract` returns SQL `NULL`, `json_format(NULL)` is `NULL`, and `NULL = '[]'` evaluates to `NULL`, i.e. the row is dropped.

VR3's "never absent across 21,146 events" was measured on a 12-day window in 2026, so it samples only post-release data and cannot see this. VR14's own by-year row counts size the loss: 9,429,401 of 11,315,457 CLUE rows predate 2025 (83.3%), plus the January-to-early-May slice of 2025's 1,261,476. So for any report over a class from 2018 through April 2026, Track B returns **nothing**, while Track C (free-standing text, no `containerIds` filter) returns everything as usual. The report looks healthy and is silently missing its new column.

Why it matters: this is a direct XR5 failure ("the report must function on logs already written"), it is the single largest silent-loss surface left in the plan, and it is asymmetric in exactly the way that hides it, since the text columns a reviewer would eyeball keep working.

Treating a missing `containerIds` as free-standing is not merely safe here, it is **correct**, and the double-counting window it opens is two days wide: the Question tile landed 2025-03-20, `questionId` 2025-04-30, `QUESTION_ANSWERS_CHANGE` 2025-05-05 (`4c90c5ca`) and `containerIds` 2025-05-07, all pre-release per the resolved XR1 Open Question. Before 2025-03-20 no container tile type existed, so every tile in that history genuinely was free-standing.

Suggested resolution: write the filter as `COALESCE(json_format(json_extract(parameters,'$.containerIds')), '[]') = '[]'`, and change the accompanying code comment from "no null branch needed" to a statement of why null means free-standing (no container tile type existed before 2025-03-20; `containerIds` logging began 2025-05-07). Add an XR4 fixture carrying a `*_TOOL_CHANGE` event with **no** `containerIds` key, asserting it appears in `other_tiles`; that is the regression guard, and no fixture in the current list has it because every fixture is modelled on today's payloads.

**Verified**: `git log -S containerIds --reverse -- src/` in `collaborative-learning` returns exactly one commit, `1efa1efb` 2025-05-07; `log-tile-base-event.ts` `processTileBaseEventParams` sets `parameters.containerIds` unconditionally (hence VR3's zero nulls post-release) and `logAnswerChange` does **not** route `QUESTION_ANSWERS_CHANGE` through it; `git log --diff-filter=A -- src/models/tiles/question/` first commit 2025-03-20, `questionId` added 2025-04-30, `QUESTION_ANSWERS_CHANGE` commit `4c90c5ca` 2025-05-05; VR14's by-year table in requirements.md for the row split; Trino `NULL = '[]'` three-valued-logic semantics.

---

### Performance Engineer

#### RESOLVED: D7's cost case was measured at 40 learners, and D2's three-CTE shape multiplies the two things that scale with learner count
**Resolution** (2026-08-04): accepted, all three parts. D7's year floor is now **required** rather than an optional trim, derived from `year(min(created_at)) - 1` over the learners already in hand, with the wall-time table recorded in D7. D2 now pins a single `clue_logs` base CTE holding the learner predicates once, explicitly labelled as a fix for the query-text ceiling and explicitly **not** a scan reduction, since Trino inlines CTEs; the alternative single-scan shape (all three windows over one relation) is named and rejected as not worth the complexity once the floor is in. `Enum.uniq()` added to the endpoint list. Sequencing step 1 now lands the base CTE alongside the table move, so Track A and Track B are added to an existing base rather than retrofitted around three duplicated predicate blocks. Recorded as **VR16** in requirements.md. The byte-scan half of D7/VR12 is unchanged and was not reopened.

D7 and VR12 retire the byte-scan risk convincingly, and that conclusion holds. What does not hold is the generalization to report scale. Both remaining costs are linear in learner count, and D2's chosen query shape multiplies both by three.

**S3 prefix enumeration (wall time).** With `app` fixed and `secure_key` injected, Athena enumerates `1 x 37 years x 12 months x N secure_keys` prefixes. At N = 40 that is 17,760, reproducing VR12's measured "~17,700" exactly. Fitting VR12's own two timings (24.2 s unbounded, 17.5 s with `year >= 2025`) gives a 17.1 s fixed cost plus **0.399 ms per prefix**, and that two-parameter fit reproduces both measurements to the tenth of a second, so the model is calibrated rather than assumed. Enumeration is per table scan, and D2 pins three CTEs each with **its own `FROM`**, which Trino inlines rather than materializing, so the enumeration happens three times:

| learners | unbounded, 1 scan | unbounded, 3 scans | 2-year floor, 3 scans |
|---:|---:|---:|---:|
| 40 | 24 s (= VR12) | 38 s | 18 s |
| 300 | 70 s | 176 s | 26 s |
| 600 | 123 s | 336 s | 34 s |
| 1000 | 194 s | 548 s | 46 s |

So D7's residual, "measured 24.2 s unbounded against 17.5 s with `year >= 2025` … a year floor is an optional latency trim, not a correctness or cost requirement", understates it twice over: the 7 s is the 40-learner, single-scan figure, and the quantity it trims is 35 of the 37 projected years, which is the term that scales with the report. The year floor is the lever that matters, and it makes the three-scan multiplication irrelevant (rightmost column); without it, a 1,000-learner CLUE report spends roughly nine minutes on prefix listing alone, per runnable, inside `fetch_resource/3`.

**Query-string length.** Separately and by a different mechanism, D2's shape embeds the learner predicates once per CTE, so the endpoint list and the secure-key list each appear three times, against the endpoint list twice today. Measured by building the actual shape with real endpoint lengths and UUID secure keys against AWS's documented 262,144-byte DML query-string quota: today's query fits until about 1,311 learners, the three-CTE shape breaks at about **628**, and hoisting the learner predicates into one base CTE that the track CTEs select from pushes it to about 1,883. That fix is purely textual and works even though Trino inlines the CTE, because the quota applies to the submitted SQL string, not the plan.

Whether 628 learners is reachable is a real question rather than a rhetorical one: `group_learners_by_runnable_url` puts every learner sharing a runnable URL into one `fetch_resource` call, and a CLUE problem URL such as `?unit=m2s&problem=4.5` is the same URL for every class that assigns it, so a cohort- or project-scoped report aggregates across classes. Exceeding the quota is a hard Athena error and there is no learner cap anywhere in the path.

Why it matters: D7 closed the performance open item outright ("no per-runnable re-check needed") on a 40-learner measurement, and both residual costs are linear in learner count. Neither fix is speculative work: the year floor needs no new data, and the base CTE removes duplication rather than adding structure.

Suggested resolution: (1) make the year floor **required** rather than optional, derived from the learners already in hand (`learner_data.ex:186,188` carry `last_run` and `created_at`, so `year(min(created_at)) - 1` is a sound floor), and restate D7's residual as linear in learner count with the table above; (2) hoist `log.app = 'CLUE'`, `log.secure_key IN (…)`, `log.run_remote_endpoint IN (…)` and the year floor into one `clue_logs` base CTE that Track A/B/C select from, for the query-text ceiling, while noting explicitly that this does **not** reduce scans because Trino inlines CTEs (a genuine single-scan shape would mean computing all three tracks' `ROW_NUMBER` windows over one relation, which is possible but not worth the complexity once the floor is in); (3) add `Enum.uniq()` to the endpoint list, which today's `clue.ex:29` omits and `report_query.ex:104` has.

**Verified**: README `logs_by_app_and_secure_key` DDL (`projection.year.range` 2014-2050, `projection.month.range` 1-12, `projection.secure_key.type` injected, `projection.app.values` includes `CLUE`); `report_query.ex:100-121` (same table, same secure-key derivation, and `apply_date_range` at `:156-172` emits `log.year`/`log.month` predicates, so the repo's own precedent for this table does prune years); `clue.ex:29` (no `Enum.uniq`); `learner_data.ex:170-191` (learner maps carry `last_run` and `created_at` but not `secure_key`, so the `List.last(String.split(&1, "/"))` derivation is right); throwaway build of both query shapes over synthetic learners with real endpoint and UUID secure-key lengths (`job_test.exs:34,58` for the real shapes), byte-sized against the 262,144-byte quota; throwaway two-parameter fit of the wall-time model, reproducing both of VR12's timings to 0.1 s and the prefix count to VR12's "~17,700"; Trino's documented CTE inlining (the 262 KB quota is a limit on the submitted string, so the base-CTE fix is unaffected by inlining, while the scan count is not).

---

### Senior Engineer

#### RESOLVED: the planned Track A/Track B SQL cannot be written as shown, in two independent ways
**Resolution** (2026-08-04): accepted, both halves, and recorded as **VR17** in requirements.md with the confirming queries. The Track B predicate is now pinned as `regexp_like(log.event, '_TOOL_CHANGE$')`, which has no backslashes or quotes to escape, with the heredoc corruption recorded as the reason and "deleting the `ESCAPE` clause is not a valid simplification" stated explicitly, since that is the path that turns a loud failure into a silent semantic change. D3 now pins `json_format(json_extract(parameters,'$.answers'))` and D2 pins `CAST(NULL AS VARCHAR)` for padded columns. BR4's Track B guidance in requirements.md was updated too, since it named the `LIKE` form specifically. Both halves are confirmed live (four literal-only Athena queries, 0 bytes scanned): the union raises `TYPE_MISMATCH: ... incompatible types: json, varchar`, `json_format` fixes it, `ESCAPE ''` is rejected with `Escape string must be a single character`, and `regexp_like` matches the correctly-escaped `LIKE` on every probe while the corrupted form additionally matches `XTOOLYCHANGE`.

Two literal-level defects in the pinned SQL. Neither is a design flaw, both cost implementation time, and one of them fails silently if half-fixed.

**1. The `LIKE` predicate does not survive an Elixir heredoc.** The plan pins `event LIKE '%\_TOOL\_CHANGE' ESCAPE '\'`. Written into `get_text_tile_answer_sql/1`'s `"""` heredoc as shown, Elixir emits:

```
AND log.event LIKE '%_TOOL_CHANGE' ESCAPE ''
```

Two separate corruptions, **with no compiler warning**: `\_` loses its backslash (so the underscores revert to single-character wildcards), and `\'` is a valid Elixir escape for `'`, so `ESCAPE '\'` becomes an empty escape string, which Trino rejects outright. The empty `ESCAPE` is at least loud; the half-fix is not. An implementer who sees the Trino error and deletes the `ESCAPE` clause is left with `LIKE '%_TOOL_CHANGE'`, which compiles, runs, and quietly means something else.

**2. Track A's `answers` column and Track C's `text_value` column cannot be unioned as written.** D3 selects `json_extract(parameters,'$.answers')`, which is Trino type `json`; Track C selects `json_extract_scalar(…)`, which is `varchar`. Trino does not implicitly coerce `json` to `varchar` in a `UNION`, so D2's union fails with an incompatible-types error unless the Track A value is wrapped in `json_format(...)` or cast explicitly. The same applies to any `NULL`-padded column in the union that never gets a concrete type on either side.

Why it matters: D2 and D3 are the two decisions the whole query rests on, and the document presents both as settled with a pinned expression. VR1 verified `json_extract(parameters,'$.answers')` in isolation, against a literal, not inside a union with the varchar tracks, so nothing measured so far would have caught either item.

Suggested resolution: for the pattern match, either double the backslashes (`'%\\_TOOL\\_CHANGE' ESCAPE '\\'`), use `~S"""` for the SQL heredoc, or sidestep SQL-string escaping entirely with `regexp_like(log.event, '_TOOL_CHANGE$')`, which needs no backslashes and reads more clearly; whichever is chosen, state it in the plan as the literal to write, and note that dropping `ESCAPE` is not a valid simplification. For the union, wrap Track A's answers value in `json_format(...)` so every branch is `varchar`, and `CAST(NULL AS VARCHAR)` the padded columns. Both are worth one confirming Athena query before step 3 starts.

**Verified**: throwaway `elixir` run of the three heredoc forms, printing `"  AND log.event LIKE '%_TOOL_CHANGE' ESCAPE ''\n"` for the form the plan shows and the intended string for the doubled and `~S` forms, with no warning emitted; `clue.ex:42-72` (the SQL is built in a `"""` heredoc); implementation.md D2 (union of three CTEs), D3 (`json_extract(parameters,'$.answers')`), Track C CTE (`json_extract_scalar`); the `json`/`varchar` union incompatibility and its `json_format` fix, both executed against Athena (engine v3, 0 bytes scanned).

#### RESOLVED: the Track A prompt header is fixed by whichever CSV row arrives first, so DR1's enrichment lands nondeterministically
**Resolution** (2026-08-04): accepted. The Structure section now requires the stored prompt to be **upgraded**, not only created: a row carrying a non-empty `$.prompt` replaces a stored `questionId` fallback, making the header a deterministic function of the data rather than of Athena's row delivery. D5 rule 4 now says explicitly that "added on the first row with a survivor" governs the entry's *existence* and not its field values, since that rule is what would otherwise be read as write-once. XR4 fixture 1 extended: two learners on one `questionId`, one row with `$.prompt` and one without, fed in both orders, asserting the enriched header both times. Recorded as **VR18** in requirements.md and threaded into QR1 and DR1.

The Structure section pins the header as "enriched prompt when present, else raw `questionId`", and D5 rule 4 pins *when* the structure entry is created (the first row that yields a surviving entry). Neither says what happens when different rows for the **same** `questionId` disagree about the prompt, and today's code shape decides it by row order: `new_question = not Map.has_key?(row_acc.structure.questions, question_id)` and the entry is written only when new (`clue.ex:121-131`), never revisited.

That disagreement is the normal state during and after the DR1 rollout, not an edge case. `structure.questions` is a single global map reduced over every learner's rows, and each learner's row carries their own latest `QUESTION_ANSWERS_CHANGE`. A learner whose last answer to a question predates the enrichment deploy contributes a row with no `$.prompt`; a learner who answered after it contributes one with the prompt. Whichever the CSV happens to deliver first wins for the whole column, and the query has no `ORDER BY`, so it can differ between two runs of the same report over unchanged data. It also persists indefinitely: a student who answered once before the deploy and never returned keeps a prompt-less latest event forever, so a long-running class can hold both shapes for the same question permanently.

Why it matters: DR1's payoff is the enriched header, filing its ticket is sequencing step 0, and the plan calls the `$.prompt` lookup "starts working with no report-service change the day CLUE ships it". As written it starts working *probabilistically* per question, and the failure presents as "the enrichment only took effect on some columns", which reads as a CLUE-side bug rather than a report-service one. It is also the header analogue of the entry-order nondeterminism the Round 1 Education Researcher finding fixed for cells, and it makes header assertions in XR4 order-dependent.

Suggested resolution: state that the structure entry's `prompt` is upgraded, not just created: when a row carries a non-empty `$.prompt` and the stored prompt for that key is still the `questionId` fallback, replace it. That is one extra branch in the same `if new_question` region and makes the header a deterministic function of the data (prompt if **any** contributing row has one) rather than of row delivery order. Add an XR4 assertion with two learners on one `questionId`, one row with `$.prompt` and one without, fed in both orders, asserting the enriched prompt both times.

**Verified**: `clue.ex:121-131` (structure entry written only when `new_question`, never updated), `:104-193` (one global `structure` reduced over all learners' rows), `:190-193` (no ordering applied to the source rows); implementation.md Structure section and D5 rule 4 (neither addresses conflicting prompts); `shared_queries.ex` `prompt_header = "activities_1.questions['<key>'].prompt"`, confirmed by `mix run --no-start` against the real `get_columns_for_question/5`, so the single structure entry is the sole source of the header.

#### RESOLVED (partly accepted, partly noted): three key families share one namespace, and `other_tiles` is reachable from a tile title
**Resolution** (2026-08-04): split by cost/benefit rather than accepted wholesale, and recorded as **VR19**. Accepted and pinned: (a) `other_tiles` is a **reserved** key, with Track C disambiguating when `make_safe_id(tile_title)` produces it, which does not breach BR1 since that case is broken today rather than working; (b) `other_tiles` enters `questions` inside the reduce but `question_order` only in D6's post-sort step, with `has_other_tiles?` defined as `Map.has_key?(structure.questions, "other_tiles")`, since adding it in both places duplicates the column. XR4 fixture 5 extended with the reserved-key case. **Noted but not guarded:** the `q`-prefix collision between `make_safe_id` on a digit-leading title and D1's hex keys is real but requires a tile titled with the exact hex of a `questionId` in the same report, and no `[a-z0-9_]` key scheme can be made collision-proof against a lossy transform over arbitrary titles, so writing code for it buys nothing the reserved-key check does not.

D1 makes Track A keys collision-free *within* Track A, and the `other_tiles` key is stated as canonical, but nothing states that the three key families (Track A hex keys, Track B's reserved `other_tiles`, Track C's `make_safe_id(tile_title)`) share a single flat namespace whose collisions are silent. Two concrete collisions exist:

- `make_safe_id("Other Tiles")`, `make_safe_id("other tiles")`, `make_safe_id("other-tiles")` and `make_safe_id("OTHER_TILES")` all return exactly `"other_tiles"`. A free-standing text tile titled any of those collides with the reserved Track B key. The consequences are two silent failures at once: the structure entry keeps whichever `type` was written first, so if `clue_text_tile` wins, the `other_tiles` cell is read as `json_extract_scalar(answer,'$.text')` against a JSON array and comes back NULL; and both tracks write answer rows under one key, which is the `map_agg` duplicate case VR6 pinned as a silent drop.
- Less plausibly but by the same mechanism, `make_safe_id` prepends `q` to a leading digit (`clue.ex:218`), which is D1's own prefix, so `make_safe_id("39487a59642d") == question_key("9HzYd-") == "q39487a59642d"`.

A related sequencing trap sits next to this. The structure contract says a column exists only if the key is in **both** `question_order` and `questions`, and D5 rule 4 says the `other_tiles` structure entry is added when the first learner contributes a survivor, which invites adding it to both inside the reduce. D6 then prepends `other_tiles` to the sorted order unconditionally. Doing both duplicates the key, and `question_order` is iterated directly to build columns, so the report emits `res_1_other_tiles_json` twice. Verified by running the real column builder over a `question_order` containing the key twice.

Why it matters: neither item is likely, and the second collision is negligible, but "Other Tiles" is a title a student or teacher could plausibly type in a CLUE document, the consequence is silent in both directions, and the guard costs a few lines. The duplicate-key trap is the same shape as VR9 and D5 rule 4, which the document already treats as worth pinning explicitly.

Suggested resolution: state that `other_tiles` is a **reserved** key, and that Track C disambiguates when `make_safe_id(tile_title)` produces it (for example by suffixing), which does not violate BR1 since the colliding case is broken today rather than working; and state explicitly that `other_tiles` goes into `questions` inside the reduce but into `question_order` **only** in D6's post-sort step, so the two rules do not both add it. Add the collision to XR4 fixture 5, which already covers key sanitization.

**Verified**: throwaway `elixir` run of `make_safe_id/1` copied verbatim from `clue.ex:214-219` over the four title spellings and the digit-leading case, plus `question_key/1` from D1; `clue.ex:121-137` (first-writer-wins structure entry); `shared_queries.ex` column emission driven by `question_order`, confirmed by `mix run --no-start`: a `question_order` of `["other_tiles","abc_text","other_tiles"]` emits `res_1_other_tiles_json` twice; VR6 (silent `map_agg` duplicate drop).

---

### Education Researcher

#### RESOLVED: the VR13 `documentKey` fix reintroduces the nondeterministic cell order the cell contract was written to remove
**Resolution** (2026-08-04): accepted. The cell contract's Track A bullet now pins cross-payload order as ascending `documentKey`, implemented as an Elixir-side sort of a question's rows before flattening rather than an `ORDER BY` in the CTE, consistent with the reasoning the section already gives for Track B. XR4 fixture 2b now feeds its two documents' rows in both orders and asserts the same cell, mirroring fixture 4. Recorded as **VR20** in requirements.md. Volume is small (VR13's 15 of 1,220 pairs) but the fix is one clause and the affected fixture would otherwise flake.

Both changes landed in the same Round 1 pass and they interact. The cell contract pins Track A entry order as "document order, as the tiles appear in `answers[].answerTiles[]`, flattened across groups in payload order", which is well defined for **one** payload. The VR13 fix then adds `documentKey` to the Track A partition precisely so that one `{learner, questionId}` yields **more than one** row, each its own payload, merged Elixir-side into one entry list.

Order *across* those payloads is unpinned. It is decided by the order Athena delivers the rows, and the query has no `ORDER BY`, so the 15 of 1,220 learner/question pairs VR13 measured (14 spanning two documents, 1 spanning three) get a cell whose entry order can differ between two runs of the same report over unchanged data. That is exactly the diff-noise failure the cell-contract rule exists to remove, and XR4 fixture 2b, added as the VR13 regression guard, is the test that would flake on it.

Why it matters: it is small in volume and invisible in kind, and it undoes for 1.2% of pairs the determinism guarantee the document now states unconditionally. The fix is one clause.

Suggested resolution: extend the Track A half of the cell contract to pin the cross-document order, for example "payload groups in ascending `documentKey` order, entries within a payload in `answerTiles` document order", implemented either as an `ORDER BY documentKey` in the Track A CTE or by sorting a question's rows by `documentKey` before flattening. Say so in XR4 fixture 2b, and feed its two documents' rows in both orders asserting the same cell, mirroring what fixture 4 already does for Track B.

**Verified**: implementation.md "Cell contract" Track A bullet (order pinned within a payload only), Track A CTE (partition includes `documentKey`, no `ORDER BY` anywhere in the query), XR4 fixture 2b; VR13's measured 14-plus-1 multi-document pairs; `clue.ex:110-188` (single reduce over CSV rows in delivery order).

---

### QA Engineer

#### RESOLVED: the testability seam is sequenced after the code it needs to test, contradicting the step it enables
**Resolution** (2026-08-04): accepted. The seam moved to **step 2**, after the D7/base-CTE table move and ahead of the pure functions and both tracks, and the steps were renumbered (Track A is now 4, Track B 5, XR2 6, tests 7). The tests step's "grow alongside" note is restated against the new order rather than deleted, since with the seam at step 2 it is now true. Stale step references were updated across both documents. Recorded as **VR21** in requirements.md, and XR4's pointer in requirements.md now names step 2.

Sequencing step 6 is the testability seam and step 7 is fixtures and tests, with the note "though in practice these grow alongside 3 and 4". Those two statements cannot both be true. Steps 3 (Track A) and 4 (Track B) are where the answer-row behaviour is written, and the Tests section states that answer-row assertions are unobservable until step 6 lands: "Nothing on this path is currently reachable from a test." So tests cannot grow alongside 3 and 4 while the seam sits at 6.

The document already diagnoses the consequence in the QA resolution it wrote last round ("the most likely outcome under time pressure is that the structure-only assertions get written and the answer-row assertions ... get dropped") and then leaves the ordering that produces it. Step 6 is also independent of every feature step: routing `AthenaDB` through the `Application.get_env(:report_server, :athena_db, AthenaDB)` seam (including inside `AthenaQueryPoller`, which calls `AthenaDB.get_query_info/1` directly), routing the CSV read through the `aws_file_store` seam, and making the parquet write injectable are all mechanical and touch no track logic. It can move ahead of step 3 with no reordering cost, and doing so is what makes "tests grow alongside" achievable rather than aspirational.

Why it matters: this is the one finding in this round about the plan's own execution rather than its content, and it is the cheapest to fix: renumbering. Every silent-loss guard in the plan (QR6 suppression, the `map_agg` duplicate, the VR2 track boundary, the VR13 two-document case, and now the pre-2025 `containerIds` case) lives in the answer-row group.

Suggested resolution: move the testability seam ahead of Track A, so the order runs step 0 (DR1 ticket), D7 table move, key encoding plus `tile_type_from_event`, **seam**, Track A, Track B, XR2 plus rename, with fixtures growing alongside the two track steps as the plan intends. Delete the "alongside 3 and 4" caveat or restate it against the new numbering.

**Verified**: implementation.md "Suggested sequencing" steps 6 and 7 and the Tests-section split into structure and answer-row assertions; `clue.ex:14-26` (`fetch_resource/3` returns `%{"denormalized" => data.structure}` only), `:28-37` (direct `AthenaDB.query`), `:98` (direct `Aws.get_file_stream`), `:196-204` (unconditional S3 parquet write); `athena_query_poller.ex:12` (direct `AthenaDB.get_query_info`); `resource_data.ex:67` (`defp athena_db()` seam) and `jobs_file.ex:4` (`aws_file_store` seam) as the existing patterns.

---

### Re-review after applying the seven Round 2 findings (2026-08-04)

Re-read of the updated document. Two items fixed in place as editorial: D7 now states that the year floor is derived from **this report's own learners**, so it cannot undermine XR5 (a 2019 class yields a 2018 floor and its own history stays in scope), and the floor's one-year slack is now justified by VR14's observed year-attribution drift as well as clock skew. One substantive item, below, and it is an error in a table this round introduced.

#### RESOLVED: the scan-count multiplier is four, not three, because Track C's self-join references the base CTE twice
**Resolution** (2026-08-04): accepted, and fixed by removing the fourth reference rather than by restating the number. Track C now uses the same `ROW_NUMBER` window as Track A and Track B, so `clue_logs` is inlined three times and the three-scan column is correct as written; D7 and the Track C CTE both state the accounting explicitly, including what keeping the self-join would have cost, so the figure cannot go silently wrong again. Side benefit: VR3's duplicate-`time` tie is retired at the source for Track C instead of relying on `map_agg` to collapse it, and all three tracks are one shape. Recorded as **VR22** in requirements.md, with the BR1 reading spelled out (rows are identical after aggregation, so "unchanged" is not breached).

VR16's wall-time table and D7's residual both use "3 scans" for the shipping shape, on the reasoning that Trino inlines `clue_logs` at each of its three track references. The count is wrong: Track C keeps today's `MAX(time)` self-join, which means Track C alone references the base relation **twice** (once for `last_changes`, once for the main select it joins back to). So the shipping shape inlines `clue_logs` four times, and every figure in the three-scan column understates by a third (a 1,000-learner unbounded report is about 12 minutes of prefix listing rather than nine).

The conclusion the table was written to support is unaffected, since the year floor still collapses the whole term, but a stated multiplier that is wrong by a third invites someone to re-derive it later and distrust the rest.

There is also a free improvement sitting next to it. The plan keeps Track C's `MAX(time)` self-join deliberately, arguing BR1 requires that path unchanged and that VR3's duplicate-`time` rows are inert there because `map_agg` collapses the duplicate. Both are true, but switching Track C to the **same `ROW_NUMBER` window Track A and Track B already use** removes one of the four references, removes the tie duplicate rather than relying on a downstream collapse, and makes all three tracks one shape. It does not breach BR1, whose guarantee is about emitted columns and rows: after aggregation the rows are identical, since the only difference is tie duplicates that `map_agg` was discarding anyway. That is the same reading of "unchanged" the document already applied when D7 moved Track C's `FROM` clause.

Suggested resolution: correct the multiplier to four in D7 and VR16, and switch Track C to the `ROW_NUMBER` window, bringing it back to three with the tie risk retired as a side effect. If Track C's self-join is kept instead, say explicitly that the shape costs a fourth inlining so the number is not silently wrong again.

**Verified**: implementation.md D2 (`clue_logs` referenced by three track CTEs), Track C CTE ("keep the existing `MAX(time)` self-join"), `clue.ex:43-53` (`last_changes` CTE) and `:61-64` (the main select joining back to it, i.e. two references to the source relation); Trino's documented CTE inlining; VR16's table and D7's residual table (both stated as three scans).

---

## Open items

- **DR1** (CLUE prompt enrichment) and **DR3** (tile-change logging for the silent types) are cross-repo, new-data-only, and **not dependencies** of this story. Filing the DR1 ticket **is** a deliverable of this story, because the inert `$.prompt` lookup shipping here binds to the field name it specifies (see the Structure section); the same ticket, or DR3's, must also require the `<TYPE>_TOOL_CHANGE` naming convention so BR4's discovery absorbs new tile logging with no report-service change.
- ~~**Performance** at report scale is measured but not final: Track A scanned ~25 MB over a 12-day window against ~489 MB for the tile-change filter (VR8), so Track B's broadening is the cost centre. Re-check per-runnable during implementation.~~ **Closed 2026-08-04 by D7/VR12.** The cost was the table, not the filter: `logs_by_time` has no partitions and today's query has no time bound. On `logs_by_app_and_secure_key`, the full three-track predicate over all history for 40 learners scans **0.67 MB**, so Track B's broadening is no longer a cost centre and needs no per-runnable re-check. **Amended 2026-08-04 by VR16:** the byte half stays closed, but the two residual costs that are linear in learner count (prefix-enumeration wall time, and SQL string length against Athena's 262 KB quota) are now designed for rather than deferred, via D7's required year floor and D2's shared base CTE.
- ~~**XR2 label format** is easily adjustable and not worth blocking on.~~ **Closed 2026-08-04:** the format and its fallback chain are pinned in the XR2 section above (three cases, no runnable-URL fallback) and covered by tests, since it was otherwise the only changed behavior with no regression guard.
