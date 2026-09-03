# Persist and Surface Athena Failure Reasons on Report Runs

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-106
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

> The Jira ticket is the authoritative scope and carries the production observations, the four
> failure reasons, and the material carried over from REPORT-33. This spec does not repeat them. It
> records what the code dive and the throwaway harness added: one finding that would have made the
> feature fail in production, three corrections to the ticket's stated premises, and the decisions
> those force.

## Overview

Capture Athena's `StateChangeReason` when a query fails or is cancelled, persist it on the report
run, and show it with the query id on the run page and in the API, so a researcher whose run failed
learns whether to narrow the filter, add a date range, or retry, instead of seeing the word "Failed".

## Project Owner Overview

When a report fails in Athena today, every failure looks identical: the run page shows the single
word "Failed" and the API reports the state and nothing else. Athena knows precisely why, and the
four causes seen in one week of production runs each call for a different response from the
researcher. Recovering that reason currently takes AWS credentials, knowledge of an internal
workgroup naming scheme, and matching query executions to runs by timestamp, which is not something
the people this server exists for can do, and not something they should have to ask for.

This story stores the reason at the moment the run reaches its terminal state, shows it, and pairs
each known reason with a one-line suggestion of what to do next. It also delivers what REPORT-33
asked for, a real user's failure report from April 2025 that sat open for over a year because there
was nowhere to put the answer; that ticket was marked Done on 2026-09-03 on the strength of this
story, so shipping the `Slowdown` entry is what makes that resolution true.

## Background

`AthenaDB.get_query_info/1` (`server/lib/report_server/athena_db.ex:22-32`) matches
`%{"QueryExecution" => %{"Status" => %{"State" => state}} = result}` and returns
`{:ok, downcased_state, output_location}`. `Status.StateChangeReason` sits in that same `Status` map
and is discarded. `AthenaRunOps.refresh_query_state/1` (`athena_run_ops.ex:37-50`) persists the state
and result url from that tuple.

`report_runs` already carries `athena_query_id`, `athena_query_state` and `athena_result_url`
(migration `20241202122328_add_athena_query_columns.exs`, schema `report_run.ex:13-15`, cast at
`report_run.ex:25`). `run_json/1` (`report_json.ex:24-36`) exposes `athena_query_state` and not
`athena_query_id`. The not-ready response is built at `report_controller.ex:83-84` and carries only
`athena_query_state`. Workgroup naming is `athena_db.ex:103-106`.

The run page renders the failure at `custom_components.ex:151-155`, inside `report_header/1`: for any
Athena run that is not `succeeded` it prints `Report status: <state>` with a `capitalize` class,
which is literally the "Failed" the ticket describes.

### The finding that matters most

**`:string` is the wrong column type and would break the feature in production.** Ecto's `:string`
is `varchar(255)` in MySQL, which is what the existing migration used for the other three Athena
columns (confirmed against the running database: all three are `varchar(255)`). Athena's
`StateChangeReason` routinely exceeds that. A realistic `CONSTRAINT_VIOLATION` reason naming the
injected partition column and the S3 prefixes involved measures 378 characters, and inserting it
into a `varchar(255)` under this server's `sql_mode` (`STRICT_TRANS_TABLES`, verified on the
database) fails outright:

```
ERROR 1406 (22001): Data too long for column 'as_string' at row 1
```

It does not truncate; it errors. Because the write happens inside `refresh_query_state/1`, which
runs on every poll of a non-terminal run, the failure would be worse than losing the reason: the
update would fail, the run would never reach a terminal state in our records, and the researcher
would be left staring at a run that never resolves, on exactly the long-reason failures the story
exists to explain. `athena_query_error` must be `:text`. The same value inserted into a `TEXT`
column stores all 378 characters.

### What the code dive corrected

**Changing the return arity touches more than the ticket says.** The ticket names two callers of
`get_query_info/1` and says "the stub needs the new field too". Both parts need adjusting. The two
lib callers are right (`athena_run_ops.ex:39`, `athena_query_poller.ex:17`), but
`AthenaQueryPoller.poll_query_status/1` matches the three-element tuple in **four** separate clauses
(`athena_query_poller.ex:18-27`), and the poller is itself reached from `Clue.fetch_resource/3`
(`clue.ex:175`), a third path the ticket does not mention. The test seam
(`test/support/athena_db_stub.ex`) needs **no** change at all: it applies whatever function the test
supplies (`athena_db_stub.ex:5,9-11`), so it is arity-agnostic.

The test churn is also smaller than a grep suggests. `get_query_info` appears at roughly eight test
sites, but several are `raise "should not be called"` guards or sit on paths that error first, so
they never execute the stub. Making the change for real and running the suite gives the exact list:
**four tests fail**, and nothing else in 519 does.

- `test/report_server/reports/athena_run_ops_test.exs:44`
- `test/report_server_web/api/v1/report_controller_test.exs:314`
- `test/report_server_web/api/v1/report_controller_test.exs:435`
- `test/report_server_web/live/report_run_show_live_test.exs:67`

**The server does not need to nest anything under `Extra`.** The ticket says to put the fields "in
the `NOT_READY` body's `Extra`". There is no `Extra` key in the server's error shape:
`ErrorHelpers.render_error/4` merges the context map into `%{error:, message:}` at the top level
(`error_helpers.ex:24-29`), which is how `athena_query_state` already appears. Reading the client
confirms this is already correct: `decodeAPIError` in cc-data-cli
(`internal/api/client.go:189-214`) captures **every** top-level envelope field except `error` and
`message` into `Extra`. So adding the two fields as ordinary context keys makes them appear in the
client's `Extra` with no server-side nesting.

**The client will still drop the reason on the terminal-failure path.** The ticket calls the cc-data
half "mostly rendering". That holds for the general error path, but `pollUntilReady`
(`internal/fetch/report.go:157-165`) builds its terminal-failure `CLIError` with
`Extra: stateExtra(state, isJob)`, and `stateExtra` (`report.go:242-246`) **constructs a fresh map
containing only `athena_query_state`**, discarding whatever else the server sent. A failed run is
exactly the terminal-failure path, so the cc-data story has to extend `stateExtra` or the reason will
never reach the CLI no matter what the server sends. This is out of scope here but is the one
non-obvious thing the cc-data half must do.

### What the throwaway harness verified

A harness reproducing the real `AWS.Athena.get_query_execution` response shape was built, run, and
deleted. It established:

- The reason is reachable with no restructuring: `result` is already bound to the `QueryExecution`
  map, so `result["Status"]["StateChangeReason"]` is a one-line addition.
- Absent keys are safe. `succeeded` and `running` responses carry no `StateChangeReason` and yield
  `nil` rather than raising, so no guard clause is needed for the states that have no reason.
- `cancelled` does carry one, confirming both terminal states are worth capturing.
- The `NOT_READY` body with the two new context keys is flat, with keys
  `athena_query_error`, `athena_query_id`, `athena_query_state`, `error`, `message`.

A second pass built the column and the arity change for real against the running database and the
full suite, then removed them:

- **The `:text` finding holds at the Ecto layer, not only in raw SQL.** With a real migration and
  schema field, writing the 378-character reason to the `varchar(255)` column raises
  `(1406) Data too long for column` through MyXQL; the same value into the `TEXT` column stores all
  378 characters and reads back identical.
- **An uncast field is dropped silently and the update still succeeds.** With `athena_query_error`
  on the schema but absent from the `cast/3` list, `update_report_run/2` returned `{:ok, run}` with
  the field still `nil`. There is no error and no warning, which is why the cast needs its own test
  rather than being assumed from the field existing.
- **Rows written before the column existed read back `nil`** through the schema, with no error.
- **The arity change is mechanical and fully caught by the compiler and the suite**: three lib edits
  and the four tests listed above, with no silent breakage anywhere else.

## Requirements

### Capture and persist

- `report_runs` gains `athena_query_error`, nullable, **`:text`** for the reason established above.
- `get_query_info/1` returns the `StateChangeReason` alongside the state and result url. Capture is
  unconditional pass-through: whatever Athena reports is stored, with no state-conditional logic. In
  practice that means a reason on `failed` and `cancelled` and `nil` elsewhere, because those are the
  only states AWS attaches one to, but that is Athena's behavior rather than ours. Stated this way
  because the alternative wording ("captured for failed and cancelled") describes a state gate no
  line implements, and would make the succeeded-persists-nil test read as a check on our code when it
  is a check on the payload.
- The persisted reason is **bounded**, truncated to 4,000 bytes in the changeset with a
  ` ... (truncated)` marker appended. `:text` alone does not remove the failure it was chosen to
  prevent, it raises the threshold: the ceiling is 65,535 **bytes**, and an over-ceiling write raises
  `MyXQL.Error (1406)` rather than returning `{:error, changeset}`, so it escapes
  `refresh_query_state/1`'s `else` clause, propagates out of `ensure_current/1`, and leaves the run
  non-terminal to be retried and to raise again on every poll. Verified end to end. Truncating at the
  persistence boundary makes that state unreachable for any writer rather than merely unlikely.
  Truncation is byte-aware and trims back to a codepoint boundary, since a multi-byte reason of about
  21,800 characters already exceeds the byte ceiling and character-oriented slicing does not bound
  bytes. 4,000 bytes is roughly ten times the longest reason observed (378), so no real reason is
  affected, and it keeps the run page and the API response readable.
- `AthenaRunOps.refresh_query_state/1` persists it, and `athena_query_error` is added to the
  changeset cast in `report_run.ex:25`. A field that is not cast is silently dropped, so this is
  load-bearing and needs a test that would catch its omission.
- Every caller of `get_query_info/1` is updated: `athena_run_ops.ex:39`, all four clauses of
  `athena_query_poller.ex:18-27`, and every test call site supplying a stub response.
- `AthenaQueryPoller` logs the reason on the `failed` and `cancelled` branches, leaving its return
  value unchanged, per the resolved question below. The logged reason is bounded by the same helper
  the changeset uses: the changeset covers what is stored, not what is logged, and the poller logs the
  reason straight from `get_query_info`. Measured, a 70,000-byte reason otherwise produces a
  70,000-character log line. The bound lives in one shared function rather than being written twice.
- The full bounded reason is logged rather than only its error code, and that is a weighed decision.
  The poller's only consumer is the CLUE answers path, which persists nothing, so the log is the sole
  record of why that query failed, and the detail past the code is what an AWS support case needs.
  Against that: this is the first time query text could reach the logs at all, since SQL is logged
  nowhere today, and the CLUE query embeds `secure_key` values and full `run_remote_endpoint` URLs
  (`clue.ex:207-208`), where a secure key is a capability rather than a bare identifier. Judged
  acceptable because no observed reason echoes query text, the reasons that would are syntax and
  resolution errors on a query this server generates and does not vary, and the log stream already
  carries a username (`clue.ex:674`). Recorded rather than inherited, so the third surface gets the
  same treatment as the two display surfaces above.
- The log line itself is not covered by a test. It is diagnostic output rather than behavior, its
  only consumer is CloudWatch, and `ExUnit.CaptureLog` is used nowhere in this suite, so asserting on
  it would introduce an idiom for one line. The property that matters, that the logged reason is
  bounded, is covered by `truncate/1`'s own tests, since the poller and the changeset call the same
  function.
- A failed run is never retried in place, so a stale reason cannot be left behind:
  `start_query/1` only matches `athena_query_id: nil` (`athena_run_ops.ex:16`) and
  `ensure_current/1`'s claiming clause requires both the id and the state to be nil
  (`athena_run_ops.ex:52-55`). Nothing needs to clear the field.
- Once a run reaches a terminal state the reason must not be overwritten by a later poll.
  `refresh_query_state/1` already guards on `non_terminal?/1` (`athena_run_ops.ex:38`), so this holds
  today; a test should pin it rather than leave it to be re-derived.

### Expose it

- `run_json/1` gains `athena_query_id` and `athena_query_error`.
- The `NOT_READY` download response gains the same two fields, as ordinary top-level context keys
  alongside `athena_query_state`.
- The run page replaces the bare state (`custom_components.ex:151-155`) with, in order: the mapped
  suggestion, then the raw reason, then the query id in a details line so someone with AWS access can
  find the execution.
- The failure block is announced to assistive technology. The page polls while a run is non-terminal
  (`show.ex:232-236` reschedules every second, `show.ex:135-142` reassigns `report_run`), so the
  block appears through a live DOM patch with no navigation and is otherwise never announced. It
  carries `role="status"`, polite rather than assertive because the failure is not time-critical and
  the block runs to several lines. The container must be present in the DOM before the reason
  arrives, since a live region that appears at the same moment as its content is not reliably
  announced. This is the part of the story written for a reader who cannot use AWS, so leaving it
  silent defeats its purpose. The suggestion leads because it is the only part written for the reader: the
  ticket's own framing is that these researchers cannot use AWS, and `HIVE_EXCEEDED_PARTITION_LIMIT`
  is not a sentence they can act on. The raw reason stays visible and unmodified directly beneath it,
  since it is what makes a support conversation possible and the only thing available when a reason
  is unmapped.
- The reason can echo query text, so the claim to rely on is narrower than "it describes the query,
  not its rows". The generated SQL embeds secure keys (`report_query.ex:121`) and, for
  `teacher-actions`, portal usernames of the form `<user_id>@<portal>`
  (`teacher_actions_report.ex:18,48-49`). What holds is that the owner supplied or already received
  every identifier in their own query, so the reason shows them nothing new.
- The reason inherits each surface's existing gate and widens neither, but the two gates differ and
  the difference is worth stating rather than rediscovering. The API is **owner-only, admins
  included**: `get_api_report_run/2` filters on `r.user_id == ^user.id` (`reports.ex:95`) with no
  admin exemption, so an admin requesting another user's run gets the same 404 as anyone else. It
  additionally requires `r.report_slug in ^Tree.api_report_slugs()` (`reports.ex:96`), which is why
  a run can be invisible through the API while visible on the page. The
  run page is **owner-or-admin**: `show.ex:36` admits `user.portal_is_admin`. So an admin can read
  another user's failure reason on the page but not through the API. That asymmetry is pre-existing
  and intended, and is called out because a reader who assumes "a non-owner cannot see it" is wrong
  about one of the two surfaces. Both halves need pinning.

### Map known reasons to guidance

- A mapping from reason pattern to a one-line suggestion, shown next to the raw reason.
- The raw reason is **always** shown, mapped or not. The mapping is an aid, not a replacement.
- An unrecognized reason shows raw with no suggestion, and must not fall back to a generic
  suggestion, because the wrong suggestion is worse than none.
- Partition limit and `CONSTRAINT_VIOLATION` suggest narrowing the query. `Query timeout` and
  `HIVE_S3_THROTTLING` suggest the same plus retrying off-peak.
- **The application half of that advice is conditional on the run's report actually offering the
  filter**, because most Athena reports never will. Verified: the partition-limit and injected-column
  `CONSTRAINT_VIOLATION` failures come from `logs_by_app_and_secure_key`, which is
  `PARTITIONED BY (app, year, month, secure_key)` (`README.md:212-256`), and only `student-actions`
  and `student-actions-with-metadata` query it (`report_query.ex:100`). Those are exactly the two
  reports REPORT-105 gives an application filter. But `Query timeout`, `HIVE_S3_THROTTLING` and
  `Slowdown` can fire on any of the five Athena reports, and the other three (`student-answers`,
  `student-assignment-usage`, `teacher-actions`) never get the control. Naming it there would be the
  wrong-suggestion failure this section exists to prevent, and quieter than an unmapped reason
  because it looks authoritative.
- The date-range half is unconditional: the date inputs are on every report's form
  (`form.html.heex:90-93`).
- The condition is read as `Keyword.get(form_options, :enable_app_filter, false)` on the run's
  `%Report{}`. This is deliberately the same call REPORT-105 makes (`form.ex:457`) and it needs no
  code from that branch: `form_options` is a keyword list defaulting to `[]` (`report.ex:5`), so on
  this branch every Athena report reads `false` and no advice mentions applications. When REPORT-105
  merges, the two log reports begin reading `true` and the clause appears with no further change
  here. Verified against the real tree on both sides. The two stories can therefore merge in either
  order and this one does not rebase onto that branch.
- The narrowing phrase has one definition and is interpolated into the three sentences that use it,
  rather than each sentence being written twice. `Slowdown` does not use it at all.
- `Slowdown` ships this exact text, carried over from REPORT-33: *"Your query was delayed due to high
  traffic in AWS Athena. Please try again in a few moments. This is a temporary issue caused by heavy
  usage."* Its guidance must say retry later and must **not** suggest narrowing the filter or adding
  a date range. `Slowdown` is an internal Athena condition caused by too many small files on S3;
  neither the researcher nor this server can act on it, so the advice that is right for the partition
  and timeout failures is actively wrong here.
- Matching is on the reason text Athena returns, which begins with the error code for the coded
  failures. It must be resilient to the message text after the code changing, since that text is
  AWS's and not a contract. It is an unanchored substring test: the coded failures do not reliably
  begin the reason, and an anchored match would silently stop firing the first time AWS prefixes
  anything.
- **Matching must be case-insensitive.** This is load-bearing, not tidiness. S3's throttling error
  code is spelled `SlowDown` and the generic Athena condition is spelled `Slowdown`, and
  `String.contains?/2` is case-sensitive, so a pattern written `"Slowdown"` never matches a reason
  carrying `SlowDown`. Verified by running the table: `contains?(reason, "Slowdown")` is `false` for
  a realistic `HIVE_S3_THROTTLING` reason that contains `SlowDown`. Two things break without it: the
  REPORT-33 entry fails to fire on whichever casing AWS actually emits, and the overlap the ordering
  rule below exists to resolve does not occur, which makes its test unable to fail. Downcase the
  reason once and hold the patterns downcased.
- **Matching must be ordered and first-match-wins, most specific pattern first**, because the
  patterns overlap once matching is case-insensitive. A `HIVE_S3_THROTTLING` reason carries S3's own
  error code, `SlowDown`, so a case-insensitive substring mapping matches both the throttling pattern
  and the `Slowdown` pattern. The two have deliberately opposite guidance, so an ambiguous match is
  not a cosmetic problem: it is how the "never suggest narrowing for `Slowdown`" rule gets violated
  in production. Verified by building the table both ways: with case-insensitive matching, moving
  `Slowdown` ahead of `HIVE_S3_THROTTLING` changes the answer, and with case-sensitive matching it
  does not. Match the specific code (`HIVE_S3_THROTTLING`) before the generic token, and pin the
  order with a test.
  The exact text AWS emits is not verifiable from here; the ordering requirement holds regardless of
  the wording, which is why it is expressed as an ordering rule rather than as a fixed pattern.

### Tests

Each test below names the mutation it catches.

- A `:text` column accepts a reason longer than 255 characters. Catches the migration being written
  with `:string`, which errors under `STRICT_TRANS_TABLES` and is invisible in any test using a short
  reason.
- The truncation function's edge cases are covered on the function itself rather than through the
  database, since driving each one through a write proves nothing extra: a reason past the byte
  ceiling comes back under the limit and marked, a multi-byte one comes back valid UTF-8 (catching
  truncation by bytes without repairing the codepoint boundary, and truncation by characters, which
  does not bound bytes at all), an under-limit one comes back byte-identical and unmarked (catching a
  truncation that fires on every value and would corrupt every real reason), and `nil` comes back
  `nil`.
- Two tests then cover the wiring, which is what the function tests cannot reach. The changeset
  stores an over-ceiling reason truncated and returns `{:ok, _}` rather than raising, catching the
  changeset not calling the function. And a `failed` poll carrying an over-ceiling reason leaves the
  run at `"failed"` with `non_terminal?/1` false, catching the failure the bound exists to prevent:
  unbounded, that write raises `MyXQL.Error (1406)` out of `refresh_query_state/1` and the run stays
  `"running"` and is retried forever. The first proves the string got shorter; only the second proves
  the run escaped the loop.
- A failed run persists the reason; a cancelled run persists the reason; a succeeded run persists
  `nil`. Catches the reason being dropped or written to the wrong column. Note what the third case
  does not do: because capture is unconditional pass-through, it asserts that the stub returned `nil`
  and would stay green whether or not a state gate existed. It is a pass-through check, kept for the
  first two cases, not a guard on state handling.
- A run whose reason is absent from the AWS payload persists `nil` rather than raising. Catches a
  pattern match that assumes the key is present.
- The reason survives a round trip through the changeset. Catches `athena_query_error` being added
  to the schema but not to the `cast/3` list, which silently drops it with no error.
- Runs created before the migration return `nil` for both new fields and do not error, through both
  the run page and the API. Both halves are required: this is the state every existing failed run is
  in on the day this deploys, since no backfill is in scope. On the page that means neither
  suggestion, reason nor query id renders.
- The run body from `GET /api/v1/reports/:id` includes `athena_query_id` and `athena_query_error`,
  asserted by value and not only by key set. Asserted through the endpoint because `run_json/1` is a
  `defp` (`report_json.ex:24`), reachable only through `show/1` and `index/2`. The existing `@filter_keys`-style key-set assertions guard against undeclared keys, not
  missing ones, so a key-set check alone cannot catch the field never being added.
- The `NOT_READY` body carries all three fields.
- Each of the four observed reasons plus `Slowdown` maps to its expected suggestion, asserted by
  exact value, and an unknown string maps to none. Not an all-distinct assertion: partition limit
  and `CONSTRAINT_VIOLATION` are the same problem with the same fix and share one suggestion by
  design, so the five reasons yield four distinct strings and an all-distinct test would fail
  against a correct implementation.
- The `Slowdown` suggestion contains neither "date range" nor "application", in both variants, and is
  byte-identical to the string REPORT-33 specifies. Catches the specific regression REPORT-33's note
  warns about, which a test merely asserting "some suggestion exists" would miss, and catches the
  narrowing phrase leaking into the one entry that must not carry it. Note the second word is
  "application" and not "filter": since the suggestions were rewritten for the conditional clause, no
  shipped suggestion contains the word "filter", so asserting on it cannot fail. Checked against the
  mutation it is meant to catch, replacing the `Slowdown` text with the timeout advice: "date range"
  and "application" both catch it, "filter" does not.
- A reason containing **both** `HIVE_S3_THROTTLING` and the token `SlowDown` maps to the throttling
  suggestion, not the `Slowdown` one. Catches the pattern ordering being reversed, which no
  single-pattern test can detect because each pattern works in isolation. This test only has that
  power once matching is case-insensitive: under case-sensitive matching `Slowdown` never matches
  `SlowDown`, both orderings return the throttling advice, and the test cannot fail. Verified both
  ways.
- The `Slowdown` entry fires for `Slowdown`, `SlowDown` and `SLOWDOWN` alike. Catches the
  case-sensitivity regression directly, rather than only through the ordering test above.
- Every pattern in the table is lowercase, in both variants. A walk of the table. Catches an entry
  added later in the casing AWS uses, which would never match the downcased reason and would fail no
  other test here.
- A report with no `:enable_app_filter` key mentions no application in any of its five suggestions,
  and one with `enable_app_filter: true` does. The pair that pins the conditional. Asserted against a
  `%Report{}` built in the test rather than the real tree, so it holds whichever order this story and
  REPORT-105 merge in.
- No Athena report in the real tree that does not offer the filter yields advice mentioning one.
  Catches the condition being inverted or dropped, which the constructed-report test cannot, since it
  never touches `Tree`. Phrased against reports that do not offer the filter rather than as a blanket
  claim, so REPORT-105 merging does not turn it red.
- A terminal run's reason is not overwritten by a subsequent poll.
- A non-owner gets a 404 from the API, and so does an **admin** who is not the owner. The admin case
  is the counterintuitive half, and the one that a future change adding an admin exemption to
  `get_api_report_run/2` would widen silently.
- An admin who is not the owner **does** see the reason on the run page, matching `show.ex:36`.
  Asserting only the negative would let someone "resolve" the asymmetry by tightening the page gate,
  breaking admin support access with a green suite.

## Technical Notes

- `AthenaQueryPoller.poll_query_status/1` collapses every failure to `{:error, "Query failed"}`
  (`athena_query_poller.ex:20-21`), and its only consumer discards the message into a list
  (`clue.ex:174-179` into `resource_data.ex:38`). Per the resolved question below, the poller logs
  the reason and its return value is unchanged.
- `athena_query_id` is already stored, so exposing it is additive and needs no migration. Only the
  reason is new.
- The reason is captured at poll time from the API's own response, so there is no new AWS call and no
  new permission.

## Out of Scope

- **The cc-data-cli half.** Wire type fields, CLI and MCP error text, and fake-server captures
  sequence with REPORT-94, which rewrites `types.go` and `FetchReport`. Recorded above: extending
  `stateExtra` (`internal/fetch/report.go:242-246`) is the one non-obvious part, because it rebuilds
  the `Extra` map and would otherwise discard the reason on exactly the failed-run path.
- **Alerting or logging on failures.** The ticket notes CloudWatch logs nothing because from the
  application's point of view nothing went wrong. Making failures observable to operators rather than
  to the run's owner is a different story.
- **Backfilling reasons for historical failed runs.** Athena retains query execution history for a
  limited window and the workgroup-per-user layout makes a sweep expensive; existing failed runs keep
  showing what they show today.
- **Failures that happen before Athena accepts the query.** When `start_query/1` fails, there is no
  query execution and so no `StateChangeReason`; that path already reports its own error
  (`athena_run_ops.ex:27-33`) and releases the run's claimed state (`athena_run_ops.ex:65-66`).
  Making that case legible is a separate problem.
- **A README note for the new column.** The ticket's scope listed one, and it was dropped
  deliberately (2026-09-04) rather than overlooked. `server/README.md` documents no `report_runs`
  columns at all: the three existing `athena_query_*` columns appear nowhere in it, and its Athena
  content is Glue table DDL and IAM policies, not schema. A single new entry would be the only
  schema documentation in the file, with no siblings to sit beside and nothing keeping it in step
  with the migration and `report_run.ex`, which are the source of truth. The Jira scope line has
  been updated to say so, so a later pass does not raise it again.
- **Changing how `athena_query_state` itself is presented.** The `capitalize` styling and the state
  vocabulary stay as they are.

## Open Questions

### RESOLVED: What return shape should `get_query_info/1` have?

**Decision**: `{:ok, state, result_url, reason}`. The framing that made this look like a question for
Doug was wrong: `get_query_info/1` is a private surface of `AthenaDB` within this repo, called from
two lib sites and the test stub. No other story or repo consumes it, so it is not a contract that
needs protecting, and it is refactorable later behind full test coverage.

The positional tuple matches `AthenaDB`'s own style, where `query/3` already returns
`{:ok, athena_query_id, athena_query_state}`. The map alternative is more future-proof, but the
fifth field it protects against is speculative, and the cost of changing shape again is the same
mechanical edit across the same sites. Every site that fails to update fails loudly, at compile time
or on the first stubbed call, so there is no silent-breakage risk either way. Adding a second
function was rejected outright: it would mean a second AWS call per failed run and two sources for
one response.

### RESOLVED: Should the poller surface the real reason to the CLUE answers path?

**Decision**: Log it in the poller; do not change what the poller returns. Following the error
through settles this. `AthenaQueryPoller` returns `{:error, "Query failed"}` to
`Clue.query_for_text_tile_answers/3` (`clue.ex:174-179`), which passes it up to
`ResourceData.fetch/2`, where the `error -> error` clause (`resource_data.ex:38`) puts the raw tuple
into the resource list as a value rather than surfacing it anywhere a person reads. So passing the
reason through that path buys nothing today, while still perturbing a path REPORT-36 work touches.

Logging it is the part with real value and no contract change. The ticket notes that CloudWatch
records nothing on a failed query because from the application's point of view nothing went wrong;
the poller is already being edited for the arity change, so logging the reason there closes that gap
for the CLUE path at no risk. Making the CLUE answers path handle failures properly stays out of
scope and belongs with whoever owns that report.

## Self-Review

Roles: Security Engineer, Senior Engineer, QA Engineer, Education Researcher, DevOps. Each finding
was checked against the code, or against running code, before being written. Two candidates did not
survive and are recorded at the end.

### Security Engineer

#### RESOLVED: "describes the query, not rows" was the wrong thing to rely on

The spec justified adding the reason to a user-visible surface by asserting it describes the query
rather than its rows. Athena reasons can quote query text, and the generated SQL is not free of
identifiers: it embeds secure keys (`report_query.ex:121`), and the `teacher-actions` query embeds
portal usernames of the form `<user_id>@<portal>` (`teacher_actions_report.ex:18`, with the format
documented at `:48-49`). The conclusion still holds, but for a different reason: every identifier in
the query is one the owner supplied or already received, so the reason discloses nothing new to them.
Restated on that basis, and the non-owner test kept, since it is now the load-bearing control rather
than a formality.

### Senior Engineer

#### RESOLVED: the reason-to-guidance patterns overlap, with opposite advice

`HIVE_S3_THROTTLING` and `Slowdown` are not disjoint. S3's own throttling error code is the literal
string `SlowDown`, so a realistic throttling reason contains both tokens. Running a naive substring
mapping over realistic reason text confirmed it: both patterns matched, and the arbitrary ordering
returned the `Slowdown` advice for a throttling failure.

This is the mechanism by which REPORT-33's explicit constraint gets violated. Its note says the
`Slowdown` guidance must never suggest narrowing the filter or adding a date range, which is exactly
what the throttling guidance does say; an ambiguous match silently swaps one for the other. Added an
ordering requirement (specific code before generic token, anchored where possible) and a test that
feeds a reason containing both tokens, which no single-pattern test can catch because each pattern
works correctly in isolation.

#### RESOLVED: whether a stale reason could survive was left to be re-derived

The spec required that a terminal run's reason not be overwritten, without saying whether a run can
be re-run at all. It cannot: `start_query/1` matches only `athena_query_id: nil`
(`athena_run_ops.ex:16`) and `ensure_current/1`'s claiming clause requires both the id and the state
to be nil (`athena_run_ops.ex:52-55`). Recorded, so nobody adds clearing logic for a case that does
not exist.

### Education Researcher

#### RESOLVED: the raw reason was given the prominent position

The spec put the raw `StateChangeReason` first and the suggestion beside it. That inverts the value
for the actual reader. The ticket's own argument for the story is that these researchers cannot use
AWS and cannot act on an Athena error code; `HIVE_EXCEEDED_PARTITION_LIMIT` is not a sentence anyone
can do anything with. Reordered so the mapped suggestion leads, with the raw reason immediately
beneath it, unmodified and always present, since it is what makes a support conversation possible and
the only content available when a reason is unmapped.

### Dropped after verification

- **"Adding a column to `report_runs` risks a long lock in production."** Not supported. The
  migration that added the three existing Athena columns did the same thing to the same table
  (`20241202122328_add_athena_query_columns.exs`), and a trailing nullable column is an in-place
  metadata change on MySQL 8. No precedent for treating this as risky, and no evidence the table is
  large enough for it to matter.
- **"A run that fails before Athena accepts the query gets no reason."** True but not a defect: there
  is no query execution and so nothing to read, and that path already reports its own error
  (`athena_run_ops.ex:27-33`). Recorded in Out of Scope instead of as a finding.

## Self-Review: Round 2

A second pass, verified against the code on this branch. Implementation-level findings from the same
pass are in [implementation.md](implementation.md); the two that bear on scope and on what the
researcher is told are recorded here.

### Education Researcher

#### RESOLVED: the guidance tells researchers to use a filter that does not exist for most reports

Three of the five suggestions instruct the reader to "select an application". Checked against the
branch:

- `ReportFilter` on this branch has no application field. `defstruct` (`report_filter.ex:8-10`) runs
  `filters` through `exclude_internal` with nothing in between. The field is added by REPORT-105,
  on `REPORT-105-log-report-app-filter`, which is **not merged**: this branch is based on `master`,
  whose tip is `2a99796`. If REPORT-106 ships first, every mapped suggestion names a control that is
  not on the form.
- Even after REPORT-105 merges, the filter is not general. It is switched on per report via
  `form_options: [enable_app_filter: true]`, and REPORT-105 sets it on exactly two:
  `student-actions` and `student-actions-with-metadata` (`tree.ex`). The other Athena reports,
  `student-answers` among them, never get an application selector.

So a researcher whose **Student Answers** run fails on the partition limit is told to do something
the form does not let them do. The spec is explicit that "the wrong suggestion is worse than none",
and requires that an unrecognized reason not fall back to generic advice for exactly that reason.
That standard is not met by advice that names a nonexistent control, and the failure is quieter than
an unmapped reason because it looks authoritative.

**Decision** (2026-09-04): make the application half conditional on the run's report offering the
filter, and take no dependency on REPORT-105's branch.

The sequencing half of the original suggestion turned out to be unnecessary. The condition is
`Keyword.get(form_options, :enable_app_filter, false)`, and `form_options` is a keyword list
defaulting to `[]`, so the absent key reads `false` rather than raising. Ran it against the real tree
on this branch: all five Athena reports return `false`, so no advice mentions applications and every
string is correct as shipped. REPORT-105's `tree.ex` change flips the two log reports to `true` on
its own, with no follow-up commit here. The two stories merge in either order.

Rebasing this branch onto `REPORT-105-log-report-app-filter` was considered and rejected. PR #417 is
open and under review at 13 commits ahead of master; basing on it would mean either a pull request
carrying 13 unrelated commits or a stacked one that must be re-rebased on every force-push, and it
would entangle this story if that one changes shape. The only thing it would buy is exercising the
`true` path against the real tree, which the existing `TreeStub` pattern
(`athena_run_ops_test.exs:9-11`) already covers.

Plumbing cost is nil: guidance renders only on the run page, and `report_header/1` already receives
the `%Report{}` (`show.html.heex:10`). The API carries the raw reason and the query id, not the
suggestion, so nothing changes there.

One residual coupling, recorded rather than solved: if REPORT-105 renames `:enable_app_filter` before
merging, this condition silently reads `false` forever and the clause never appears. Once REPORT-105
lands, add a test asserting at least one Athena report in the real tree offers the filter. It cannot
be written before then, because it fails on this branch today.

### Security Engineer

#### RESOLVED: the new CloudWatch log line is a third disclosure surface and was not analyzed

The spec analyzes reason disclosure carefully for the two display surfaces, establishing that the API
is owner-only and the run page owner-or-admin, and concluding that the owner supplied or already
received every identifier their own query embeds. That argument is sound for the owner and is the
right one.

The same story also adds `Logger.error("Athena query ... failed: #{inspect(reason)}")` to the poller,
and that surface gets no analysis at all. It differs from the other two in audience and retention:
it goes to CloudWatch, is read by operators rather than by the run's owner, and is not governed by
either gate the spec reasons about. Against the spec's own premise that the reason can echo query
text, the content at risk is not only identifiers: `report_query.ex:121` embeds `secure_key` values,
and a secure key is the last path segment of
`https://<portal>/dataservice/external_activity_data/<secure_key>`, which is a capability for that
learner's data rather than a bare id.

This is a small probability on a real path, not a live leak, and the four observed reasons do not
echo query text. But the spec's Out of Scope says making failures observable to operators is a
different story, and this line is the first step of exactly that, taken without the analysis the
other two surfaces got.

**Decision** (2026-09-04): keep the line, bound it with the shared `AthenaFailure.truncate/1`, and
record the disclosure judgment in the requirements rather than leaving it inherited.

The concrete defect was that the line is unbounded: the changeset truncation from the byte-ceiling
finding covers what is stored, not what is logged, so a 70,000-byte reason produced a
70,000-character log line. Bounding it costs nothing and was measured at 4,051 characters after.

Logging only the error code prefix was considered and rejected. It degrades cleanly, including for
`Slowdown`, which has no colon, but it drops the S3 request id on a throttling failure, and the
poller's only consumer is the CLUE answers path, which persists nothing, so the log is the only
record that failure leaves. The residual exposure is a reason echoing query text into a stream that
has never carried SQL; judged acceptable on the grounds written into the Capture and persist
requirements, where a reader will find it beside the other two surfaces.

One consequence for the byte-ceiling decision above: the truncation helper is a public function on
`AthenaFailure`, called by both the changeset and the poller, rather than a private helper inside
`ReportRun`. That also moves the reason module to the first implementation step, since the two steps
that store and log a reason both depend on it.

### WCAG Accessibility Expert

#### RESOLVED: the failure block appears through a live update and is never announced

The run page polls while a run is non-terminal: `maybe_poll_query_state/2` reschedules
`:poll_query_state` every second (`show.ex:232-236`), and `handle_info/2` reassigns `report_run`
(`show.ex:135-142`), so `report_header/1` re-renders in place. A researcher watching a running report
sees the region change from "Report status: Running" to the suggestion, the raw reason and the query
id with no page navigation.

The proposed markup carries no `role="alert"` and no `aria-live` region, so for a screen reader user
nothing announces that the run failed or what the suggestion is. The content is reachable only by
re-navigating the page. This is the one part of the story written specifically for a reader who
cannot use AWS, so silently swapping it into the DOM undercuts the story's own purpose.

The existing bare state has the same gap, which is why this is worth deciding now rather than
inheriting: the story is replacing that markup anyway.

**Decision**: adopted. The failure block gets `role="status"` on a container that is present before
the reason arrives, so the patch mutates its contents rather than creating the region. Recorded in
the Expose it requirements and in the run-page implementation step, with a rendering test asserting
the attribute.

### Factual corrections

All three are applied.

- **REPORT-33 is already `Done`.** The Overview says this story "closes REPORT-33 ... open ever since
  because there was nowhere to put the answer", and the Project Owner Overview repeats it. The ticket
  was resolved 2026-09-03, before this spec was written. The mapping entry is still the right thing
  to ship and still satisfies REPORT-33's acceptance criteria, but the framing that it is being
  closed here is no longer true and will read as wrong to anyone who opens the ticket.
- **`run_json/1` is private.** The test bullet "`run_json/1` includes `athena_query_id` and
  `athena_query_error`, asserted by value" cannot be written as stated: `run_json/1` is a `defp`
  (`report_json.ex:24`), reachable only through `show/1` and `index/2`. The implementation spec's
  version of this test goes through `GET /api/v1/reports/:id`, which is correct; only the
  requirements wording needs to match.
- **`get_api_report_run/2` also filters on report slug.** The spec describes it as filtering on
  `r.user_id` with no admin exemption, which is the load-bearing half and is correct. It additionally
  requires `r.report_slug in ^Tree.api_report_slugs()` (`reports.ex:96`), which matters for anyone
  reasoning about why a run is invisible through the API.
