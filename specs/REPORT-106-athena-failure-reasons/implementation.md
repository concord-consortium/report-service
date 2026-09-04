# Implementation Plan: Persist and Surface Athena Failure Reasons on Report Runs

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-106
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

Server half only. The cc-data-cli half sequences with REPORT-94 and is out of scope here; the one
non-obvious thing it must do is recorded in the requirements spec.

Steps are ordered so each compiles and its tests pass without the next. The reason module comes
first, because the two steps that store and log a reason both call its `truncate/1`; capture comes
before the two that display what it stores.

## Implementation Plan

### Add the Athena failure reason module

**Summary**: Everything this app does with a `StateChangeReason`: bounding it, and mapping a
recognized one to a suggestion. Both are pure functions with no callers yet, so the module is
testable on its own and its two hazards, the pattern ordering and the byte ceiling, are pinned before
anything stores, logs or renders a reason. It comes first because the next two steps both call
`truncate/1`.

**Files affected**:
- `server/lib/report_server/reports/athena_failure.ex` — new
- `server/test/report_server/reports/athena_failure_test.exs` — new

**Diff size**: 287 lines as built

Two properties carry the correctness here, and they are coupled: matching is **case-insensitive**,
and the table is **an ordered list matched first-to-last, not a map**.

Case-insensitivity first, because the ordering rule depends on it. S3's throttling error code is
spelled `SlowDown` and the generic Athena condition is spelled `Slowdown`; `String.contains?/2` is
case-sensitive, so a `"Slowdown"` pattern matches neither a real `SlowDown` nor `SLOWDOWN`. Built the
table and ran it: `contains?(throttle_reason, "Slowdown")` is `false` while
`contains?(throttle_reason, "SlowDown")` is `true`. Case-sensitive matching therefore both misses
REPORT-33's condition on the casing AWS is most likely to emit and removes the very overlap the
ordering rule exists to resolve, which leaves the ordering test unable to fail.

With matching case-insensitive the overlap is real: a `HIVE_S3_THROTTLING` reason contains
`SlowDown`, so it matches the `slowdown` pattern too, and the two have deliberately opposite advice.
Order is then the correctness property, not a style choice. Verified by building the table in both
orderings: case-insensitive, the reversal changes the answer; case-sensitive, it does not.

The advice that narrowing helps is conditional on the run's report offering an application filter,
so the table is built per report rather than held as a module attribute. Only the narrowing phrase
varies, and it has one definition rather than each sentence being written out twice.

```elixir
alias ReportServer.Reports.Report

# Athena documents no bound on StateChangeReason and the column's is 65,535 bytes, past which
# the write raises rather than truncating and strands the run non-terminal. 4,000 is roughly
# ten times the longest reason observed, so no real one is touched. Byte-oriented, because the
# column's limit is: a multi-byte reason of about 21,800 characters already exceeds it and
# String.slice/3 by characters does not bound bytes.
@max_reason_bytes 4_000
@truncation_marker " ... (truncated)"

def max_reason_bytes, do: @max_reason_bytes

def truncate(nil), do: nil
def truncate(reason) when byte_size(reason) <= @max_reason_bytes, do: reason
def truncate(reason) do
  keep = @max_reason_bytes - byte_size(@truncation_marker)
  <<prefix::binary-size(keep), _rest::binary>> = reason
  trim_to_valid(prefix) <> @truncation_marker
end

# The prefix can split a codepoint, so step back until it is valid UTF-8. At most three passes.
defp trim_to_valid(binary) do
  if String.valid?(binary), do: binary, else: trim_to_valid(binary_part(binary, 0, byte_size(binary) - 1))
end

# Ships verbatim from REPORT-33 and is the same in both variants. It must never suggest
# narrowing: Slowdown is an internal Athena condition that neither the researcher nor this
# server can act on, so the advice that is right for the partition and timeout failures is
# actively wrong here.
@slowdown "Your query was delayed due to high traffic in AWS Athena. Please try again in a few moments. This is a temporary issue caused by heavy usage."

def guidance_for(report, reason)
def guidance_for(_report, nil), do: nil
def guidance_for(report, reason) do
  downcased = String.downcase(reason)

  report
  |> offers_app_filter?()
  |> guidance()
  |> Enum.find_value(fn {pattern, advice} -> String.contains?(downcased, pattern) && advice end)
end

# Most Athena reports never offer an application filter, so naming one would be advice the
# researcher cannot act on. Those reports carry no such key, and a keyword default reads that
# as false rather than raising.
def offers_app_filter?(%Report{form_options: form_options}) do
  Keyword.get(form_options, :enable_app_filter, false)
end
def offers_app_filter?(_), do: false

defp narrowing(true), do: "a date range or one or more applications"
defp narrowing(false), do: "a date range"

# Patterns are lowercase and the reason is downcased once before matching. S3 spells its
# throttling code "SlowDown" and Athena spells the generic condition "Slowdown", so a
# case-sensitive match would fire on neither reliably.
#
# Ordered, first match wins. The specific Athena error codes must precede the generic
# slowdown token: a HIVE_S3_THROTTLING reason embeds S3's own SlowDown error code and
# would otherwise take the slowdown branch, whose advice is deliberately the opposite.
# Partition limit and CONSTRAINT_VIOLATION on the injected column are the same problem
# with the same fix, so they deliberately share one string rather than repeating it.
def guidance(app_filter?) do
  narrowing = narrowing(app_filter?)
  too_many_partitions = "This query covers too many Athena partitions. Narrow it with #{narrowing} and run it again."

  [
    {"hive_exceeded_partition_limit", too_many_partitions},
    {"constraint_violation", too_many_partitions},
    {"hive_s3_throttling", "AWS throttled this query. Narrowing it with #{narrowing} will help, and running it outside peak hours will too."},
    {"query timeout", "This query ran out of time. Narrow it with #{narrowing} and consider running it outside peak hours."},
    {"slowdown", @slowdown}
  ]
end
```

Built and run against the real tree. On this branch all five Athena reports read `false`, so the
partition advice reads "Narrow it with a date range and run it again"; with `enable_app_filter: true`
it reads "Narrow it with a date range or one or more applications and run it again". `Slowdown` is
byte-identical in both variants and mentions neither.

The patterns must stay lowercase, since `guidance_for/2` only ever compares them against a downcased
reason. A pattern added with any uppercase character silently never matches, which is the same defect
this design exists to remove, so the test below walks both variants of the table and asserts it.

The `Slowdown` text is the exact string carried over from REPORT-33 and must ship verbatim. Its
advice deliberately contains no instruction to narrow the filter or add a date range, because
`Slowdown` is an internal Athena condition caused by too many small files on S3 that neither the
researcher nor this server can act on.

Tests for `truncate/1`:

- a reason past the byte ceiling comes back under `max_reason_bytes/0` and ends in the marker.
  Catches the truncation being dropped, which turns the persisting poll into a raise and the run into
  a permanent retry loop.
- a 40,000-character multi-byte reason comes back valid UTF-8 and under the byte limit. Catches
  truncation by characters, which does not bound bytes, and truncation by bytes without the codepoint
  repair.
- a reason under the limit comes back byte-identical and carries no marker. Catches a truncation that
  fires on every value, corrupting every real reason with every other test still green.
- `nil` comes back `nil`.

Tests for `guidance_for/2`, six required cases plus the ones that guard the hazards:

- each of the four observed reasons and `Slowdown` returns the expected suggestion, asserted by
  value against the exact string, **in both variants**. Note that this is **not** an all-distinct
  assertion: partition limit and `CONSTRAINT_VIOLATION` share one string by design, so five reasons
  yield four distinct suggestions. Running the table confirmed it, in both variants. An all-distinct
  assertion fails against the correct implementation, and the guard against a mapping that returns
  one string for everything is the per-reason value assertions plus the hazard tests below.
- **a report with no `:enable_app_filter` key mentions no application in any of its five
  suggestions, and one with `enable_app_filter: true` does.** This is the pair that pins the
  conditional. Asserted against a `%Report{}` built in the test rather than against the real tree,
  so it keeps working whichever order the two stories merge in.
- **every Athena report in the real tree currently yields advice that mentions no application.**
  Catches the condition being inverted or dropped, which the constructed-report test above cannot,
  since it never touches `Tree`. This assertion is true on this branch and becomes false for the two
  log reports when REPORT-105 merges, so write it as "no report that does not offer the filter
  mentions one" rather than as a blanket claim, or it turns into a failure on someone else's merge.
- an unrecognized reason returns `nil`, not a generic fallback
- `nil` returns `nil`
- **a reason containing both `HIVE_S3_THROTTLING` and `SlowDown` returns the throttling advice.**
  This is the ordering test. Each pattern works in isolation, so no single-pattern test detects the
  order being wrong. It only has that power because matching is case-insensitive: verified that under
  case-sensitive matching both orderings return the throttling advice and the test cannot fail.
- **`Slowdown`, `SlowDown` and `SLOWDOWN` all return the REPORT-33 text.** Catches the
  case-sensitivity regression head-on rather than only through the ordering test.
- **every pattern is already lowercase, in both variants.** A one-line walk of the table. Catches a
  later entry added in the casing AWS uses, which would never match the downcased reason and would
  fail no other test here.
- **the `Slowdown` advice contains neither "date range" nor "application", in both variants, and is
  byte-identical to the string REPORT-33 specifies.** This pins REPORT-33's explicit constraint
  against a future edit that makes the messages uniform, and against the narrowing phrase leaking
  into the one entry that must not carry it.

### Add the athena_query_error column

**Summary**: The migration, the schema field, and the cast. Nothing writes the column yet, so this is
the smallest unit that carries the two decisions the story turns on: the column type and the bound.
It depends only on `AthenaFailure.truncate/1` from the previous step.

**Files affected**:
- `server/priv/repo/migrations/<timestamp>_add_athena_query_error.exs` — new
- `server/lib/report_server/reports/report_run.ex` — field and cast
- `server/test/report_server/reports/report_run_test.exs` — new

**Diff size**: 91 lines as built

```elixir
def change do
  alter table(:report_runs) do
    # :text, not :string. Athena's StateChangeReason routinely exceeds varchar(255) and this
    # server runs with STRICT_TRANS_TABLES, so an over-length reason errors the write rather
    # than truncating, which would strand the run in a non-terminal state.
    add :athena_query_error, :text, default: nil
  end
end
```

The schema gains `field :athena_query_error, :string` (the Ecto type for a `TEXT` column is still
`:string`; only the migration's column type differs) **and `:athena_query_error` must be added to the
`cast/3` list at `report_run.ex:25`**. This was built and run: with the field on the schema but
missing from the cast, `update_report_run/2` returns `{:ok, run}` with the value still `nil`. There
is no error, no warning, and nothing else fails, so the cast has to be covered by its own test rather
than assumed from the field existing.

The changeset also bounds the value. `:text` raises the ceiling to 65,535 bytes but does not remove
the failure it was chosen to prevent: an over-ceiling write raises `MyXQL.Error (1406)` rather than
returning `{:error, changeset}`, so it escapes `refresh_query_state/1`'s `else` clause and propagates
out of `ensure_current/1`, leaving the run non-terminal to raise again on the next poll. Reproduced
end to end. Truncating here makes that unreachable for every writer, present and future, and is
directly testable through `update_report_run/2`.

```elixir
|> update_change(:athena_query_error, &AthenaFailure.truncate/1)
```

The bound itself lives in `AthenaFailure` from the previous step, because the poller logs the reason
too and both call sites must agree. Built and run through `update_report_run/2`: a 70,000-byte reason
that previously raised now stores 4,000 bytes ending `"... (truncated)"`, the run reaches `failed`
and `non_terminal?` goes false; a 40,000-character multi-byte reason stores valid UTF-8; a 352-byte
reason is stored byte-identical with no marker; `nil` still round-trips.

Tests:

- a reason longer than 255 characters round-trips through the changeset and reads back identical.
  This is the test that catches the migration being written with `:string`: it fails with
  `(1406) Data too long for column`, and it is the only test here that a short fixture would not
  have caught.
- `athena_query_error` set through `update_report_run/2` is persisted, which fails if the cast list
  is not updated.
- a row written without the field reads back `nil`.
- a reason past the byte ceiling is stored truncated, under `AthenaFailure.max_reason_bytes/0`, and
  `update_report_run/2` returns `{:ok, _}` rather than raising. The truncation function's own edge
  cases are covered in the previous step; what this one pins is that the changeset actually calls it,
  which is the difference between a bounded column and a run stuck in a permanent retry loop.

### Capture the reason from Athena

**Summary**: Return `StateChangeReason` from `get_query_info/1` and persist it. This is the change
that makes the data exist.

**Files affected**:
- `server/lib/report_server/athena_db.ex` — the return shape
- `server/lib/report_server/athena_query_poller.ex` — four clauses, plus logging the reason
- `server/lib/report_server/reports/athena_run_ops.ex` — persist it
- four existing tests, listed below

**Diff size**: 126 lines as built

`athena_db.ex`: `result` is already bound to the `QueryExecution` map (`athena_db.ex:26`), so the
reason is one line and needs no restructuring:

```elixir
{:ok, %{"QueryExecution" => %{"Status" => %{"State" => state}} = result}, _} ->
  output_location = (result["ResultConfiguration"] && result["ResultConfiguration"]["OutputLocation"]) || nil
  reason = result["Status"]["StateChangeReason"]
  {:ok, String.downcase(state), output_location, reason}
```

No guard is needed for the states that carry no reason: a `SUCCEEDED` or `RUNNING` payload has no
`StateChangeReason` key and map access yields `nil`. Confirmed by running against the real response
shape.

`athena_query_poller.ex`: all four clauses (`:18-27`) take a fourth element, and the module gains
`alias ReportServer.Reports.AthenaFailure`. The failed and cancelled
clauses also log the reason (diagnostic only, deliberately untested; see the requirements spec), which is the resolved decision from the requirements spec: the poller's
return value does not change, so the CLUE answers path is undisturbed, but the reason stops being
invisible in CloudWatch for that path.

```elixir
{:ok, "failed", _output_location, reason} ->
  Logger.error("Athena query #{query_id} failed: #{inspect(AthenaFailure.truncate(reason))}")
  {:error, "Query failed"}
```

The log line is bounded by the same helper the changeset uses. Without it this path is the one place
an unbounded reason still reaches somewhere: the changeset truncation covers what is stored, not what
is logged, and the poller logs the reason straight from `get_query_info`. Measured: a 70,000-byte
reason produces a 4,051-character log line instead of a 70,000-character one.

The full bounded reason is logged rather than just its error code, and that is a decision rather than
an inheritance. The poller's only consumer is the CLUE answers path, which persists nothing, so this
line is the sole record of why that query failed, and the detail past the code is what an AWS support
case needs (the throttling reason carries S3's request id). The cost is that a reason echoing query
text would put it in the log stream, and the CLUE query embeds `secure_key` values and full
`run_remote_endpoint` URLs (`clue.ex:207-208`). That is judged acceptable: no observed reason echoes
query text, the path that would is a syntax or resolution error that cannot occur on a query this
server generates and does not vary, and the log stream already carries a username
(`clue.ex:674`). Recorded here so a later reader sees it was weighed.

Note this is the first time query text could reach the logs at all: SQL is logged nowhere today.

The bound also has to be applied at the log site rather than at the source in `athena_db.ex`. Doing
it in `get_query_info/1` would bound both callers in one place, but every test stubs that function
and so bypasses it, leaving the persistence boundary, which is where the raise happens, unprotected.

Note `athena_query_poller.ex` uses `IO.puts` for its existing error branch (`:29`) and has no
`require Logger`; adding one is part of this step.

`athena_run_ops.ex:39-40` destructures the fourth element and includes it in the update. The
`non_terminal?/1` guard at `:38` already prevents a terminal run from being re-read, so a stored
reason cannot be overwritten, and a failed run is never retried in place (`:16`, `:52-55`), so
nothing needs to clear it.

The four existing tests that supply three-element stubs, established by making the change and running
the suite rather than by grepping (several other `get_query_info` stub sites are
`raise "should not be called"` guards that never execute):

- `test/report_server/reports/athena_run_ops_test.exs:44`
- `test/report_server_web/api/v1/report_controller_test.exs:314`
- `test/report_server_web/api/v1/report_controller_test.exs:435`
- `test/report_server_web/live/report_run_show_live_test.exs:67`

`test/support/athena_db_stub.ex` needs no change: it applies whatever function the test supplies.

A sixth stub site needs updating and does not announce itself: the `echo` map behind the
non-succeeded download cases in `report_controller_test.exs`. A three-element tuple no longer matches
the `with` clause, so those cases fall through to the error branch, which leaves the run untouched,
which is exactly what the test then asserts. It stays green while exercising the wrong path, so it
has to be found by reading rather than by running the suite.

New tests:

- a `failed` response persists the reason; a `cancelled` response persists the reason; a `succeeded`
  response persists `nil`
- a response with no `StateChangeReason` key persists `nil` rather than raising. Covered at the stub
  boundary, with `nil` as the fourth element, rather than by feeding a key-less payload through
  `get_query_info/1`: `AthenaDB` builds its AWS client inline and has no seam, so the extraction
  itself is not reachable from a test. What the extraction relies on is that indexing a map with a
  missing key yields `nil`, which is language behavior rather than ours
- a terminal run's stored reason is unchanged by a subsequent `refresh_query_state/1` call
- **a `failed` response carrying a reason past the byte ceiling leaves the run at
  `athena_query_state: "failed"` with `non_terminal?/1` false.** This is the assertion the truncation
  exists for, and the one the changeset test in the previous step cannot make: that one proves the
  stored string got shorter, this one proves the run escaped the retry loop. Without the bound this
  raises `MyXQL.Error (1406)` out of `refresh_query_state/1` and the run stays `"running"` forever.
  Reproduced both ways.

### Expose the reason through the API

**Summary**: Two fields on the run JSON and two on the not-ready body.

**Files affected**:
- `server/lib/report_server_web/api/v1/report_json.ex` — `run_json/1`
- `server/lib/report_server_web/api/v1/report_controller.ex` — the `NOT_READY` context
- `server/test/report_server_web/api/v1/report_controller_test.exs`

**Diff size**: 72 lines as built

`run_json/1` (`report_json.ex:24-36`) gains `athena_query_id` and `athena_query_error`.
`report_controller.ex:84` gains both in its context map:

```elixir
ErrorHelpers.render_error(conn, "NOT_READY", "The report is not ready to download.",
  %{athena_query_state: athena_query_state, athena_query_id: report_run.athena_query_id,
    athena_query_error: report_run.athena_query_error})
```

No nesting under an `Extra` key: `render_error/4` merges context at the top level
(`error_helpers.ex:24-29`), and the cc-data client's `decodeAPIError`
(`internal/api/client.go:189-214`) already collects every top-level field except `error` and
`message` into `Extra`.

Tests must assert **by value**, not by key set, and here there is not even a key-set guard to lean
on: adding `athena_query_id` to `run_json/1` and running the suite left all 519 tests passing, so
nothing at all currently notices a change to the run body's shape. (The filter object has
`@filter_keys`; the run object has no equivalent.) Nothing catches a field that is never added
except an explicit assertion on its value:

- a failed run's `GET /api/v1/reports/:id` returns the reason and the query id
- the `NOT_READY` download body carries all three fields
- a run predating the column returns `nil` for both and does not error
- a non-owner gets a 404 rather than the reason, and so does an admin who is not the owner:
  `get_api_report_run/2` filters on `user_id` with no admin exemption (`reports.ex:95`)

### Show the reason on the run page

**Summary**: Replace the bare state with the suggestion, the raw reason, and the query id.

**Files affected**:
- `server/lib/report_server_web/components/custom_components.ex` — `report_header/1`
- `server/test/report_server_web/live/report_run_show_live_test.exs`
- `server/test/report_server_web/components/custom_components_test.exs`

**Diff size**: 122 lines as built

`custom_components.ex` carries a single alias today (`:6`), so this step also adds
`alias ReportServer.Reports.AthenaFailure`. No new assign is needed: `report_header/1`
already declares `attr :report` and receives the `%Report{}` from `show.html.heex:10`, which is what
`guidance_for/2` reads the application-filter option from.

`report_header/1`'s non-succeeded branch (`custom_components.ex:151-155`) currently renders only
`Report status: <state>`. It becomes: the state as today, then, when `athena_query_error` is present,
the mapped suggestion, then the raw reason, then the query id in a details line.

The suggestion leads because it is the only part written for the reader; the raw reason follows
directly, always present and unmodified, since it is what makes a support conversation possible and
is the only content available when a reason is unmapped. The query id is last and visually quiet: it
is for whoever has AWS access, not for the researcher.

The reason carries `break-words`. It can run to the bound of 4,000 bytes and can contain a single
unbroken token, an S3 url among them, which would otherwise push the page sideways.

```heex
<div>
  Report status: <span class="font-bold capitalize"><%= @report_run.athena_query_state || "gathering information..." %></span>
</div>
<div role="status" class="mt-2">
  <div :if={@report_run.athena_query_error}>
    <div :if={guidance = AthenaFailure.guidance_for(@report, @report_run.athena_query_error)} class="font-bold">
      <%= guidance %>
    </div>
    <div class="mt-1 font-mono text-sm break-words"><%= @report_run.athena_query_error %></div>
    <div :if={@report_run.athena_query_id} class="mt-1 text-xs text-gray-600">
      Athena query id: <%= @report_run.athena_query_id %>
    </div>
  </div>
</div>
```

The conditional application clause is covered in `custom_components_test.exs` through
`render_component/2` rather than through the LiveView. `ReportRunLive.Show` resolves its report with
a direct `Tree.find_report/1` call (`show.ex:33`) rather than through the `:report_tree` seam the
rest of the app uses, so putting a stub tree in the application env does not change the report the
page renders, and only a component call can supply one that offers the filter. Written against the
LiveView the assertion passes vacuously in one direction and cannot pass at all in the other. The
same file covers the live region's presence and the wrapping class, since both are properties of the
markup rather than of the page.

Tests, against the existing LiveView harness (`log_in_conn/2`, `test/support/conn_case.ex:56`):

- a failed run with a mapped reason renders both the suggestion and the raw reason
- a failed run with an unmapped reason renders the raw reason and no suggestion
- a run with no reason renders no suggestion, no reason and no query id, so unaffected runs gain
  nothing but the empty live region
- the failure block carries `role="status"`, and the container is present even when there is no
  reason, so the LiveView patch mutates a live region rather than creating one
- the query id appears for a failed run
- an admin who is not the owner sees the reason here, matching the page's owner-or-admin gate
  (`show.ex:36`), which is the opposite of the API's owner-only rule
In `custom_components_test.exs`, through `render_component/2`:

- a failed run on a report that offers the application filter renders the application clause, and one
  on a report that does not renders the same suggestion without it
- the reason element carries `break-words`
- a succeeded run renders the download control and no live region, which pins the block to the branch
  it belongs in
- a run predating the migration, with both new fields `nil`, renders without error and shows neither
  a suggestion, a reason nor a query id. The API half of this is covered in the previous step; this
  is the run page half, and it is the state every existing failed run is in on the day this deploys,
  since no backfill is in scope


## Open Questions

None. Both questions the requirements spec raised were resolved there.

## Self-Review

Roles: the engineer who has to write the named tests, the reviewer who has to read the resulting
commits, and a senior engineer on the code itself. Every finding was checked by building the proposed
code and running it. One finding corrects the requirements spec as well, which is noted below rather
than deferred, because leaving a known-wrong test in place would have it written and then deleted.

### The engineer who has to write the tests

#### RESOLVED: the required distinctness test fails against the correct implementation

Both specs asked for "each of the five reasons maps to a distinct suggestion". Building the guidance
table and running it shows five reasons yielding **four** distinct suggestions: partition limit and
`CONSTRAINT_VIOLATION` share one string, which is correct and is what the ticket asks for, since they
are the same problem with the same fix. So the test as specified would fail against a correct
implementation, and the likely response to that failure would be to weaken it or to invent a
gratuitously different string for one of the two.

Corrected in both specs: assert each reason's suggestion by exact value, and state explicitly that
the mapping is not all-distinct and why. The real guards against a degenerate mapping are the
per-reason value assertions plus the two hazard tests. Both were superseded in round 2: the
throttling-versus-`Slowdown` test only became able to fail once matching was made case-insensitive,
and the second assertion now reads "date range" and "application", because the rewritten suggestions
contain the word "filter" nowhere and asserting on it could not fail.

### Senior Engineer

#### RESOLVED: the shared suggestion was written out twice

The guidance literal repeated the same sentence for the partition-limit and `CONSTRAINT_VIOLATION`
entries. Two copies of a string that must stay identical is the duplication that drifts, and it is
also what made the distinctness confusion above hard to see. Extracted to `@too_many_partitions` and
referenced twice, so the sharing is deliberate and visible.

### The reviewer who has to read the commits

#### RESOLVED: the run-page step used an unaliased module

`custom_components.ex` carries exactly one alias (`:6`). The proposed markup referenced
`AthenaFailure` with no mention of adding one, which is the kind of omission that turns a
clean step into a compile error on someone else's machine. Named in the step.

#### RESOLVED: the API step leaned on a guard that does not exist

The step said to assert by value rather than by key set "because the key-set assertions guard against
undeclared keys". True, but understated: adding `athena_query_id` to `run_json/1` and running the
full suite left all 519 tests passing. There is no key-set guard on the run object at all, unlike
`@filter_keys` for the filter object, so nothing whatsoever notices a change to the run body's shape.
Restated, because it makes the by-value assertions the only protection rather than a second layer.

### Verified and left unchanged

- The HEEx pattern `:if={guidance = AthenaFailure.guidance_for(...)}` compiles under
  `--warnings-as-errors` and `guidance` is genuinely in scope in the element body. Rendered both
  paths: a mapped reason emits the suggestion and the raw reason, an unmapped one emits the raw
  reason and no suggestion element at all.
- The ordered-list mapping returns the right advice for every observed reason, including the
  throttling-versus-`Slowdown` collision that motivated the ordering.
- The `StateChangeReason` extraction needs no guard clause: `SUCCEEDED` and `RUNNING` payloads yield
  `nil` rather than raising.
- The arity change is caught entirely by the compiler and four named tests, with nothing silent.

## Self-Review: Round 2

A second review pass, run against the code on this branch rather than against the spec's own prose.
Every finding below was reproduced by building the proposed code and running it: the guidance table
was transcribed verbatim and exercised, the migration was applied to the running database and rolled
back, the arity change was made for real and the full suite run, and the proposed HEEx was compiled
and rendered. Claims that survived verification are listed at the end so they are not re-litigated.

### Senior Engineer

#### RESOLVED: the `Slowdown` pattern cannot match the string the ordering rule exists to disambiguate

Both specs build the ordering requirement on this claim: a `HIVE_S3_THROTTLING` reason carries S3's
own error code, "the literal string `SlowDown`", so it matches the `Slowdown` pattern too. The
implementation spec then writes that pattern as `"Slowdown"` and matches with `String.contains?/2`,
which is case-sensitive. `SlowDown` and `Slowdown` differ in one character.

Transcribing the `@guidance` table verbatim and running it against a realistic throttling reason:

```
contains?(throttle, "HIVE_S3_THROTTLING") = true
contains?(throttle, "Slowdown")           = false
contains?(throttle, "SlowDown")           = true
```

Two consequences, and at least one of them is a live defect whichever way the real text falls:

- The collision does not exist as written, so the ordering rule, the requirement it generated, and
  the test that guards it are all protecting against nothing.
- If AWS emits S3's `SlowDown` casing anywhere in the reason text for the REPORT-33 condition, the
  `Slowdown` entry never fires and REPORT-33's acceptance criteria are not met by this story, which
  is the one outcome the ticket names explicitly. Probing the built table:

```
"Slowdown"             -> mapped
"SlowDown"             -> NO SUGGESTION
"SLOWDOWN"             -> NO SUGGESTION
"Error Code: SlowDown" -> NO SUGGESTION
```

The requirements spec's claim that this was "confirmed by running one against realistic reason text:
both patterns matched" does not hold for the patterns the implementation spec actually specifies.

Related, and the same root cause: the requirements spec tells the implementer to "anchor the coded
patterns at the start of the reason where possible", and the proposed implementation uses an
unanchored `String.contains?` for all five entries. The implementation contradicts the requirement
written to constrain it.

**Decision**: adopted. The reason is downcased once and the patterns are held downcased, and the
guidance step above is rewritten accordingly. Built and run: the collision becomes real, the
four-distinct property is intact, and the REPORT-33 entry fires for `Slowdown`, `SlowDown` and
`SLOWDOWN` alike. The anchoring sentence is dropped from the requirements spec rather than
implemented: the coded failures do not reliably begin the reason, so anchoring would trade one
silent-miss failure mode for another. A test now walks `@guidance` asserting every pattern is
lowercase, since an uppercase pattern added later would never match and would fail nothing else.

#### RESOLVED: `:text` moves the strand-the-run failure rather than removing it

The `:text` finding is correct and is the right call, but the argument for it proves more than the
spec concludes. The spec's reasoning is that an over-length reason errors instead of truncating, and
because the write sits inside `refresh_query_state/1`, which runs on every poll, the run never
reaches a terminal state. That reasoning applies unchanged to `TEXT`, whose ceiling is 65,535
**bytes**, not characters.

Applying the proposed migration to the running database and writing through `update_report_run/2`:

```
  60000 chars -> OK
  65535 chars -> OK
  65536 chars -> ERROR: (1406) Data too long for column 'athena_query_error'
  80000 chars -> ERROR: (1406) Data too long for column 'athena_query_error'
```

and for multi-byte text, 40,000 characters (120,000 bytes) also fails, so a UTF-8 reason of roughly
21,800 characters is already over the line. Note also that this arrives as a **raise**, not as
`{:error, changeset}`: `refresh_query_state/1`'s `else` clause never sees it, so it propagates out of
`ensure_current/1` and crashes the API request or the polling LiveView rather than being handled.

Athena reasons of that size are not the common case, but they are not excluded either: syntax and
resolution errors echo query text, and `check_query_size/1` (`athena_db.ex:172-179`) permits queries
up to 256KB.

**Decision** (2026-09-04): truncate in the changeset at 4,000 bytes with a ` ... (truncated)` marker,
keeping `:text` for the column.

The changeset was chosen over the two other places it could live. Truncating in `athena_db.ex` would
also bound the poller's log line, but stubbed tests bypass that function entirely, so the persistence
boundary, which is where the raise happens, would stay unprotected. `MEDIUMTEXT` would make the
failure astronomically unlikely rather than impossible and still store and render unbounded text,
which treats a correctness property as a capacity problem.

4,000 bytes is roughly ten times the longest reason observed, so no real reason is affected, and it
keeps the run page and the API response readable. The marker stays: a truncated reason that looks
complete would mislead a support conversation. Note that this bounds what is persisted and served,
not what the poller logs, which is picked up separately in the CloudWatch finding.

### QA Engineer

#### RESOLVED: the mandated ordering test cannot fail

Both specs require this test and describe it as the one that no single-pattern test can substitute
for: "a reason containing both `HIVE_S3_THROTTLING` and `SlowDown` maps to the throttling suggestion,
not the `Slowdown` one. Catches the pattern ordering being reversed."

Built the table twice, once in the specified order and once with the `Slowdown` entry moved ahead of
`HIVE_S3_THROTTLING`, and ran the specified input through both:

```
correct order  -> AWS throttled this query. Narrowing it w...
REVERSED order -> AWS throttled this query. Narrowing it w...
Does the ordering test CATCH the reversal? false
```

The mutation the test is specified to catch leaves it green, because the `Slowdown` pattern never
matches the input at all. As specified it is decoration.

**Decision**: fixed by the case-insensitivity change rather than by rewriting the test. Re-ran the
same comparison against the corrected table: the two orderings now give different answers, so the
test catches the reversal. The coupling is written into both specs beside the test, so a later edit
cannot quietly decouple them.

#### RESOLVED: "a succeeded run persists `nil`" asserts the stub, not the code

The requirements spec states the reason "is captured for `failed` and `cancelled`; for every other
state it is `nil`", and requires a test that a succeeded response persists `nil`. The proposed
implementation has no state-conditional logic: `reason = result["Status"]["StateChangeReason"]` runs
for every state, and `refresh_query_state/1` persists whatever comes back.

So the property holds only because Athena happens not to send a reason for `SUCCEEDED`, and the test
demonstrates that the stub returned `nil`, not that our code did anything. Adding a state gate or
removing one both leave it green.

**Decision**: restated rather than gated. Adding a state gate would be code written to make a test
meaningful rather than to change behavior, and it would have to be revisited the first time Athena
attaches a reason to a state we did not anticipate. The requirement now says capture is unconditional
pass-through, and the succeeded case is labeled in both specs as a pass-through check that asserts
the payload rather than a guard on state handling.

### Verified and left unchanged

These claims were re-checked against the branch and hold as written:

- The `:text` decision itself. All three existing Athena columns are `varchar(255)` in the running
  database, `sql_mode` includes `STRICT_TRANS_TABLES`, and the same 390-character reason errors with
  `(1406) Data too long` on `varchar(255)` while round-tripping identically through `TEXT`.
- `default: nil` on a `:text` column migrates cleanly on MySQL 8. Ecto emits no `DEFAULT` clause, so
  the "BLOB/TEXT can't have a default value" error does not arise.
- An uncast field is silently dropped. With `athena_query_error` on the schema but absent from
  `cast/3`, `update_report_run/2` returned `{:ok, run}` and both the returned struct and the reloaded
  row held `nil`, with no error and no warning.
- The HEEx `:if={guidance = AthenaFailure.guidance_for(...)}` pattern compiles under
  `--warnings-as-errors` and `guidance` is in scope in the element body. Rendered all four states:
  mapped, unmapped, no reason, and a reason containing markup, which HEEx escapes.
- Exactly four tests break on the arity change, and they are the four named, at the lines cited.
- Nothing notices a change to the run body's shape: adding both fields to `run_json/1` introduced no
  new failures.
- The suite is 519 tests, 0 failures, 7 skipped on this head, so that number is current.
- `ExUnit.CaptureLog` is used nowhere in the suite, so the decision not to test the poller's log line
  does not skip an established idiom.
- The test stub is arity-agnostic, and the only other `get_query_info` in the tree
  (`old_report_live/query.ex`) is an unrelated private function.

One claim in the previous round is wrong and should be corrected rather than carried forward: "the
arity change is caught entirely by the compiler". Both call sites dispatch dynamically through the
`athena_db()` seam (`Application.get_env`), so the compiler sees nothing. The change compiled
silently and was caught only by the four tests. The conclusion is unchanged because those four
tests exist, but the reason it is safe is test coverage, not the compiler.
