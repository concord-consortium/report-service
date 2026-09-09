# Implementation Plan: Portal download transaction budget

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-128

**Requirements Spec**: [requirements.md](requirements.md)

**Status**: **In Development**

## Implementation Plan

Three commits. The first is the fix and its two tests, the second makes a blown budget legible, the third corrects the one document outside this folder that records the inverted model. Nothing depends on a later step.

### Give the download the budget it is configured to have

**Summary**: Rename `stream_query/4`'s budget option to the thing it actually controls, delete the option MyXQL discards, and stop the controller deriving a cap from a number that was never a cap. This is the whole behavior change; the two tests that pin it are here because neither is meaningful without it.

**Files affected**:
- `server/lib/report_server/portal_dbs.ex` — `:timeout` becomes `:transaction_timeout`, the inert `timeout:` on `MyXQL.stream/4` goes, the `@doc` is rewritten.
- `server/lib/report_server_web/api/v1/report_controller.ex` — `@portal_download_batch_timeout_ms` and the `min/2` go, along with the blank line the attribute leaves behind inside the alias block, the budget is bound once, and the block comment is replaced.
- `server/test/report_server/portal_dbs_test.exs` — a `stream_query/4` describe block.
- `server/test/report_server_web/api/v1/report_controller_test.exs` — one test pinning what the controller hands down.

**Estimated diff size**: ~70 lines.

`portal_dbs.ex`, replacing the docstring and the two option reads:

```elixir
  @doc """
  Streams a SELECT to a caller-supplied reducer in max_rows batches, inside a transaction.
  reducer :: (%MyXQL.Result{}, acc -> acc). Returns {:ok, acc} | {:error, reason}.
  Exceptions from the reducer propagate (the caller classifies them); only setup/DB errors
  are converted to {:error, reason}.

  opts: :max_rows, :acc (initial accumulator), :reducer, and :transaction_timeout, which is
  DBConnection's checkout deadline and therefore bounds the whole stream, including time the
  reducer spends between batches. There is no per-fetch bound to set alongside it: MyXQL's
  cursor fetches ignore a :timeout option and read from the socket with no deadline of their own.
  """
  def stream_query(server, statement, params, opts) do
    max_rows = Keyword.get(opts, :max_rows, 500)
    transaction_timeout = Keyword.get(opts, :transaction_timeout, @query_timeout)
    acc = Keyword.fetch!(opts, :acc)
    reducer = Keyword.fetch!(opts, :reducer)

    with {:ok, pool_name} <- get_or_start_pool(server) do
      MyXQL.transaction(pool_name, fn conn ->
        MyXQL.stream(conn, statement, params, max_rows: max_rows)
        |> Enum.reduce(acc, reducer)
      end, timeout: transaction_timeout)
    end
  end
```

The default stays `@query_timeout`, so the two existing `:portal_db` callers (`student_id_mapping_report_db_test.exs:125`, `student_metadata_report_db_test.exs:187`), which pass no budget, are untouched.

`report_controller.ex`: delete the module attribute and its comment at `:8-10` outright, then in `stream_portal_csv/5` bind the budget once and hand it down.

```elixir
        budget = portal_download_timeout_ms()
        deadline = System.monotonic_time(:millisecond) + budget
        server = report_run.user.portal_server
        sent = :atomics.new(1, signed: false)
        acc0 = %{conn: conn, state: :header_pending, deadline: deadline, filename: filename, sent: sent}

        # The budget is both the reducer's wall-clock deadline and the transaction's checkout
        # deadline, which is the only thing bounding a fetch: MyXQL fetches take no timeout.
        result =
          try do
            case portal_db().stream_query(server, sql, [],
                   acc: acc0, max_rows: 500, transaction_timeout: budget,
                   reducer: &stream_reducer/2) do
```

Binding `budget` is not cosmetic: the old code read `portal_download_timeout_ms()` twice for two purposes that have to agree, which is what let them drift apart in the first place.

The `stream_query/4` block goes at the end of `portal_dbs_test.exs`, after the `query/4` describe, so the file keeps mirroring the order the functions are defined in `portal_dbs.ex`:

```elixir
  defp stream_sleep(opts) do
    defaults = [acc: 0, max_rows: 500, reducer: fn result, acc -> acc + length(result.rows) end]
    PortalDbs.stream_query(@server, "SELECT SLEEP(2)", [], Keyword.merge(defaults, opts))
  end

  describe "stream_query/4" do
    test "a transaction budget above the query time streams it to completion" do
      assert {:ok, 1} = stream_sleep(transaction_timeout: 6_000)
    end

    test "a transaction budget below the query time ends the stream" do
      assert_raise DBConnection.ConnectionError, fn ->
        stream_sleep(transaction_timeout: 1_000)
      end
    end
  end
```

That shape keeps the file passing `mix format --check-formatted`, which it does on master. The repo as a whole does not: 138 files fail it, and CI runs only `mix compile --warnings-as-errors` and `mix test`, so the rule is to leave an already-clean file clean rather than to format anything.

Measured at 3.0 seconds for the pair, against the fixture database, before this plan was written. The failing half logs a MyXQL disconnect at `[error]`, which is expected: aborting a checkout kills the connection. The file's existing `query_with_reason/4` timeout test already does the same thing, so this is the established idiom here rather than a new hazard.

The controller half, in the `GET /api/v1/reports/:id/download (Portal)` describe block:

```elixir
    test "hands the full configured budget to the streaming seam", %{} do
      {token, run} = portal_admin_run()
      test_pid = self()

      start_portal_stub(fn _server, _sql, _params, opts ->
        send(test_pid, {:stream_opts, opts})
        {:ok, opts[:reducer].(myxql_result(["a"], []), opts[:acc])}
      end)

      conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")
      assert response(conn, 200)

      budget = Application.get_env(:report_server, :portal_download) |> Keyword.fetch!(:timeout_ms)
      assert_receive {:stream_opts, opts}
      assert opts[:transaction_timeout] == budget
    end
```

The expectation is read from config rather than written as `120_000`, so the test cannot disagree with the configured value. The mutation it catches is the one this story exists to remove: reintroduce `min(budget, 15_000)` and the assertion sees 15,000 against a configured 120,000. The `:portal_db` test cannot catch that, because it calls `stream_query/4` directly and never goes through the controller.

---

### Say when a download has run out of budget

**Summary**: A blown budget currently reaches the log as `socket closed`, which is what made this bug hard to read from the outside. Classify the pre-first-byte failure by the clock rather than by exception type and name the budget it blew. The client-visible response does not change.

**Files affected**:
- `server/lib/report_server_web/api/v1/report_controller.ex` — one new private function, one changed call.
- `server/test/report_server_web/api/v1/report_controller_test.exs` — one test.

**Estimated diff size**: ~35 lines.

Classifying by elapsed time rather than by exception type is deliberate, and it follows `kind_by_elapsed/2` in `portal_dbs.ex:66-68`, which already decides timeout-versus-other the same way for `query_with_reason/4`. It is also the only thing that works here: the two exceptions that mean "out of budget" are `PortalDownloadTimeout` from the reducer and a `DBConnection.ConnectionError` from the pool, and the latter is indistinguishable by struct from a pool-start failure or a queue timeout. The message strings differ, but matching on driver message text would break on a dependency bump.

```elixir
          {:pre_stream, reason} ->
            log_pre_stream_failure(report_run, deadline, budget, reason)
            ErrorHelpers.server_error(conn)
```

```elixir
  # At or past the deadline the budget ran out, whatever exception carried it; the reducer's
  # PortalDownloadTimeout and the pool's terminal "socket closed" are the same event.
  defp log_pre_stream_failure(report_run, deadline, budget, reason) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.error("Portal download for run #{report_run.id} exceeded its #{budget} ms budget: #{inspect(reason)}")
    else
      Logger.error("Portal download failed before first byte for run #{report_run.id}: #{inspect(reason)}")
    end
  end
```

Both calls stay on one line, matching the six existing `Logger.error` calls in the module; collapsed they are 114 and 106 characters, inside the file's existing maximum of 122.

The classification is sound in both directions for the reason recorded in the requirements: the checkout deadline starts strictly later than `deadline`, because `deadline` is computed before `get_or_start_pool/1` runs, so a pool-side kill always lands after `deadline` has passed. A pool-start failure or a malformed-SQL `MyXQL.Error` arrives long before it.

The test drives the stub past a small budget rather than using a negative one, so the assertion reads as a real message:

```elixir
    test "a download that runs past its budget says so", %{} do
      put_download_timeout_ms(50)

      {token, run} = portal_admin_run()

      start_portal_stub(fn _server, _sql, _params, _opts ->
        Process.sleep(80)
        {:error, %DBConnection.ConnectionError{message: "socket closed"}}
      end)

      log =
        capture_log(fn ->
          conn = get(authed_conn(token), ~p"/api/v1/reports/#{run.id}/download")
          assert json_response(conn, 500)["error"] == "SERVER_ERROR"
        end)

      assert log =~ "exceeded its 50 ms budget"
    end
```

`import ExUnit.CaptureLog` is added to the test module; `athena_query_poller_test.exs` is the precedent for it in this suite. The three-line config override becomes a `put_download_timeout_ms/1` helper rather than a second copy, and the existing "a deadline in the past" test moves onto it, so the restore path has one definition. The 80 ms sleep against a 50 ms budget has 30 ms of margin and costs the suite 80 ms. Deleting `log_pre_stream_failure/4` and restoring the single `Logger.error` call fails this test, since the generic message contains neither the budget nor the word.

---

### Correct the prose that records the inverted model

**Summary**: REPORT-88's closed spec states, twice, that `MyXQL.stream`'s `:timeout` bounds each fetch. It is the document a reader consults before touching this path, so it is the one that will recreate this bug.

**Files affected**:
- `specs/REPORT-88-expose-portal-reports-through-api.md` — the Timeout / pool bullet at `:52` and decision Q2 at `:85-87`.

**Estimated diff size**: ~10 lines.

The corrected claim also gets a pointer to where it was established, matching the file's existing cross-reference to REPORT-76 at `:56`, so a reader who finds a surprising statement about a dependency can check it instead of re-litigating it. The Timeout / pool bullet loses "(since `MyXQL.stream`'s `:timeout` only bounds each per-batch fetch)" and "plus a per-batch fetch timeout", and gains a sentence saying the wall-clock deadline and the transaction's checkout deadline are the two bounds, and that MyXQL cursor fetches take no timeout. Q2's context sentence and decision drop the per-batch fetch timeout the same way. Q2's actual decision, an API-specific configurable budget rather than the portal DB's five minutes, is unchanged and stays; only the mechanism described under it was wrong.

The three comments inside the server that say the same thing are corrected in the first step, where the code they describe changes.

## Verification

- `mix test` in `server/`, with the fixture database up so the `:portal_db` tests are not excluded, and with the four dummy env vars rather than a sourced `.env`. Master measures 1012 tests, 0 failures, 7 skipped at `02095d3`; this adds four.
- `mix compile --warnings-as-errors --force`. The rename is the thing to watch: `Keyword.get/3` on a renamed key fails silently rather than at compile time, which is why the controller test asserts the key by name.
- **Done, against production, on 2026-09-09**, through the SSH tunnel on 4001 with a local server on the branch code. The tunnel was fingerprinted first (`external_activities` at 3,524 rows and 812 null `tool_id`, against the 3,523 / 812 recorded on 2026-09-04) so the numbers are known to be production rather than staging.

| Run | Report | Result |
|---|---|---|
| 206 | `school-metrics`, state CA | 200 in 30.2 s, 643 rows, 63,657 bytes, chunked `text/csv` |
| 200 | `summary-metrics-by-subject-area`, state MA | 200 in 7.6 s, 7 rows |
| 201 | `school-metrics`, unfiltered | 200 in 71.5 s, 4,051 rows, 334,768 bytes |

  The ticket recorded run 206 failing at 15,004 ms before the fix; that old behaviour was not re-run here, so the comparison is against the ticket's figure rather than a fresh one. Run 206's CSV was also compared byte for byte against the buffered path the web run page uses, rebuilt from the same run through `PortalDbs.query/4` and the same encoder: both are 63,657 bytes with the same SHA-256, which settles the "matches what the web UI produces" criterion on real data rather than on the shared-encoder argument alone.

- **The one thing the check turned up that the spec had wrong**: the unfiltered run takes 71.5 s, not the roughly 30 s the margin was reasoned from, and an aggregate is silent for essentially its whole download: first byte against total is 29.96 s of 30.17 s for run 206 and 70.71 s of 71.55 s for run 201.

- **The edge was then read from the deployed stacks and is not a constraint.** Both environments front the service with a shared `fargate-public-cluster` ALB whose `idle_timeout.timeout_seconds` is **600**, in production (`app/farga-Publi-1R328TZK4E1PC`, account 612297603577) and in QA (`app/farga-Publi-VIQR22PP0CN3`, 816253370536). Seventy seconds of silence is well inside that, and 600 exceeds `portal_download_timeout_ms`, so the server's own budget is always what cuts a download. The value is declared in the sibling `cloud-formation` repo at `fargate/public-network-stack.yml:163-169`, not set by hand, and `fargate/report-server.yml:8` is what ties this service to that network stack. It is shared with the rest of the cluster, so the invariant worth keeping is 600 staying above the download budget.

## Open Questions

None. Q1 in the requirements spec settled the only design decision, and the three steps follow from it.

## Self-Review

Roles: whoever reviews the three commits, whoever has to run the tests, and whoever operates the result. Every claim below was **measured against a working build** of this plan rather than reasoned about, which is why the numbers are exact. Nothing survived as a defect; what follows is the evidence, which is the part worth keeping.

### Whoever reviews the commits

The steps compose and none has a forward dependency. Step one binds `budget` and uses it twice, so it carries no unused variable without step two; step two adds `log_pre_stream_failure/4` and rewires one call, and `budget` and `deadline` are both already in scope at the `{:pre_stream, reason}` branch. `mix compile --warnings-as-errors --force` is clean with all three applied.

### Whoever runs the tests

Every named test was written against the real harness and run. The suite is **1016 tests, 0 failures, 7 skipped**, against master's 1012, 0 and 7 at `02095d3`: the four this plan adds, and the same seven skips. The two `:portal_db` tests genuinely execute rather than being excluded, confirmed by running that file alone (11 tests, up from 9, in 7.4 seconds).

Each test fails on the mutation it claims to catch, one failure each and no collateral:

| Mutation | Result |
|---|---|
| `transaction_timeout: min(budget, 15_000)` in the controller | 41 tests, 1 failure: "hands the full configured budget to the streaming seam", on `opts[:transaction_timeout] == budget` |
| `log_pre_stream_failure/4` replaced by the old single `Logger.error` | 41 tests, 1 failure: "a download that runs past its budget says so" |
| `stream_query/4` ignoring the option and taking `@query_timeout` | 11 tests, 1 failure: "a transaction budget below the query time ends the stream" |

The third is the one that answers whether the `:portal_db` pair is decorative. It is not: the option has to be read for it to pass.

### Whoever operates the result

The classification holds in both directions, which is the claim worth checking because it decides whether an operator is told the truth. A budget failure lands at or after `deadline`, since `deadline` is set before `get_or_start_pool/1` and the pool's own deadline therefore starts later; a pool-start failure or a malformed-SQL `MyXQL.Error` arrives long before it. Both directions are exercised: the new budget test asserts the "exceeded its 50 ms budget" wording, and the four existing pre-first-byte failure tests still assert their generic 500 and pass unchanged.

## Requirements coverage

| Requirement | Step |
|---|---|
| `stream_query/4`'s option named for the checkout deadline, inert `timeout:` deleted, default kept | Give the download the budget it is configured to have |
| Transaction budget is the full `portal_download_timeout_ms` | same |
| A 200 `text/csv` for `school-metrics` and `summary-metrics-by-subject-area`, byte-identical to the web page | **no step**, see the gap below |
| The download still ends at the wall clock, with today's pre-first-byte and mid-stream behavior | no step, and none needed: nothing on that path changes, and the existing "a deadline in the past yields a clean pre-first-byte JSON error" test still exercises it and passes |
| The two tests | Give the download the budget it is configured to have |
| A blown budget names itself in the log | Say when a download has run out of budget |
| The three inverted comments in the server | Give the download the budget it is configured to have |
| REPORT-88's spec corrected | Correct the prose that records the inverted model |
| The spec states in one place what bounds a stalled fetch | the requirements spec's verified findings, plus the rewritten `stream_query/4` docstring |

No step lacks a requirement. The one implementation choice not written as a requirement is binding `budget` once instead of calling `portal_download_timeout_ms()` twice, which serves the transaction-budget requirement and the standing rule that a value needed in two places has one source.

### Gap: neither named report appears anywhere in the plan

The ticket names `school-metrics` and `summary-metrics-by-subject-area` in an acceptance criterion and again in a scope bullet, and the plan mentions neither. That is defensible, because the fix is report-agnostic: it changes one option in `stream_query/4` and one call in the controller, and the two reports reach that code by the same path as every other Portal report. The evidence that they work is the ticket's own production measurement, and repeating it through the tunnel is listed under Verification.

It is still the one place where the plan does less than the ticket says. The alternative considered was a stub-driven test seeding a `school-metrics` run with a `country`/`state`/`subject_area` filter and asserting it streams a CSV through `GET /api/v1/reports/:id/download`, pinning that the report resolves through `Tree`, builds SQL, and is not refused on the download path the way `derives_learner_data: false` refuses it on the bulk path.

**Accepted as-is, no test added** (decided 2026-09-09). The stub-driven version would assert that a report which already downloads still downloads, over a seam where the timeout under test is a value the stub ignores, so it could not fail for the reason this story cares about. What it would really check is `Tree` resolution and SQL construction, neither of which this change touches. The property that matters, that both reports are fast enough to finish inside the budget, is only observable against production, where it is already measured, and repeating it through the tunnel is listed under Verification.
