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
- The poller logs the reason's error code on the `failed` and `cancelled` branches, never the message after it, and its return value is unchanged so the CLUE answers path is undisturbed.
- A failed run is never retried in place, so no stale reason can survive and nothing needs clearing. A terminal run's reason is not overwritten by a later poll.

**Expose it**

- `run_json/1` and the `NOT_READY` download body gain `athena_query_id` and `athena_query_error`, as ordinary top-level context keys.
- The run page renders, in order: the mapped suggestion, the raw reason, then the query id. The suggestion leads because it is the only part written for the reader; the raw reason is always present and unmodified.
- The failure block sits in a `role="status"` container that renders whether or not there is a reason, because the page patches it in live and a region created with its content is not reliably announced. The reason carries `break-words`.
- The reason inherits each surface's existing gate. The API is owner-only with no admin exemption; the run page is owner-or-admin. That asymmetry is pre-existing and both surfaces are pinned on both halves: the API denies a non-owner and a non-owning admin alike, and the page admits a non-owning admin while redirecting a non-owning non-admin.

**Map known reasons to guidance**

- An ordered, first-match-wins table from reason pattern to a one-line suggestion. The raw reason is always shown; an unrecognized reason gets no suggestion rather than a generic one.
- Matching is case-insensitive and unanchored. Both properties are load-bearing (see Decisions).
- Two patterns match message wording rather than an error code: `injected projected partition column`, because the `CONSTRAINT_VIOLATION` code carrying it also covers failures a smaller cohort would not fix, and `query timeout`, which has no code. AWS rewording either one costs the suggestion, not the raw reason.
- The injected-column failure is advised to narrow the cohort, not the date range: it is rejected during planning, so neither a date range nor an application changes it.
- The application half of the narrowing advice appears only when the run's report offers that filter. The date-range half is unconditional.
- One test reaches the real report tree through `offers_app_filter?/1` rather than a constructed `%Report{}`, asserting that some Athena report still offers the filter and that its advice names an application. Renaming `:enable_app_filter` would otherwise leave the condition reading `false` forever and the clause silently absent from every suggestion.
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

**A shape guarantee for `AthenaFailure.error_code/1`.** It splits on the first colon, so a reason carrying none is returned whole and only the 60-character bound keeps message text out of the log. AWS does not guarantee the `CODE: message` shape. Tightening it means accepting a recognized code format plus a short allowlist of known code-less reasons (`Query timeout`, `Query cancelled by user`, `Slowdown`) and returning a fixed placeholder otherwise; an uppercase-code-only rule would throw away those known cases, which are the useful ones. Left out here because it is a behavior change with its own tests rather than part of surfacing the reason.

**An atomic write in `AthenaRunOps.refresh_query_state/1`** (REPORT-125). The non-terminal check reads the caller's struct while the write is unconditional, so two overlapping polls that both loaded a `queued` run can have the older `running` response land last, clobbering the terminal state and restarting polling. Reproduced: the reason itself survives, because Ecto's `cast/3` records no change when the new value equals the one already in the struct and the older poller's struct held `nil`, and the next poll re-reads `failed` from Athena and rewrites it, so the visible effect is the status flickering back to Running for about a second. The race predates this story: `master` has the identical stale-check-then-unconditional-write shape for `athena_query_state` and `athena_result_url`, and this story only added a fourth column to the same write. The fix should follow the precedent in the same file, where `ensure_current/1` claims the row with `Repo.update_all` guarded by `where: is_nil(r.athena_query_id) and is_nil(r.athena_query_state)` and branches on the `{1, _}` count, plus a reload when the conditional update loses. That changes the function's return contract and touches every caller and test, which is why it is its own change.

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
**Decision**: make the clause conditional on the run's report offering the filter, and take no dependency on REPORT-105's branch. Only `student-actions` and `student-actions-with-metadata` query the partitioned log table, and only they gain the filter; the other three Athena reports never do. The condition is `Keyword.get(form_options, :enable_app_filter, false)`, which reads `false` on a report without the key, so no code from that branch is needed and the two stories merge in either order. Stacking on `REPORT-105-log-report-app-filter` while its PR was open was rejected, since it would have meant re-rebasing on every force-push for a `true` path a constructed `%Report{}` already covered. REPORT-105 merged on 2026-09-05 and this branch was rebased onto it, so the tree assertion that was deferred on that reasoning is now in place.

### Is the poller's log line an acceptable third disclosure surface?
**Context**: The spec analyzed the API and run page gates carefully but added a `Logger.error` with no analysis. SQL is logged nowhere else today, and the CLUE query embeds secure keys and full `run_remote_endpoint` URLs.
**Options considered**: log the full reason; log the error code prefix only; bound the reason; drop the line.
**Decision**: log `AthenaFailure.error_code/1`, the part of the reason before its first colon, and never the message after it. The line was originally unbounded, which was its own defect: the changeset covers what is stored and not what is logged, and a 70,000-byte reason produced a 70,000-character log line. Bounding it was not enough, though, because the log stream sits outside both owner-gated surfaces and a bounded reason still carries whatever the message echoes. The argument for keeping the message was that the poller's only consumer persists nothing, so the log is the failure's sole record and the detail past the code is what an AWS support case needs. That does not hold: the line already carries the Athena query id, which retrieves the full `StateChangeReason` from Athena directly, so the message was redundant for anyone able to act on it while being the only part carrying the risk. Retrieval lasts only as long as Athena's execution history, so a detail like the S3 request id becomes unrecoverable after that window; that cost is accepted.
**Residual**: AWS does not guarantee the `CODE: message` shape, so a reason carrying no colon is returned whole and the 60-character bound, not the split, is what limits the exposure. Tightening that is listed under Not Yet Implemented.

### Should the failure block be announced to assistive technology?
**Context**: The page reschedules a poll every second while a run is non-terminal, so the block arrives through a live DOM patch with no navigation.
**Decision**: wrap it in `role="status"`, polite rather than assertive, on a container present before the reason arrives, since a live region created with its content is not reliably announced. This is the part of the story written for a reader who cannot use AWS, so leaving it silent defeats its purpose.

### How should the reason-to-suggestion mapping be asserted?
**Context**: Both specs originally required "each of the five reasons maps to a distinct suggestion".
**Decision**: assert each by exact value, and separately that the five are distinct. Exact values are what catch a suggestion drifting onto the wrong reason; the distinctness assertion catches two entries collapsing onto one string, which is how the injected-column advice would silently revert to the partition-limit wording.

### Does the partition-limit advice fit `CONSTRAINT_VIOLATION`?
**Context**: The story grouped `CONSTRAINT_VIOLATION` with `HIVE_EXCEEDED_PARTITION_LIMIT` as "the same problem with the same fix", and the first implementation gave both the same "narrow it with a date range" string.
**Options considered**: keep the pairing; match the message rather than the code; drop the entry.
**Decision**: match the message, and give it its own advice. Athena's wording, from the production runs, is `For the injected projected partition column secure_key, the WHERE clause must contain only static equality conditions, and at least one such condition must be present. Predicates provided cannot be converted to a valid partition.` That is the secure-key `IN` list outgrowing what Athena will expand into injected partition values, and it is rejected during planning: runs 2287, 2283 and 2281 carried 2,130, 3,493 and 3,669 learners and failed in one to two seconds, before any data was read. Neither a date range nor an application shortens that list, so the partition-limit advice would have sent the researcher somewhere that cannot help; only a smaller cohort can. The pattern is `injected projected partition column` rather than `constraint_violation` because the code covers unrelated failures whose fix is not a smaller cohort, and an unrecognized one showing the raw reason with no suggestion is the better outcome. `HIVE_EXCEEDED_PARTITION_LIMIT` keeps the narrowing advice, which is right for it: a date range cut 6,660 prefix combinations per learner to 735 and lifted that ceiling from about 150 learners to about 1,360.

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
