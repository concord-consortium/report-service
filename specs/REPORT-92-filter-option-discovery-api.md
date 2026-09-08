# Filter-Option Discovery in the API

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-92

**Repos**: [report-service](https://github.com/concord-consortium/report-service), [cc-data-cli](https://github.com/concord-consortium/cc-data-cli)

**Status**: **Closed**

## Overview

Expose the report form's cascading filter-option lookup through the API, so a caller can discover the cohorts, schools, teachers, assignments, classes, students and permission forms available to them, narrowed by whatever they have already picked, and assemble a valid report filter without the web form. The same endpoint doubles as a standalone "what data do I have?" browser: with no prior selections it returns a dimension's top-level options. Unlike the web form, whose option loading is all-or-nothing per dimension, the API paginates, so a caller can walk a large dimension deterministically.

REPORT-93's create-from-scratch consumes this endpoint; it is also useful on its own, which is why it was built as a general endpoint rather than a private helper for that story.

## Requirements

> **Terminology.** Throughout this spec "the ten dimensions" means the ten **portal-backed**
> dimensions, the ones `%ReportFilter{}` resolves through a portal query. Every count in this
> document (ten, nine of ten, four of the ten) is a measurement over those and stays a measurement
> over those. **Static dimensions**, added below, are a second kind that answers from a fixed
> server-defined vocabulary with no query at all, and are deliberately outside those counts.

### The endpoint

- One generic `POST` endpoint answers for any dimension: given an optional report slug, a partial
  filter, and a target dimension, it returns that dimension's options. `POST` rather than `GET`
  because the request carries student ids and search text that is often a student's name, which must
  not travel in a URL that logs record.
- The report slug is optional. When present, the target dimension must be one the report actually
  accepts, and a dimension the report does not filter on is a client error rather than an empty
  list. How that is checked depends on the kind: a portal dimension must appear in the report's
  `include_filters`; a static dimension answers its own `enabled_for_report?/1`, because static
  dimensions are not declared in `include_filters`. When the slug is absent, any dimension of either
  kind is allowed, so the endpoint works as a standalone data browser.
- The response envelope is the API's established paged shape, `{items, next_page_token}`, plus the
  count fields below, so existing clients page it with their existing machinery.
- The id dimensions and the search text narrow options, and so does `exclude_internal` on the
  `teacher` dimension. `start_date` and `end_date` are accepted and ignored, because a caller
  round-tripping a run's `report_filter` from `GET /reports/:id` will send them; the endpoint
  documents that they do not narrow. `hide_names` is likewise accepted and ignored: the caller's
  role decides it, per Privacy.
- With no prior selections the endpoint returns the dimension's top-level options, so it works
  standalone as a data browser and not only as a step in building a filter.
- Prior selections cascade: options are narrowed by every other dimension the caller supplies,
  in any order.
- Optional text search narrows results, matching the form's behavior.
- Scoping matches the form's per-dimension behavior exactly, and is **not** uniform across the ten
  portal dimensions. The seven person- and assignment-bearing dimensions (`cohort`, `school`, `teacher`,
  `assignment`, `permission_form`, `class`, `student`) are scoped to the caller's allowed projects,
  and an option outside that scope never appears under any combination of parameters; a caller with
  no allowed projects gets an empty list, not an error and not an unscoped list. The three
  taxonomy dimensions (`country`, `state`, `subject_area`) apply no project scoping today and must
  keep applying none, because adding it would change the web form's behavior for the two aggregate
  reports that filter on them. They carry no per-person data.
- `exclude_internal` **does** narrow the `teacher` dimension, adding a `NOT IN` over Concord's own
  teacher ids; it is inert for the other nine. The endpoint honors it there rather than ignoring it,
  and callers are told it costs an extra portal query to resolve those ids. That extra query is
  `ReportUtils.get_internal_teacher_ids/1`, which the form and the report path also call and which
  runs under the module's five-minute default; bounding it would change their behavior on a slow
  portal, since it swallows an error into an empty list and silently makes the flag a no-op. It
  stays as it is. This is a different call from the quoting fix above, which is folded in because it
  is byte-identical for every real value; bounding a query that turns a timeout into a silently
  ignored filter is a behavior change on two shipped surfaces and needs its own decision.
- Each option is `{id, label}`. `id` is a string on the wire for every dimension, because `state`'s
  id is a state code rather than a number; the caller echoes it back unchanged.
- The response carries the total matching count when the caller asks for it, so a caller knows the
  size of what it is paging through, subject to the count bound below. **It is requested by default
  on a first page and not on a later one**, and an explicit request field overrides that in either
  direction, including on a page resumed from a saved token. Measured on 50,000 options, a count
  costs what a page costs (51 ms against 54 ms), because the wrap materializes the whole distinct
  set either way, so returning it on every page of a walk roughly doubles the walk while handing
  back the same number each time. `DrainPages`, the only client that exists, never reads it.

### Static dimensions

A **static dimension** is a fixed, server-defined vocabulary rather than portal data: no query, no
project scoping, no cascading. It exists because not everything in `%ReportFilter{}` is portal-backed,
and the endpoint is the one place a caller assembles a filter, so a field it cannot answer for is a
hole in that story. REPORT-105's `app` is the first, and the design is for the kind rather than for
that one member.

- A static dimension is a module implementing a small behaviour: `options/1`, taking the search text
  and returning `{id, label}` pairs, and `enabled_for_report?/1` answering whether a given report
  accepts it. The search text is a parameter rather than a separate callback because a dimension
  owns how its own vocabulary narrows; what narrowing *means* is one shared predicate, per the
  search requirement below.
- **`enabled_for_report?/1` for `app` delegates to `AthenaFailure.offers_app_filter?/1` rather than
  reading `form_options` itself.** REPORT-106 landed that predicate after this spec was written; two
  readings of the same `:enable_app_filter` key are free to disagree.
- **The wire contract is identical to a portal dimension's.** Same `{id, label}` items with string
  ids, same `{items, next_page_token}` envelope, same limit and cursor mechanics, same ordering by
  `(label, id)` **compared case-insensitively**, because the portal dimensions order under a `_ci`
  collation while Elixir's term order puts every uppercase letter before every lowercase one.
  Measured on the fifteen-entry `app` vocabulary, a naive `Enum.sort_by` disagrees with MySQL in two
  places (`DEVOPS` before `Dataflow`, `GRASP` before `GeniStarDev`), so this is a real divergence on
  the only static dimension that exists, not a theoretical one. Ordering and matching are the two
  halves of what the contract means by a label and are defined together, in one module, for the same
  reason the search predicate is: SQL owns the other copy and cannot share it. A caller cannot tell the two kinds apart, which is the point: the client, the CLI
  and the MCP tool need no branch.
- Text search narrows a static dimension the same way it narrows a portal one: substring,
  case-insensitive, over the label. The portal dimensions get that from SQL `LIKE` under a `_ci`
  collation and no option query searches an id, so a static dimension must not either. **A static
  dimension narrows its own vocabulary** (it may not be a plain pair list) **but does not decide what
  matching means**: the comparison is one shared predicate, so a second implementor cannot make the
  API case-sensitive for one dimension without a test failing.
- The count is always exact and never `:skipped`: a fixed vocabulary is bounded by construction.
- Narrowing dimensions in the request body are **accepted and ignored**, exactly as `start_date` and
  `end_date` already are, because a static vocabulary does not cascade. A caller round-tripping a
  run's filter must not be rejected for sending fields the API handed it.
- Project scoping does not apply and must not silently appear to: a static dimension returns the same
  options to every caller who may use it at all, and access is decided entirely by
  `enabled_for_report?/1`.
- The label is server-owned. Where a raw value is not self-explanatory the module supplies the
  display label, so the web form and every API client render it identically from one source.

**Sequencing.** The static-dimension work depends on REPORT-105 having landed, which supplies the
first implementor and its value list. The ten portal dimensions do not depend on it, so the rest of
this story is unblocked.

### Privacy

**Scope of the rule: student data is protected, teacher data is not** (project owner, 2026-09-07).
`hide_names` exists for the former and the query builder consults it only in the `:student` branch.
A teacher option's label carries an email address for every caller by design, and the endpoint
carries that forward unchanged rather than inventing a protection the product does not have.

- The `student` dimension's label is a real student name unless hide-names is on, and the API admits
  project researchers, who are **not** permitted to see names in the web form. The endpoint must
  enforce the same rule the form enforces: hide-names is forced on for any caller who is not a
  portal admin or project admin, regardless of what the request asks for.
- A caller who is not permitted to see names cannot obtain a student's name from this endpoint by
  any parameter combination, including text search. The search predicate is built from the same
  hide-names branch as the label, so a name-shaped search term matches nothing rather than
  confirming a name.
- This is a regression test, not just an implementation note: a researcher-role request for
  `student` options returns id-shaped labels.

### Pagination

- The caller sets the page size, bounded by a server maximum, and pages with an opaque token. The
  API does not apply the form's 200-option auto-load gate.
- Paging is **keyset**, not offset, and the ordering is total. Ordering by label alone is not
  deterministic when labels repeat, and duplicate labels are common (two schools with the same name,
  two students with the same display name). Probed on MySQL 8.0.39: six rows with four identical
  labels, paged three times at size two ordered by label alone, returned one row twice and omitted
  another entirely. The ordering must carry the id as a tiebreaker.
- Paging a dimension end to end visits every option exactly once, with no duplicates and no
  omissions, including across a page boundary that falls inside a run of identical labels.
- Tokens are opaque to the client and are only ever echoed back. **Within a single walk no token
  recurs**, which the keyset cursor gives for free because it strictly increases. This is not a
  stylistic rule: `DrainPages` keeps a `seen` set and aborts the walk with "server repeated page
  token" rather than loop forever, so a repeat is a client-visible failure. The new `POST` paging
  helper carries the same guard.
- The `ORDER BY` and the keyset comparison use the **same expression with the same type**. A walk
  that orders on one and compares on the other silently skips options rather than failing, so this
  is pinned by a test over a fixture with tied labels and ids whose numeric and lexicographic orders
  disagree.
- **That shared expression is NULL-safe.** A label can be NULL: `CONCAT` returns NULL if any
  argument is, so a teacher with no email, a student with no last name, a class with no class word
  and a permission form missing either name all produce one, and four more dimensions select a
  bare nullable column. A comparison against NULL is NULL, so a cursor whose label is NULL matches
  no row and the walk stops early while the count still reports the full set. The wrap therefore
  coalesces the label once, in its own projection, and the sort key, the keyset predicate, the
  cursor and the `label` on the wire are all that same never-null value. `country` and `state`
  already coalesce inside the builder, which is the evidence that NULL labels occur in practice.
- **Every portal query this endpoint makes is bounded** well under `PortalDbs`' five-minute module
  default: the permission lookup that resolves the caller's allowed projects, the page, and the
  count. The permission lookup is also resolved once per request and passed to both, rather than run
  again for the count. The page and the count in particular are bounded because the wrap materializes the dimension's whole distinct
  option set on each page, and a request a client calls interactively must not hold one of five
  shared connections for minutes. On top of that, the count is bounded in two further layers. A `student` request with no narrowing selections is skipped
  outright and never runs, matching the form's own special case; every other count runs under a
  short per-query timeout well below the portal module's five-minute default, and is reported as
  skipped if it trips.
- **A skipped count says what actually happened, and "timed out" is claimed only when it is true.**
  The driver reports a query that blew its budget, a pool that could not hand out a connection, and
  a database that is down as the same exception type, so the type is not evidence: measured, an
  unreachable database fails in 2.5 seconds under a 5 second budget while reporting the same
  exception a real timeout reports. The distinguishable cases are told apart on what is observable,
  and the three benign outcomes (never run, budget consumed, portal too busy) each carry their own
  reason. Only a broken query is an error.
- A skipped count is unambiguous on the wire: `count` is null, a boolean says it was skipped, and a
  reason string says why. It is never omitted, because an omitted number decodes to zero in the
  client's language and would read as "there are none".
- **The three states are distinguishable without reading the reason string.** A count that was asked
  for and produced is a number with the skipped flag false; one that was asked for and refused is
  null with the flag true and a reason; one that was never asked for is null with the flag false.
  The flag keeps its single meaning, "we would not or could not run it", so a client never has to
  substring-match English to tell "too expensive to count" from "you did not ask".

### Input validation

- Every id in the partial filter is validated as an integer before it reaches the query builder,
  except `state`'s, which are strings and are validated as strings. A non-integer id, and a
  non-string `state` value, are each a client error naming the field, never a crash:
  `escape_single_quote/1` raises `FunctionClauseError` on anything but a binary.
- The page size, the page token and the search text are validated and parameter-bound. The keyset
  predicate in particular compares against a label, and labels contain apostrophes.
- **The search text means the same thing to both kinds of dimension.** A portal dimension
  interpolates it into `LIKE '%…%'`, where `%` and `_` are wildcards; a static dimension compares it
  as a substring, where they are not. Unescaped, one search means two things, and `%` alone matches
  every portal row while matching no static one. It also defeats the count guard: any non-empty
  search counts as narrowing, so `search: "%"` walked past the guard and ran the unnarrowed student
  count it exists to prevent. The endpoint escapes `\`, `%` and `_` before the text reaches the
  builder, using MySQL's default `LIKE` escape character so no `ESCAPE` clause is needed. The web
  form is untouched, since the escaping is applied on the API's path rather than in the shared
  `like_params/2`.
- **`state`'s values are the one thing a caller supplies that reaches SQL as text, and they are
  quoted with a MySQL-safe escape.** `state` narrows `country`, `state` and `subject_area` through
  `string_list_to_single_quoted_in/1`, whose `escape_single_quote/1` doubles `'` and ignores `\`,
  which MySQL treats as an escape character: see the defect below. This story does not parameterize
  the `IN` list, which would mean threading params through the shared builder's `where` list and is
  the form-regression risk the whole design avoids; it makes the quoting correct and pins it with a
  test that a backslash-bearing value cannot break out of its literal.
- Paging parameters are accepted in **both** the JSON body and the query string, and in the body
  `limit` is accepted as a JSON number as well as a string. The existing `Params.parse_limit/1` was
  written for query strings and rejects a numeric `25` with "limit must be an integer", which is the
  natural thing a JSON client sends and a misleading thing to tell it. Extending it must not change
  what the existing GET endpoints accept.
- An unknown report slug, an unknown dimension, a malformed token and a malformed id are each a
  clear client error naming what was wrong.

### Not breaking the form

- The web form's option lookup keeps its option ordering and its results, and is regression tested
  by asserting the generated SQL for all ten dimensions. Its 200-option auto-load gate is not
  regression tested, because this story does not touch `has_few_options?`, `@max_auto_options_length`
  or `get_option_count/4`: the gate reads a count from code the story leaves alone, so a test of it
  would be guarding against nothing this change can do. The paging machinery is added in a wrapper the form never
  calls, so `get_options_sql/1` itself is untouched and the regression risk the ticket flags as
  caveat (d) largely does not arise.
- The one exception is the `permission_form` builder, whose value expression gains an alias so its
  own `ORDER BY` becomes legal (see the defect below). The column *name* is invisible to the form,
  since `get_options/4` destructures each row positionally as `[id, value]`, but **the ordering is
  not**: the dropdown sorted by `ppf.name` and now sorts by the `project: form` label, so two forms
  in different projects can move relative to each other. That is unavoidable rather than incidental.
  Ordering by a column outside the select list is what makes the old statement illegal under
  `ONLY_FULL_GROUP_BY`, and the only legal alternatives are to add `ppf.name` to the select list,
  which changes the positional shape every caller destructures, or to leave the statement illegal.
  The new order is also the one the user can see, since it matches the label the dropdown renders.
  Pinned by a test over two forms whose name order and label order disagree.

### Pre-existing defects this story has to fix

- `get_query_and_params/4` short-circuits on `allowed_project_ids == :none` but not on an **empty
  list**, and `get_allowed_project_ids/1` returns an empty list, not `:none`, for a project admin or
  researcher with no `admin_project_users` rows. The seven scoped builders then render
  `project_id IN ()`, which is `ERROR 1064`, so the requirement above that such a caller gets an
  empty list is not met by the code as it stands. The state is reachable and permanent: the role
  flags are read from an `EXISTS` at login and stored on the `User` row, `Api.AuthPlug`
  authenticates from that row without refreshing it, and API tokens do not expire, so a
  de-provisioned caller keeps the flag while the live lookup returns nothing. `ReportUtils.scope_by_allowed_projects/5`
  already treats `[]` and `:none` alike for exactly this reason, with a comment naming the syntax
  error; `ReportFilterQuery` never inherited the guard, so the web form carries the same latent
  crash. This story adds the missing case beside the existing `:none` check, so an empty list
  yields no options rather than a broken statement. It applies to all ten dimensions, matching how
  `:none` already behaves, rather than being spelled out seven times in the scoped builders.
- `ReportUtils.escape_single_quote/1` doubles single quotes and leaves backslashes alone, so a
  `state` value ending in a backslash escapes the closing quote of its own literal and the next
  value is parsed as SQL. Demonstrated end to end: the real helper turns
  `["x\\", ") OR (name LIKE 0x536563726574) #"]` into `('x\',') OR (name LIKE 0x536563726574) #')`,
  which on 8.0.39 returns the row the filter excluded and drops a following `AND name LIKE …`. The
  correct escape already exists in the repo as `LearnerHideNames.escape_mysql_literal/1`, private to
  one module, with a comment naming this exact hazard. This story promotes it to `ReportUtils` and
  adds a MySQL-specific list helper built on it, used by `get_filter_query/5`.
  **`escape_single_quote/1` itself must not change**: eleven of its fifteen call sites build
  Presto SQL for Athena, and Presto does not treat backslash as an escape, so doubling backslashes
  there would silently corrupt literals. Verified after the fix: the payload returns no rows, while
  `CA`, `O'Fallon` and `C:\x` all still match.
- **Every MySQL caller of the list helper switches, not just this endpoint's.** The worse exposure is
  not the option lookup: `detailed_metrics_by_school_report.ex` and
  `summary_metrics_by_subject_area_report.ex` interpolate the same caller-supplied `state` list into
  the report's own `WHERE`, and those are the two reports whose `include_filters` is
  `[:country, :state, :subject_area]`, so the injected predicate shapes rows the user then downloads
  as CSV. `post_processing/job.ex` uses the helper for secure keys. Switching all three is free:
  driven through both helpers, `["CA","NY"]`, `["(Unknown)"]`, `["O'Fallon"]`, `["Puerto Rico"]`,
  `[]` and secure-key-shaped strings produce byte-identical SQL, and only backslash-bearing values
  differ, which is exactly the case that is broken today. There is no behavior to regress, so
  leaving the more serious path for later would be a smaller diff bought with a live vulnerability.
- `get_filter_query(:permission_form, …)` builds `SELECT DISTINCT ppf.id, CONCAT(ap.name, ': ',
  ppf.name) … ORDER BY ppf.name`, ordering by a column that is not in the select list. Under
  MySQL's `ONLY_FULL_GROUP_BY` that is `ERROR 3065`, verified on MySQL 8.0.39; it succeeds only with
  that mode off, which is therefore an undocumented requirement the portal databases currently
  satisfy. The endpoint must not inherit a latent dependency on a server sql_mode, so this story
  aliases the value and orders by the alias, matching what the other nine dimensions already do.
- A regression test pins the corrected `permission_form` SQL, and the fix is called out as also
  correcting the web form on any portal whose sql_mode is ever tightened.

### cc-data-cli

- A client method for the endpoint, a CLI command to browse filter options, and an MCP tool, so an
  LLM can assemble a filter interactively.
- The client pages the endpoint with a `POST` paging helper carrying the same repeated-token loop
  guard, rather than a second paging model. The existing helpers are `GET`-only, so the new helper
  is the one piece the `POST` shape costs.
- **The client's envelope carries the count fields.** `Page[T]` is `{items, next_page_token}` and
  `encoding/json` drops what it does not name, so reusing it would silently discard `count`,
  `count_skipped` and `count_skipped_reason` while the MCP tool still advertises `include_count` as
  the field to set when a user asks how many there are. The endpoint gets a purpose-built envelope,
  as `FetchBulkPage`/`BulkPage` already does for `total_endpoints`, so `Page[T]` keeps meaning one
  thing and the count reaches the surface that wants it.
- The CLI surface renders `{id, label}` pairs in both a human table and `--json`.
- The MCP tool is registered with a read-only annotation, and its name and description are added to
  the shared guidance source and its catalog in the same change, so REPORT-104's drift guard passes.
- Fake-server tests pinned to a wire capture of the endpoint, matching the existing client test
  pattern.

### Testing

- Cascading: an option that a narrowing selection should exclude is asserted absent, not merely that
  the list got shorter.
- Scoping: a request as a user whose allowed projects exclude an option asserts that specific option
  is absent, and the same request as a super-admin asserts it is present, so the test cannot pass
  because the fixture was empty.
- Pagination: the end-to-end walk is asserted against the full expected set, on a fixture that
  contains a run of duplicate labels spanning a page boundary. A test that pages a fixture with
  unique labels cannot catch the tie-ordering bug.
- The `nil` versus `[]` distinction for a narrowing dimension is asserted in both directions.
### Fixed beyond the original scope

Found while sweeping all ninety dimension/secondary-filter pairs against the test fixture, and fixed in this story because the endpoint exposes every pair while the form reaches only some. All three predate the story.

- `assignment` narrowed by `cohort` emitted the `aci_cohort` alias twice for a **scoped** caller, because the scoping join and the secondary join were the same join written twice differing only by `LEFT`, so `Enum.uniq/1` could not collapse them. It succeeded as `:all`, which is why it went unreported, and it meant a project admin or researcher could not use that combination in the web form at all.
- `country` narrowed by `teacher`, and by `subject_area`, reused a membership join keyed on `portal_schools`, which is right for the `school` and `state` primaries but not for `country`, which reaches schools as `ps_country`. The `subject_area` chain also hung two joins off unjoined aliases.
- `resolve_join_patterns/1` did not recurse, so a join pattern naming another pattern emitted the atom itself into the SQL. Fixing it is what made one shared definition of the assignment/cohort join possible.

Of the 180 statements the ten dimensions generate against every secondary filter under both `:all` and a scoped caller, exactly six changed and the other 174 are byte-identical, so the form is provably untouched elsewhere.

## Technical Notes

The probe records and stage-by-stage verification that produced these are in the source spec and in the commit history. What survives for the next engineer:

- **Paging wraps the existing builder rather than changing it.** A keyset predicate cannot reference a select alias, and four of the ten dimensions select their label as one, so the page and the count wrap `get_options_sql/1` in a subquery. The wrap must name its own columns (`AS o (opt_id, opt_label)`): an unaliased value expression's derived column is named with the expression text itself.
- **The wrap is materialized.** `EXPLAIN FORMAT=TREE` shows the derived table materialized with the predicate not pushed into it, so every page builds and sorts the dimension's whole distinct option set. Correctness is unaffected and memory is bounded by the `LIMIT`, but a full walk is quadratic rather than the O(log N)-per-page a keyset walk usually buys. Bounded in practice by the per-query timeout, the page-size cap and text search.
- **`(label, id)` is a total order and label alone is not.** Ordering by label alone over six rows with four identical labels returned one row twice and omitted another. The id tiebreaker is load-bearing, and the `ORDER BY` and the keyset comparison must use the same expression with the same type or the walk silently skips rows.
- **A label can be NULL**, since `CONCAT` returns NULL if any argument is. The wrap coalesces once in its own projection so the sort key, the predicate, the cursor and the wire label are one never-null value. `country` and `state` already coalesced inside the builder, which is the evidence that NULL labels occur.
- **The `student` label is PII and the API's role gate is wider than the form's.** `Auth.can_access_reports?/1` admits project researchers, who cannot see names in the web form, so the endpoint takes `hide_names` from the caller's role rather than the request. This is the first API surface that builds a filter from caller-supplied input, so the first that has to enforce the rule itself.
- **Conventions the endpoint follows**: the `{items, next_page_token}` envelope that `GET /api/v1/reports` returns and cc-data is typed against; `Api.V1.Params` as the only definition of the paging default and maximum; `PortalDbs.query/4`'s per-call options for bounding the timeout; and the shared portal pool's `pool_size: 5`, which is why an unbounded count is a starvation risk rather than merely a slow one.

## Out of Scope

- Creating or duplicating report runs (REPORT-93). This story supplies the discovery half; the
  create endpoint consumes it.
- Changing the web form's behavior, including its 200-option auto-load gate and its student-count
  skip. Those stay exactly as they are.
- Inventing new filter dimensions. The endpoint serves the dimensions `%ReportFilter{}` already has:
  the ten portal-backed ones and any static ones registered with it (REPORT-105's `app` is the
  first). Adding a dimension to `%ReportFilter{}` is another story's work; exposing one that exists
  is this endpoint's job.
- Resolving a filter to labels for storage. `report_filter_values` is written at run creation and is
  REPORT-93's concern.
- Caching option results. Every request is a live portal query, as the form's are.
## Not Yet Implemented

- **A per-query timeout on `ReportUtils.get_internal_teacher_ids/1`**: the extra portal query that `exclude_internal` costs still runs under the module's five-minute default. It swallows an error into an empty list, so bounding it would silently turn a slow portal into a filter that stops excluding anyone, on two already-shipped surfaces. Needs its own decision rather than riding along here.
- **Pushing the keyset predicate into the shared builder**: the escape hatch if profiling ever shows the materialized wrap matters. Deliberately not done: it would trade a measured cost for an unmeasured regression risk to the web form, which is the risk the wrap design exists to avoid.
- **A 503 rather than a 500 for `AllowedProjectsLookupError`**: `SERVICE_UNAVAILABLE` would suit a transient upstream failure better, and this API already uses it that way for the download limiter, but the exception is shared with REPORT-76's bulk path, so giving it a `Plug.Exception` status would change a shipped contract for a different endpoint. Its own ticket.
- **A `--report-filter` flag on `cc-data reports filter-options`**: the MCP tool takes a `report_filter` and can narrow one dimension by the selections already made, but the CLI exposes only `--search`, `--report-slug`, `--limit` and `--all`, so from the terminal a dimension can only be browsed at its top level. This matched the story's scope, whose client requirement is interactive assembly by an LLM. Recorded on REPORT-93, which has to give the terminal a way to express a filter for `reports create` regardless, and should reuse the same expression here.

## Decisions

### What is the endpoint's method and path?

**Context**: The wire shape had to be fixed before either repo could start, and a filter carries student ids and search text that is often a student's name.

**Options considered**:
- A) `POST /api/v1/reports/filter-options`, filter and paging in the body
- B) `POST` for the filter with `limit`/`page_token` in the query string
- C) `GET /api/v1/reports/:slug/filter-options/:dimension` with repeated query params

**Decision**: **A**. The deciding argument is privacy, not ergonomics: on a `GET` the student ids and the name-shaped search text land in access logs, proxy logs and browser history, for a surface whose whole point is that a researcher must not be able to read student names out of it. C also builds multi-kilobyte URLs for a filter narrowing on a few hundred students, and fails at a layer nobody in this system owns. B was tempting, but `Plug.Parsers` merges query-string and body params into one `conn.params`, so A gets B's flexibility for free and there is no reason to mandate the split.

---

### What is the response envelope?

**Context**: cc-data already pages the reports index, and a second paging model would need a parallel client path.

**Options considered**:
- A) `{items, next_page_token, count}`
- B) The ticket's `{options, count, next}`
- C) `{items, next_page_token}` with `count` as an object

**Decision**: **A**. `{items, next_page_token}` is what `GET /api/v1/reports` already returns and what cc-data's `api.Page[T]`, `FetchPage` and `DrainPages` are typed against, including the repeated-token loop guard a hand-rolled path would have to reimplement. Adding one field to a known envelope is cheaper than a new one differing on all three names, and "options" carries nothing the endpoint's own name does not.

---

### How does the response signal that the count was skipped?

**Context**: The count cannot always be produced, and the one client that exists is written in Go.

**Options considered**:
- A) `count: null` plus `count_skipped: true` and a reason
- B) Omit `count` when skipped
- C) Always count, with a cap and a `count_capped` flag

**Decision**: **A**. B is the trap it looks like it avoids: an omitted JSON number decodes to zero in Go, so the only consumer would read "we did not count" as "there are none", with no error anywhere. C is rejected for the case that motivates the question: the unnarrowed student count is not slow, it is unbounded, and capping it still runs it.

---

### Which cases skip or bound the count, and is the rule per-dimension or general?

**Context**: The form skips counting students on the first filter, in as many words, because there are so many of them.

**Options considered**:
- A) Mirror the form: skip only the unnarrowed `student` case
- B) Skip whenever there is no narrowing and no search text, for any dimension
- C) Always attempt with a short timeout and report skipped on timeout

**Decision**: **A as the rule, with C's timeout as a safety net.** Checked rather than assumed: an unnarrowed count for cohorts, schools and assignments is a count over a table's own primary key, at a scale the form already counts happily. `student` is the outlier, joining `portal_students` to `users`. So B would refuse a cheap and useful count for nine dimensions to avoid one expensive one. C alone was tempting because it is empirical, but a timed-out count has still held one of the shared pool's five connections for the whole timeout, which is the starvation REPORT-88 needed a limiter for.

---

### What does the page token encode, and what happens when the data changes mid-walk?

**Context**: The existing `parse_page_token/1` decodes to a single positive integer, which cannot carry a `(label, id)` keyset.

**Options considered**:
- A) Base64 of a JSON `{label, id}`, opaque by convention
- B) The same, signed
- C) Encode only the id and re-derive the label server-side

**Decision**: **A**. Both worries behind B and C dissolve on inspection. Tampering gains nothing: the token supplies only a position in an ordering, while the dimension, the narrowing filter and the project scoping are all rebuilt from the request and the caller's role on every page, so a forged token can at worst start the caller at an odd place in their own already-scoped result. The token discloses nothing new either: its label is the last row of the page the server just returned to that same caller. C additionally does not work for `state`, whose id *is* its label. Mid-walk data changes are inherent to keyset paging and are the reason it is preferred: a row inserted before the cursor is missed and one deleted is skipped, but no page is ever misaligned, which is the failure offset paging has.

---

### Is the `report_slug` required, and what does it buy?

**Context**: The ticket asks for the endpoint to work "not only for filter building".

**Options considered**:
- A) Required, with a general-purpose slug for standalone browsing
- B) Optional: validate against `include_filters` when present, allow any dimension when absent
- C) Required, plus a separate endpoint listing each report's filter dimensions

**Decision**: **B**. A satisfies the standalone case only by inventing a report that exists to be named in requests that are not about a report, a fiction the API would then have to keep alive. B keeps the check where it is worth having, since a caller assembling a filter for `school-metrics` and asking for `student` options has made a real mistake, and drops it where it is meaningless. C's dimension-listing endpoint is genuinely useful but is discovery of *reports*, and belongs with the create story that needs it.

---

### Do `start_date`, `end_date` and `exclude_internal` participate?

**Context**: `report_filter_json/1` emits all of them on every run, so the most natural client workflow sends them back.

**Options considered**:
- A) Accept and ignore, matching the form
- B) Reject as unknown fields
- C) Accept and make them narrow

**Decision**: **A for the dates, with one correction found in review: `exclude_internal` is not inert.** It destructures into the `teacher` builder and adds a `NOT IN` over Concord's own teacher ids, so it is honored rather than documented away. B is disqualified by the API's own output: a caller taking a run's filter, adjusting it and asking what else is available would be rejected for carrying fields the API just handed it. C is the honest-looking option and the one to revisit if a user asks, but making dates narrow is new work inside the shared per-dimension builders, which is exactly the form-regression risk the wrap design avoids. `hide_names` is ignored for the same round-trip reason and then decided by role.

---

### Does the endpoint need its own concurrency or timeout bound?

**Context**: REPORT-88 added a concurrency cap for streaming downloads because the portal pool is shared and small.

**Options considered**:
- A) A per-query timeout well under the module default, no concurrency cap
- B) A timeout plus a concurrency cap mirroring the download limiter
- C) Neither

**Decision**: **A**. The download limiter exists because a streaming download holds one of five shared connections for the entire transfer, which can be minutes; an option query holds one for a single indexed lookup and returns. Once the counts are bounded there is no shape left resembling what the limiter was built for, and a second limiter would add a `503` failure mode to a lookup a client is expected to call repeatedly and interactively. C is rejected because the module default is five minutes, which is not a bound for a request a human is waiting on.

---

### "Every response is scoped to the caller's allowed projects" is false for three dimensions

**Context**: The requirement was written as an absolute across all ten dimensions.

**Decision**: Verified false and corrected. `get_filter_query/5` takes `allowed_project_ids` as an underscore-prefixed, unused parameter for `:country`, `:state` and `:subject_area`. There is no leak, which is why this is a wording defect rather than a vulnerability: the three are global taxonomies carrying no per-person data. The harm is to the implementer, who would go looking for the missing scoping and add it, and those three are exactly the dimensions the two aggregate reports filter on, so adding it would silently change the web form for them. The requirement now states scoping per-dimension and says explicitly that the three must keep applying none.

---

### The shipped `permission_form` options query errors under `ONLY_FULL_GROUP_BY`

**Context**: Found while probing the subquery wrap against each dimension's real shape rather than a simplified one.

**Decision**: `get_filter_query(:permission_form, …)` set an unaliased value with `order_by: "ppf.name"`, ordering by a column outside its select list, which returns `ERROR 3065` under the default sql_mode and succeeds only with `ONLY_FULL_GROUP_BY` removed. Permission-form filter options therefore work today only because the portal databases run without that mode, an undocumented dependency nobody had written down. It is exactly one of the ten dimensions. This story aliases the value and orders by the alias, which is invisible to the form because `get_options/4` destructures each row positionally as `[id, value]`.

---

### The subquery wrap needs an explicit derived-table column alias list

**Context**: The first sketch assumed the derived table inherits usable column names.

**Decision**: It does not for an unaliased expression: `SHOW COLUMNS` reports a column literally named `CONCAT(ap2.name, ': ', pf.name)`. The wrap names its own columns, which also makes the outer predicate independent of which dimension is being paged.

---

### The wrap is materialized, so paging is not the cheap operation the note implied

**Context**: The spec presented the wrap as a free way to get keyset paging without touching the builders.

**Decision**: Correctness holds and memory stays bounded by the `LIMIT`, but the derived table is materialized and the predicate is not pushed into it, so a full walk of a large dimension is quadratic rather than O(log N) per page. The spec should not claim a cost it does not have. Recorded with its mitigations, and the escape hatch named as a deliberate not-now rather than an oversight.

---

### Does the `teacher` dimension's email label need the same protection as `student`?

**Context**: `get_filter_query(:teacher, …)` selects the teacher's email into the label unconditionally, and `:student` is the only branch in the whole builder that consults `hide_names`.

**Options considered**:
- A) Accept it; the endpoint matches the form's semantics exactly
- B) Extend hide-names to the teacher label in the endpoint only
- C) Extend hide-names to the teacher label everywhere, form included

**Decision**: **A**, and not a close call once two things are checked. The endpoint exposes nothing the existing API does not already serve: `report_filter_values` is returned in the report JSON for every run a caller can read, and any run that filtered on teacher already hands a researcher those addresses behind the same role gate. And the form does not cap enumeration the way an earlier draft assumed: `has_few_options?/5`'s count check only ever runs for the **first** filter, so a researcher who picks any first filter and then adds teacher already receives every teacher label their projects allow. The project owner confirmed on 2026-09-07 that teacher emails are not protected data and only student data is, which is what `hide_names` is for. B and C both fail on that policy before they fail on anything else.

---

### A failed permission lookup raises from inside the query builder

**Context**: `get_allowed_project_ids/1` returns `:all`, `:none`, a list, **or** `{:error, reason}` when the portal permission query itself fails.

**Decision**: The tuple reaches `list_to_in/1`, which calls `Enum.map` on it, producing `Protocol.UndefinedError` from deep inside the query builder, saying nothing about what actually failed. The codebase already has a convention: `ReportUtils.scope_by_allowed_projects/5` raises `AllowedProjectsLookupError` on the same tuple, with a comment recording why swallowing it into a zero-row result is wrong. `ReportFilterQuery` has its own scoping branches and never calls that function, so the mechanism is not inherited, but the convention applies. The wire result is identical to a tagged tuple because `ErrorJSON` renders any raised exception in the contract shape for `/api/` paths, so one convention beats two and each caller loses an error branch instead of gaining one.

---

### The dimension reached `String.to_atom/1` territory with no allowlist

**Context**: The plan said only that an unknown dimension is a client error, without saying how the caller's string becomes an atom.

**Decision**: Atoms are never garbage collected, so converting caller-supplied strings on an endpoint a client calls repeatedly is an exhaustion vector. It compounds with `prepare/3`, which does `Map.put(dimension, nil)` on a struct: an unrecognized key is silently *added* rather than rejected, and the corrupted filter then flows into the query builder. Resolved by having both registries hand back the atom they already hold, so no caller-supplied string is ever converted, and by generating the error message from the same lists so it cannot drift from what is accepted. `ReportFilter`'s list is made public rather than copied, and the SQL regression test iterates it, so a dimension the struct accepts but the builder cannot serve fails in the suite rather than at runtime.

---

### The plan's tests depend on a fixture no step in it builds

**Context**: Three test bullets asserted on results over "the fixture the earlier steps make available", which none of the steps created.

**Decision**: Half settled, half real. The scheduling hazard went away when REPORT-91 merged, and the `admin_project_users` half of the finding was wrong. The rest stood: loading `portal_fixture.sql` into a scratch database and executing every dimension's real generated SQL showed four dimensions running and six failing, `cohort` on a missing `admin_cohorts.name` column and the other five on tables the fixture had no reason to carry for the report tests it was built for. Extending it became its own step ahead of the core rather than an assumption inside it.

---

### The client cannot reuse `Page[T]`

**Context**: The plan said the `POST` paging helper would reuse the existing generic envelope.

**Decision**: `Page[T]` names only `Items` and `NextPageToken`, and `encoding/json` drops what it does not name, so reusing it would silently discard `count`, `count_skipped` and `count_skipped_reason` while the MCP tool still advertised `include_count` as the field to set when a user asks how many there are. `FetchBulkPage` had already set the precedent with a purpose-built `BulkPage` carrying `total_endpoints`. The endpoint gets its own envelope, so `Page[T]` keeps meaning one thing and the count reaches the surface that wants it. `Count` is a pointer so the wire's explicit null stays distinguishable from a real zero, which is the whole reason the server never omits the field.

---

### A NULL option label truncates the paged walk

**Context**: Found in the second review round, verified against MySQL 8.0.39.

**Decision**: A comparison against NULL is NULL, so a cursor whose label is NULL matches no row: probed at page size 2 over six class options with two NULL labels, page 1 returned two rows and page 2 returned none, ending a walk that the wrapped `COUNT(*)` said had six. Seven of the ten dimensions can emit a NULL label. Fixed by coalescing once in the wrap's projection so the sort key, the keyset predicate, the cursor and the wire label are the same never-null value, rather than repeating the `COALESCE` in three places that must agree. Two fixture rows carry NULL labels so that a page of one ends on a NULL cursor with another still to visit, which is the only shape that catches an ordering that is not null-safe; a single NULL row always lands on the first page and proves nothing.

---

### A caller with no allowed projects got a syntax error, not an empty list

**Context**: The requirement says such a caller gets an empty list, not an error and not an unscoped list.

**Decision**: `get_query_and_params/4` short-circuited on `:none` but not on an empty list, and `get_allowed_project_ids/1` returns an empty list for a project admin or researcher with no `admin_project_users` rows, so the seven scoped builders rendered `project_id IN ()`, which is `ERROR 1064`. The state is reachable and permanent: role flags are read from an `EXISTS` at login and stored on the `User` row, `Api.AuthPlug` authenticates from that row without refreshing it, and API tokens do not expire. `ReportUtils.scope_by_allowed_projects/5` already pairs `[]` with `:none` for exactly this reason. The missing case goes beside the existing `:none` check, so it applies to all ten dimensions rather than being spelled out seven times.

---

### `state` values reach SQL as text through a bypassable escape

**Context**: The requirement claimed nothing a caller supplies is interpolated into SQL as text.

**Decision**: False for `state`, whose values narrow `country`, `state` and `subject_area` through an escape that doubles `'` and ignores `\`, which MySQL treats as an escape character. Demonstrated end to end: a value ending in a backslash escapes the closing quote of its own literal and the next value is parsed as SQL, returning rows the filter excluded. The correct escape already existed in the repo, private to `LearnerHideNames`, with a comment naming the hazard. It is promoted to `ReportUtils` with a MySQL-specific list helper built on it. `escape_single_quote/1` itself must not change, because eleven of its fifteen call sites build Presto SQL and Presto has no backslash escape. All four MySQL callers switch, not just this endpoint's: the two aggregate reports feed the same caller-supplied list into a report whose rows the user downloads, which is the worse exposure, and the switch is byte-identical for every value without a backslash.

---

### A static dimension sorted differently from a portal one

**Context**: The wire contract's point is that a caller cannot tell the two kinds apart.

**Decision**: Portal dimensions order under a `_ci` collation while Elixir's term order puts every uppercase letter before every lowercase one. Measured on the real fifteen-entry `app` vocabulary, a naive `Enum.sort_by` disagrees with MySQL in two places. Ordering and matching are the two halves of what the contract means by a label, so they are defined together in one module, for the same reason the search predicate already was: SQL owns the other copy and cannot share it. The natural thing to write in a new implementor is a case-sensitive comparison that no test would catch, which is what the shared definition prevents.

---

