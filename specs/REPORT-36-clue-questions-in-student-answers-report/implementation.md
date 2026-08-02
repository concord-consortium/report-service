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
defp question_key(question_id), do: "q" <> Base.encode16(question_id, case: :lower)
```

`"9HzYd-"` -> `q39487a59642d` -> column `res_1_q39487a59642d_json`.

Satisfies all three constraints simultaneously: alias-safe (leading letter, only `[a-z0-9]`, verified necessary by VR7 since `res_1_9HzYd-_json` is a Presto syntax error), collision-free (hex is injective, so the `make_safe_id` folding risk cannot occur even as the corpus grows past today's 193 ids), and a **deterministic function of `questionId`** as Round 3 requires for cross-report column-order stability. Reversibility is a free bonus for debugging: `Base.decode16!(key, case: :lower)` recovers the raw id.

**Do not** use `make_safe_id/1` for Track A (lossy, folds case and `-`/`_`), and **do not** assign run-local surrogates like `q1`, `q2` (breaks cross-report ordering, explicitly rejected by Round 3).

Doubling the key length is acceptable: 6-char ids become 13-char keys, so `res_1_<key>_json` stays around 25 characters.

### D2: one Athena query with `UNION ALL`, not two round trips

Track A and Track B are computed as separate CTEs and combined with `UNION ALL` under a `track` discriminator column, so `fetch_resource/3` keeps a **single** `AthenaDB.query` + `AthenaQueryPoller.wait_for` cycle and a single CSV parse. Two sequential queries would double per-runnable Athena startup latency for no benefit, and this path already runs once per CLUE runnable during resource fetch.

The two selects have different natural columns, so the union pads: columns absent for a track are selected as `NULL`. See the row contract in "Query" below.

### D3: flatten `answers` in Elixir, not in SQL

Per VR1, `$.answers[*].answerTiles[*]` does not run on Athena engine v3. The query selects the whole `$.answers` value as one string column and `clue.ex` decodes it with `Jason` and flattens across groups. The SQL-side `CAST(... AS ARRAY(ROW(...)))` + double `UNNEST` alternative is verified working but rejected here: the single-value-per-key constraint already forces Elixir-side aggregation, so SQL-side flattening would just have to be re-grouped in Elixir anyway, and it hardcodes the payload shape into the SQL where a CLUE change would break it silently.

### D4: tile type labels come from a known-casing map with a title-case fallback

Required by BR4, because tile-change events carry no type field (VR10) and the set of logging types is expected to grow (DR3).

Derivation is the primary mechanism and the override table holds only genuine exceptions:

```elixir
## CLUE registers compound tile types as e.g. "BarGraph"; the event name flattens
## that to BARGRAPH, which no case rule can recover. Everything else derives cleanly.
@tile_type_overrides %{"BARGRAPH" => "BarGraph"}

defp tile_type_from_event(event) do
  stem = String.replace_suffix(event, "_TOOL_CHANGE", "")
  Map.get_lazy(@tile_type_overrides, stem, fn ->
    stem |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end)
end
```

Verified against CLUE's registered tile-type strings: the derivation reproduces **six of the seven** exactly (`Geometry`, `Drawing`, `Table`, `Text`, `Dataflow`, and `IFRAME_INTERACTIVE` -> `IframeInteractive`), and only `BARGRAPH` -> `Bargraph` misses, because the registered name `BarGraph` is a compound the uppercased event name has flattened beyond recovery. It also produces the right answers for types that do not log yet: `GRAPH` -> `Graph`, `DATA_CARD` -> `DataCard`, `NUMBERLINE` -> `Numberline`, all matching CLUE's registered names.

This matters because it makes adaptivity the default rather than something maintained. A new logging tile type gets a correct label with **no code change at all**, and the override map only grows for compound names. Casing consistency with Track A is the point: Track A takes `type` verbatim from the payload as the registered string, so a Track B label of `"Bargraph"` would render the same tile type two ways in the JSON cells that cc-data queries. An unrecognized event must always fall through and appear, never be dropped and never raise.

### D5: empty answers are suppressed before they reach parquet (QR6)

Applied in this order when building a Track A question's entry list:

1. Drop any answer tile whose `type` is `"Placeholder"` (147 distinct tiles across 81 documents in production).
2. For `Text` tiles, drop the entry when `plainText` is nil, `""`, or trims to `""` (44% of Text entries).
3. If the surviving list is **empty**, emit **no answer row** for that (student, question), and do not count it. Do not emit `[]`.

Rule 3 is what keeps `num_answers` honest: an emitted row counts as an answer in the shared completion counters (XR6) whether or not it has content.

Note rules 1-2 apply to *entries*; a question keeps its column as long as any learner in the report contributes a surviving entry, since the structure is a union across learners.

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

## Changes by file

### `server/lib/report_server/clue.ex` (primary, no shared blast radius)

**Query** (`get_text_tile_answer_sql/1`, currently `:39-73`). Rename to reflect its widened role and restructure into three CTEs unioned into one result set.

*Track A CTE.* Filter `event = 'QUESTION_ANSWERS_CHANGE'`, `run_remote_endpoint IN (…)`. Select the latest event per learner **per question** with

```sql
ROW_NUMBER() OVER (PARTITION BY run_remote_endpoint, json_extract_scalar(parameters,'$.questionId') ORDER BY time DESC) AS rn
```

and keep `rn = 1`. Partitioning on `run_remote_endpoint` is mandatory (VR4 measured up to **33 learners sharing one `questionId`**; `MAX(time) GROUP BY questionId` would keep one and silently drop 32). The window also resolves the real duplicate-timestamp rows observed in production (VR3). Do **not** apply an `operation = 'update'` filter: `QUESTION_ANSWERS_CHANGE` has no `operation` field.

Selected columns: `username`, `questionId`, `json_extract(parameters,'$.answers')` as a raw JSON string, `documentKey`, `documentHistoryId`.

*Track B CTE.* Filter `event LIKE '%\_TOOL\_CHANGE' ESCAPE '\'` **excluding** `TEXT_TOOL_CHANGE`, plus the XR1 disjointness filter `json_format(json_extract(parameters,'$.containerIds')) = '[]'`. Never an `IN (…)` list of event names (BR4). `containerIds` is present on every tile-change event (VR3), so no null branch is needed, though writing the predicate to treat a hypothetical null as "free-standing" is harmless insurance. Latest-per-tile keeps today's `toolId` grouping, which is safe because `toolId` is a globally-unique `nanoid(16)`. Carry `event` through so the type label can be derived (D4).

*Track C CTE (unchanged behavior).* Today's `TEXT_TOOL_CHANGE` query, verbatim, for BR1's free-standing text columns. Keep the `tileTitle` null/empty/`<no title>` guards and the `operation = 'update'` filter exactly as they are.

Union the three with a `track` discriminator (`'A'`, `'B'`, `'C'`) and `NULL`-padded columns.

**Add a code comment** at the `containerIds` filter recording the "Question is currently the only container tile type" assumption, so a future container type triggers a re-read (required by the resolved XR1 decision).

**Parsing** (`parse_text_tile_answer_csv/3`, currently `:104-210`). Branch on `track`:

- *Track C* keeps the existing path untouched, including the Slate `Jason.decode` + `extract_text` handling and `make_safe_id(tile_title)` keys. **Do not** fold `toolId` into that key (BR3 is deferred; doing so renames every existing column and breaks BR1).
- *Track A* decodes the raw `$.answers` string with `Jason.decode`, flattens `answers[].answerTiles[]` across groups, applies D5's drop rules, maps each survivor to `{"type", "text"?, "link"}`, and accumulates **one** entry list per `{username, question_key}`. **`plainText` is consumed verbatim** and must not be routed through the Slate `extract_text` path, whose `else -> row_acc.answers` fallback would silently drop every Track A text answer.
- *Track B* maps each row to `{"type" => tile_type_from_event(event), "link" => history_link}` and accumulates all of a learner's entries under the single `other_tiles` key.

**Aggregation.** Track A and Track B both need many tiles under one key, which the per-tile write pattern cannot express: `map_agg` allows one value per key and on engine v3 **silently drops** duplicates (VR6). So accumulate entry lists in the reduce and `Jason.encode` **one** answer row per `{username, key}` before the parquet write.

**Structure.** Add matching `questions` + `question_order` entries, since a column exists only if the key is in both (`shared_queries.ex:218-219`):

| Track | Key | `type` | `prompt` |
|---|---|---|---|
| A | `question_key(questionId)` (D1) | `clue_question` | enriched prompt when present, else raw `questionId` (QR1/DR2) |
| B | `other_tiles` | `clue_tile` | `Other tiles` |
| C | `make_safe_id(tile_title)` | `clue_text_tile` (unchanged) | tile title |

All `required: false`. The Track A prompt reads an enrichment field that does not exist yet (DR1, zero occurrences in production per VR4), so write the lookup now with the `questionId` fallback and it starts working when CLUE ships the change.

**Ordering.** D6.

**XR2**, `clue.ex:20`. Replace `"Test Clue"` by parsing `unit` and `problem` from the runnable URL into e.g. `"CLUE m2s: Problem 4.5"`, falling back to `"CLUE"` then the runnable URL. No unit-code lookup table.

**Housekeeping.** `clue.ex:139` rebinds the local `url` to the history link inside the reduce, so `resource_url: url` at `:160` writes the history link into the parquet's `resource_url` column. This is latent rather than breaking, because the report takes `resource_url` from the learners table (`runnable_url as resource_url`, `shared_queries.ex:78`) and not from the answers parquet. Rename the local to `history_url` while touching this function so Track A and Track B do not propagate the confusion.

### `server/lib/report_server/reports/athena/shared_queries.ex` (shared, additive only)

Add two branches to `get_columns_for_question/5` (`:390`), beside the existing `clue_text_tile` branch:

```elixir
"clue_question" -> [%{name: "#{column_prefix}_json", value: answer, header: prompt_header}]
"clue_tile"     -> [%{name: "#{column_prefix}_json", value: answer, header: prompt_header}]
```

Both mirror the existing `_ ->` fallback shape (`:491-494`) with a prompt header added, emitting a **single** column carrying the JSON array verbatim rather than `json_extract_scalar`-ed `_text`/`_url` sub-columns. `res_<n>_<key>_json` is the committed contract for cc-data and tests. The legacy `_text`/`_url` pair stays for Track C only.

XR3 holds by construction: non-CLUE data can never carry these types, so no existing branch changes. `get_columns_for_question/5` is called only under `if report_type == :answers` (`:210`), so usage reports never reach the new branches.

### Not changed

`reports/clue/history_link.ex`, the parquet writer and `partitioned-answers` layout, `resource_data.ex`, and the downstream report SQL.

## Cell contract

Uniform across Track A and Track B, for cc-data SQL consumption:

```json
[
  {"type": "Text",    "text": "the student's answer", "link": "https://…historyId=…"},
  {"type": "Drawing", "link": "https://…historyId=…"}
]
```

`type` always present. `text` only for Text tiles with surviving content. `link` carried **per entry** in both tracks: Track A repeats the question's single link on each entry (harmless redundancy) so cc-data has exactly one parsing pattern.

## Tests (XR4)

No test exercises `clue.ex`'s query path or the `clue_text_tile` branch today, and every existing fixture is `TEXT_TOOL_CHANGE`-only, so **fixture construction is the bulk of this work**, not a tail task.

Fixtures must carry nested `QUESTION_ANSWERS_CHANGE` payloads, `containerIds`, and non-text `*_TOOL_CHANGE` events, covering:

1. **AC1 alignment** with **at least two learners sharing one `questionId`**, the regression guard for the partition trap.
2. **AC2 copies**: within-document (new id, distinct question) and across-document (preserved id, aggregated).
3. **XR1 disjointness** via non-empty `containerIds`.
4. **Multi-tile aggregation** for a Track A question and for `other_tiles`, asserting one row per (student, key).
5. **Key sanitization**: a hyphenated `questionId`, plus two ids differing only by case or `-`/`_`, asserting distinct columns.
6. **Special characters** in `plainText` (embedded quotes, commas, newlines). Regression guard rather than live risk: verified surviving `json_extract_scalar` byte-identical (VR1).
7. **QR6**: a `Placeholder`-only question and an empty/whitespace Text question, both asserting **no answer row is emitted**.
8. **BR4 adaptivity**: a synthetic `GRAPH_TOOL_CHANGE` fixture (an event the code has never seen) asserting it appears as `"Graph"` in `other_tiles`. This is the test that stops the six types getting hardwired.

Plus direct **answers-path** query-generation tests for the two new `shared_queries` branches, with usage-report tests as broad smoke coverage only.

## Suggested sequencing

Each step should be independently reviewable:

1. Key encoding (D1) + `tile_type_from_event` (D4) with unit tests. Pure functions, no query changes.
2. Track A: query CTE, parsing, structure entries, aggregation. The bulk of the value.
3. Track B: query broadening, `containerIds` filter, `other_tiles` synthesis, D6 ordering.
4. `shared_queries` branches, plus XR2 and the `history_url` rename.
5. Fixtures and tests, though in practice these grow alongside 2 and 3.

## Open items

- **DR1** (CLUE prompt enrichment) and **DR3** (tile-change logging for the silent types) are cross-repo, new-data-only, and **not dependencies**. DR3 should specify the `<TYPE>_TOOL_CHANGE` naming convention so BR4's discovery absorbs it with no report-service change.
- **Performance** at report scale is measured but not final: Track A scanned ~25 MB over a 12-day window against ~489 MB for the tile-change filter (VR8), so Track B's broadening is the cost centre. Re-check per-runnable during implementation.
- **XR2 label format** is easily adjustable and not worth blocking on.
