# Create and duplicate report runs

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-93

**Status**: **Closed**

## Overview

Add `POST /api/v1/reports` and `POST /api/v1/reports/:id/duplicate` so a report run can be created from scratch or cloned without the web form, add a duplicate button to the runs UI, and expose both over the cc-data CLI and MCP. Without this the CLI can only consume runs a human authored in the browser.

Two repositories: `report-service` for the endpoints, the shared validation and the UI, and `cc-data-cli` for the typed client, the two commands and the two MCP tools.

## Requirements

### The two endpoints

- `POST /api/v1/reports` creates a run from `report_slug` and `report_filter`, for the bearer token's user, answering the same run JSON `GET /api/v1/reports/:id` returns.
- `POST /api/v1/reports/:id/duplicate` creates a new run from run `:id`'s slug and filter; the client sends only the id.
- Both refuse a non-API-exposed slug and an id the caller does not own with the same `NOT_FOUND` the read endpoint returns, so ownership and API exposure stay indistinguishable from non-existence. *(A missing or non-string `report_slug` is a `BAD_REQUEST` instead, since nothing was named to be not found.)*
- Both respond 201.
- Neither has a rerun or refresh sibling: an Athena run is immutable and a Portal run is computed on request, so refreshing is a re-read for Portal and a duplicate for Athena.

### Filter values are always server-derived

- `report_filter_values` is derived from `report_filter` on both endpoints and never accepted from a client.
- Duplicate re-derives rather than copying, because a stored label is a point-in-time snapshot.
- Derivation distinguishes "no labels to derive" (stored) from "deriving them failed" (fails the create).
- `report_filter.filters` is derived server-side on both endpoints in reverse `ReportFilter.dimensions()` order; any client-supplied `filters` is ignored.

### Validation the server performs, not the client

- `hide_names` is forced on for any caller `HideNames.allowed?/1` rejects.
- An `app` value is accepted only on a report whose `form_options` set `enable_app_filter`, and only for known applications.
- A dimension the report does not offer is a client error.
- A dimension present with an empty value list is a client error on create; duplicate normalizes it to unset instead. Deliberately not shared with the web form.
- A filter that yields no query is a client error: exact for Portal reports (build the query and discard it), by input rule for Athena ones (at least one dimension, date or application).
- An id outside the caller's option set is refused with a `BAD_REQUEST` naming the dimension and the ids. Membership is against the *unnarrowed* option set, so a cohort and a school that do not intersect are an empty report rather than a bad request. `country`, `state` and `subject_area` are unscoped global vocabularies, so for those the check is "this id exists".
- A dimension's id expression, base table, joins and scope predicate are expressed once, in a module option discovery and label resolution both read.
- `start_date` and `end_date` are validated as ISO dates before a run is stored, on both endpoints. *(Extended during implementation to the web form's submit, which is where an unvalidated date enters — see Decisions.)*
- The `state` dimension's values are escaped, closing a live SQL injection.

### The Portal duplicate guard

- Duplicating an Athena run is free. Duplicating a Portal run requires `force: true`; without it the response is a 409 with its own code naming the run and pointing at re-reading it.
- The refusal's body keys are exactly `error`, `message` and `run_id`, asserted by a test, because cc-data forwards a coded error's context verbatim into the CLI envelope and the MCP result.
- The message points at re-reading the run rather than at any client's flag. REPORT-94 carries the client-side half of the same advice.
- Adding the code must not change what `ErrorHelpers.code_for_status/1` returns for any existing status.

### An Athena run created over the API actually runs

- A newly created Athena run, from either endpoint, has its query started without a second request, as a supervised task rather than inside the request.
- The response may therefore carry a null `athena_query_state`.
- A duplicate inserts a new row with `athena_query_id` and `athena_query_state` unset, asserted by a test.
- Duplicating a run whose stored `report_filter` is `nil` treats it as the empty filter rather than raising. *(Such a duplicate is then refused by the yields-a-query rule; the requirement is that it does not raise.)*

### Web UI

- The runs table and the run detail page gain a duplicate action that creates a new run and takes the user to it. *(Landed on three surfaces: the report form renders the same runs table as Previous Runs — see Decisions.)*
- The action appears on `/reports/all-runs` as well as `/reports/runs`; the duplicate is owned by the clicking user and its filter passes through `HideNames.enforce/2`.
- The UI duplicates Portal runs freely; the guard is a server concern.

### cc-data client, CLI and MCP

- Typed create and duplicate methods reusing `postJSON` and `AsCLIError`.
- A failure the server never answered is reported as possibly-created rather than retried, pointing at `cc-data reports list`.
- `cc-data reports create` and `cc-data reports duplicate`, plus the matching MCP tools, with catalog entries so REPORT-104's drift guard stays green.
- The filter is expressed as the JSON object the API emits on a run, `--report-filter '{"cohort":[1,2]}'`, with `--report-filter-file`; the same expression is accepted on `reports filter-options`.
- Fake-server tests pinned to live wire captures of both endpoints and the guard.

## Technical Notes

- **A cloned Athena run must not inherit `athena_query_id`.** A clone built by copying the source struct would carry the query id, `start_query/1` would decline to run, and `refresh_query_state/1` would report the source's finished result. The clone copies `report_slug` and `report_filter` only.
- **`AthenaRunOps` reads `report_run.user`, not `user_id`**, and the portal-server field on that struct decides which portal database the query builds against, so anything starting a query after create must load the association.
- **An Athena kickoff is a portal query and an S3 upload, not an API call**: `start_query/1` runs the full portal learner query and uploads the learner file before Athena is contacted. That is why the kickoff is a supervised task.
- **The kickoff needs no admission control.** `PortalDbs.get_or_start_pool/1` caps concurrent portal work at five connections per server whatever the task count, excess checkouts fail fast, and `ensure_current/1` releases its claim so the next read retries. The synchronous version of the same work already ships on `GET /reports/:id` and `/download`.
- **The `state` injection was reachable, not theoretical**: `state: ["CA') OR 1=1 -- "]` returned every state in the fixture rather than none.
- **The dates were a second injection**, arriving with this story: `apply_start_date/3` interpolates its argument directly, and nothing between the request body and that interpolation inspected the value.
- **`report_filter_values` can legitimately be empty** (a log report filtered only by `app` and a date range), so "never store an empty one" is not enforceable; the old function returned `%{}` for that and for a portal failure alike.
- **Adding an error code was not additive**: `@codes_by_status` was an inversion of `@statuses`, so a second 409 code silently took the status over.
- **A stored filter changes type across a database round trip**: atoms in, strings out. `filters` is therefore never a source of which dimensions a filter carries; the struct fields are.
- **The runs table is shared**, so a duplicate action added to the component appears on every surface that renders it.
- **The partition warning is a LiveView interaction, not a filter property**; an API create has no confirm step.
- **Audit**: there is no run-created event on any path, including the web form, so creating runs over the API leaves the same trace: the run row itself.

## Out of Scope

- A rerun or refresh endpoint, for the immutability reasons above.
- Deleting runs over the API, and editing an existing run's filter in place.
- A one-shot create-and-pull convenience command in cc-data.
- The skill and MCP guidance prose teaching the create-and-pull workflow (REPORT-95). This story adds only the catalog entries the drift guard requires.
- Portal report consumption in cc-data (REPORT-94), including the run-type column on `reports list`.

## Not Yet Implemented

- **How labels are produced and stored at all** — filed as REPORT-126, blocked by this story. `report_filter_values` remains a display cache written at creation, so labels still go stale and pre-existing rows stay unscoped. This story's scoped lookup stands on its own regardless, because answering "what is cohort 7 called" for an id the caller cannot see is the same disclosure at write time or render time.
- **The partition warning on the API** — decided against rather than deferred (see Decisions), so an over-limit API create fails at Athena with REPORT-106's guidance rather than warning first.
- **Residual: a super-admin creating an Athena run with only `app` and no dates** passes the input rule and fails at kickoff. Accepted: the run's state and cc-data's oscillation detector both report it.
- **Residual: the web form discards every derived label when any one id fails to resolve**, so such a run's filters display blank. Reachable only through a mid-session project-membership change or a crafted event, since the form's option lists are scoped by the same module. Left as is; label storage is REPORT-126's subject.
- **Residual: a write the server never answered exits 1 (`INTERNAL`) rather than 6 (`TRANSIENT`)** in cc-data. Decided rather than deferred (see Decisions).

## Decisions

### Does create start the Athena query, or leave it to the first read?
**Context**: `ensure_current/1` already self-starts a run on `GET /reports/:id`, so both behaviors produce a working run.
**Options considered**: A) insert only, first read starts it; B) call `ensure_current/1` on create; C) call `start_query/1` directly.
**Decision**: B, as a supervised task. `ensure_current/1` claims the run atomically and releases the claim on failure, which is what stops a concurrent `GET` starting the same query twice; `start_query/1` would duplicate that. Asynchronous because the kickoff runs the portal learner query and an S3 upload first, so doing it in the request would time out an HTTP create whose run was fine — the one failure a client cannot disambiguate.

### What does the server store in `report_filter.filters` for a created run?
**Context**: the field drives how a run's filters display, and appeared to drive which dimension `filter-options` treats as primary.
**Options considered**: A) derive server-side, ignore any client value; B) accept it when present; C) store it empty.
**Decision**: A. The cascade half of the concern does not exist — `FilterOptions.prepare/3` replaces the list wholesale — so the only consumer is the UI's display, which needs no client input. Stored in reverse declaration order because the runs table reverses it again to render.

### What happens when label derivation fails or has nothing to derive?
**Context**: `get_filter_values/2` returned `%{}` both for a filter with no id dimensions and for a failed portal query.
**Options considered**: A) return a tagged tuple and fail the create only on a real failure; B) keep `%{}` and drop the never-empty rule; C) reject a create whose derived values are empty.
**Decision**: A. C would reject app-only and date-only log filters the web form accepts; B leaves a run silently missing every label when the portal is down. The empty-statement case is recognized before the query, and the web form keeps its lenient behavior explicitly.

### Which HTTP status does the Portal-duplicate guard use?
**Context**: a new code cannot reuse 409 without changing what `code_for_status/1` returns for raised exceptions.
**Options considered**: A) 422 `UNPROCESSABLE`, adding no code; B) a new code on an unused status; C) 409 with the status-to-code direction pinned explicitly.
**Decision**: C. 409 is the honest status for "well formed but conflicts with this run's nature, retry with `force`"; A gives up the coded branch and B picks a status for its availability rather than its meaning. `@codes_by_status` becomes a declared table naming one primary code per status, with a test in both directions.

### Does the API create surface the partition warning?
**Context**: a log run over Athena's partition ceiling fails at query time; the form warns before submitting and lets the user proceed.
**Options considered**: A) nothing, let REPORT-106's guidance explain the failure; B) compute the estimate and return it as an advisory field; C) refuse over-limit creates without an acknowledgement flag.
**Decision**: A. A prediction drifts and an error report cannot — `@log_apps` gained `CODAPV3` mid-story, changing every unconstrained estimate by about seven per cent. B cannot be made shape-uniform without a portal count query per run per list page. Depends on REPORT-127 landing so the failure explains itself.

### Where does the duplicate button appear, and whose run does it create?
**Context**: the runs table renders both `/reports/runs` and `/reports/all-runs`, where rows belong to other users.
**Options considered**: A) my-runs only; B) both surfaces, always owned by the clicker; C) both for admins, my-runs otherwise.
**Decision**: B, which subsumes C. `/reports/all-runs` is already portal-admin only, so the cross-user case only arises for a user who may see every run anyway, and the duplicate goes through the same `HideNames.enforce/2` as every other path.

### The duplicate action landed on a third surface
**Context**: the report form renders the same runs table as **Previous Runs**, the caller's own runs of the report being authored, so the shared component put the button there too. Without a handler the click raised a `FunctionClauseError` and killed the form.
**Options considered**: A) keep it, with the form's LiveView delegating to the shared module; B) suppress it with an opt-in attr on the component; C) keep it but flash instead of redirecting, only on the form.
**Decision**: A. The form is the one surface where the source run and the report about to be run are guaranteed to be the same, and the redirect to the new run is the navigation that page already produces on submit. C would make one button behave two ways by page. The cost: a click there leaves a half-assembled filter behind.

### What is the terminal syntax for expressing a report filter?
**Context**: `reports create` cannot work without one, and it is then reused on `filter-options`.
**Options considered**: A) a JSON string plus `--report-filter-file`; B) repeatable typed flags; C) both.
**Decision**: A. It is byte-identical to the wire shape the API emits, so `reports list --json`, edit, `reports create` round-trips with no translation layer. B is a second syntax to keep in agreement with the first.

### Is there a cap on how many ids a filter dimension may carry?
**Context**: ids are interpolated into portal SQL and the list length was unbounded.
**Options considered**: A) no cap; B) a per-dimension cap; C) a whole-filter cap.
**Decision**: A. Athena's limits are driven by the learner count a filter expands to, not by the id count — 15 assignment ids can expand to thousands of learners while 500 school ids may expand to none — so a cap would not prevent the failure it appears to.

### `report_filter_values` derivation was not project-scoped, so create would have been a label oracle
**Context**: `get_filter_values/2` issued `WHERE id IN (...)` with no project predicate, so a caller who could browse nothing could still read back cohort 7's name.
**Decision**: derive the labels through the same scoping the options endpoint uses, and refuse an id the caller's option set does not contain. One query answers both questions, it honors REPORT-92's contract, and it turns a silent zero-row report into an actionable error. The three taxonomies stay unscoped.

### The refusal was defined on labels, which is the structure REPORT-126 may remove
**Context**: refusing "any id that came back without a label" puts the authorization predicate on a display cache, and it breaks on `state`, whose offered `(Unknown)` resolves nothing under a plain `state IN (...)`.
**Decision**: the refusal is membership in the caller's option set, and `DimensionScope` carries each dimension's id expression alongside its base, joins and scope predicate, so discovery and resolution cannot disagree about what an id is. Rejected the narrower fix of exempting the taxonomies: it works only while `state` is the only synthesized id.

### The `state` dimension was a live SQL injection
**Decision**: fixed here rather than filed, by routing the branch through `ReportUtils.mysql_string_list_to_in/1`, which every other string-dimension interpolation already used.

### Duplicate was not covered by the "created run actually runs" requirement
**Decision**: both endpoints go through the same post-insert path; a duplicate of an Athena run is the primary way a fresh snapshot is taken and needs the same kickoff.

### Duplicating a run with a `nil` stored filter would have raised
**Decision**: duplicate coalesces a nil stored filter to `%ReportFilter{}`, matching what `CustomComponents` and `ReportController.build_query/2` already do.

### `FilterParams.parse/1` could be widened rather than copied
**Context**: the spec left "widen or add a second parser" undecided, which invites the divergence that follows.
**Decision**: widen. `app` is not a filter dimension in `ReportFilterQuery` at all and `hide_names` is overridden by `FilterOptions.prepare/3` regardless, so neither new field can change what filter-options returns.

### An empty value list widens a run instead of narrowing it, and only the API gets the rule
**Context**: `[]` short-circuits a discovery request to zero options but is not a filter at all to the report queries, so a caller who narrows to nothing in discovery and passes the result to create gets a run over their whole project scope.
**Decision**: create refuses an empty list; the web form keeps its behavior, because its mistake is a live UI state a user is still editing; duplicate normalizes `[]` to unset, which provably cannot move a row and keeps a form-produced run duplicable. Rejected changing `have_filter?/1` globally: 26 call sites, and it would change what an already-submitted form filter does.

### A create could store a run whose query can never be built
**Context**: `ReportQuery.update_query/2` returns "Cannot run query with no filters" for a filter contributing no join and no where, and label derivation for such a filter succeeds.
**Options considered**: a per-report `validate_filter` callback, defaulted or required.
**Decision**: check exactly where it is free and by input rule where it is not, branching on `report.type`. All seven Portal reports' `get_query` are pure builders; the Athena ones reach the same check only through a portal query and an S3 upload. A defaulted callback is a production timeout waiting for the next expensive report; a required one is boilerplate on eleven modules for one answer.

### The date validation reached create only, while duplicate also stores a run
**Decision**: one definition, `FilterValidation.check_dates/1`, applied by the parser, by the context function (so duplicate is covered) and — decided during implementation — by the web form's submit. The form is where an unvalidated date enters: `handle_event("form_updated", ...)` assigns whatever the event carries, so the date control constrains a browser and not a crafted event. A duplicate whose stored dates do not parse is refused rather than repaired, since dropping a date bound returns more data than the source run did.

### A permission-lookup failure must not raise through the context function
**Context**: `FilterOptions.allowed_projects/1` raises rather than answering "no projects", which is right for a query builder, but `create_api_report_run/3` documents three tagged failures and the runs UI's duplicate button handles exactly those.
**Decision**: the exception becomes `{:error, :derivation_failed, reason}` — rescued in the context function for the Portal `get_query` path, and converted to an error tuple inside `get_filter_values/2` for the label path, so the web form logs it and creates the run rather than dying mid-submit.

### The Athena kickoff task cannot do Repo work under the test sandbox
**Context**: a task started from `Task.Supervisor` owns none of the test's sandboxed connection, so a hard-wired starter dies inside the task and every assertion about the kickoff passes vacuously.
**Decision**: an injectable `:athena_run_starter`, the seam `SweepServer` already establishes for this problem. Without it, "an Athena create starts the query" is a claim no test can make.

### Two different failures returned the same error shape
**Context**: a client mistake and a portal outage both reached the controller as `{:error, binary}`, so an outage would have rendered as a 400 carrying raw MySQL text.
**Decision**: the context function tags failures by kind — `:invalid`, `:out_of_scope`, `:derivation_failed` — and the controller matches on the tag rather than the payload's shape.

### The error code is added six steps before its caller
**Decision**: intentional. The table rewrite is the risky part and is much easier to review on its own than folded into the endpoint that motivated it.

### `Reports` calling `AthenaRunOps` is a mutual module reference
**Decision**: verified it compiles — runtime references, not compile-time ones; nothing here is a struct or a macro.

### The exit class for a write the server never answered
**Context**: a POST is never retried, so it never becomes a `TransientError`, and a transport failure on `reports create` exits 1 (`INTERNAL`) while the same failure on a read exits 6 (`TRANSIENT`).
**Options considered**: A) leave it; B) map an unanswered write to 6; C) B plus widening the documented meaning of 6.
**Decision**: A. Exit 6 tells a caller retrying is the right move, which for a write that may have reached the server would create a second run, a second portal learner query and a second S3 upload. The unknown outcome is carried by the envelope's `action` field, which `EmitError` already writes to stdout, so a script can branch on it without an exit code meaning two things. Pinned by a test so the tidier-looking 6 cannot be introduced later without the reason surfacing.

### The commands' logic must be reachable without a stored credential
**Context**: everything the two write commands did lived inside `RunE`, which needs a credential, so no test could reach it.
**Decision**: the seam `filterOptionsFlags` already has. Verified by mutation that before it, dropping `--report-filter` from the create body, ignoring `--force`, ignoring `--json` and dropping the possibly-created advice all left the suite green.

### The possibly-created advice belongs to the client, not the CLI
**Context**: it was a `cmd` helper, so the MCP tools — the surface most likely to blind-retry — did not have it.
**Decision**: `api.AsWriteCLIError/2`, called by both CLI commands and both MCP handlers. Only a 4xx suppresses the advice, since a 5xx can come from a proxy in front of the server and a retry budget that ran out says nothing about the attempts before it.

### The create response status was unstated
**Decision**: 201. cc-data accepts any 2xx, so a created-resource status costs the client nothing and distinguishes a create from a read in logs and wire captures.

### A clone must not inherit `athena_query_id`
**Decision**: promoted from a technical note to a requirement with a test, because the failure it prevents is silent — a duplicate that returns the source's frozen result.

### `offers_app_filter?/1` stays on `AthenaFailure`
**Decision**: not moved. `AppDimension.enabled_for_report?/1` already reaches across module boundaries for the same predicate, so following that precedent leaves REPORT-106's module and its test alone. `get_form_options/2` and the form's submit both read it from there, so the flag has one definition.
