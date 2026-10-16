# A report run that can't start fails with its error

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-168

**Status**: **Closed**

## Overview

An Athena report run whose query can never be built (no learners match its filters, an unknown report, a query too large) used to stay unstarted forever and tell no one why. Such a run now fails at once, with its error stored and returned, and the retries for failures that might clear up are bounded in time, so no run can stay unstarted indefinitely.

The case that found it: on 2026-10-09 a researcher's Student Answers run on staging (run 209) could never start, because the class's only assignment was in none of the researcher's projects. report-server logged "No learners were found matching the filters you selected." but stored nothing, and cc-data waited its full 30 minutes and gave up with nothing useful to say. The companion story REPORT-169 makes cc-data stop waiting on a run that never starts; R8 below is the contract it reads.

## Requirements

### Failing a run that can't start

- **R1.** When an Athena run's self-start fails for a **permanent** reason, the run moves to `athena_query_state: "failed"` with the reason in `athena_query_error`, and `athena_query_id` stays null. Permanent reasons are exactly:
  - the run's report slug is not found;
  - the filters match no learners (`LearnerData`'s "No learners were found matching the filters you selected." and `ReportQuery`'s "No learners found to match the requested filter(s).");
  - no teachers or activities match (the teacher actions report's message);
  - the query can't be built: no filters, an unknown application filter, or a query over Athena's 256 KB limit;
  - an unexpected return value inside the start (stored as the generic "An unexpected error occurred while running the report.").
- **R2.** Every other self-start failure is **transient**: portal database errors, failures uploading learner or resource data, AWS errors from the workgroup or `StartQueryExecution` calls, a failure storing the started query, and any exception, exit or throw during the self-start.
- **R3.** A transient failure releases the claim (state back to null) and stores one fixed message in `athena_query_error`, "The report could not be started because of a temporary error; it will be retried.", so a client can see that the run is retrying. The failure's own detail (a portal database or AWS message, or an exception) goes only to the log: those messages can carry internal hostnames and AWS account ARNs.
- **R4.** A transient failure on a run created more than **10 minutes** earlier fails the run instead (R1's shape, with the error "The report could not be started because of a temporary error. Duplicate the run to try again.").
- **R5.** A claim that is never released (state `queued`, no query id, claimed more than **30 minutes** earlier) is treated as abandoned: the next read fails the run with "The report could not be started; the attempt to start it did not finish." This covers a process that died mid-start.
- **R6.** When a self-start succeeds, `athena_query_error` is cleared.
- **R7.** Every write of a self-start's outcome (the started query, `failed`, or a release) changes the row only while it is still claimed and unstarted. A run that another request started, failed or claimed again in the meantime is never overwritten; in particular a start that outlives R5's 30 minutes cannot revive a run R5 has failed.

### What a client sees

- **R8.** The client-visible contract, unchanged in shape (no new fields, no status code changes):

  | Run | `athena_query_state` | `athena_query_id` | `athena_query_error` | `GET /reports/:id` | `GET /reports/:id/download` |
  |---|---|---|---|---|---|
  | Not yet tried, or being started | `null` or `"queued"` | `null` | `null` | 200 | 409 `NOT_READY` |
  | Retrying after a transient failure (R3) | `null` (or `"queued"` during a retry) | `null` | R3's fixed retrying message | 200 | 409 `NOT_READY` |
  | Failed to start (R1, R4, R5) | `"failed"` | `null` | the reason | 200 | 409 `NOT_READY` |
  | Started | Athena's states | the query id | Athena's reason on failure | unchanged | unchanged |

  The 409 body is `{"error": "NOT_READY", "message": "The report is not ready to download.", "athena_query_state", "athena_query_id", "athena_query_error", "athena_query_guidance"}`. A failed-to-start run is told apart from an Athena failure by its null `athena_query_id`.

  **The server's bound:** a run that has not started answers `failed` no later than the first read after it is 10 minutes old if its start keeps failing (R4), or 30 minutes after a start that never finished (R5). R5 counts from the last claim, and a retrying run is reclaimed on its reads until R4's window closes, so an abandoned start can answer `failed` up to about 40 minutes after creation. That is past cc-data's default 30-minute `--poll-timeout`, so a client keeps its own timeout as a backstop. REPORT-169's cc-data keeps waiting through a retry (a non-null `athena_query_error` with a null or `"queued"` state) until the run answers `failed`, and stops early only after four NOT_READY answers whose state, id and error are all null. Servers older than this story never set that error on an unstarted run.
- **R9.** `athena_query_guidance` for both no-learners messages tells the researcher what to check: that the filters match students, and that a chosen class's assignment must itself be in one of their projects (its cohorts or material lists), not just the class's teacher. It does not claim the cause is certainly project membership, since a class with no students produces the same message.
- **R10.** A run that starts normally behaves exactly as before.

### Everywhere a run is started

- **R11.** The run's web page (`ReportRunLive.Show`) starts an unstarted Athena run through the same self-start as the API (one claim, the same classification, the same bounds), and never starts a run whose state is `failed`. A failed-to-start run's page shows its status, error and guidance through the existing report header. While a run is retrying, the page tries again every 30 seconds rather than on its usual one-second poll; reloading the page tries at once. A start the page begins finishes and records its outcome even if the page is closed meanwhile.
- **R12.** Runs already stuck when this ships heal on their next read: an unstarted run with a permanent failure fails at once; one older than 10 minutes with a transient failure fails (R4); one stuck at `queued` for over 30 minutes fails (R5).

### Done when

- **R13.** On staging, a Student Answers run for a class whose assignments are in none of the researcher's projects answers `failed` with the no-learners error and guidance on the first poll after its start attempt has finished, and `cc-data get report --refresh` (`v0.3.0-pre.1`) prints that error and exits 5 within one poll of that. The check uses a fresh run for class 591 ("Researcher Dashboard Wildfire Outside"), whose only assignment is material 605 (offering 1255), in no project or cohort, and whose one learner is `ostudent`. It runs as a non-admin project-20 researcher such as `dougresearcher`, because report-server skips the project rule for an admin. *(Pending: runs after the staging release; see Not Yet Implemented.)*
- **R14.** Tests cover: each permanent class failing at once, including a real Student Answers run against the portal fixture; a transient failure that stores its message and is retried, followed by a success that clears it; the 10-minute bound; a raise, exit or throw during the self-start; an abandoned claim; R7's guard; the web page not restarting a failed run; and a page closed mid-start not stranding its claim.

## Technical Notes

- **Where it lives.** `AthenaRunOps.ensure_current/1` (`server/lib/report_server/reports/athena_run_ops.ex`) is the one self-start, called by the create-time kickoff in `Reports.create_api_report_run`, by `GET /api/v1/reports/:id` and `/download`, and by the run page. `start_query/1` is private and returns `{:ok, id, state}` or `{:error, :permanent | :transient, message}`; `record_outcome/2` writes it, and an exception, exit or throw while storing a started query is handled as a transient failure (R2), and its log line carries the query id, as does the warning when the guard below drops a late start's outcome.
- **Classifying by message.** `get_query` returns every failure as a flat string. Each permanent message has one home, a function on the module that returns it (`LearnerData.no_learners_error/0`, `ReportQuery.no_filters_error/0`, `no_learners_error/0`, `unknown_app_error/1` and `unknown_app_error?/1`, `TeacherActionsReport.no_match_error/0`, `AthenaDB.query_too_large_error/0`), and `permanent?/2` compares against those. A new permanent message not added there is retried and fails after 10 minutes, a safe default. Portal database failures arrive flattened by `PortalDbs.query/4` and are transient because their text matches no permanent message.
- **The guard.** An outcome is written with `update_all` only where the row has no query id, state `queued` and `updated_at` equal to the claim's timestamp; otherwise the current row is reloaded and returned. `AthenaFailure.truncate/1` is applied by hand, since `update_all` skips the changeset. `ReportController.portal_download/4` binds `ReportQuery.no_filters_error()` and matches it with a pin, because a remote call can't appear in a guard.
- **Guidance.** `AthenaFailure.guidance/1` matches the lowercase substring `"no learners"` first. `guidance_for/2` runs at render time in `ReportJSON`, the download 409 and the web header, so runs failed before the deploy get it too.
- **The bounds.** `@retry_window_seconds` (10 minutes) and `@abandoned_claim_seconds` (30 minutes) are module attributes. A start runs several portal queries with a 5-minute budget each (`PortalDbs` `@query_timeout`), so 30 minutes leaves a slow but live start alone.
- **The page.** `ReportRunLive.Show` runs every `ensure_current/1` call in an unlinked task under `PostProcessingTaskSupervisor` (`ensure_current_async/2`), which reports back with `{:report_run_changed, run}`: the run `ensure_current/1` returned, or nil after a call that raised, exited or threw, in which case the page reads the run itself. The page schedules its next `:poll_query_state` only then and keeps one pending poll timer, so at most one call is in flight. The retry interval reads `:run_page_retry_poll_ms` (default 30 seconds) so tests can shorten it. The sort handler has no page process to report to, so on an Athena run it starts nothing.
- **No migration.** `athena_query_error`, `athena_query_state` and `updated_at` already exist.

## Out of Scope

- cc-data changes: REPORT-169 (stop waiting on a run that never starts, retire the oscillation detector).
- Backing off the API's retries between polls. Each read of a retrying run reruns the learner query; the 10-minute bound limits how long that lasts.
- Moving the API's retry out of the GET request into a background task, as the run page does: REPORT-177.
- Classifying start failures where they are made rather than by message text, so bad SQL and portal configuration errors fail at once: REPORT-175.
- Retrying or restarting a failed run in place. A researcher who fixes the cause duplicates the run.
- Portal (sync) reports, which have no self-start.
- Renaming `athena_query_error` or adding a field for the failure's origin.

## Not Yet Implemented

- **The staging release and check (R13).** On Doug's say, after the PR merges: release report-server to staging as the next pre-release after `1.13.0-pre.1`, with the version bump uncommitted and no tag. That pre-release also carries REPORT-173, so build from `master` only once both have merged. Wait first for REPORT-169's live check on class 591 and note its run id. Then:
  - a fresh class 591 Student Answers run as `dougresearcher` fails with the no-learners error and guidance, and cc-data exits 5;
  - a class 590 run starts as before;
  - REPORT-169's run fails on its next read (R12);
  - run 209 starts.

  Post the result, naming the version. Production follows with REPORT-164's 1.13.0.

## Decisions

### Bound transient retries by time since creation, or by an attempt counter?
**Context**: R4 needs a bound on transient retries.
**Options considered**:
- A) Time since the run was created (`inserted_at`), no migration.
- B) A new `start_attempts` column, failing after N attempts.

**Decision**: A. No migration, and the bound means "a researcher waits at most this long". The cost: a run first read long after its creation gets no retry on a transient failure, and the researcher duplicates it.

---

### Store an error while a run is retrying?
**Context**: R3 could release the claim silently or record why.
**Options considered**:
- A) Store a message in `athena_query_error` while the state is null.
- B) Store nothing until the run fails.

**Decision**: A, as one fixed message. It gives clients a one-poll signal ("null with an error means retrying") and lets the web page show why a run is waiting. Storing the failure's own text was rejected: portal and AWS messages can carry internal hostnames and IAM ARNs, so the detail goes only to the log.

---

### Bring the web page's start path into scope?
**Context**: The story named only the API. The page called `start_query/1` directly, without the claim, so it could restart a run the API had failed and race the API's claim.
**Options considered**:
- A) Route the page through the same self-start (R11).
- B) Leave it, and only stop it restarting `failed` runs.

**Decision**: A. A second start path with different rules is the defect class this story fixes.

---

### Are 10 and 30 minutes the right bounds?
**Context**: Both are reasoned from the 5-minute portal query budget and cc-data's 30-minute poll budget, not measured.
**Options considered**:
- A) 10 minutes for transient retries, 30 for an abandoned claim.
- B) 5 and 15.

**Decision**: A. The abandoned-claim bound must exceed the longest live start, and a start can run several 5-minute portal queries, so 15 risks failing a live start; with raises caught, an abandoned claim needs a dead process and is rare. 10 minutes rides out a short portal or AWS blip. Both are one-line changes to tune.

---

### Guard outcome writes against a late start
**Context**: A start still running when R5 fails its run would write `queued` and a query id over `failed`.
**Options considered**:
- A) Match state `queued`, no query id and the claim's `updated_at`.
- B) Match state `queued` and no query id only.

**Decision**: A. B would let a start that outlived its abandoned claim write over a later claim's outcome; A ties each write to the claim it belongs to at no extra cost. The cost of either, accepted because it is rare, is an orphaned Athena query whose id only the log keeps. The same cost follows a failure to store a started query's id. A learner-data report's retries then reuse the run's Athena request token with new SQL, which Athena rejects, so the run also fails after its retry window; REPORT-176 is to recover the query instead.

---

### Classify failures by message, or tag them where they arise?
**Context**: `get_query` returns permanent and transient failures as flat strings from many modules.
**Options considered**:
- A) Compare against message functions owned by the producing modules.
- B) Change producers to return `{:error, :permanent, message}`.

**Decision**: A. B would change `get_query`'s contract for every report and for the portal path. A gives one source of truth per message without touching a contract eight callers share.

---

### Slow the page's polling for a retrying run
**Context**: Through `ensure_current/1`, every page poll of an unstarted run reruns the learner query.
**Options considered**:
- A) Poll a retrying run every 30 seconds.
- B) Keep one-second polls, rerunning the learner query each second for up to 10 minutes.

**Decision**: A. cc-data's backoff already caps at 30 seconds, so the two clients retry at a similar rate. The mount reports back with `:report_run_changed` rather than polling, so a failure on mount isn't retried at once.

---

### Run the page's start where closing the page can't kill it
**Context**: In a process linked to the page (the `assign_async/3` task, or the page itself), closing the tab mid-start killed the start and left the claim for R5 to fail 30 minutes later, and a retry in the page's own process blocked the page for the whole learner query.
**Options considered**:
- A) An unlinked task under `PostProcessingTaskSupervisor`, as the create-time kickoff uses.
- B) Keep the start in the page's processes.

**Decision**: A. The start outlives the page and records its outcome, and the page never blocks.

---

### A running run whose refresh fails keeps polling
**Context**: Through `ensure_current/1`, a failed Athena state refresh is logged and the stored run served, so the page keeps its one-second poll where it used to stop.
**Options considered**:
- A) Accept it, matching what the API does on every read.
- B) Stop polling on a refresh error.

**Decision**: A. The page recovers by itself when Athena does.
