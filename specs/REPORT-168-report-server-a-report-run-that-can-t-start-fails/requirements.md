# A report run that can't start fails with its error

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-168
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

An Athena report run whose query can never be built (no learners match its filters, an unknown report, a query too large) stays unstarted forever and tells no one why. This story makes such a run fail at once, with its error stored and returned, and puts a time bound on the retries for failures that might clear up, so no run can stay unstarted indefinitely.

## Project Owner Overview

On 2026-10-09 a researcher's Student Answers run on staging (run 209) could never start: the class's only assignment was in none of the researcher's projects, so the learner query found nobody. report-server knew this ("No learners were found matching the filters you selected.") but only logged it, so the run looked identical to one still starting. cc-data waited its full 30 minutes and gave up with nothing useful to say.

After this change a researcher sees the real reason on the next poll, in cc-data and on the run's web page, with a sentence explaining what to check. Failures that might be temporary (the portal database or AWS briefly unavailable) are still retried, but only for a bounded time, after which the run fails with the last error. The companion story REPORT-169 makes cc-data stop waiting on a run that is retrying; this spec defines the contract it reads.

## Background

**The self-start.** An Athena run is created with no query (REPORT-93). `Reports.create_api_report_run` kicks off `AthenaRunOps.ensure_current/1` in a supervised task, and every `GET /api/v1/reports/:id` and `GET /api/v1/reports/:id/download` calls `ensure_current/1` too (REPORT-74). For a run with no query id and a null state, `ensure_current/1` claims the row atomically (state `queued`), calls `start_query/1`, and on success stores the Athena query id and state.

**What goes wrong** (`server/lib/report_server/reports/athena_run_ops.ex`, `ensure_current/1`, at `f5adf65`):

1. When `start_query/1` returns `{:error, message}`, `ensure_current/1` logs "API self-start failed for report run …", resets the state to null and returns the run unchanged. Nothing is stored, so every later read retries, fails again and answers null, forever. A throwaway test confirmed this: after a no-learners failure the stored state and error are both null.
2. **A second stuck path the Jira story does not name.** When the self-start *raises* (for example `AllowedProjectsLookupError`, which `ReportUtils.scope_by_allowed_projects/5` raises when the portal permission lookup fails), the release never runs. The row keeps state `queued` with no query id, and the second `ensure_current/1` clause returns such a row untouched, so it answers `queued` forever. A throwaway test confirmed this too. A process that dies mid-start (a deploy, an OOM) leaves the same row.
3. **The web page has its own start path.** `ReportRunLive.Show.run_report/5` calls `start_query/1` directly for any Athena run with no query id, without the claim. It shows the error on the page, stores nothing, and would happily start a run the API had already marked failed.

**What a client sees today.** cc-data's `get report --refresh` polls `GET /api/v1/reports/:id/download`, not the show route. For a run that isn't ready, that answers HTTP 409 with the `NOT_READY` envelope carrying `athena_query_state`, `athena_query_id`, `athena_query_error` and `athena_query_guidance`. cc-data (at the released `v0.3.0-pre.1`) already treats `failed` and `cancelled` as terminal: it exits 5 with "run N is in terminal state \"failed\"", the guidance as its action, and the other keys forwarded. Its oscillation detector, meant to catch the null/queued/null cycle, can't trip because the server resets the state before replying.

**Corrections to the story and the stream plan, checked against the code:**

- **The self-start is not REPORT-142's.** `ensure_current/1` came from REPORT-74 (`be13de5`) and the create-time kickoff from REPORT-93 (`35bc3e3`). REPORT-142 is only a related story.
- **"Answers a failed state on its first poll" holds only once the create-time start attempt has finished.** A poll that arrives while that task still holds the claim answers `queued`; the next poll answers `failed`. The Done-when is restated in R13 accordingly.
- **The no-client-change half.** Because cc-data already exits on `failed` and prints the guidance, the permanent-failure half of the Done-when needs no cc-data change. REPORT-169's remaining work is the retrying window (R4) and the oscillation detector this story makes obsolete.
- **The release line in `plan.md` no longer holds.** It says REPORT-168 "ships in REPORT-167's 1.13.0 staging release if it merges before that is cut". That staging release was cut and deployed on 2026-10-09 as `1.13.0-pre.1` from `9793e8f` (stream channel #123), before this story was specced, and `master` still says `1.12.0` because pre-release bumps stay uncommitted. So REPORT-168 reaches staging in a later pre-release (`1.13.0-pre.2` or whichever comes next), and production in REPORT-164's final 1.13.0 if it merges before that is cut, which is what the Jira fix version 1.13.0 already says.

## Requirements

### Failing a run that can't start

- **R1.** When an Athena run's self-start fails for a **permanent** reason, the run moves to `athena_query_state: "failed"` with the reason in `athena_query_error`, and `athena_query_id` stays null. Permanent reasons are exactly:
  - the run's report slug is not found;
  - the filters match no learners (`LearnerData`'s "No learners were found matching the filters you selected." and `ReportQuery`'s "No learners found to match the requested filter(s).");
  - no teachers or activities match (the teacher actions report's message);
  - the query can't be built: no filters, an unknown application filter, or a query over Athena's 256 KB limit;
  - an unexpected return value inside `start_query/1` (stored as its existing generic message, "An unexpected error occurred while running the report.").
- **R2.** Every other self-start failure is **transient**: portal database errors, failures uploading learner or resource data, AWS errors from the workgroup or `StartQueryExecution` calls, a failure storing the started query, and any exception raised during the self-start.
- **R3.** A transient failure releases the claim (state back to null, as today) and stores one fixed message in `athena_query_error`, "The report could not be started because of a temporary error; it will be retried.", so a client can see that the run is retrying. The failure's own detail (a portal database or AWS message, or an exception) goes only to the log, as today: those messages can carry internal hostnames and AWS account ARNs, and until now no API response has carried them.
- **R4.** A transient failure on a run created more than **10 minutes** earlier fails the run instead (R1's shape, with the error "The report could not be started because of a temporary error. Duplicate the run to try again."). So a run whose start keeps failing reaches `failed` on the first attempt after that point.
- **R5.** A claim that is never released (state `queued`, no query id, claimed more than **30 minutes** earlier) is treated as abandoned: the next read fails the run with "The report could not be started; the attempt to start it did not finish." This covers a process that died mid-start.
- **R6.** When a self-start succeeds, `athena_query_error` is cleared, so a run that recovered from a transient failure carries no stale error into Athena's states.
- **R7.** Every write of a self-start's outcome (the started query, `failed`, or a release) changes the row only while it is still claimed and unstarted (state `queued`, no query id). A run that another request started or failed in the meantime is never overwritten; in particular a start that outlives R5's 30 minutes cannot revive a run R5 has failed.

### What a client sees

- **R8.** The client-visible contract, unchanged in shape (no new fields, no status code changes):

  | Run | `athena_query_state` | `athena_query_id` | `athena_query_error` | `GET /reports/:id` | `GET /reports/:id/download` |
  |---|---|---|---|---|---|
  | Not yet tried, or being started | `null` or `"queued"` | `null` | `null` | 200 | 409 `NOT_READY` |
  | Retrying after a transient failure (R3) | `null` (or `"queued"` during a retry) | `null` | R3's fixed retrying message | 200 | 409 `NOT_READY` |
  | Failed to start (R1, R4, R5) | `"failed"` | `null` | the reason | 200 | 409 `NOT_READY` |
  | Started | Athena's states, as today | the query id | Athena's reason on failure, as today | unchanged | unchanged |

  The 409 body is `{"error": "NOT_READY", "message": "The report is not ready to download.", "athena_query_state", "athena_query_id", "athena_query_error", "athena_query_guidance"}`, as today. A failed-to-start run is told apart from an Athena failure by its null `athena_query_id`; a client needs to do so only for display.

  **The server's bound, for a client to rely on:** a run that has not started answers `failed` no later than the first read after it is 10 minutes old if its start keeps failing (R4), or 30 minutes after a start that never finished (R5). The R5 bound counts from the last claim, and a retrying run is reclaimed on its reads until R4's window closes, so an abandoned start can answer `failed` up to about 40 minutes after creation. That is past cc-data's default 30-minute `--poll-timeout`, so a client keeps its own timeout as a backstop; with it, a client at that default can time out at about the moment R5 would have answered. A client can also stop early on a non-null `athena_query_error` with a null state if it chooses. Servers older than this story never set that error on an unstarted run, so a client talking to production before 1.13.0 still needs its own timeout.
- **R9.** `athena_query_guidance` for both no-learners messages is a sentence telling the researcher what to check: that the filters match students, and that a chosen class's assignment must itself be in one of their projects (its cohorts or material lists), not just the class's teacher. The exact wording is settled in the implementation spec; it must not claim the cause is certainly project membership, since a class with no students produces the same message.
- **R10.** A run that starts normally behaves exactly as before: same states, same timing, same responses.

### Everywhere a run is started

- **R11.** The run's web page (`ReportRunLive.Show`) starts an unstarted Athena run through the same self-start as the API (one claim, the same classification, the same bound), and never starts a run whose state is `failed`. A failed-to-start run's page shows its status, error and guidance through the existing report header, as an Athena failure does today. While a run is retrying (state null, no query id), the page tries again every 30 seconds rather than on its usual one-second poll, since each try reruns the learner query; reloading the page tries at once. A start the page begins finishes and records its outcome even if the page is closed meanwhile.
- **R12.** Runs already stuck when this ships heal on their next read: an unstarted run with a permanent failure fails at once; one older than 10 minutes with a transient failure fails (R4); one stuck at `queued` for over 30 minutes fails (R5).

### Done when

- **R13.** On staging, a Student Answers run for a class whose assignments are in none of the researcher's projects answers `failed` with the no-learners error and guidance on the first poll after its start attempt has finished, and `cc-data get report --refresh` (the released `v0.3.0-pre.1`) prints that error and exits 5 within one poll of that. A run that does start behaves as before. Run 209 itself is no longer a reproduction: material 604 has been in cohort 12 since 2026-10-09 (stream channel #114), so its next read after the deploy starts it. The check uses a fresh run for class 591 ("Researcher Dashboard Wildfire Outside"), the staging fixture REPORT-149 made on 2026-10-11 (stream channel #173): its only assignment is material 605 (offering 1255), which is in no project or cohort. Since 2026-10-13 the class has one learner, `ostudent` (in class 591 only; started offering 1255 and answered one open response), so a non-admin's no-learners result comes from the project rule, not an empty roster. It must run as a non-admin project-20 researcher such as `dougresearcher`, because report-server skips the project rule for an admin, so an admin's run of the same class finds learners and starts.
- **R14.** Tests cover: each permanent class failing at once; a transient failure that stores its message and is retried, followed by a success that clears it; the 10-minute bound; a raise during the self-start; an abandoned claim; R7's guard; the web page not restarting a failed run; and a page closed mid-start not stranding its claim.

## Technical Notes

- **Where errors come from.** `start_query/1` (`athena_run_ops.ex`) is a `with` over: `Tree.find_report/1` (nil = unknown report), `report.get_query.(filter, user)` (the learner and resource queries and S3 uploads, for most Athena reports via `LearnerData.fetch_and_upload/2` and `ResourceData.fetch_and_upload/2`), `ReportQuery.get_sql/1`, `AthenaDB.query/3` (`check_query_size`, workgroup, `StartQueryExecution`), and `Reports.update_report_run/2`. All failures are flat strings, so `get_query`'s permanent and transient failures look alike; the implementation needs a way to classify them that has one source of truth for each permanent message.
- **Error message strings.** `LearnerData` (line 155), `ReportQuery` (lines 44, 97, 100), `TeacherActionsReport` (line 39), `AthenaDB.check_query_size/1`, and the generic message in `start_query/1`. Portal database failures reach `start_query/1` as flat strings too: every portal call on the start path goes through `PortalDbs.query/4`, which flattens `query_with_reason/4`'s `{:error, kind, message}` to `{:error, message}` (only `FilterOptions` calls `query_with_reason/4` directly). They are transient (R2) because their text matches no permanent message, not because of their shape.
- **Guidance.** `AthenaFailure.guidance_for/2` already matches lowercase substrings of `athena_query_error` and is called at render time by `ReportJSON`, the download 409 and the web header, so a new pattern reaches all three, and runs failed before the deploy too.
- **The 10- and 30-minute bounds.** A start runs several portal queries, each with a 5-minute budget (`PortalDbs` `@query_timeout`), so 30 minutes leaves a slow but live start alone. 10 minutes since creation keeps a run that can't start well inside cc-data's 30-minute poll budget. Both are module attributes, not configuration.
- **One source for "no filters".** `ReportController.portal_download/4` matches the literal "Cannot run query with no filters" to answer 422. It moves to `ReportQuery.no_filters_error()` with the rest, so the portal path and the start path can't disagree on the text. This changes no behavior.
- **Columns.** `athena_query_error` (text, truncated by `AthenaFailure.truncate/1` in the changeset) and `athena_query_state` already exist. The claim already sets `updated_at`, which R5 reads. No migration is needed.
- **Throwaway checks run while writing this spec** (deleted): a no-learners failure leaves state and error null; a raised `AllowedProjectsLookupError` leaves the row `queued` with no query id, and the next `ensure_current/1` answers `queued` without retrying.

## Out of Scope

- cc-data changes: REPORT-169 (stop waiting on a retrying run, retire the oscillation detector, pin the release Go toolchain).
- Backing off the retries between polls. Each poll of a retrying run still reruns the learner query, as today; the 10-minute bound limits how long that lasts.
- Retrying or restarting a failed run in place. A researcher who fixes the cause (for example by adding the material to a cohort) duplicates the run, as with any failed run.
- Portal (sync) reports, which have no self-start.
- Renaming `athena_query_error` or adding a field for the failure's origin.

## Open Questions

### RESOLVED: Judgment call: time bound since creation, or an attempt counter?
**Context**: R4 needs a bound on transient retries.
**Options considered**:
- A) Time since the run was created (`inserted_at`), no migration.
- B) A new `start_attempts` column, failing after N attempts.
**Decision**: A. No migration, and the bound means "a researcher waits at most this long", which is what the story cares about. The cost: a run first read long after its creation gets no retry on a transient failure; the researcher duplicates it.

### RESOLVED: Judgment call: store the transient error while retrying?
**Context**: R3 could release the claim silently, as today, or record why.
**Options considered**:
- A) Store the last transient message in `athena_query_error` while the state is null.
- B) Store nothing until the run fails.
**Decision**: A. It gives REPORT-169 a one-poll signal ("null with an error means retrying") and lets the web page show why a run is waiting. R6 clears it on success.

### RESOLVED: Judgment call: bring the web page's start path into scope?
**Context**: The story names only the API. The page's direct `start_query/1` call would restart a run the API failed, and races the API's claim.
**Options considered**:
- A) Route the page through the same self-start (R11).
- B) Leave it, and only stop it restarting `failed` runs.
**Decision**: A. A second start path with different rules is the defect class this story fixes.

### RESOLVED: Low confidence: are 10 and 30 minutes the right bounds?
**Context**: Both are reasoned from the 5-minute portal query budget and cc-data's 30-minute poll budget, not measured. A shorter retry bound fails runs on longer outages; a longer one keeps a researcher waiting.
**Options considered**:
- A) 10 minutes for transient retries, 30 for an abandoned claim.
- B) 5 and 15.
- C) Other.

**Decision**: A. The abandoned-claim bound must exceed the longest live start, and a start can run several portal queries of up to 5 minutes each, so 15 risks failing a live start; with raises now caught (R3), an abandoned claim needs a dead process and is rare, so 30 costs little. 10 minutes of retrying rides out a short portal or AWS blip and still fails the run well inside cc-data's 30-minute budget. Both are module attributes, so tuning them later is a one-line change. Not a call that needs Doug.

## Self-Review

Roles: Senior Engineer, Security Engineer, QA Engineer, API consumer (the REPORT-169 author), Operator. Only findings the code confirmed are recorded.

### Security Engineer

#### RESOLVED: Transient failure detail would reach API clients
`PortalDbs.query/4` returns the raw `DBConnection`/`MyXQL` message, which `LearnerData` passes through to `start_query/1`, and `AthenaDB`'s `transform_aws_error/1` returns AWS's `Message`, which for access errors names IAM ARNs. Storing those in `athena_query_error` (R3 as drafted) would put them in every API response. Fixed in R3 and R4: a fixed message is stored and the detail is logged. The permanent messages (R1) are all this server's own strings.

### Senior Engineer

#### RESOLVED: A late start could overwrite a failed run
`start_query/1` stores the started query with an unguarded `Reports.update_report_run/2`. A start still running when R5 fails its run would write `queued` and a query id over `failed`. Fixed in R7: every outcome write is conditional on the row still being claimed and unstarted. The cost, an orphaned Athena query in that rare case, is accepted.

### QA Engineer

#### RESOLVED: The Done-when's reproduction no longer reproduces
Run 209 failed because material 604 was in none of the researcher's projects; Doug added it to cohort 12 on 2026-10-09 (#114), and run 210 then succeeded. Fixed in R13: the staging check needs a new fixture.

### API consumer (REPORT-169)

#### RESOLVED: The contract did not say how long a client might wait
R8 listed the states but not when an unstarted run is guaranteed to fail, which is what decides whether cc-data needs its own timeout. Fixed in R8: the 10- and 30-minute bounds, and the note that pre-1.13.0 servers never set the retry signal.

### Senior Engineer (second pass)

#### RESOLVED: The Technical Notes misplaced the portal three-element error
They said `PortalDbs.query_with_reason/4`'s `{:error, kind, message}` falls through to `start_query/1`'s generic branch. It cannot reach it: `LearnerData`, `TeacherActionsReport` and `ReportUtils` call `PortalDbs.query/4`, which flattens it, and `grep` finds `query_with_reason/4` called only from `PortalDbs.query/4` and `FilterOptions`. The plan's classifier is right either way (a flat portal message is transient), but the note sent a reader looking for a shape that never arrives. Fixed in Technical Notes.

### API consumer (REPORT-169, second pass)

#### RESOLVED: R8's table contradicted R3 on the retrying error
R8's retrying row said `athena_query_error` holds "the last failure's message", while R3 (and the plan's `@retrying`) store one fixed message and keep the failure's own text out of responses. A client reading R8 alone would expect varying text. Fixed in R8: the cell names R3's fixed message.

### Researcher using the web page

#### RESOLVED: Closing the page mid-start would fail the run 30 minutes later
R11 routes the page through the claim, and the page's start ran in a process linked to the page, so closing the tab during a start left the claim held until R5 failed the run with "did not finish"; today the page's start holds no claim, so closing the tab costs nothing. Confirmed with a throwaway LiveView test (details in implementation.md's Self-Review). Fixed in R11 and R14: a start the page begins finishes and records its outcome even if the page is closed, and a test covers it; the plan runs it in an unlinked supervised task.
