# Implementation Plan: A report run that can't start fails with its error

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-168
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Three commits, then a staging pre-release. All code is in `server/`. No migration.

### Name the start failures that can't be retried, and explain no learners

**Summary**: Give each permanent start failure's message one home in the module that produces it, so the classifier in the next step compares against the same value the code returns, and add the no-learners guidance (R1, R9). Behavior is unchanged in this step apart from the new guidance sentence, which renders for any stored no-learners error.

**Files affected**:
- `lib/report_server/reports/athena/learner_data.ex`: `no_learners_error/0`, used at line 155.
- `lib/report_server/reports/report_query.ex`: `no_filters_error/0` (line 44), `no_learners_error/0` (line 100), `unknown_app_error/1` and `unknown_app_error?/1` (line 97).
- `lib/report_server/reports/athena/teacher_actions_report.ex`: `no_match_error/0` (line 39).
- `lib/report_server/athena_db.ex`: `query_too_large_error/0`, used by `check_query_size/1`.
- `lib/report_server/reports/athena_failure.ex`: a no-learners entry in `guidance/1`, and the moduledoc widened to cover self-start reasons.
- `test/report_server/reports/athena_failure_test.exs`: guidance for both no-learners messages.
- `lib/report_server_web/api/v1/report_controller.ex` and `test/report_server_web/api/v1/report_controller_test.exs`: the no-filters match, and a message assertion in its existing test.

**Estimated diff size**: ~100 lines.

Each message keeps its exact text; existing tests that assert the literal strings (`report_query_test.exs`, `learner_base_query_test.exs`, the portal report tests) stay as they are and now also pin the functions' values. For example:

```elixir
# report_query.ex
@unknown_app_prefix "Unknown application filter: "

def no_filters_error, do: "Cannot run query with no filters"
def no_learners_error, do: "No learners found to match the requested filter(s)."
def unknown_app_error(app), do: @unknown_app_prefix <> inspect(app)
def unknown_app_error?(message), do: String.starts_with?(message, @unknown_app_prefix)
```

`ReportController.portal_download/4` matches the literal `{:error, "Cannot run query with no filters"}` (line 194). It moves to the function, bound before the `with` and pinned in the `else`, because Elixir refuses a remote call inside a guard (checked: "cannot invoke remote function M.e/0 inside guards"):

```elixir
no_filters = ReportQuery.no_filters_error()

with {:ok, query} <- build_query(report, report_run),
  # ...
else
  {:error, ^no_filters} ->
    ErrorHelpers.unprocessable(conn, "This report run has no filters and cannot be downloaded.")
```

The existing test "a construction error (super-admin blank filter) returns a clean 422, not a raised 500" in `report_controller_test.exs` already reaches this branch, and fails if the pinned value stops matching the returned message (checked by misspelling the literal). This step adds one assertion to it, that the body's `message` is "This report run has no filters and cannot be downloaded.", rather than a second test. The run must belong to a super-admin, as that test's `portal_admin_run/1` does: for any other user the allowed-projects scope adds a `1 = 0` clause, so the query is never empty and the branch is not reached.

The guidance entry goes first in `AthenaFailure.guidance/1`, matching the lowercase substring `"no learners"`, which both messages carry and no Athena reason does:

```elixir
@no_learners "No student work matches these filters. If you chose a class or an assignment, check that the assignment itself is in one of your projects' cohorts or material lists: a class whose teacher is in your project is not enough on its own."
```

The moduledoc and `guidance/1`'s doc say the table covers the reasons a run failed to start as well as Athena's `StateChangeReason`. Tests: `guidance_for/2` returns `@no_learners` for `LearnerData.no_learners_error()` and `ReportQuery.no_learners_error()`, and nil for `TeacherActionsReport.no_match_error()`.

---

### Fail or release an unstarted run by its start outcome

**Summary**: The core of the story (R1 to R8, R12). `start_query/1` becomes private and returns a classified outcome instead of writing; `ensure_current/1` records that outcome with a write guarded on its own claim, catches raises, applies the 10-minute retry window, and fails abandoned claims.

**Files affected**:
- `lib/report_server/reports/athena_run_ops.ex`: as below.
- `lib/report_server_web/live/report_run_live/show.ex`: the one `start_query/1` call, as in the notes below.
- `test/report_server/reports/athena_run_ops_test.exs`: the `ensure_current/1` and `start_query/1` describes reworked, as below.

**Estimated diff size**: ~260 lines, about 70 of them code.

```elixir
# A start can run several portal queries, each allowed 5 minutes (PortalDbs @query_timeout), so a
# claim this old belongs to a process that died. The retry window keeps a run that can't start
# well inside a client's poll budget.
@retry_window_seconds 10 * 60
@abandoned_claim_seconds 30 * 60

@retrying "The report could not be started because of a temporary error; it will be retried."
@gave_up "The report could not be started because of a temporary error. Duplicate the run to try again."
@abandoned "The report could not be started; the attempt to start it did not finish."
@unexpected "An unexpected error occurred while running the report."

def ensure_current(report_run = %ReportRun{id: id, athena_query_id: nil, athena_query_state: nil}) do
  claimed_at = DateTime.utc_now(:second)

  claim = from r in ReportRun,
    where: r.id == ^id,
    where: is_nil(r.athena_query_id) and is_nil(r.athena_query_state)

  case Repo.update_all(claim, set: [athena_query_state: "queued", updated_at: claimed_at]) do
    {1, _} ->
      self_start(%{report_run | athena_query_state: "queued", updated_at: claimed_at})

    _ ->
      %{report_run | athena_query_state: "queued"}
  end
end
def ensure_current(report_run = %ReportRun{athena_query_id: nil, athena_query_state: "queued"}) do
  if older_than?(report_run.updated_at, @abandoned_claim_seconds) do
    Logger.error("Report run #{report_run.id} was claimed at #{report_run.updated_at} and never started; failing it")
    record_outcome(report_run, athena_query_state: "failed", athena_query_error: @abandoned)
  else
    report_run
  end
end
def ensure_current(report_run = %ReportRun{athena_query_id: nil}) do
  report_run
end
# the third clause (a started run) is unchanged

defp self_start(report_run) do
  case start_query_rescued(report_run) do
    {:ok, athena_query_id, athena_query_state} ->
      record_outcome(report_run, athena_query_id: athena_query_id, athena_query_state: athena_query_state, athena_query_error: nil)

    {:error, :permanent, message} ->
      Logger.error("API self-start failed for report run #{report_run.id}, permanently: #{message}")
      record_outcome(report_run, athena_query_state: "failed", athena_query_error: message)

    {:error, :transient, detail} ->
      Logger.error("API self-start failed for report run #{report_run.id}: #{detail}")

      if older_than?(report_run.inserted_at, @retry_window_seconds) do
        record_outcome(report_run, athena_query_state: "failed", athena_query_error: @gave_up)
      else
        record_outcome(report_run, athena_query_state: nil, athena_query_error: @retrying)
      end
  end
end

defp start_query_rescued(report_run) do
  start_query(report_run)
rescue
  exception ->
    {:error, :transient, Exception.format(:error, exception, __STACKTRACE__)}
end

defp start_query(report_run = %ReportRun{}) do
  with {:report, report = %Report{}} <- {:report, tree().find_report(report_run.report_slug)},
       {:query, {:ok, query}} <- {:query, report.get_query.(report_run.report_filter, report_run.user)},
       {:ok, sql} <- ReportQuery.get_sql(query),
       {:athena, {:ok, athena_query_id, athena_query_state}} <- {:athena, athena_db().query(sql, report_run.id, report_run.user)} do
    {:ok, athena_query_id, athena_query_state}
  else
    {:report, nil} ->
      {:error, :permanent, "Unable to find report: #{report_run.report_slug}"}

    {step, {:error, message}} when is_binary(message) ->
      if permanent?(step, message), do: {:error, :permanent, message}, else: {:error, :transient, message}

    {_step, {:error, reason}} ->
      {:error, :transient, inspect(reason)}

    unexpected ->
      Logger.error("Unknown error running Athena report #{report_run.id}: #{inspect(unexpected)}")
      {:error, :permanent, @unexpected}
  end
end

defp permanent?(:query, message) do
  message in [
    LearnerData.no_learners_error(),
    ReportQuery.no_filters_error(),
    ReportQuery.no_learners_error(),
    TeacherActionsReport.no_match_error()
  ] or ReportQuery.unknown_app_error?(message)
end
defp permanent?(:athena, message), do: message == AthenaDB.query_too_large_error()

# Written only while the row still holds the claim this outcome belongs to, so a start that
# outlives the abandoned-claim bound can't revive a run that bound has failed.
defp record_outcome(report_run = %ReportRun{id: id, updated_at: claimed_at}, changes) do
  changes = Keyword.update(changes, :athena_query_error, nil, &AthenaFailure.truncate/1)
  now = DateTime.utc_now(:second)

  still_claimed = from r in ReportRun,
    where: r.id == ^id and is_nil(r.athena_query_id),
    where: r.athena_query_state == "queued" and r.updated_at == ^claimed_at

  case Repo.update_all(still_claimed, set: [{:updated_at, now} | changes]) do
    {1, _} ->
      struct(report_run, [{:updated_at, now} | changes])

    _ ->
      Logger.warning("Report run #{id} changed while it was being started; the start's outcome was not recorded")
      current = Repo.get!(ReportRun, id)
      struct(report_run, Map.take(current, [:athena_query_id, :athena_query_state, :athena_query_error, :athena_result_url, :updated_at]))
  end
end

defp older_than?(at, seconds), do: DateTime.diff(DateTime.utc_now(), at) > seconds
```

Notes for the implementer:

- **The claim's timestamp is the guard.** `self_start/1` gets a struct whose `updated_at` is the value the claim wrote, and the abandoned-claim clause gets the row as read, so `record_outcome/2` matches the same `updated_at` either way. Only one claim can be live at a time (claiming needs a null state), so second precision is enough.
- **Why the success write moves out of `start_query/1`.** It was an unguarded `Reports.update_report_run/2`; R7 needs the guard, and R6 needs it to clear `athena_query_error`. `AthenaFailure.truncate/1` is applied by hand because `update_all` skips the changeset.
- **Logging stays where it was.** The transient detail (a DB or AWS message, or a formatted exception) goes to the log, never to the row (R3). Athena reasons are kept out of logs by REPORT-106, but nothing here reaches Athena's reason: these are pre-Athena failures, as logged today.
- **`start_query/1` becomes private here**, so this step also changes its one outside caller, `ReportRunLive.Show.run_report/5`'s unstarted-run clause, to call `AthenaRunOps.ensure_current/1` and then `send(live_view_pid, :poll_query_state)` unconditionally, so the commit compiles and the page never restarts a failed run from this commit on. The next step finishes the page.
- **The aliases** `AthenaDB`, `AthenaFailure`, `LearnerData` and `TeacherActionsReport` are added to the module.

Tests, in `athena_run_ops_test.exs` (the existing `run_fixture/2`, `athena_report/1`, `with_user/2` and `AthenaDBStub` serve; a run's `inserted_at` or `updated_at` is aged with `Repo.update_all` on the row, then the run is reloaded):

- **Permanent failures fail at once:** one test per message (`LearnerData.no_learners_error()`, `ReportQuery.no_filters_error()`, `ReportQuery.no_learners_error()`, `ReportQuery.unknown_app_error(["x"])`, `TeacherActionsReport.no_match_error()`) returned from `get_query`, each asserting the stored and returned state `"failed"`, that exact error, and a null query id. Also an unknown slug (`TreeStub` returning nil), the query-too-large message from the `query` stub, and an unexpected `get_query` value (`:unexpected`, stored as `@unexpected`). This replaces the old "generic message" `start_query/1` test.
- **A transient failure is retried, and success clears it:** `get_query` returns "Unable to upload the learner data for the report."; the stored state is null and the error is the retrying message; a second `ensure_current/1` with the `query` stub succeeding stores the query id, state `"queued"` and a null error. Replaces "releases the claim and serves the stored run when self-start fails".
- **The detail is not stored:** a `query` stub returning `{:error, "User: arn:aws:iam::1:user/x is not authorized"}` leaves the retrying message, not the ARN.
- **The retry window:** a run aged 11 minutes with a transient failure is `"failed"` with the gave-up message; one aged 9 minutes is retrying.
- **A raise:** `get_query` raising `AllowedProjectsLookupError` leaves the run retrying (state null, the retrying message), and `ensure_current/1` does not raise.
- **An abandoned claim:** a run with state `"queued"`, no query id and `updated_at` 31 minutes ago becomes `"failed"` with the abandoned message without calling either stub; at 29 minutes it is served as `"queued"` untouched (the existing losing-path test, with its raising stubs, covers that shape).
- **R7's guard:** a `get_query` stub that, before returning, writes `athena_query_state: "failed"` to the row (simulating the abandoned-claim clause winning) leaves that row as it was and returns its stored state; the same with a stub that writes a query id.
- **Kept:** the passed-filter test, rewritten to call `ensure_current/1`; the single-flight winning, losing and stale-struct tests, unchanged.

---

### Start the run page through the self-start

**Summary**: R11. `ReportRunLive.Show` stops calling `start_query/1` and polling `refresh_query_state/1`, and uses `ensure_current/1` for both, so the page and the API share one claim, one classification and one bound, and a failed run is never restarted. `ensure_current/1` runs in a supervised task the page does not link to, so closing the page mid-start can't strand the claim and a retry doesn't block the page. A run that is retrying is polled every 30 seconds, not every second, so the page doesn't rerun the learner query once a second.

**Files affected**:
- `lib/report_server_web/live/report_run_live/show.ex`: `run_report/5`'s two Athena clauses become one; `ensure_current_async/2`; a `:report_run_changed` handler; the `:poll_query_state` handler, `check_query_state/2` (deleted) and `maybe_poll_query_state/2` as below.
- `test/report_server_web/live/report_run_show_live_test.exs`: new tests below, and a wait added to two kept ones.

**Estimated diff size**: ~110 lines.

```elixir
@retry_poll_ms 30_000
@poll_ms 1_000

defp run_report(%Report{type: :athena}, report_run = %ReportRun{}, _sort_columns, _row_limit, live_view_pid) do
  ensure_current_async(report_run, live_view_pid)
  {:ok, %{report_results: nil}}
end

# A start holds the run's claim for as long as its learner query runs. Run in a process linked to
# the page, a page closed mid-start would kill it and leave the claim to the abandoned-claim bound,
# and run in the page's own process, a retry would block the page for the whole attempt.
defp ensure_current_async(report_run = %ReportRun{}, live_view_pid) do
  Task.Supervisor.start_child(ReportServer.PostProcessingTaskSupervisor, fn ->
    AthenaRunOps.ensure_current(report_run)
    send(live_view_pid, :report_run_changed)
  end)
end

@impl true
def handle_info(:poll_query_state, socket = %{assigns: %{report_run: report_run}}) do
  # need to load report run each time as it is set by the background task
  ensure_current_async(Reports.get_report_run_with_user!(report_run.id), self())
  {:noreply, socket}
end

@impl true
def handle_info(:report_run_changed, socket = %{assigns: %{report_run: report_run}}) do
  report_run = Reports.get_report_run_with_user!(report_run.id)
  maybe_poll_query_state(report_run, self())
  {:noreply, assign(socket, :report_run, report_run)}
end

defp maybe_poll_query_state(report_run = %ReportRun{}, live_view_pid) do
  if AthenaRunOps.non_terminal?(report_run) do
    Process.send_after(live_view_pid, :poll_query_state, poll_interval(report_run))
  end
end

# An unstarted run with a null state is retried on every read, which reruns the learner query.
defp poll_interval(%ReportRun{athena_query_id: nil, athena_query_state: nil}), do: @retry_poll_ms
defp poll_interval(_report_run), do: @poll_ms
```

The merged clause is reached on mount (and by a sort change, which passes a nil pid; today's second clause already calls `maybe_poll_query_state/2` with it, and sorting isn't offered for Athena runs, so nothing changes there). The next poll is scheduled only once the previous task reports back, so a page has at most one `ensure_current/1` in flight, and the 30-second interval runs from the end of a failed attempt. A task that raises sends nothing, so the page stops polling until it is reloaded; `ensure_current/1` already rescues a raising start. The page's header already renders a failed run's state, error and guidance, and a retrying run's error under "gathering information..." (`custom_components.ex` `report_header/1`), so no template changes.

`AthenaRunOps.refresh_query_state/1` stays public: `ensure_current/1` uses it, and its own tests pin its behavior.

Tests, using the existing `AthenaDBStub` setup in `report_run_show_live_test.exs`. The work now happens in a task `render_async/1` does not track, so each test waits for it: a stub sends the test process a message, the test `assert_receive`s it, and then waits for the page's re-render (or the row) with a short bounded retry. Waiting also keeps the task from outliving the test's sandbox owner.

- **A failed-to-start run is not restarted:** a run with state `"failed"`, a null query id and `LearnerData.no_learners_error()`, with stubs that raise if called; mounting renders "failed", the no-learners guidance and the error, and the row is unchanged.
- **A permanent failure on mount is shown:** a never-started run whose `get_query` returns the no-learners error; after mount the page renders "failed" and the guidance, and the row is failed.
- **A retrying run shows why and isn't hammered:** a never-started run whose `get_query` returns a transient message; the page renders the retrying message, and `get_query` was called once (the next poll is 30 seconds out).
- **Closing the page mid-start doesn't strand the claim:** a `get_query` stub that reports its pid and then blocks; the test stops the page's process with `{:shutdown, :closed}`, checks the stub's process is still alive, unblocks it, and asserts the row is no longer `"queued"`.
- **Kept, with the wait added:** "mounting a never-started Athena run starts the query" and "a stored running run refreshes its state on poll". As written they read the row straight after `render_async/1` or `render/1` and would race the task.

---

### Release to staging and check

Not a commit. On Doug's say, after the PR merges:

0. **Wait for REPORT-169's live check (Doug, 2026-10-11; stream channel #179, tracker 6.3).** REPORT-169's main path is for servers without this story, and staging is the only place it can be checked live, so this deploy waits until REPORT-169 has posted its check on class 591. Note that check's run id: it is the run step 4 reads. Deploying without the check is Doug's call.
1. Release report-server to staging with the `release-report-server` skill as the next pre-release after `1.13.0-pre.1` (`1.13.0-pre.2` unless another has gone out first): version bump uncommitted, no tag. No migrations. **This pre-release also carries REPORT-173** (a refused package upload leaves its connection clean; stream channel #199 and #222), which merges before this deploy and has no deploy of its own: build from `master` only once both PRs have merged, and if REPORT-173 hasn't, ask Doug rather than deploying without it. REPORT-173 adds no migration either. Its own staging check (its `implementation.md`, "Release and the staging check") runs after this deploy, alongside the checks below.
2. **The failure (R13).** As `dougresearcher` (a non-admin project-20 researcher; an admin bypasses the project rule and the run would start), read `GET /api/v1/reports/filter_options` for Student Answers and confirm class 591 is listed with no assignments, #113's signature of a class whose assignments are in none of the researcher's projects. Class 591 is REPORT-149's fixture (stream channel #173): its only assignment is material 605, offering 1255, in no project or cohort. If it is listed with an assignment, someone has added material 605 to a project; stop and ask rather than pick another class. Create a Student Answers run filtered on class 591, then run `cc-data get report <run> --refresh` with the released `v0.3.0-pre.1`. Expected: exit 5, "run N is in terminal state \"failed\"", the no-learners guidance as its action, and the no-learners message as `athena_query_error`. `GET /api/v1/reports/<run>` answers `failed` with a null query id.
3. **No regression (R10).** A Student Answers run for class 590 starts and succeeds as before (run 210's shape).
4. **A run stuck before the deploy (R12).** REPORT-169's class 591 run from step 0, created while staging lacked this story and left unstarted, answers `failed` with the no-learners error on its first read after the deploy. This complements step 2 and doesn't replace it: step 2's fresh run is the one that exercises the start attempt made at creation.
5. **Run 209**, still unstarted on staging, now starts on its first read, since material 604 is in cohort 12. Expected, and worth one look to confirm it succeeds.
6. Post the result on the stream channel, naming the deployed version and that it carries REPORT-173, so its session can run its check. Production comes with REPORT-164's 1.13.0.

## Open Questions

### RESOLVED: Judgment call: classify by message, or tag errors where they arise?
**Context**: `get_query` returns permanent and transient failures as flat strings from many modules.
**Options considered**:
- A) Compare against message functions owned by the producing modules (this plan).
- B) Change producers to return `{:error, :permanent, message}`, which would change `get_query`'s contract for every report and for the portal path (`Reports.check_yields_query/3`, the LiveView, `portal_download/4`).
**Decision**: A. One source of truth per message without touching a contract eight callers share. A new permanent message added later without updating `permanent?/2` is retried and fails after 10 minutes, a safe default.

### RESOLVED: Judgment call: guard outcome writes on the claim's timestamp
**Context**: R7 needs a guard. Matching only "no query id" lets a late start overwrite a failed run.
**Options considered**:
- A) Match state `queued`, no query id and the claim's `updated_at`.
- B) Match state `queued` and no query id only.
**Decision**: A. B would let a start that outlived its abandoned claim write over a later reclaim's outcome; A ties the write to the claim it belongs to at no extra cost.

### RESOLVED: Judgment call: slow the page's polling for a retrying run
**Context**: R11 routes the page's polls through `ensure_current/1`, which retries an unstarted run on every read.
**Options considered**:
- A) Poll a retrying run every 30 seconds.
- B) Keep one-second polls, rerunning the learner query each second for up to 10 minutes.
**Decision**: A. cc-data's backoff already caps at 30 seconds, so the two clients retry at a similar rate.

## Verified while writing this plan

The first two steps' code above was applied to a scratch copy of `master` (`f5adf65`), with `show.ex`'s stopgap, and deleted afterwards:

- It compiles with `--warnings-as-errors`.
- Throwaway tests passed for: a permanent failure (no learners, unknown application) failing at once; a transient AWS message stored as the retrying message with no ARN, then a success storing the query id and clearing the error; the 9- and 11-minute retry window; a raised `AllowedProjectsLookupError` leaving the run retrying without raising; the 29- and 31-minute abandoned claim; and a row failed mid-start not being overwritten by the start's success.
- `athena_run_ops_test.exs`, `report_run_show_live_test.exs`, `report_controller_test.exs` and `reports_api_runs_test.exs` passed (102 tests) except the two `start_query/1` tests, which call the now-private function and are reworked in the second step as planned.

## Self-Review

Roles: commit reviewer, test writer, Senior Engineer, operator. Only findings the code confirmed are recorded.

### Senior Engineer

#### RESOLVED: The page's first poll would retry a run the mount just failed to start
As first drafted, `run_report/5` sent `:poll_query_state` after its `ensure_current/1`, and that handler now calls `ensure_current/1` too, so a transient failure on mount was retried at once and the 30-second interval never applied to the first retry. Fixed in the third step: the mount sends `:report_run_changed`, which reloads and schedules without starting.

#### RESOLVED: A page closed mid-start would strand the claim for 30 minutes
As drafted, the page's start ran in the `assign_async/3` task, which LiveView starts with `Task.start_link/1` (`phoenix_live_view` 0.20.14 `async.ex`), and its retries ran inside the page's own `handle_info/2`. A throwaway test with the drafted `show.ex` confirmed both: stopping the page with `{:shutdown, :closed}` while `get_query` was blocked killed the task with the same reason and left the row `queued` with no query id, which R5 would fail after 30 minutes with "did not finish", where today's unclaimed page start leaves nothing behind; and a poll's start ran in the page's pid, blocking the page for the whole learner query. Fixed in the third step: `ensure_current_async/2` runs every page call to `ensure_current/1` in an unlinked `PostProcessingTaskSupervisor` child, as `Reports` does for the create-time start, and reports back with `:report_run_changed`. A second throwaway test confirmed the task outlives the page and releases the claim, and that the kept page tests race the task as written, hence the waits.

### Test writer

#### RESOLVED: The kept "releases the claim" test can't catch a broken R3
The existing test asserts only a null query id and state after a failed start, which held under the throwaway build and would hold if the retrying message were never stored. The second step's test list already replaces it with one that asserts the retrying message; recorded so the replacement isn't skipped as redundant.

#### RESOLVED: "get_query was called once" needs a counter, and depends on assign_async
`assign_async/3` runs only on the connected mount (`phoenix_live_view` `async.ex`), so a mount makes exactly one start attempt. The test counts calls by having the `get_query` stub `send(test_pid, :get_query)` and asserting one `assert_receive` and then `refute_receive` after `render_async/1`.

#### RESOLVED: The no-filters 422 branch is already tested
The first step said no test reaches `portal_download/4`'s no-filters branch and added one. "a construction error (super-admin blank filter) returns a clean 422, not a raised 500" already reaches it: with the literal misspelled in a throwaway edit, that test failed on its 422 assertion. Fixed in the first step: one `message` assertion is added to that test instead of a duplicate.

### Operator

#### RESOLVED: The page keeps polling a running run whose refresh fails
Through `ensure_current/1`, a failed Athena state refresh is logged and the stored run served, so the page polls on every second instead of stopping as `check_query_state/2` did on `{:error, _}`. That matches what the API already does on every read, and the page recovers by itself when Athena does; accepted.

### Commit reviewer

No findings: each step compiles alone (the second step's `show.ex` stopgap was compiled), and no step uses what a later one adds.
