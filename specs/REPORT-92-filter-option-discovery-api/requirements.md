# Filter-Option Discovery in the API

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-92
**Repo**: https://github.com/concord-consortium/report-service
**Also touches**: https://github.com/concord-consortium/cc-data-cli (client, CLI and MCP surface)
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

> The Jira ticket is the authoritative scope and carries the verified code references for the
> existing surface (`ReportFilterQuery.get_options/4`, `get_option_count/4`, the LiveView gate, the
> four caveats). This spec does not repeat them. It records what the code dive and the MySQL probes
> added, including one security finding the ticket does not raise and one correction that removes
> the ticket's stated regression risk.
>
> The story spans two repos. The API half is the substance and lives here; the cc-data-cli client,
> CLI and MCP surface are specified from here in their own section.

## Overview

Expose the report form's cascading filter-option lookup through the API, so a caller can discover
the cohorts, schools, teachers, assignments, classes, students and permission forms available to
them, narrowed by whatever they have already picked, and assemble a valid report filter without the
web form. The same endpoint doubles as a standalone "what data do I have?" browser: with no prior
selections it returns a dimension's top-level options. Unlike the web form, whose option loading is
all-or-nothing per dimension, the API paginates, so a caller can walk a large dimension
deterministically.

## Project Owner Overview

Everything the API can do today starts from a report run that somebody already created in the web
form. Creating a run from the API (REPORT-93) is impossible without first being able to ask what a
valid filter looks like, and that question has no answer outside the LiveView today. This story
supplies it.

It is also useful on its own, which is why it is worth building as a general endpoint rather than a
private helper for the create story. A researcher, or Claude acting for one, can ask "which classes
am I allowed to see?" or "which assignments has this teacher assigned?" and get a scoped answer,
without having a report in mind. That is a capability the product does not have in any form today.

One thing to know about the shape of the work: the underlying lookup already exists and is well
exercised by the web form. The new parts are pagination (the form never needed it: it either
loads a dimension whole or asks for search text) and getting the privacy rules right for a
surface that answers questions about individual students by name.

## Background

`ReportFilterQuery.get_options/4` and `get_option_count/4` are the form's cascading, project-scoped,
type-ahead lookup, and they are the right primitives to expose. Both take a partial `%ReportFilter{}`
whose **first** entry in `filters` is the dimension being asked about and whose other dimensions
narrow it, plus the caller's `allowed_project_ids`.

Three properties of those primitives shape the endpoint:

- The dimension being asked about is the *primary* filter, taken as `hd(report_filter.filters)`. A
  filter with an empty `filters` list short-circuits to no options, so the endpoint has to construct
  the `%ReportFilter{}` with the target dimension at the head rather than passing the caller's
  partial filter through unchanged. This is the ticket's caveat (a).
- `nil` and `[]` are different for a narrowing dimension. `nil` means "not selected"; `[]` triggers
  `has_empty_dependent_filters?` and short-circuits the whole query to no options. The wire format
  has to preserve that distinction rather than coalescing JSON `null` and `[]`.
- Ids are integers everywhere except `state`, whose id *is* its label (a `COALESCE`d state code
  string). `get_filter_value/2` in the LiveView coerces every other dimension's form values with
  `String.to_integer/1`, and `list_to_in/1` raises on a non-integer, so the endpoint must coerce and
  validate identically before calling.

`get_options/4` returns `{label, id}` tuples with the id stringified, so the `{id, label}` wire shape
is a remap, not a pass-through.

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
  readings of the same `:enable_app_filter` key are free to disagree. See the stage-4 re-run note.
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
  default, the page as well as the count: the wrap materializes the dimension's whole distinct
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
- The one exception is the `permission_form` builder, whose value expression must gain an alias so
  the wrap can name it and so its own `ORDER BY` becomes legal (see the defect below). That edit is
  invisible to the form: `get_options/4` destructures each row positionally as `[id, value]`, so a
  column's name never reaches a caller.

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

## Technical Notes

### Correction: pagination needs almost no change to the shared query builders

The ticket's caveat (d) says "adding limit/offset means modifying the shared
`get_options_sql`/`get_counts_sql` builders the LiveView also calls, so there is regression risk to
the form UI." Probed, and it does not:

Four of the ten dimensions select their label as an **aliased expression** (`fullname` for teacher,
class and student; `state_name`, `country_name`). A keyset predicate cannot reference a select
alias, verified on MySQL 8.0.39:

```
SELECT DISTINCT id, CONCAT(name,'!') AS fullname FROM t WHERE (fullname, id) > ('Dup!', 1) ...
ERROR 1054 (42S22): Unknown column 'fullname' in 'where clause'
```

Wrapping the existing statement in a subquery makes the label visible to the predicate, and works
for both the page and the count. Two details the first pass missed, both probed on MySQL 8.0.39:

- **The wrap needs an explicit column alias list.** An unaliased value expression's derived column
  is named with the expression text itself: `SELECT DISTINCT ppf.id, CONCAT(ap.name, ': ', ppf.name)
  …` produces a column literally called `CONCAT(ap.name, ': ', ppf.name)`. So the wrap names its own
  columns, `… ) AS o (opt_id, opt_label)`, rather than assuming a usable inherited name.
- **`permission_form` has to be fixed first**, because it is the one dimension whose value is
  unaliased and whose `ORDER BY` names a column outside the select list, which is `ERROR 3065` under
  `ONLY_FULL_GROUP_BY`. See the requirement above.

With those, the shape is:

```
SELECT o.opt_id, COALESCE(o.opt_label, '') AS opt_label FROM (<get_options_sql output>) AS o (opt_id, opt_label)
  WHERE (COALESCE(o.opt_label, ''), o.opt_id) > (?, ?)
  ORDER BY COALESCE(o.opt_label, ''), o.opt_id LIMIT ?
SELECT COUNT(*) FROM (<get_options_sql output>) AS o (opt_id, opt_label)
```

Probed green. `get_options_sql/1` itself stays as it is, the LiveView keeps calling it unwrapped,
and the regression surface is one new wrapper the form never calls plus the one-word alias fix to
`permission_form`.

### The wrap is materialized: paging cost is not free

`EXPLAIN FORMAT=TREE` on the wrapped keyset query shows the derived table is **materialized** and
the predicate is **not** pushed into it:

```
-> Limit -> Sort -> Filter: ((o.opt_label,o.opt_id) > (…)) -> Table scan on o
   -> Materialize -> Temporary table with deduplication -> …
```

So every page builds and sorts the dimension's whole distinct option set, and only then applies the
cursor and the limit. Correctness is unaffected and memory is bounded by the `LIMIT`, but a keyset
walk is not the O(log N)-per-page operation the pattern usually buys: a full walk of a large
dimension is quadratic in the number of options. The search text is the same practical narrowing the form
already relies on, and unlike the form this endpoint never has to hand back a dimension whole.
Note that the form's 200-option gate is narrower than it looks: `has_few_options?/5`
checks the count only for the **first** filter, and every later filter loads
its complete option list, so "the form refuses large dimensions" is not a cost floor to measure
against. It is bounded by the required per-query timeout and the page-size cap.

If profiling ever shows it matters, the escape is to push the keyset predicate into the builder
itself behind an option, which is the shared-builder edit the ticket originally anticipated. Doing
it now would trade a measured cost for an unmeasured regression risk, so it is deliberately not
done.

The count via the wrap is `COUNT(*)` over `SELECT DISTINCT id, label`, where `get_counts_sql/1` is
`COUNT(DISTINCT id)`. They differ only if one id can carry two labels, which none of the ten
dimensions can (each label is derived from the id's own row). Using the wrap for the count too keeps
one definition of what a row is.

### Verified: ordering by label alone is not stable enough to page

Six rows, four sharing the label `Dup`, paged at size two on MySQL 8.0.39:

| Page | `ORDER BY name` | `ORDER BY name, id` |
| --- | --- | --- |
| 1 | ids 6, 4 | ids 6, 1 |
| 2 | ids 2, 3 | ids 2, 3 |
| 3 | ids 4, 5 | ids 4, 5 |

Id 4 is returned twice and id 1 never appears. With the id tiebreaker the walk is exact. The keyset
form was probed the same way and visits all six exactly once.

`(label, id)` is a total order for every dimension: the query is `SELECT DISTINCT id, label` and each
label is a function of its own id's row, so no `(label, id)` pair repeats.

### The `student` label is PII and the API's role gate is wider than the form's

`get_filter_query(:student, …)` selects `CONCAT(u.first_name, ' ', u.last_name, ' <', u.id, '>')` as
the label when `hide_names` is false, and `CAST(u.id AS CHAR)` when it is true; the `LIKE` predicate
is built from the same branch. The web form never lets a researcher reach the first branch:
`HideNames.enforce/2` forces `hide_names` on for anyone who is not `portal_is_admin` or
`portal_is_project_admin`, on every path that builds a filter.

The API's gate is `Auth.can_access_reports?/1`, which additionally admits
`portal_is_project_researcher`. So a researcher token, which cannot see a student name anywhere in
the product today, would be able to enumerate student names one page at a time through this endpoint
unless it applies the same enforcement. The endpoint takes its `hide_names` from the caller's role,
not from the request.

This is worth stating precisely because REPORT-88's download path is *not* an equivalent precedent:
there, `hide_names` was already fixed on the stored run at creation time by the LiveView. This
endpoint is the first API surface that builds a filter from caller-supplied input, so it is the
first that has to enforce the rule itself.

### Existing conventions this endpoint should not diverge from

- The index endpoint's paged envelope is `{items, next_page_token}`, and cc-data's client is built
  on it (`api.Page[T]`, `FetchPage`, `DrainPages`, with a repeated-token loop guard). The ticket
  sketches `{options, count, next}`, which differs from the established shape on all three names and
  would need a parallel client path.
- `Params.parse_limit/1` and `Params.parse_page_token/1` are the existing validation helpers.
  `parse_page_token/1` decodes to a single positive integer, which cannot carry a `(label, id)`
  keyset, so this endpoint needs its own token encoding alongside them.
- `PortalDbs.query/4` takes bound params and a per-call options keyword, so the query timeout can be
  bounded for this endpoint without touching the module default of five minutes.
- The portal DB pool is shared and small (`pool_size: 5`); REPORT-88 added a concurrency cap for
  streaming downloads for exactly that reason. Filter-option queries are short, but an unbounded
  student count is not.

### Rehearsal of the wrap across all ten dimensions

Before any implementation spec, `ReportFilterQuery.get_options_sql/1` was driven for all ten
dimensions through a throwaway script, and each real statement was executed against a MySQL 8.0.39
schema stubbed from the tables they reference. The throwaway code was deleted rather than committed.

**The `permission_form` defect is exactly one of ten.** Every other dimension executes cleanly under
the default `ONLY_FULL_GROUP_BY`; `permission_form` alone returns `ERROR 3065`. So the fix is one
builder, and the "nine of ten already alias or select what they order by" claim is now measured
rather than read off the source.

**The wrap works everywhere once that one is fixed.** With the value aliased, all ten dimensions
execute both the wrapped keyset page and the wrapped count:

```
SELECT o.opt_id, COALESCE(o.opt_label, '') AS opt_label FROM (<get_options_sql>) AS o (opt_id, opt_label)
  WHERE (COALESCE(o.opt_label, ''), o.opt_id) > (?, ?)
  ORDER BY COALESCE(o.opt_label, ''), o.opt_id LIMIT ?
SELECT COUNT(*) FROM (<get_options_sql>) AS o (opt_id, opt_label)
```

Ten for ten, page and count. This is the load-bearing design decision in the spec and it is now
rehearsed against real generated SQL rather than a synthetic stand-in.

**A new hazard: ordering and comparison must agree on type.** On a fixture of three classes sharing
one label with ids 5, 9 and 40, a page after `('Lincoln High (sec)', 5)` returns `9, 40` when both
the `ORDER BY` and the comparison are numeric. Ordering lexicographically while comparing numerically
returns `40, 9`, and since the full lexicographic order is `40, 5, 9`, a walk mixing the two skips a
row without any error. The wire contract stringifies every id, so casting in one place and not the
other is an easy mistake; the requirement above pins it.

**Checked and cleared: `state`'s string id is safe.** `state` is the one dimension whose id and label
are the same expression, so a tie in the label implies the same row after `DISTINCT` and the id
component of the tuple never decides a comparison. Its cursor id can be bound as a string or a
number with the same result, verified both ways.

**Confirmed: the endpoint can take paging params in either place.** A `Plug.Parsers` probe shows
`conn.params` merging a JSON body with the query string, so the resolved decision to put everything
in the body loses nothing. But `Params.parse_limit/1` returns `{:ok, 25}` for `"25"` and
`{:error, "limit must be an integer"}` for `25`, so reusing it unchanged would reject the shape a
JSON client naturally sends. That is now a requirement rather than a surprise.

### Verification environment

Probes ran against a local MySQL 8.0.39 (the repo's `docker-compose.yml` dev database) on a
throwaway six-row table, covering: offset paging instability under duplicate labels, keyset paging
correctness, the select-alias restriction in a keyset predicate, and the subquery wrap for both the
page and the count. The table is throwaway and is not part of this story's deliverables.

### Stage-4 re-run (2026-09-07): assumptions re-verified after REPORT-105 and REPORT-106 landed

This spec was written on 2026-09-02 against `2a99796`. REPORT-105 (#417) and REPORT-106 (#419) have
since merged, so the assumption verification was re-run against `173cb3e` under the stage-4 re-run
guard in `spec-writing-waves.md`. Most of it holds, including the parts written speculatively
against REPORT-105 before that code existed. One thing REPORT-106 landed makes a step in the
implementation spec redundant, one is incoming from an unmerged PR, and one is a decision that is
not this spec's to make (see the OPEN question below).

**Unchanged, re-checked rather than assumed.** `report_filter_query.ex` was not touched by either
story, so `get_options_sql/1` (`:920`) and `get_counts_sql/1` (`:925`) are the functions this spec
was written against. `@valid_filter_types` is still the same ten portal-backed dimensions
(`report_filter.ex:12`). The `permission_form` defect is still exactly one of ten and still has the
shape described above: `value: "CONCAT(ap.name, ': ', ppf.name)"` unaliased, with
`order_by: "ppf.name"` naming a column outside the select list. `Auth.can_access_reports?/1`
(`auth.ex:63`) still admits `portal_is_project_researcher`, and the enforcement it has to be paired
with still exists, though no longer under the name this spec first recorded: REPORT-91 extracted
`maybe_enforce_hide_names/2` out of the form into `HideNames.enforce/2`, which the form now calls at
each of its four filter-building sites. The rule is unchanged. The
`{items, next_page_token}` envelope is unchanged (`report_json.ex:10-11`), so the envelope decision
holds.

**The `{label, value}` prediction was right, and the measurement sharpens the test.** The
implementation spec's `AppDimension.options/0` already reverses `AthenaConfig.app_options/0`, with
the reason recorded and a test that asserts the id explicitly. That was written before the function
existed; it is now run. `app_options/0` (`athena_config.ex:24`) returns fifteen entries as
`{label, value}`, and **exactly one has slots that differ**:
`{"none (no application recorded)", "none"}`. The other fourteen are identical pairs. So a dropped
swap is invisible to any test built on `CLUE`, `CODAP` or any other application, and the existing
requirement that the test assert the id explicitly is load-bearing in a narrower way than it reads:
the test has to use `none`, because on this vocabulary it is the only case that can fail.

**`enabled_for_report?/1` for `app` now has an owner, and the implementation step duplicates it.**
The step defines `enabled_for_report?(%Report{form_options: form_options})` as
`Keyword.get(form_options, :enable_app_filter, false)`. REPORT-106 landed
`AthenaFailure.offers_app_filter?/1` (`athena_failure.ex:75-79`), which is that expression exactly,
including the default-false clause for a report with no such key. Written on 2026-09-02 the
duplication did not exist; it does now, and two readings of one flag are free to drift. The step
delegates instead. Its current home in the failure-advice module is a poor fit for a
report-capability predicate, but moving it is REPORT-105/106 cleanup rather than this story's work.

**REPORT-105 emits `app` as a list in the filter JSON.** `report_json.ex:45` adds
`app: ReportFilter.app_list(report_filter.app)`, where `app_list/1` (`report_filter.ex:45-48`)
normalizes `nil`, `""`, a bare string and a list to a list. That is concretely what a caller
round-tripping a stored run's filter hands back to this endpoint, which is what the requirement that
narrowing fields be accepted and ignored for a static dimension exists to protect. The requirement
needs no change; it now has its real input rather than an anticipated one.

**Incoming from PR #421, and now a dependency.** The open follow-on to REPORT-105 adds
`AthenaConfig.app_options/1`, returning the pairs whose label contains a search string,
case-insensitively, for the form's application LiveSelect (`form.ex:82`, its only caller). An earlier
draft of this spec assigned static-dimension search to the endpoint's generic machinery, which would
have been a second implementation of one narrowing rule once #421 landed, and a divergent one:
measured against the code, every portal `LIKE` predicate matches the label and never the id, while
the drafted generic filter matched both.

Resolved by splitting the two halves rather than choosing between the modules. The **narrowing**
belongs to the dimension, because a future static vocabulary may not be a plain pair list, so the
behaviour's lookup callback takes the search text. The **rule** belongs to one predicate that
`app_options/1` and every static dimension call, because the natural thing to write in a new
implementor is a case-sensitive `String.contains?/2` that no test would catch. The static-dimension
step therefore depends on #421 merging, and `follow-ups.md` tracks that trigger.

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

## Open Questions

All eight questions raised while drafting were resolved against the code and against MySQL probes;
none needed a project-owner call. They are kept as RESOLVED with their rationale, because most of
them are the reason a requirement above reads the way it does.

### RESOLVED: What is the endpoint's method and path?
**Options considered**:
- A) `POST /api/v1/reports/filter-options`, filter and paging in the body.
- B) `POST` for the filter with `limit`/`page_token` in the query string.
- C) `GET /api/v1/reports/:slug/filter-options/:dimension` with repeated query params.

**Decision**: **A**. The deciding argument is the privacy section, not ergonomics. A filter carries
student ids, and the search text a caller sends is frequently a student's name; on a GET those land
in request URLs, which means access logs, proxy logs and browser history for a surface whose whole
point is that a researcher must not be able to read student names out of it. A POST body keeps them
out of every log that records URLs.

C also has a hard limit: a filter narrowing on fifty classes or a few hundred students builds a URL
in the multi-kilobyte range, which is fine until it is not, and fails at a layer nobody in this
system owns. B was the interesting option, because Phoenix's `Plug.Parsers` merges query-string and
body params into one `conn.params` map, so paging params in the query string cost the server
nothing. But that same merge means A gets B's flexibility for free: a caller that prefers
`?limit=…` still works, so there is no reason to *mandate* the split.

The client cost of A is one small POST paging helper in cc-data. That is a fair price, and it is
spelled out in the cc-data-cli requirements above.

---

### RESOLVED: What is the response envelope?
**Options considered**:
- A) `{items, next_page_token, count}`.
- B) The ticket's `{options, count, next}`.
- C) `{items, next_page_token, count}` with `count` as an object.

**Decision**: **A**. `{items, next_page_token}` is what `GET /api/v1/reports` already returns and what
cc-data's `api.Page[T]`, `FetchPage` and `DrainPages` are typed against, including the
repeated-token loop guard that a hand-rolled second paging path would have to reimplement. Adding
one field to a known envelope is strictly cheaper than a new one that differs on all three names,
and "options" carries no information that the endpoint's own name does not. C is folded into the
count question below rather than decided here.

---

### RESOLVED: How does the response signal that the count was skipped?
**Options considered**:
- A) `count: null` plus `count_skipped: true` and a reason.
- B) Omit `count` when skipped.
- C) Always count, with a cap and a `count_capped` flag.

**Decision**: **A**. B is the trap it looks like it avoids: an omitted JSON number decodes to zero in
Go, which is cc-data's language, so the one consumer that exists would read "we did not count" as
"there are none" with no error anywhere. An explicit null plus a boolean cannot be misread by
accident, and the reason string means a caller can tell a user *why* rather than showing a blank.

C is rejected for the specific case that motivates the question: the unnarrowed student count is not
slow, it is unbounded, and capping it still runs it.

---

### RESOLVED: Which cases skip or bound the count, and is the rule per-dimension or general?
**Options considered**:
- A) Mirror the form: skip only the unnarrowed `student` case.
- B) Skip whenever there is no narrowing and no search text, for any dimension.
- C) Always attempt with a short timeout and report skipped on timeout.

**Decision**: **A as the rule, with C's timeout as a safety net.** Skip the count outright, without
running it, for an unnarrowed `student` request; bound every other count with a short per-query
timeout and report it skipped if it trips.

Checked the other dimensions rather than assuming: with `:all` scoping an unnarrowed count is
`COUNT(DISTINCT admin_cohorts.id) FROM admin_cohorts` for cohorts, `portal_schools` for schools, and
`external_activities` for assignments, all counts over a table's own primary key at a scale the form
already counts happily today. `student` is the outlier, joining `portal_students` to `users`, and
the form's code says why in as many words: *"since there are a lot of students in the system, we
should skip getting the count when it is the first filter."* So B would refuse a cheap and useful
count for nine dimensions to avoid one expensive one.

C alone was tempting because it is empirical rather than a guess, but a timed-out count has still
held one of the shared pool's five connections for the whole timeout, which is precisely the
starvation REPORT-88 had to add a limiter for. Not running the known-unbounded query is better than
running it and giving up. Keeping C's timeout for everything else covers the shapes this analysis
has not thought of.

---

### RESOLVED: What does the page token encode, and what happens when the underlying data changes mid-walk?
**Options considered**:
- A) Base64 of a JSON `{label, id}`, opaque by convention.
- B) The same, signed.
- C) Encode only the id and re-derive the label server-side.

**Decision**: **A**. Both worries behind B and C dissolve on inspection. Tampering gains nothing: the
token supplies only a position in an ordering, while the dimension, the narrowing filter and the
project scoping are all rebuilt from the request and the caller's role on every page, so a forged
token can at worst start the caller at an odd place in their own already-scoped result. And the
token discloses nothing new: its label is the last row of the page the server just returned to that
same caller. C additionally does not work for `state`, whose id *is* its label, and costs a lookup
per page to solve a problem that does not exist.

Mid-walk data changes are inherent to keyset paging and are the reason it is preferred here: a new
option inserted before the cursor is missed and one deleted is skipped, but no page is ever
misaligned, which is the failure offset paging has.

---

### RESOLVED: Is the `report_slug` required, and what does it buy?
**Options considered**:
- A) Required, with a general-purpose slug for standalone browsing.
- B) Optional: validate against `include_filters` when present, allow any dimension when absent.
- C) Required, plus a separate endpoint listing each report's filter dimensions.

**Decision**: **B**. The ticket asks for the endpoint to work "not only for filter building", and A
satisfies that only by inventing a report that exists to be named in requests that are not about a
report, which is a fiction the API would then have to keep alive. B keeps the check where it is
worth having (a caller assembling a filter for `school-metrics` and asking for `student` options has
made a real mistake worth catching) and drops it where it is meaningless.

C's dimension-listing endpoint is a genuinely useful thing, but it is discovery of *reports*, not of
filter options, and it belongs with the create story that needs it. Note that a caller already has a
cheaper route to the same fact: `include_filters` determines the filter shape, and REPORT-93 is
where a report catalog would earn its place.

---

### RESOLVED: Do `start_date`, `end_date` and `exclude_internal` participate?
**Options considered**:
- A) Accept and ignore, matching the form.
- B) Reject as unknown fields.
- C) Accept and make them narrow.

**Decision**: **A**, with one correction found in the later self review: `exclude_internal` is
**not** inert. It narrows the `teacher` dimension, which destructures it and applies
`exclude_internal_accounts/4`. Only `start_date` and `end_date` are accepted and ignored. The
reasoning below stands for those two.

B is disqualified by the API's own output: `report_filter_json/1` emits
`start_date`, `end_date`, `exclude_internal` and `hide_names` on every run returned by
`GET /api/v1/reports/:id`, so the most natural client workflow, take a run's filter, adjust it, ask
what else is available, would be rejected for carrying fields the API itself just handed over.

C is the honest-looking option and is the one to revisit if a user ever asks for it, but making
dates narrow option queries is new work inside the shared per-dimension builders, which is exactly
the form-regression risk the subquery-wrap design otherwise avoids paying. The documentation
requirement is the mitigation: the endpoint states that only id dimensions and the search text
narrow options.

The same round-trip is why `hide_names` in a request body is ignored rather than rejected: a caller
will send it, and the answer is that the caller's role decides, not the request.

---

### RESOLVED: Does the endpoint need its own concurrency or timeout bound?
**Options considered**:
- A) A per-query timeout well under the module default, no concurrency cap.
- B) A timeout plus a concurrency cap mirroring the download limiter.
- C) Neither.

**Decision**: **A**. The download limiter exists because a streaming download holds one of five
shared connections for the entire transfer, which can be minutes; an option query holds one for the
length of a single indexed lookup and returns. Once the counts are bounded (above), there is no
shape left in this endpoint that resembles what the limiter was built for, and a second limiter
would add a `503` failure mode to a lookup that a client is expected to call repeatedly and
interactively. C is rejected because the module default is five minutes, which is not a bound for a
request a human is waiting on.

## Self-Review

Multi-role review of this spec, run after it was written. Roles: Senior Engineer, Security & Privacy
Engineer, QA Engineer, Database Engineer, API Designer, Education Researcher. Every issue below was
checked against the code, and where it was a claim about SQL behavior, against MySQL 8.0.39, before
being written down; candidates that did not survive were dropped.

### Security & Privacy Engineer / Senior Engineer

#### RESOLVED: "every response is scoped to the caller's allowed projects" is false for three dimensions
Stated as an absolute across all ten dimensions. Verified false: `get_filter_query/5` takes
`allowed_project_ids` as an **underscore-prefixed, unused** parameter for `:country`, `:state` and
`:subject_area`, and applies scoping only in the other seven.

There is no leak here, which is why this is a wording defect rather than a vulnerability: the three
are global taxonomies (`portal_countries`, `portal_schools.state`, `admin_tags`) carrying no
per-person data. The harm is to the implementer. Someone reading the requirement literally would go
looking for the missing scoping and add it, and those three dimensions are exactly the ones the two
aggregate reports (`school-metrics`, `summary-metrics-by-subject-area`) filter on, so adding it
would silently change the web form for them. **Resolution**: the requirement now states scoping
per-dimension, and says explicitly that the three taxonomy dimensions must keep applying none.

#### RESOLVED: `exclude_internal` is not inert, and a resolved question said it was
The resolved question on dates and flags concluded that `start_date`, `end_date` and
`exclude_internal` are all "accepted and ignored, matching the form." The third is wrong.

Verified: `get_filter_query(:teacher, %ReportFilter{exclude_internal: exclude_internal}, …)`
destructures the flag and applies `exclude_internal_accounts(exclude_internal, query.where,
portal_server, "portal_teachers")`, adding a `NOT IN` over Concord's own teacher ids. The comment on
`get_query_and_params/4` names the case directly: "this handles the case where the user has not
selected any filters but checked the 'exclude CC users' checkbox." It is inert for the other nine
dimensions. It also costs a second portal query, since `get_internal_teacher_ids/1` resolves the ids
with its own `SELECT`.

**Resolution**: the requirement and the resolved question are both corrected. The flag is honored on
`teacher` rather than documented away, which is also the behavior a caller round-tripping a run's
filter would expect.

### Database Engineer

#### RESOLVED: the shipped `permission_form` options query errors under `ONLY_FULL_GROUP_BY`
Found while probing the subquery wrap against each dimension's real shape rather than a simplified
one. `get_filter_query(:permission_form, …)` sets `value: "CONCAT(ap.name, ': ', ppf.name)"` with no
alias and `order_by: "ppf.name"`, so `get_options_sql/1` emits `SELECT DISTINCT ppf.id, CONCAT(…)
… ORDER BY ppf.name`, ordering by a column outside the select list.

Verified on MySQL 8.0.39: that statement returns `ERROR 3065 (HY000) … this is incompatible with
DISTINCT` under the default sql_mode, and succeeds once `ONLY_FULL_GROUP_BY` is removed from the
session. So permission-form filter options work today only because the portal databases run without
that mode, an undocumented dependency nobody has written down. It is the only one of the ten
dimensions with the defect; the other nine either select a bare column they order by, or alias the
expression and order by the alias.

**Resolution**: a new requirement section has this story alias the value and order by the alias,
with a regression test pinning the corrected SQL. The edit is invisible to the web form because
`get_options/4` destructures each row positionally as `[id, value]`, so a column's name never
reaches a caller.

#### RESOLVED: the subquery wrap needs an explicit derived-table column alias list
The Technical Note showed the wrap as `SELECT * FROM (<get_options_sql output>) o WHERE (o.fullname,
o.id) > …`, which assumes the derived table inherits usable column names. Verified it does not for
an unaliased expression: `SHOW COLUMNS` on that shape reports a column literally named
`CONCAT(ap2.name, ': ', pf.name)`.

**Resolution**: the wrap names its own columns, `… ) AS o (opt_id, opt_label)`, which also makes the
outer predicate independent of which dimension is being paged. Probed green.

#### RESOLVED: the wrap is materialized, so paging is not the cheap operation the note implied
The spec presented the wrap as a free way to get keyset paging without touching the builders.
`EXPLAIN FORMAT=TREE` shows otherwise: the derived table is materialized (`Materialize` ->
`Temporary table with deduplication`), and the keyset predicate and sort are applied *after* the
scan of it, so the predicate is not pushed down. Every page therefore builds and sorts the
dimension's entire distinct option set.

This does not break anything and does not change the design: correctness holds, memory stays bounded
by the `LIMIT`, and the form is not the cheap comparison it looks like, since it loads every
secondary filter's dimension whole. But a
full walk of a large dimension is quadratic rather than the O(log N)-per-page a keyset walk normally
buys, and the spec should not claim a cost it does not have. **Resolution**: a Technical Note records
the plan, names the mitigations already required (the per-query timeout, the page-size cap, and text
search), and states the escape hatch (pushing the predicate into the builder, the edit the ticket
originally anticipated) as a deliberate not-now rather than an oversight.

---

### RESOLVED: does the `teacher` dimension's email label need the same protection as `student`?

The privacy requirement above is written entirely around the `student` dimension, whose label is a
student name unless hide-names is on. The `teacher` dimension has a second PII-bearing label that
hide-names does not reach: `get_filter_query(:teacher, ...)` selects
`CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') AS fullname`
(`report_filter_query.ex:716`) unconditionally, and `:student` (`:819-829`) is the only branch in
the whole builder that consults `hide_names`. So a teacher option's label is a real email address
for every caller, including the project researchers `can_access_reports?/1` admits.

**Options considered**:
- A) Accept it. The endpoint matches the form's semantics exactly, which the rest of the privacy
  section already commits to.
- B) Extend hide-names to the teacher label in the endpoint only.
- C) Extend hide-names to the teacher label everywhere, form included.

**Decision**: **A**, and it is not a close call once two things are checked rather than assumed.

**The endpoint exposes nothing the existing API does not already serve.** `report_filter_values` is
returned in the report JSON (`report_json.ex:31`) for every run a caller can read, and
`ReportFilter.get_filter_values/2` builds the teacher entry as
`CONCAT(TRIM(u.first_name), ' ', TRIM(u.last_name), ' <', TRIM(u.email), '>') AS name`
(`report_filter.ex`, the `:teacher` branch). Any run that filtered on teacher already hands a
researcher those email addresses through `GET /api/v1/reports`, behind the same role gate.

**The form does not cap enumeration the way this spec assumed.** An earlier draft of this question
argued the endpoint was different in kind because the form refuses to auto-load a dimension over
`@max_auto_options_length` (`form.ex:34`, 200) while the endpoint pages without a ceiling. That is
wrong: `has_few_options?/5` is a `cond` whose first clause is
`filter_index > 1 -> true`, so the count check only ever runs for the **first** filter. For any
filter after the first, `update_options/5` calls `ReportFilterQuery.get_options/3` and
sends the dimension's complete option list to the LiveSelect component. A researcher who picks any
first filter and then adds teacher already receives every teacher label their projects allow, emails
included, with no search text and no cap.

**The policy, confirmed by the project owner on 2026-09-07: teacher emails are not protected data.
Only student data is protected.** That is what `hide_names` is for, and it is why the builder
consults it in the `:student` branch and nowhere else. The asymmetry is deliberate rather than an
oversight the API should compensate for.

So B and C both fail on the policy before they fail on anything else: they would protect data the
product does not treat as protected, B by making the API stricter than the UI for data the UI hands
over in one interaction, C by changing the web form, which this story's Out of Scope explicitly
forbids.

**Consequence for this spec**: no requirement changes. The privacy section's rule, that the endpoint
enforces exactly what the form enforces, already produces the right behavior for `teacher`. The
`student` enforcement it spells out remains necessary, because that is the one dimension where the
form's rule is not the identity.

---

### Second review round (2026-09-08): six findings, each verified before it was written down

Roles: Database Engineer, Security Engineer, Senior Elixir Engineer, QA Engineer, API/Client
Engineer. Every SQL claim was executed against the repo's MySQL 8.0.39 container on throwaway
schemas, and every code claim was read out of the tree at `8a70c29`. The requirement text above
carries each fix and its evidence; this is the index, not a second copy.

- **RESOLVED: a NULL label truncated the paged walk.** Verified: page 2 of a six-option dimension
  returned nothing while the count said six. Fixed by coalescing the label once in the wrap's
  projection. See Pagination.
- **RESOLVED: a caller with no allowed projects got `ERROR 1064`, not an empty list.** An empty
  `allowed_project_ids` list is not `:none` and renders `IN ()`. Reachable and permanent for a
  de-provisioned token holder. See the pre-existing defects.
- **RESOLVED: `state` values reached SQL as text with a bypassable escape.** Demonstrated end to
  end. Fixed with a MySQL-safe list helper, deliberately leaving `escape_single_quote/1` alone
  because Presto depends on its current behavior. See Input validation and the pre-existing defects.
- **RESOLVED: a static dimension sorted differently from a portal one**, on the real `app`
  vocabulary, in two places. Ordering joins matching in one module. See Static dimensions.
- **RESOLVED: the client envelope could not carry the count** the MCP tool advertises. See
  cc-data-cli.
- **RESOLVED: the token requirement was unfalsifiable as written.** It is really `DrainPages`' loop
  guard, which is a per-walk property the keyset cursor satisfies. See Pagination.

Checked and cleared, so that a later reader does not re-derive them: the derived-table column alias
list works on 8.0.39; `permission_form` is exactly one of ten failing under `ONLY_FULL_GROUP_BY`;
the keyset walk is exact across tied labels with ids whose numeric and lexicographic orders
disagree; a stringified cursor id compares correctly against an INT column; and every dimension's
secondary-filter list matches `get_dependent_filters/1`, so `[]` really does always short-circuit.
