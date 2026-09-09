# Create and duplicate report runs

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-93
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

Add `POST /api/v1/reports` and `POST /api/v1/reports/:id/duplicate` so a report run can be created from scratch or cloned without the web form, add a duplicate button to the runs UI, and expose both over the cc-data CLI and MCP. Without this the CLI can only consume runs a human authored in the browser.

## Project Owner Overview

Researchers using cc-data can list, download and analyze report runs today, but they cannot make one. Every workflow therefore starts in a browser: open the report form, assemble a filter by hand, submit, then switch to the terminal with the run id. That break is most painful for the Student ID Mapping report, whose whole purpose is to be the run that drives a later data pull, and it is the reason the 0.2.0 release exists at all.

This story closes the loop. A researcher (or Claude acting for one) can create a run from a filter assembled through the filter-option discovery endpoint, or duplicate an existing run to get a fresh snapshot, and project investigators get a duplicate button in the web UI so they stop re-authoring runs by hand.

## Background

`ReportRun` rows are created in exactly one place today: `ReportLive.Form.create_run/2` (`server/lib/report_server_web/live/report_live/form.ex:357-379`), which derives the labels with `ReportFilter.get_filter_values/2`, calls `Reports.create_report_run/1` and redirects to the run's page. Nothing on the API can write a run: the authenticated `/api/v1` scope (`server/lib/report_server_web/router.ex:60-72`) is `GET /reports`, `POST /reports/filter-options`, `GET /reports/:id`, `GET /reports/:id/download`, `GET /reports/:id/answers`, `GET /reports/:id/history`, `POST /reports/:id/attachments` and the two job routes. The only writing POST is the attachment presign, which is download-oriented.

The transport is not the gap. `Client.postJSON` and `deleteJSON` exist in cc-data (`internal/api/client.go:229-255`), `AsCLIError` already passes a coded API error's code, message and extra straight through to the exit-code contract (`internal/api/errors.go:57-88`), and `FilterOptions` (`internal/api/endpoints.go:129-135`) already POSTs a JSON body. The gap is the two server endpoints, their validation, and the typed client methods on top.

REPORT-92 shipped the filter-option discovery endpoint this story consumes, including `FilterParams.parse/1` (`server/lib/report_server_web/api/v1/filter_params.ex`), which turns the API's `report_filter` object into a `%ReportFilter{}`. It parses a deliberately narrow subset: the ten portal-backed id dimensions plus `exclude_internal`, carrying `start_date` and `end_date` without using them and dropping `hide_names` and `app` entirely, because none of those narrow a dimension's options. Creating a run needs all of them, so this story widens that parser rather than adding a second one; the Self-Review records why widening cannot change what filter-options returns.

REPORT-105 added the `app` dimension and the submit-time partition warning (`server/lib/report_server/reports/partition_estimate.ex`, wired at `form.ex:266-295`), and REPORT-91 added `HideNames.enforce/2` (`server/lib/report_server/reports/hide_names.ex:24-30`). Both are validation the form performs before a run is created and that an API create must perform too, since a client cannot be trusted to have performed either.

## Requirements

### The two endpoints

- `POST /api/v1/reports` creates a run from `report_slug` and `report_filter`. The caller is the bearer token's user. The response is the same run JSON shape `GET /api/v1/reports/:id` returns (`ReportJSON.run_json/1`), so a client has one run representation, not two.
- `POST /api/v1/reports/:id/duplicate` creates a new run from run `:id`'s slug and filter. The client sends only the id; the server reconstructs the rest from the stored run.
- Both refuse a slug that is not API-exposed and an id the caller does not own, with the same `NOT_FOUND` that `GET /api/v1/reports/:id` returns for both cases (`Reports.get_api_report_run/2`, `server/lib/report_server/reports.ex:92-103`). Ownership and API exposure stay indistinguishable from non-existence.
- Neither endpoint has a rerun or refresh sibling. An Athena run is immutable (`AthenaRunOps.start_query/1` only fires on `athena_query_id: nil`, `athena_run_ops.ex:16`, and `AthenaDB` derives a deterministic `ClientRequestToken` per run and workgroup, `athena_db.ex:104-111`), and a Portal run is computed on request, so refreshing is a re-read for Portal and a duplicate for Athena.

### Filter values are always server-derived

- `report_filter_values` is derived from `report_filter` on both endpoints and never accepted from the client. One derivation path serves both: create derives from the ids the client sent, duplicate derives from the source run's stored `report_filter`.
- Duplicate re-derives rather than copying the source run's stored labels, because a stored label is a point-in-time snapshot and a cohort, school or class may have been renamed, or an id may no longer resolve, since the source run was created.
- Derivation distinguishes "no labels to derive" from "deriving them failed". A filter with no id dimensions, a log report filtered only by `app` and a date range, derives an empty map and is stored; a portal query that fails, fails the create. Today `ReportFilter.get_filter_values/2` returns `%{}` for both.
- `report_filter.filters` is derived server-side on both endpoints from the dimensions the filter carries, in reverse `ReportFilter.dimensions()` order, and any client-supplied `filters` is ignored. Duplicate derives it rather than copying the source's, for the same reason it re-derives the labels. The reversal is what the runs UI expects (see Technical Notes).

### Validation the server performs, not the client

- `hide_names` is forced on for any caller `HideNames.allowed?/1` rejects, whatever the request asked for, matching the web form's `HideNames.enforce/2` call in `update_options/5` (`form.ex:386`).
- An `app` value is accepted only on a report whose `form_options` set `enable_app_filter`, and only when every value is a known application. Both checks exist today as `check_app_supported/2` and `check_apps_known/1` inside the LiveView (`form.ex:487-505`); they become one shared module both callers use, rather than a second copy in the controller.
- A dimension the report does not offer is a client error rather than a silently ignored key, matching `FilterOptionsController.check_dimension_offered/3` (`filter_options_controller.ex:96-104`).
- A dimension present with an empty value list is a client error on `POST /reports`. `[]` narrows a `filter-options` request to nothing and constrains a run to nothing, so accepting it would hand back a run wider than the one asked for. This rule is deliberately **not** shared with the web form (see the Self-Review), and it does not apply to duplicate, which normalizes instead.
- A filter that yields no query is a client error rather than a stored run. `POST /reports` answering 201 for a run that can never return a row asserts something untrue and makes every client spend a second call to find out. Portal reports are checked exactly, by building the query and discarding it; Athena reports are checked by requiring the filter to carry at least one dimension, date or application, because their query builder is not affordable in a request. See the Self-Review for why the check is not per-report.
- An id that is not in the caller's option set for its dimension is refused with a `BAD_REQUEST` naming the dimension and the ids, rather than stored. The predicate is membership in what `filter-options` offers, not "a label came back": the two are the same predicate by construction, so a value the discovery endpoint hands out can always be used to create a run. The seven person-bearing dimensions are scoped; `country`, `state` and `subject_area` are not, per REPORT-92's decision that they are global vocabularies carrying no per-person data, so for those three the check admits any id that exists.
- The check is membership in the *unnarrowed* option set. It does not apply the cascade: a caller may legitimately name a cohort and a school that do not intersect, and that is an empty report rather than a bad request.
- A dimension's id expression, base table, joins and scope predicate are expressed once, in a module that option discovery and the label lookup both read. It is not a per-dimension copy inside `ReportFilter`. The id expression is the half that makes `state` work: its option id is the synthesized `COALESCE(portal_schools.state, '(Unknown)')`, so `(Unknown)` is a real offered value, and a create stores the canonical spelling the lookup returns rather than whatever case the caller sent.
- `start_date` and `end_date` are validated as ISO dates before a run is stored, on **both** endpoints. They reach the report queries as raw interpolation, `"#{table_name}.start_time >= '#{start_date}'"` (`report_utils.ex:37-49`), and `FilterParams.parse/1` currently assigns them with no validation and no type check (`filter_params.ex:36-47`), so run creation would put caller-controlled text straight into the portal statement the report runs. Duplicate is not exempt: it never sees the parser, and a stored run can carry an unvalidated date because `ReportFilter.from_form/2` copies `form.params["start_date"]` as it arrives. A duplicate whose stored dates do not parse is refused rather than repaired, because dropping a date bound would widen the report (unlike the empty-list normalization, which is provably behavior-preserving).
- The `state` dimension's values reach `ReportFilter.get_filter_values/2` as caller-supplied strings, and that function interpolates them into portal SQL unescaped (`report_filter.ex:92`). This is fixed as part of this story, by routing the branch through `ReportUtils.mysql_string_list_to_in/1` (`report_utils.ex:18-21`), which every other string-dimension interpolation already uses.

### The Portal duplicate guard

- Duplicating an Athena run is free: it is the expected way to take a fresh snapshot.
- Duplicating a Portal run requires `force: true`. Without it the response is a coded error naming the existing run and pointing at re-pull, so a caller that reached for duplicate out of the Athena habit is told the cheaper thing to do. With `force: true` the duplicate proceeds.
- The refusal is a 409 with its own code, so cc-data can map it through `AsCLIError` into actionable CLI and MCP text. Adding it must not change what `ErrorHelpers.code_for_status/1` returns for any existing status, which today it would (see Technical Notes).
- The refusal's body is a pinned contract, not incidental: its keys are exactly `error`, `message` and `run_id`, asserted by a test. cc-data forwards a coded error's context verbatim into the CLI's printed envelope and the MCP result, so a field added here is disclosed the day it ships.
- The message points at re-reading the run rather than at any client's flag, since the server does not know about `--refresh`. REPORT-94 carries the client-side half of the same advice and cites this guard as its reason, so the wording lives here and that story matches it.
- The guard is defense in depth, not the only steering: the MCP tool and CLI descriptions, and the skill guidance REPORT-95 writes, point Portal callers at re-pull first.

### An Athena run created over the API actually runs

- A newly created Athena run, whether from `POST /reports` or from `POST /reports/:id/duplicate`, has its query started without requiring the caller to make a second request. Both endpoints use the same post-insert path, and the kickoff runs as a supervised task rather than inside the request, because starting an Athena query means running the portal learner query and uploading the learner file first (see Technical Notes).
- The response is therefore allowed to carry a null `athena_query_state`, exactly as a run created in the web form does before its page is opened.
- A duplicate inserts a new row with `athena_query_id` and `athena_query_state` unset. Copying them would make the "fresh snapshot" silently return the source run's frozen result (see Technical Notes), so this is asserted by a test rather than left to the clone's construction.
- Duplicating a run whose stored `report_filter` is `nil` treats it as the empty filter rather than raising, matching `ReportController.build_query/2`.
- `POST /reports` responds 201 and `POST /reports/:id/duplicate` responds 201, both with the run JSON.

### Web UI

- The runs table and the run detail page gain a duplicate action that creates a new run from an existing one and takes the user to it.
- The action appears on `/reports/all-runs` as well as `/reports/runs`, since all-runs is already portal-admin only. The duplicate is owned by the clicking user and its filter passes through `HideNames.enforce/2` like every other path, so a duplicate can never widen what its creator may see.
- The Portal guard is a server concern; an explicit button click is the user's intent, so the UI duplicates freely.

### cc-data client, CLI and MCP

- Typed create and duplicate methods on the API client, reusing `postJSON` and `AsCLIError` rather than new transport.
- A transport failure on either call is reported as possibly-created rather than retried, and the error text points at `cc-data reports list`. The client already refuses to retry a non-idempotent request for this reason (`internal/api/client.go:116-121`); the CLI has to say what it means.
- `cc-data reports create` and `cc-data reports duplicate`, plus the matching MCP tools, with catalog entries so the REPORT-104 drift guard (`internal/guidance/guard_test.go`) stays green.
- The filter is expressed on the command line as the JSON object the API already emits on a run, `--report-filter '{"cohort":[1,2]}'`, with `--report-filter-file` for anything too long to quote. The CLI needs some way to express a `report_filter` from a terminal. REPORT-92 shipped `cc-data reports filter-options` with `--search`, `--report-slug`, `--limit`, `--page-token` and a capped `--all`, so from a terminal a dimension can only be browsed at its top level; the MCP tool takes a `report_filter` and cascades. `reports create` has to invent a terminal filter expression regardless, so this story owns it, and the same expression is then accepted as `--report-filter` on `reports filter-options` so the two commands agree instead of diverging.
- Fake-server tests pinned to live wire captures of both endpoints, including the guard.

## Technical Notes

**A cloned Athena run must not inherit `athena_query_id`.** `ReportRun.changeset/2` casts `athena_query_id` (`report_run.ex:25-36`), so a clone built by copying the source struct's fields would carry the source's query id, and `AthenaRunOps.start_query/1` would then decline to run (it matches on `athena_query_id: nil`, `athena_run_ops.ex:16`) while `refresh_query_state/1` happily reports the source's finished state and result URL. The "fresh snapshot" would silently be the old snapshot. The clone copies `report_slug` and `report_filter` only.

**`AthenaRunOps` reads `report_run.user`, not `user_id`.** `start_query/1` passes `report_run.user` to both `report.get_query.(...)` and `athena_db().query(...)` (`athena_run_ops.ex:18-20`), and the portal-server field on that struct decides which portal database the query builds against. `Reports.create_report_run/1` (`reports.ex:133-137`) returns the inserted struct with `user` unloaded, so anything that starts a query after create must load it. `Reports.get_api_report_run/2` already preloads `:user` and applies the ownership and API-slug scoping, so re-reading through it is both the load and the authorization.

**Athena kickoff may not need to be explicit.** `AthenaRunOps.ensure_current/1` (`athena_run_ops.ex:52-73`) already starts a query for a run with `athena_query_id: nil` and `athena_query_state: nil`, under an atomic `update_all` claim that makes concurrent callers safe, and both `GET /api/v1/reports/:id` and `GET /api/v1/reports/:id/download` call it. The web form does not start the query either; `ReportRunLive.Show` does (`show.ex:175-185`). So "create then GET" already runs the query, and an explicit kickoff on create is a decision about whether a created-and-never-read run should burn Athena time, not a requirement of the plumbing. See the open question.

**The `state` injection is reachable, not theoretical.** Verified against the fixture portal: `get_filter_values/2` called with `state: ["CA') OR 1=1 -- "]` returned every state in the fixture, `%{state: %{"MA" => "MA", "NH" => "NH"}}`, rather than none. The payload closes the `IN` list, makes the predicate always true and comments out the rest of the statement, because the branch interpolates each value into `'#{id}'` directly (`report_filter.ex:92`) where every other string-dimension interpolation goes through `ReportUtils.mysql_string_list_to_in/1`, which escapes (`report_utils.ex:18-21`, `escape_mysql_literal/1` at `report_utils.ex:93-95`). The values are already client-supplied today, since the LiveView reads them from `form.params`, so this is a pre-existing defect the API create would widen rather than one this story introduces.

**The dates are a second injection, and it arrives with this story.** `apply_start_date/3` and `apply_end_date/3` interpolate their argument directly into the portal statement (`report_utils.ex:37-49`), and nothing between the request body and that interpolation inspects the value: `FilterParams.parse/1` writes `start_date: filter["start_date"]` without a type check, so a JSON string, number or object all arrive intact. Found while writing REPORT-118, whose cohort run needs a date bound.

REPORT-92 is not exposed, which was checked rather than assumed: neither `ReportFilterQuery` nor `FilterOptions` reads `start_date` or `end_date` anywhere, so the shipped filter-options endpoint carries the dates into the struct and never puts them into a statement. That is why this is REPORT-93's defect and not a live one, and it is also why widening `FilterParams` is what opens the path: the same parser that gains `app` and `hide_names` is the one whose dates start reaching SQL.

**`report_filter_values` can legitimately be empty.** `ReportFilter.get_filter_values/2` builds a `UNION ALL` only over the dimensions that have ids (`report_filter.ex:65-110`). A filter with no id dimensions, for example a log report filtered only by `app` and a date range, produces an empty statement, and the function returns `%{}` after logging the resulting portal error. A rule of "never store a run with empty `report_filter_values`" therefore cannot be enforced unconditionally without rejecting filters the web form accepts today. It also swallows a genuine portal failure into `%{}`, so a create whose label derivation failed is indistinguishable from one that had no labels to derive. Verified: a filter carrying only `app` and `start_date` logs `Error executing query on portal-test.example.com: Query was empty` and returns `%{}`.

**An Athena kickoff is a portal query and an S3 upload, not an API call.** `AthenaRunOps.start_query/1` calls the report's `get_query/2` (`athena_run_ops.ex:18`), which for the Athena reports runs `LearnerData.fetch_and_upload/2`: the full portal learner query, then an upload of the learner file to S3, and only then `athena_db().query/3` (`learner_data.ex:15-33`). Verified by running it. This is why the kickoff is a supervised task rather than part of the request, and it is also why `GET /reports/:id` and `/download` can be slow on a run whose query has never started.

**The kickoff needs no admission control, and the reason is not local to it.** Spawning one supervised task per create looks unbounded: `PostProcessingTaskSupervisor` (`application.ex:19`) sets no `max_children`, it already has three unbounded users (`form.ex:271`, `show.ex:243`, `job_server.ex:81`), and there is no rate limiting anywhere in the application. What bounds it is downstream. `PortalDbs.get_or_start_pool/1` starts each portal server's pool with `pool_size: 5` (`portal_dbs.ex:99`), so concurrent portal work from this application is capped at five connections per server however many tasks exist, and that is the ceiling with or without this endpoint. Excess checkouts are dropped rather than queued forever, so a kickoff that cannot get a connection fails fast, `ensure_current/1` logs and releases its claim back to a null state, and the next read retries. Nothing is lost and nothing needs clearing. Queued tasks block in checkout before fetching anything, so they hold no learner data while they wait.

The heavier version of this is already live regardless: `GET /reports/:id` and `/download` run the same portal query and S3 upload *synchronously* inside the request through `ensure_current/1`, shipped with REPORT-88 (`f588f10`), holding a web worker as well as a connection. A limiter in front of the create's asynchronous kickoff would be a looser bound behind a tighter one, and when it filled it would push load onto those synchronous paths. The one residual: S3 uploads happen outside the pool, so a burst can leave a few concurrent uploads each holding a learner dataset in memory, bounded by portal query throughput and shared with the form and read paths that already do this.

**Adding an error code is not additive.** `ErrorHelpers` holds `@statuses` (code to HTTP status) and inverts it into `@codes_by_status` (`error_helpers.ex:5-16`), which `code_for_status/1` uses and `ErrorJSON` calls to render raised exceptions in the contract shape (`server/lib/report_server_web/controllers/error_json.ex:23`). Verified by running the inversion with a second 409 code added: the map goes from 9 entries to 8 and `code_for_status(409)` returns the new code instead of `NOT_READY`. Any new code either takes a status no existing code uses, or the inversion is changed to name one primary code per status explicitly.

**`FilterParams.parse/1` is not sufficient as-is.** It iterates `ReportFilter.dimensions()` and builds a `%ReportFilter{}` carrying `exclude_internal`, `start_date` and `end_date` (`filter_params.ex:36-47`). It never sets `app`, `hide_names` or `filters`, and it does not validate the dates. Its `null` versus `[]` distinction (`filter_params.ex:49-58`) is meaningful for narrowing options and meaningless on a run, in the dangerous direction: `[]` on a create constrains *nothing*, it does not select nothing. Verified by building the learner query both ways, `cohort: []` produces SQL byte-identical to `cohort: nil`, because every dimension is gated on `ReportUtils.have_filter?/1`, which is `!Enum.empty?`. This is the one place where widening the discovery parser was not free: the distinction belongs to a discovery request, where `has_empty_dependent_filters?` honors it, and a persisted run cannot hold it.

**A stored filter changes type across a database round trip.** `EctoReportFilter.dump/1` hands Ecto a plain map and `load/1` rebuilds the struct from JSON, so what goes in as atoms comes back as strings. Verified against the Repo: `filters` inserted as `[:school, :cohort]` reloads as `["school", "cohort"]`, and `report_filter_values` inserted as `%{cohort: %{1 => "Cohort One"}}` reloads as `%{"cohort" => %{"1" => "Cohort One"}}`. The API JSON is unaffected either way, since `ReportJSON.report_filter_json/1` maps `to_string/1` over `filters` and Jason renders both key shapes identically, which is why this is invisible until something pattern matches.

It matters on the duplicate path, which is the only path that reads a filter back out of the database. Anything deriving dimensions from `filters` would compare strings against `ReportFilter.dimensions()` atoms and find nothing, so `filters` is never a source of which dimensions a filter carries: the struct fields are, and `filters` is derived from them on every write.

**`filters` is display and cascade metadata, not query input.** The report queries read the individual dimension fields (`LearnerBaseQuery.apply_filters/2` (`learner_base_query.ex:57-61`) destructures them by name), while `report_filter.filters` is consumed by `ReportJSON.report_filter_json/1`, by the runs UI, which renders it reversed (`custom_components.ex:269`), and by `ReportFilterQuery.get_query_and_params/4`, which takes `hd(filters)` as the primary dimension when the filter is fed back into option discovery (`report_filter_query.ex:571-575`). `ReportFilter.from_form/2` builds it in reverse form order and says so (`report_filter.ex:31-42`). A create endpoint that leaves it empty produces a run that displays no filters in the web UI and cascades differently when its filter is sent back to `filter-options`.

**The runs table is shared between my-runs and all-runs.** `CustomComponents.report_runs/1` (`custom_components.ex:327-357`) has no actions column and takes an `include_user` flag; `/reports/all-runs` renders other users' runs through the same component. A duplicate action added to the component appears on both surfaces, so who a duplicated run belongs to, and whether the action shows at all on all-runs, is a decision the component cannot make for itself.

**The partition warning is a LiveView interaction, not a filter property.** `LearnerData.count/2` (`learner_data.ex:73-79`) is a single portal count query, cheap enough for a request, and `PartitionEstimate.projected_partitions/4` turns it into the estimate. The form runs the count in a task, shows the warning, and creates the run only after an explicit confirm (`form.ex:255-295`); an over-limit run is still allowed. An API create has no confirm step.

**What the neighboring stories need from this one.** REPORT-94 and REPORT-127 are independent of this story in both directions (Jira records neither as blocking or blocked by it; REPORT-94's plan states that no step of it depends on the create endpoint, and a run authored in the web form exercises every path it has). Two agreements still cross the boundary and are easy to break silently.

REPORT-94 hardcodes the client-side re-pull advice and cites this story's Portal-duplicate guard as its justification, so the guard's message is pinned in the implementation plan rather than left to the implementer. And REPORT-127 establishes that an API error body is caller-visible surface, because cc-data passes a coded error's context through to the CLI envelope and the MCP result unchanged; that is already true of this story's 409 body, so its keys are pinned and asserted here rather than after 127 lands.

Sequencing, for whoever picks this up: the server work overlaps nothing, since REPORT-127's server half changes `download/2`, `athena_download/3` and `report_json.ex` while this story adds `create/2` and `duplicate/2`. The cc-data work meets both stories in `internal/api/types.go`, meets REPORT-94 in `cmd/reports.go` and meets REPORT-127 in `internal/api/reports_test.go`, all additively. The guidance files do not collide (`src/tools.md` here, `src/core.md` in 94), so REPORT-104's drift guard does not become a three-way merge.

**Audit.** `AuditLog` records `download_url_issued`, `attachment_urls_issued` and `run_csv_streamed` (`server/lib/report_server/audit_log.ex`). There is no run-created event on any path, including the web form, so creating runs over the API leaves the same trace the web form does: the run row itself.

## Out of Scope

- A rerun or refresh endpoint, for the immutability reasons above.
- Deleting runs over the API.
- Editing an existing run's filter in place.
- A one-shot create-and-pull convenience command in cc-data. `reports create` followed by `get report <new-run-id>` is two calls the skill can chain, and folding them into one command is a trivial follow-on if it is ever wanted.
- The skill and MCP guidance prose that teaches the create-and-pull workflow, which is REPORT-95. This story adds only the minimal catalog entries the drift guard requires.
- Portal report consumption in cc-data (REPORT-94), including the run-type column on `reports list`. This story's client work does not depend on that branch and must not pre-empt it.

## Open Questions

### RESOLVED: Does create start the Athena query, or leave it to the first read?

**Context**: `AthenaRunOps.ensure_current/1` already self-starts a run on `GET /reports/:id` and `/download`, safely and idempotently, so both behaviors produce a working run. Starting eagerly costs Athena time for a run nobody reads; starting lazily means a client that creates and walks away has a run in no state at all, and `reports list` shows it as `(none)`.

**Options considered**:
- A) Create inserts only. The first `GET` or `download` starts the query, exactly as it does for a run created in the web form.
- B) Create calls `ensure_current/1` on the re-read run, so the query is submitted before the response is rendered and the response carries a real state.
- C) Create calls `start_query/1` directly.

**Decision**: B, kicked off asynchronously. The Jira description already settles that an Athena create kicks off the query, so the question is only which entry point, and `ensure_current/1` is the right one: it claims the run atomically with a conditional `update_all` before starting, releases the claim if the start fails (`athena_run_ops.ex:52-73`), and its claim is what keeps a concurrent `GET /reports/:id` from starting the same query twice. `start_query/1` would duplicate that claim and failure handling for no gain.

Revised during stage 4 from a synchronous call to a supervised task, because the cost of a kickoff turned out to be much larger than the phrase suggests. Verified by running `ensure_current/1` on a freshly created `student-answers` run: the stack is `ensure_current/1` to `start_query/1` to the report's `get_query/2` to `LearnerData.fetch_and_upload/2`, so before Athena is contacted at all it runs the full portal learner query and uploads the resulting learner file to S3 (`learner_data.ex:15-33`). On a cohort the size of the one REPORT-118 will create, doing that inside the request would make a create that timed out at the HTTP layer while the run it created was perfectly fine, which is the one failure the client cannot disambiguate. The task runs in `ReportServer.PostProcessingTaskSupervisor` (`application.ex:19`), the same supervisor the form's learner count and the job server already use.

The consequence for the response: a just-created Athena run may render with `athena_query_state` null, because the task may not have claimed it yet. That is the same value a form-created run has until its page loads, the client polls for the state anyway, and the alternative is holding the response open for the portal query.

### RESOLVED: What does the server store in `report_filter.filters` for a created run?

**Context**: The field drives how the run's filters display in the web UI and, it appeared, which dimension `filter-options` treats as primary when the filter is sent back.

**Options considered**:
- A) Derive it server-side from the dimensions present, and ignore any client-supplied `filters`.
- B) Accept `filters` from the client when present, validating it, and derive it when absent.
- C) Store it empty and accept that such runs display no filters in the web UI.

**Decision**: A. The cascade half of the concern does not exist: `FilterOptions.prepare/3` replaces the list wholesale with `[dimension]` and documents that "the caller's filters list is replaced rather than merged with" and "the tail is never read" (`filter_options.ex:161-170`), so a stored run's `filters` never reaches option discovery. Its only remaining consumer is the web UI's filter display, which needs no client input to get right. Accepting the field from the client would add a contract surface nothing reads.

The list is stored in reverse `ReportFilter.dimensions()` order, because `CustomComponents.report_filter_values/1` renders `Enum.reverse(@report_filter.filters)` (`custom_components.ex:269`); storing it forward would display every created run's dimensions backwards relative to a form-created one. `app`, the dates, `exclude_internal` and `hide_names` render from their own struct fields and are unaffected either way (`custom_components.ex:272-292`).

### RESOLVED: What happens when label derivation fails or has nothing to derive?

**Context**: `get_filter_values/2` returns `%{}` both for a filter with no id dimensions and for a portal query that failed. The Jira description's rule, never store a run with empty `report_filter_values`, cannot distinguish them as the function stands.

**Options considered**:
- A) Distinguish them in the function: return `{:ok, values}` or `{:error, reason}`, treat "no id dimensions" as `{:ok, %{}}`, and fail the create on a portal error. The web form keeps its current lenient behavior.
- B) Keep `%{}` and accept it on create, dropping the never-empty rule as unenforceable.
- C) Reject a create whose derived values are empty.

**Decision**: A. Verified by running the two cases against the fixture portal (`test/support/portal_fixture.ex`): a filter carrying only `app` and `start_date` logs `Error executing query on portal-test.example.com: Query was empty` and returns `%{}`, because the `UNION ALL` is assembled only from dimensions that have ids (`report_filter.ex:65-110`) and an all-empty reduction yields an empty statement. A genuine portal failure returns the same `%{}` after the same shape of log line. C is therefore wrong outright: it would reject app-only and date-only log filters the web form accepts and the runs UI already renders correctly (`custom_components.ex:272-286`). B leaves a created run silently missing every label when the portal is down, which is exactly the case the never-empty rule was reaching for.

So the empty-statement case is recognized before the query rather than after it, and a portal error becomes a real error the create surfaces. The web form keeps its current behavior, and the rule in the Jira description is restated as: never store a run whose label derivation *failed*; storing a run with no labels to derive is correct.

### RESOLVED: Which HTTP status does the Portal-duplicate guard use?

**Context**: A new code cannot reuse 409 without changing what `code_for_status/1` returns for raised exceptions.

**Options considered**:
- A) 422 `UNPROCESSABLE`, adding no new code, at the cost of cc-data's ability to branch on it.
- B) A new code on a status no existing code holds.
- C) Add the code at 409 and pin the status-to-code direction explicitly.

**Decision**: C. 409 Conflict is the honest status for "the request is well formed but conflicts with this run's nature, retry with `force`", and the two remaining options both distort something to avoid touching six lines: A gives up the coded branch the Jira description asks for, and B picks a status for its availability rather than its meaning. `@codes_by_status` becomes an explicit map naming one primary code per status rather than an inversion of `@statuses`, so `code_for_status(409)` stays `NOT_READY` by declaration instead of by map ordering, with a test asserting it. Verified that the naive addition breaks it: adding a second 409 code takes the inverted map from 9 entries to 8 and makes `code_for_status(409)` return the new code, which `ErrorJSON` (`error_json.ex:23`) would then render for every raised 409.

### RESOLVED: Does the API create surface the partition warning?

**Context**: A log-report run whose filter projects past Athena's partition ceiling fails at query time with a `CONSTRAINT_VIOLATION` the researcher then has to interpret; REPORT-106's failure guidance names the application filter for exactly this case. The web form warns before submitting and lets the user proceed anyway (`form.ex:255-295`). `LearnerData.count/2` (`learner_data.ex:73-79`) is one portal count query, so the estimate is affordable in a request.

This is the one question where the port stories argue against the cheap answer. The warning exists because Scott hit the partition ceiling and worked around it with his own AWS credentials, and REPORT-118 and REPORT-119 will create exactly those runs from the CLI rather than the form. If the API stays silent, the port reintroduces the failure mode the warning was built to prevent, and the researcher learns about it from a failed run instead of before submitting. Against that: REPORT-105 scoped the warning to the form, the run JSON shape is otherwise identical to what `GET /reports/:id` returns, and REPORT-106 already turns the eventual failure into actionable text.

**Options considered**:
- A) Nothing. The run is created, Athena rejects it, and REPORT-106's guidance explains why.
- B) Compute the estimate on create for reports that offer the app filter and return it in the response as an advisory field, creating the run either way. Deviates from the run JSON shape by one field.
- C) Refuse over-limit creates unless the body passes an acknowledgement flag, mirroring the form's confirm step. Costs a round trip and a second code, and makes the CLI's create fail by default on the runs the port cares about.

**Decision**: A. Two reasons decide it, and neither is the "keep the response shape clean" argument an earlier draft leaned on.

A prediction drifts and an error report cannot. The estimate is a function of `AthenaConfig`'s `@log_apps` and its projection ranges, and `@log_apps` gained `CODAPV3` on 2026-09-08, taking it from fifteen applications to sixteen and changing every unconstrained estimate by about seven per cent. A predictive API contract would have been silently wrong until that commit and will be wrong again the next time the DDL changes. Athena's own `StateChangeReason` cannot disagree with Athena.

B also cannot be made shape-uniform. cc-data decodes one `api.ReportRun` for list, show, create and duplicate, so a create-only advisory field forces either a second response type or a field that is null on every other endpoint; making it genuinely uniform means a portal count query per run per list page, which is not affordable on `/reports/all-runs`. The web form keeps its predictive warning because it has a confirm step and a human in front of it, and the API has neither.

A depends on the failure actually explaining itself, and at the time of writing it does not. The server sends `athena_query_error` and `athena_query_id` in the `NOT_READY` body (`report_controller.ex:84-88`) and on the run (`report_json.ex:32-34`), but cc-data drops them: `stateExtra/2` rebuilds the error's `Extra` from scratch as `{"athena_query_state": state}` (`internal/fetch/report.go:242-247`), so `get report` on a failed run prints only "terminal state \"failed\"". That gap is REPORT-127, which is inside the same `cc-data-cli 0.2.0` release as this story and is sequenced after REPORT-94. If REPORT-127 slips out of 0.2.0, this decision should be revisited, because A without it ships the bare "failed" that REPORT-106 existed to remove.

### RESOLVED: Where does the duplicate button appear, and whose run does it create?

**Context**: `CustomComponents.report_runs/1` renders both `/reports/runs` and `/reports/all-runs`, and on all-runs the rows belong to other users.

**Options considered**:
- A) My-runs only.
- B) Both surfaces, always owned by the clicking user and re-validated against that user's role.
- C) Both surfaces for admins, my-runs only otherwise.

**Decision**: B, which subsumes C. `/reports/all-runs` is already portal-admin only: `ReportRunLive.Index.mount/3` redirects anyone without `portal_is_admin` (`report_run_live/index.ex:15-21`), so the cross-user case only ever arises for a user who may see every run anyway, and duplicating a user's failed run is a plausible reason an admin is on that page. The duplicate is owned by the clicking user and its filter goes through the same `HideNames.enforce/2` every other path applies, so a duplicate can never widen what its creator may see. The run detail page gets the button too, since that is where a user lands after following a run link.

### RESOLVED: What is the terminal syntax for expressing a report filter?

**Context**: This story owns the expression because `reports create` cannot work without one, and it is then reused as `--report-filter` on `reports filter-options`. It has to survive a shell, express ten id dimensions plus `state` strings, `app`, dates and two booleans, and round-trip what the API emits on a run.

**Options considered**:
- A) A JSON string, `--report-filter '{"cohort":[1,2]}'`, plus `--report-filter-file` for anything long.
- B) Repeatable typed flags, `--filter cohort=1,2 --filter state=CA`.
- C) Both, with one defined as canonical and the other building it.

**Decision**: A. It is byte-identical to the wire shape the API already emits on every run (`ReportJSON.report_filter_json/1`), so `cc-data reports list --json`, edit, `reports create` round-trips with no translation layer that could disagree with the server, and the MCP tool passes the same JSON it already passes to `reports_filter_options` (`endpoints.go:93-126`). B is friendlier to type but is a second syntax that has to be kept in agreement with the first, which is the duplication this project keeps flagging. `--report-filter-file` covers the case that actually motivates B, a long hand-assembled cohort, without inventing a grammar. Typed flags stay additive if hand use turns out to be painful.

### RESOLVED: Is there a cap on how many ids a filter dimension may carry?

**Context**: `FilterParams.parse/1` validates each id but does not cap list length, and the ids are interpolated into portal SQL.

**Options considered**:
- A) No cap.
- B) A per-dimension cap with a `BAD_REQUEST`.
- C) A cap on the whole filter's total id count.

**Decision**: A. The ceiling the question was reaching for is the wrong one: Athena's 256 KB SQL limit and its partition limit are driven by the *learner* count a filter expands to, not by the number of filter ids, and 15 assignment ids can expand to thousands of learners while 500 school ids may expand to none. A cap on ids would not prevent the failure it appears to prevent, and would reject filters the web form accepts. An oversized list fails at the portal query with a MySQL error the create surfaces, which is the same thing every other malformed filter does. The learner-count ceiling is the subject of the partition-warning question above, which is where it belongs.

## Self-Review

### Security Engineer

#### RESOLVED: `report_filter_values` derivation is not project-scoped, so create becomes a label oracle

REPORT-92's requirements state that for the seven person-bearing dimensions "an option outside that scope never appears under any combination of parameters; a caller with no allowed projects gets an empty list" (`specs/REPORT-92-filter-option-discovery-api.md:49-51`). `POST /reports` as specified would break that: it accepts arbitrary ids and returns `report_filter_values` derived from them.

Verified. `ReportFilter.get_filter_values/2` (`report_filter.ex:65-110`) issues a `UNION ALL` of `WHERE id IN (...)` selects with no project predicate at all, where `FilterOptions` resolves `allowed_projects(user)` and passes it on every call (`filter_options_controller.ex:38-43`). So a caller who can browse nothing can still post `{"cohort":[7]}` and read back cohort 7's name, and the same for school, assignment, class and permission form. Teacher returns name and email, which is existing policy rather than a new gap. Student is safe by accident of a different rule: `hide_names` is forced on for non-admins and the student branch then selects the user id instead of the name (`report_filter.ex:84-88`).

The report *data* is not exposed. `LearnerBaseQuery.apply_filters/2` calls `apply_allowed_project_ids_filter/5` unconditionally (`learner_base_query.ex:68`) and `:none` renders as `1 = 0` (`report_utils.ex:156-159`), so an out-of-scope filter yields a zero-row report. That is what makes this a labels-only leak, and also what makes the current behavior unhelpful: the caller gets an authoritative-looking empty report and no indication why.

It is reachable through the web form today, since `ReportFilter.from_form/2` reads whatever `filter1` values the client posts, so this is a pre-existing defect the API would make scriptable rather than one this story invents.

**Recommendation**: derive the labels through the same scoping the options endpoint uses, and treat a requested id that comes back without a label as out of scope, failing the create with a `BAD_REQUEST` naming the dimension and the ids. One query answers both questions, it honors 92's contract without inventing a second one, it turns a silent zero-row report into an actionable error, and it makes the bad state impossible rather than recording it. The three taxonomy dimensions keep applying no scoping, per 92's decision that `country`, `state` and `subject_area` are global vocabularies (`specs/REPORT-92-filter-option-discovery-api.md:466-470`).

**Decision: scope the derivation and refuse ids the caller's option set does not contain**, with the per-dimension definition written as a shared source rather than as a third copy of the rule. The refusal is stated in terms of the option set rather than the label because defining it on labels breaks on `state` and rests on a structure REPORT-126 may remove; the entry below this one records that and is the operative form of the rule.

The behavior is the easy half. An id outside the caller's option set is one the caller cannot see, and the create fails with a `BAD_REQUEST` naming the dimension and the ids, rather than storing a run whose report is `1 = 0` and whose filter displays blank. REPORT-118 sees a refusal instead of an empty report, which is the more useful of the two.

The structure is the half worth recording. "What may this user see" already exists in two shapes: `ReportUtils.apply_allowed_project_ids_filter/5`, the learner-data shape parameterized by two id refs and used by `LearnerBaseQuery` and three Portal reports, and `ReportFilterQuery`'s seven `allowed_projects_*` join patterns, the dimension-entity shape. Grafting the second onto the label lookup would make a third copy of a rule this project's reviews reliably flag. So the per-dimension scoped source becomes one module and `get_filter_values/2` is its first caller. `ReportFilterQuery` then adopts it inside this story: REPORT-92's #422 merged as `562bd03`, so the reason for deferring that (churn on 92's own file mid-review) is gone, and the implementation plan carries it as its own step. Option discovery and label resolution end up sharing one definition, discovery adding `LIKE`, ordering and paging, and label resolution adding `id IN` over the same id expression.

`report_filter_values` is a display cache and nothing more: its only readers are the runs table, the run page and the API JSON (`custom_components.ex:265-271,351`), nothing computes on it, and this spec already treats it as untrustworthy by re-deriving on duplicate. How labels should be produced at all, and whether the API should expose them, is filed as REPORT-126, blocked by this story. Note what that story does **not** cover: the scoped lookup is required either way, because answering "what is cohort 7 called" for an id the caller cannot see is the same disclosure whether it happens at write time or at render time. So this story's scoping stands on its own. REPORT-126 decides the storage, which is what makes labels go stale and what leaves pre-existing rows unscoped, and whether the v1 API needs to carry them at all given that its only consumer is the FILTERS column of `cc-data reports list`.

#### RESOLVED: the refusal was defined on labels, which is the one structure REPORT-126 may remove

The first draft of this decision refused any requested id that came back without a label. That makes "did a label come back" the authorization predicate, and this spec already calls `report_filter_values` a display cache that REPORT-126 is chartered to change or delete, so the check would sit on top of the structure the next story exists to rework.

It also broke on the one dimension whose option id is synthesized rather than a primary key. Verified against the fixture portal: `filter-options` for `state` offers `(Unknown)`, because its id expression is `COALESCE(portal_schools.state, '(Unknown)')`, while the label select's `state IN ('(Unknown)')` resolves nothing, so a caller picking an offered value would have been refused. Case folding has the same shape, `state IN ('ma')` resolves `MA`, so the asked-for value never equals the resolved one.

Rejected the narrower fix of applying the refusal only to the seven scoped dimensions. It happens to work today only because `state` is currently the only synthesized id, so it is an exception list that the next such dimension reintroduces, and it leaves the predicate on the display cache regardless.

**Decision**: the refusal is membership in the caller's option set, and `DimensionScope` carries each dimension's id expression alongside its base, joins and scope predicate, so option discovery and label resolution cannot disagree about what an id is. Verified the rewrite: with the shared id expression the same three values resolve to `["NH", "MA", "(Unknown)"]` where today's select drops `(Unknown)`, and `ma` comes back as `MA`, which is what the create then stores. Checked the other two taxonomies for the same hazard and neither has it; `subject_area`'s option base is `admin_tags WHERE scope = 'subject_areas'`, identical to its label base.

The `Enum.member?(country, -1)` branches in `DetailedMetricsBySchoolReport` and `SummaryMetricsBySubjectAreaReport` are deleted with this. `-1` has never been a selectable country id: the option query has projected `portal_countries.id` since `89aad07` introduced the reports and the filter together, with the `COALESCE` on the label only.

#### RESOLVED: the `state` dimension is a live SQL injection, and it belongs to this story

Already a requirement, and confirmed exploitable rather than theoretical during stage 2; the evidence is in Technical Notes. Recorded here so the security pass is not silent about the most serious thing it found.

### Senior Engineer

#### RESOLVED: duplicate was not covered by the "created run actually runs" requirement

The requirement named create only, while a duplicate of an Athena run is the primary way a fresh snapshot is taken and needs the same kickoff. Both endpoints now go through the same post-insert path.

#### RESOLVED: duplicating a run with a `nil` stored filter would raise

Verified. A stored run can carry `report_filter: nil`; `CustomComponents.report_filter_values/1` says so and defends against it ("a programmatically created run (API/console) can have a nil report_filter", `custom_components.ex:264-266`), and `ReportController.build_query/2` coalesces it (`report_controller.ex:105`). `ReportFilter.get_filter_values/2` pattern-matches `%ReportFilter{}` (`report_filter.ex:65`), so duplicating such a run would raise a `FunctionClauseError` rendered as a 500. Duplicate now coalesces a nil stored filter to `%ReportFilter{}`, matching the existing convention.

#### RESOLVED: `FilterParams.parse/1` can be widened rather than copied

The spec left "widen or add a second parser" undecided, which invites the second parser and the divergence that follows. Verified that widening is safe: `app` is not a filter dimension in `ReportFilterQuery` at all (every `app`-shaped occurrence in that file is `apply_secondary_filters`), so carrying it through the shared parser cannot change what filter-options returns, and `hide_names` is overridden by `FilterOptions.prepare/3`'s own `HideNames.enforce/2` call regardless of what the parser sets (`filter_options.ex:165-170`). One parser, with the create path supplying the fields the options path does not read.

#### RESOLVED: an empty value list widens the run instead of narrowing it, and the API is the only path that gets the rule

`FilterParams` preserves `[]` as distinct from `nil` because `filter-options` needs it: `has_empty_dependent_filters?` short-circuits the option query, so `{"cohort": []}` correctly returns zero options. The report query reads the same value the opposite way. Every dimension is gated on `ReportUtils.have_filter?/1`, which is `!Enum.empty?`, so `[]` is not a filter at all. Verified: for a project-scoped user, `cohort: []` produces SQL byte-identical to `cohort: nil`, while `cohort: [1]` adds `(aci_teacher.admin_cohort_id in (1))`. A caller who narrows to nothing in discovery and passes the result to create therefore gets a run over their whole project scope.

The web form is *nearly* immune, and the shape of the gap is worth recording because it is not where it looks. `form.html.heex:91` wraps the dates, the options and the Run Report button in `<%= if !blank?(@form.params["filter1"]) do %>`, and `blank?/1` covers `[]` (`helpers.ex:2-5`), so an empty **first** filter cannot be submitted. The gate never re-checks the later rows. Choosing cohorts, clicking Add Filter, selecting "School" from the type dropdown and selecting no schools leaves the button visible, and `from_form/2` then returns `filters: [:school, :cohort], cohort: [1], school: []`. Verified, including that the resulting SQL carries no `rl.school_id IN`. Adding a filter row without choosing a type is harmless: `get_filter_type!/2` skips a blank type.

**Decision**: `POST /reports` refuses a dimension whose value list is empty, and the web form keeps its current behavior. Deliberately not shared, against the story's general preference for one shared rule per validation: the form's mistake is a live UI state a user is still editing, where the existing gate already prevents the common case, and turning a half-filled filter row into a submit-time error is a UI change this story has no mandate for. The API has no cascading UI and no half-filled state, so the same value there is a finished request that cannot mean what it says.

`POST /reports/:id/duplicate` normalizes `[]` to `nil` rather than refusing. Create is a caller asserting an intent a run cannot express, so refusing is the useful answer; duplicate is a faithful copy of what an existing run *does*, and what it does is already unconstrained, so normalizing provably cannot move a row and only makes the copy's stored filter honest. It also keeps the multi-filter runs the form can already produce duplicable, which a shared refusal would have turned into a dead end with no edit-a-run path to escape it.

Rejected changing `have_filter?/1` so that `[]` selects nothing everywhere. It is the semantically correct answer and it is a different ticket: 26 call sites across 8 files, including four Portal reports and an Athena report, and it would change what an already-submitted form filter does.

#### RESOLVED: a create can store a run whose query can never be built

`ReportQuery.update_query/2` returns `{:error, "Cannot run query with no filters"}` when a filter contributes no join and no where, and the plan stored such a run anyway, because label derivation for it succeeds with `{:ok, %{}}`. Verified by calling each API-exposed report's `get_query` with an empty filter: `school-metrics` fails that way for anyone, and `student-answers` fails for a portal super-admin. Project-scoped users are unaffected on the learner reports, because `apply_allowed_project_ids_filter/5` always contributes a where clause, so this is a super-admin and aggregate-report case, and portal admins are a good part of the intended audience.

Neither downstream failure is silent, which is worth recording because it bounds what this is worth. `portal_download/4` matches that exact error and renders a 422 reading "This report run has no filters and cannot be downloaded." An Athena run fails in the kickoff, `ensure_current/1` releases its claim back to a null state, and cc-data already detects the resulting null-queued-null cycle in `oscillation.observe/1` (`internal/fetch/report.go:208-220`) and exits with "the server repeatedly failed to start the query for run N". The defect is the wrong 201 and the inert row, not a confused user.

**Decision**: check exactly where that is free, and by input rule where it is not, branching on `report.type`. All seven Portal reports' `get_query` are pure builders that execute nothing (two are a direct `LearnerBaseQuery.build/4`; the rest assemble a `%ReportQuery{}` and run `apply_filters`), so building and discarding costs at most the allowed-projects lookup and, with `exclude_internal` set, the internal-teacher-ids query, against a create that already makes a portal round trip for labels. Four of the five Athena reports reach the same check only through `LearnerData.fetch_and_upload/2`, so theirs is the input rule and the async kickoff keeps reporting the rest.

Rejected a per-report `validate_filter` callback, which is the precise answer and the wrong cost. Defaulted to `get_query` it is safe for the eleven reports that exist and dangerous for the next one, since an author who does not think about the override gets a portal learner query and an S3 upload inside the request, failing as a production timeout rather than a compile error. Made required instead, it is permanent boilerplate on every report to answer a question ten of them answer identically. `report.type` is already the branch `ReportController` uses for `ensure_current_if_athena/1` and for choosing between `portal_download/4` and `athena_download/3`, so this adds a third use of an established seam and no new per-report obligation: a new Portal report gets exactness automatically and a new Athena report gets the input rule automatically.

Residual, accepted: a super-admin creating an Athena run with only `app` and no dates still passes the input rule and fails at kickoff, with the state and the cc-data detector above reporting it.

#### RESOLVED: the date validation reached create only, while duplicate also stores a run

The requirement says the dates are validated "before a run is stored" and the plan put the check in `FilterParams.parse/1`, which duplicate never calls. Verified that the gap is real rather than theoretical: `ReportFilter.from_form/2` copies `form.params["start_date"]` with no validation, so the socket stores whatever it receives and the template's `<.input type="date">` constrains a browser but not a crafted event. Downstream, `ReportUtils.apply_start_date([], "2026-01-01' OR '1'='1")` returns `run.start_time >= '2026-01-01' OR '1'='1'`, interpolated into the portal statement.

Log reports turned out to be safer than the learner and Portal ones, which is worth recording so nobody assumes the reverse: `apply_log_date/4` splits on `-` and runs `DateTime.from_iso8601`, discarding a value that will not parse, so that payload is dropped there. It raises only for a value that does not split into three parts.

**Decision**: check on both paths, refusing a duplicate whose stored dates do not parse. Rejected dropping the bad date by analogy with the empty-list normalization, because that analogy fails: normalizing `[]` cannot move a row, and removing a date bound returns more data than the source run did. The practical cost of refusing is near zero, since the form's date control means the stored population of unparseable dates is probably empty, and any run that is in it is one whose statement is already malformed or injected.

The check has one definition, `FilterValidation.check_dates/1`, called from the parser (so `filter-options` keeps being tightened as the plan intends) and from the context function (so duplicate is covered), rather than a second copy on the duplicate path.

Two neighboring risks checked and deliberately left alone. Duplicate also re-runs `FilterValidation.validate/2`, so a stored run could become non-duplicable if its report stopped offering a dimension or an application were retired; the git history says neither has ever happened, as every `include_filters` change in `tree.ex` is a commit adding a report and `@log_apps` only grows. And a run whose ids fall outside the caller's projects after a membership change is refused, which is the scoping decision working rather than a regression.

### QA Engineer

#### RESOLVED: "a clone must not inherit `athena_query_id`" was a note, not a requirement

The failure it prevents is silent, a duplicate that returns the source's frozen result, so it needs a test and therefore a requirement, not a paragraph in Technical Notes.

#### RESOLVED: the create response status was unstated

Verified that cc-data accepts any 2xx (`internal/api/client.go:124-126`), so a created-resource status costs the client nothing and distinguishes a create from a read in logs and in wire captures.

### cc-data client author

#### RESOLVED: a failed create cannot be retried, and the CLI has to say so

Verified. `Client.do` treats a transport error on a non-idempotent method as terminal precisely because the request may have reached the server (`internal/api/client.go:116-121`), so a timed-out `reports create` may or may not have created a run and the client cannot tell. The CLI's error text points the user at `reports list` rather than at retrying, and this is a property to assert, not just to document.
