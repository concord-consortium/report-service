# Persist and Surface Athena Failure Reasons on Report Runs

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-106

**Status**: **Closed**

## Overview

Capture Athena's `StateChangeReason` when a query fails or is cancelled, persist it on the report run, and show it with the query id on the run page and in the API, so a researcher whose run failed learns whether to narrow the filter, add a date range, or retry, instead of seeing the word "Failed". Also delivers what REPORT-33 asked for; that ticket was marked Done on 2026-09-03 on the strength of this story, so shipping the `Slowdown` entry is what makes that resolution true.

## Requirements

All requirements were implemented. Grouped as they were specified.

**Capture and persist**

- `report_runs` gains `athena_query_error`, nullable, `:text`. Ecto's `:string` is `varchar(255)`, and under this server's `STRICT_TRANS_TABLES` an over-length value errors the write rather than truncating.
- The persisted reason is bounded to 4,000 bytes in the changeset with a ` ... (truncated)` marker. `:text` raises the ceiling to 65,535 bytes but does not remove the failure: an over-ceiling write raises `MyXQL.Error (1406)` rather than returning an error tuple, escaping `refresh_query_state/1`'s `else` clause and leaving the run non-terminal to raise again on every poll. Truncation is byte-oriented and trims back to a codepoint boundary.
- `get_query_info/1` returns the reason alongside the state and result url. Capture is unconditional pass-through, with no state-conditional logic.
- `AthenaRunOps.refresh_query_state/1` persists it, and the field is added to the `cast/3` list. An uncast field is dropped in silence.
- Every caller is updated: `AthenaRunOps`, all four `AthenaQueryPoller` clauses, and six test stub sites.
- The poller logs the bounded reason on the `failed` and `cancelled` branches, its return value unchanged, so the CLUE answers path is undisturbed.
- A failed run is never retried in place, so no stale reason can survive and nothing needs clearing. A terminal run's reason is not overwritten by a later poll.

**Expose it**

- `run_json/1` and the `NOT_READY` download body gain `athena_query_id` and `athena_query_error`, as ordinary top-level context keys.
- The run page renders, in order: the mapped suggestion, the raw reason, then the query id. The suggestion leads because it is the only part written for the reader; the raw reason is always present and unmodified.
- The failure block sits in a `role="status"` container that renders whether or not there is a reason, because the page patches it in live and a region created with its content is not reliably announced. The reason carries `break-words`.
- The reason inherits each surface's existing gate. The API is owner-only with no admin exemption; the run page is owner-or-admin. That asymmetry is pre-existing and both surfaces are pinned on both halves: the API denies a non-owner and a non-owning admin alike, and the page admits a non-owning admin while redirecting a non-owning non-admin.

**Map known reasons to guidance**

- An ordered, first-match-wins table from reason pattern to a one-line suggestion. The raw reason is always shown; an unrecognized reason gets no suggestion rather than a generic one.
- Matching is case-insensitive and unanchored. Both properties are load-bearing (see Decisions).
- The application half of the narrowing advice appears only when the run's report offers that filter. The date-range half is unconditional.
- `Slowdown` ships REPORT-33's text verbatim and must never suggest narrowing.

## Technical Notes

- The reason is read from the poll response already being made, so there is no new AWS call and no new permission.
- `athena_query_id` was already stored; exposing it needed no migration.
- `AthenaQueryPoller` collapses every failure to `{:error, "Query failed"}`, and its only consumer discards the message into a list, which is why the poller logs rather than returning the reason.
- `ReportRunLive.Show` resolves its report with a direct `Tree.find_report/1` call rather than through the `:report_tree` seam, so a stubbed tree cannot vary what the page renders.
- `AthenaDB` builds its AWS client inline and has no test seam.

## Out of Scope

- **The cc-data-cli half**, which sequences with REPORT-94. The one non-obvious part: `stateExtra` (`internal/fetch/report.go:242-246`) rebuilds the `Extra` map from scratch and would otherwise discard the reason on exactly the failed-run path.
- **Alerting or operator-facing observability.** Making failures visible to operators rather than to the run's owner is a different story.
- **Backfilling reasons for historical failed runs.** Athena's execution history window and the workgroup-per-user layout make a sweep expensive; existing failed runs keep showing what they show today.
- **Failures before Athena accepts the query.** There is no query execution and so no reason; that path already reports its own error.
- **A README note for the new column.** Dropped deliberately: `server/README.md` documents no `report_runs` columns at all, so a single entry would have no siblings and nothing keeping it in step with the migration.
- **Changing how `athena_query_state` is presented.**

## Not Yet Implemented

**A test asserting that at least one Athena report in the real tree offers the application filter.** It cannot be written until REPORT-105 merges, because it fails today, where no report carries the key. Without it, a rename of `:enable_app_filter` during that story's review leaves this story's conditional reading `false` forever and the application clause silently absent from every suggestion. Every existing test constructs its own `%Report{}`, so none of them touch the real tree.

It belongs in `athena_failure_test.exs`, where `@athena_slugs` is already defined:

```elixir
test "the application filter option is spelled the way the report tree spells it" do
  offering = Enum.filter(@athena_slugs, &AthenaFailure.offers_app_filter?(Tree.find_report(&1)))

  assert offering != [], "no Athena report offers :enable_app_filter; has the option been renamed?"
end
```

The assertion message carries the value: an empty list on its own would send the next reader looking in the wrong place. Check at the same time that the sibling test `no Athena report in the tree that lacks the filter yields advice mentioning one` is still green; it is phrased against reports that do not offer the filter precisely so REPORT-105 merging cannot turn it red.

## Decisions

### What return shape should `get_query_info/1` have?
**Context**: The function gains a fourth value, and the shape is mechanical to change later but noisy to change twice.
**Options considered**: positional tuple; a map; a second function.
**Decision**: `{:ok, state, result_url, reason}`. It is a private surface within this repo with two lib callers and a test stub, so it is not a contract needing protection, and the positional form matches `AthenaDB`'s own style. A second function was rejected outright: two AWS calls per failed run and two sources for one response.

### Should the poller surface the real reason to the CLUE answers path?
**Context**: The poller collapses every failure to `{:error, "Query failed"}`.
**Options considered**: pass the reason through; log it; leave it.
**Decision**: log it, return value unchanged. Following the error through settles it: the consumer puts the raw tuple into a resource list as a value rather than surfacing it anywhere a person reads, so passing it through buys nothing while perturbing a path REPORT-36 touches.

### What justifies showing the reason at all, given it can echo query text?
**Context**: The spec first claimed the reason "describes the query, not its rows".
**Decision**: that basis was wrong and was replaced. The generated SQL embeds secure keys and, for `teacher-actions`, portal usernames. What holds is narrower: the owner supplied or already received every identifier in their own query, so the reason shows them nothing new. The non-owner test became the load-bearing control rather than a formality.

### How should overlapping reason patterns be resolved?
**Context**: `HIVE_S3_THROTTLING` and `Slowdown` are not disjoint, and their advice is deliberately opposite.
**Decision**: an ordered, first-match-wins list with the specific code first, pinned by a test. An ambiguous match is how REPORT-33's "never suggest narrowing for Slowdown" constraint gets violated in production.

### Must matching be case-insensitive?
**Context**: S3 spells its throttling code `SlowDown`; Athena spells the generic condition `Slowdown`. `String.contains?/2` is case-sensitive.
**Options considered**: case-sensitive patterns as first written; downcase the reason and hold patterns lowercase; anchor the coded patterns.
**Decision**: downcase the reason once and hold the patterns lowercase. Verified: `contains?(throttling_reason, "Slowdown")` is `false`, so the original spelling both missed REPORT-33's condition on the casing AWS is most likely to emit and removed the overlap the ordering rule exists to resolve, leaving the ordering test unable to fail. Anchoring was rejected: the coded failures do not reliably begin the reason, so it trades one silent-miss failure mode for another. A test walks the table asserting every pattern is lowercase, since an uppercase one would match nothing and fail no other test.

### Is `:text` enough to prevent the run being stranded?
**Context**: `:text` was chosen because an over-length write errors rather than truncating, stranding the run non-terminal.
**Options considered**: `:text` alone; truncate in `athena_db.ex`; truncate in the changeset; `MEDIUMTEXT`.
**Decision**: truncate in the changeset at 4,000 bytes, keeping `:text`. The argument for `:text` applies unchanged at its own 65,535-byte ceiling, and a multi-byte reason of about 21,800 characters already exceeds it. Reproduced end to end: it raises rather than returning an error tuple, so it escapes the `else` clause and crashes the request or the polling LiveView. Truncating in `athena_db.ex` was rejected because every test stubs that function, leaving the persistence boundary unprotected; `MEDIUMTEXT` was rejected as treating a correctness property as a capacity problem. Both `Repo.update_all` sites in `AthenaRunOps` set only `athena_query_state`, so the changeset is the sole write path.

### Should the guidance name the application filter?
**Context**: Three of five suggestions said "select an application", but most Athena reports never offer that control.
**Options considered**: sequence behind REPORT-105 and make the clause conditional; drop the clause; ship as written.
**Decision**: make the clause conditional on the run's report offering the filter, and take no dependency on REPORT-105's branch. Only `student-actions` and `student-actions-with-metadata` query the partitioned log table, and only they gain the filter; the other three Athena reports never do. The condition is `Keyword.get(form_options, :enable_app_filter, false)`, which reads `false` on a report without the key, so no code from that branch is needed and the two stories merge in either order. Rebasing onto `REPORT-105-log-report-app-filter` was considered and rejected: PR #417 is open at 13 commits ahead, so it would mean a stacked PR re-rebased on every force-push, and the only gain is exercising the `true` path against the real tree, which a constructed `%Report{}` already covers.

### Is the poller's log line an acceptable third disclosure surface?
**Context**: The spec analyzed the API and run page gates carefully but added a `Logger.error` with no analysis. SQL is logged nowhere else today, and the CLUE query embeds secure keys and full `run_remote_endpoint` URLs.
**Options considered**: log the full reason; log the error code prefix only; bound the reason; drop the line.
**Decision**: bound it with the shared `AthenaFailure.truncate/1` and log the full bounded reason, recording the judgment rather than inheriting it. The concrete defect was that the line was unbounded, since the changeset covers what is stored and not what is logged; a 70,000-byte reason produced a 70,000-character log line, measured at 4,051 after. Code-prefix-only was rejected because it drops the S3 request id an AWS case needs, and the poller's only consumer persists nothing, so the log is the sole record. This is why the truncation helper is public on `AthenaFailure` rather than private to `ReportRun`, and why the module is the first implementation step.

### Should the failure block be announced to assistive technology?
**Context**: The page reschedules a poll every second while a run is non-terminal, so the block arrives through a live DOM patch with no navigation.
**Decision**: wrap it in `role="status"`, polite rather than assertive, on a container present before the reason arrives, since a live region created with its content is not reliably announced. This is the part of the story written for a reader who cannot use AWS, so leaving it silent defeats its purpose.

### How should the reason-to-suggestion mapping be asserted?
**Context**: Both specs originally required "each of the five reasons maps to a distinct suggestion".
**Decision**: assert each by exact value, not all-distinct. Partition limit and `CONSTRAINT_VIOLATION` are the same problem with the same fix and share one string by design, so five reasons yield four distinct suggestions and an all-distinct test would fail against a correct implementation.

### Does the ordering test actually catch a reversed table?
**Context**: The test feeds a reason carrying both `HIVE_S3_THROTTLING` and `SlowDown`.
**Decision**: only once matching is case-insensitive. Built both orderings and ran the specified input through each: case-sensitive, both return the throttling advice and the test cannot fail; case-insensitive, the reversal changes the answer. The coupling is written into both specs beside the test so a later edit cannot quietly decouple them.

### Does "a succeeded run persists `nil`" test our code?
**Context**: The requirement described capture as gated on state, but the implementation is unconditional pass-through.
**Options considered**: add a state gate so the test earns its keep; restate the requirement.
**Decision**: restate. A gate would be code written to make a test meaningful rather than to change behavior, and would need revisiting the first time Athena attaches a reason to an unanticipated state. The requirement now says pass-through, and the succeeded case is labeled a pass-through check that asserts the payload rather than our state handling.

### Where do the run page's conditional-clause tests live?
**Context**: The plan put them in the LiveView test.
**Decision**: `custom_components_test.exs`, through `render_component/2`. `ReportRunLive.Show` resolves its report with a direct `Tree.find_report/1` call rather than through the `:report_tree` seam, so a stubbed tree cannot vary the report the page renders; written against the LiveView the assertion passes vacuously in one direction and cannot pass at all in the other. The same file covers the live region and the wrapping class, both properties of the markup rather than of the page.

### How many stub sites does the arity change touch?
**Context**: The plan named four failing tests, found by making the change and running the suite.
**Decision**: six. The fifth and sixth are the `echo` map behind the non-succeeded download cases, which stayed green while exercising the wrong path: a three-element tuple no longer matches the `with` clause, so those cases fell through to the error branch, which leaves the run untouched, which is exactly what the test asserted. Found by reading rather than by running.

### Where is the absent-`StateChangeReason` case covered?
**Decision**: at the stub boundary, with `nil` as the fourth element, rather than by feeding a key-less payload through `get_query_info/1`. `AthenaDB` builds its AWS client inline and has no seam, so the extraction is not reachable from a test. What it relies on is that indexing a map with a missing key yields `nil`, which is language behavior rather than ours.

### Minor spec corrections made during review
- The shared partition suggestion was written out twice in the guidance table and was extracted to one binding, so the sharing is deliberate and visible.
- The run-page step referenced `AthenaFailure` with no mention of adding an alias; named in the step.
- The API step claimed key-set assertions would guard the run body. They did not: adding a field to `run_json/1` and running the full suite left every test passing, so by-value assertions were the only protection. Closed during the pre-PR review by giving the run object a `@run_keys` guard matching the `@filter_keys` pattern already used one level down for the filter object. Mutation-tested: the pre-existing `refute Map.has_key?(body, "athena_result_url")` catches only a field someone thought to name, while the guard also catches an arbitrary new one.
- Whether a stale reason could survive was left to be re-derived. It cannot: `start_query/1` matches only `athena_query_id: nil` and `ensure_current/1`'s claiming clause requires both the id and the state to be nil, so nothing needs clearing.
- Two candidate findings were dropped after verification: that adding a column risks a long lock (the migration that added the three existing Athena columns did the same thing to the same table, and a trailing nullable column is an in-place metadata change on MySQL 8), and that a run failing before Athena accepts the query gets no reason (true but not a defect; recorded in Out of Scope).
