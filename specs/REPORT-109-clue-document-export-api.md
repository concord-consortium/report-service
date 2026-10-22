# CLUE Document Export API (Metadata, History, Content) Scoped by Report Run

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-109 (decisions from the spike https://concord-consortium.atlassian.net/browse/REPORT-108; the CLUE function: https://concord-consortium.atlassian.net/browse/CLUE-742)

**Status**: **Closed**

## Overview

Three new report-server endpoints let a researcher download, for a report run they own, the CLUE documents of that run's students: each document's metadata, its full edit history, and its current content. A function in CLUE's own Firebase project does the reads with CLUE's own credentials, and report-server decides who and what may be read, so a CLUE study no longer starts by borrowing a maintainer's service-account key.

## Requirements

### Routes and authorization

- **R1.** Three routes under the existing `:api_authenticated` scope, beside `/answers` and `/history`: `GET /api/v1/reports/:id/clue/documents`, `/clue/history` and `/clue/content`.
- **R2.** Authorization is D2's, implemented by the same calls in the same order as `BulkExportController.serve/4`: `Params.parse_id/1`, `Reports.get_api_report_run/2`, then `BulkParams.parse_limit/1` and `parse_page_token/1` (400 `BAD_REQUEST`), and on the first page only `EndpointSet`'s gates: the `derives_learner_data` check and the allowed-project short-circuits (`:none` or `[]` is an empty scope, a failed lookup is 500). The CLUE route reuses those gates and `LearnerData.fetch` but maps the learner rows itself, since `EndpointSet.to_endpoints/1` keeps only `remote_endpoint` and `source` (R6). `LearnerData.fetch` raises on a learner whose `teachers_id` or `permission_forms_id` is NULL (`get_unique_ids/2` hands `nil` through `split_id_list/1` to `String.split/3`, a `FunctionClauseError`, `learner_data.ex:159-180`), which made the bulk endpoints answer 500 for the whole run; REPORT-109 makes `split_id_list/1` answer `[]` for `nil` (`learner_data.ex:176`), so a NULL list holds no ids, as `get_info_by_ids/2` already treats it. rigse can leave either column NULL: rows that predate the columns were never backfilled, a failed `update_field` keeps the old value, and `ensure_no_nils` covers neither (`report/learner.rb:33-39`, `:62-78`). A non-existent, not-owned, non-API or malformed `:id` answers an indistinguishable 404 `NOT_FOUND`; a report without per-learner data answers 422 `UNPROCESSABLE`.
- **R3.** Athena runs and Portal runs are both accepted, since both derive learners from the run's filter. A Student ID Mapping run is the documented way to define a CLUE cohort, and R23's controller tests include one.
- **R4.** Responses carry `Cache-Control: no-store` and `Pragma: no-cache`.

### Scope

- **R5.** On the first page, the export derives the run's learners as D1 says, then reads `id, class_hash` from `portal_clazzes` for the learners' distinct `class_id`s, in the caller's portal database. A learner whose class has no class hash is left out. The scope owners are frozen in the scratch row, ordered by `class_hash` then owner id, each with its `portal_class_id`, its kind and its offering set:
  - **Student owners:** the distinct `(class_hash, user_id)` pairs, each with the set of the run's `offering_id`s for that learner.
  - **Group owners:** every `group_<offeringId>_<groupId>` owner under RTDB `classes/{class_hash}/users` whose `offeringId` is one of the run's offerings in that class, listed by the function's `owners` operation (R17) before the scratch row is written.
  - **The class owner:** `class_<class_hash>` for each class with at least one student owner (R6), frozen without an existence check; an absent owner walks empty.
- **R6.** The CLUE route does not use `EndpointSet`'s source rule, because CLUE documents are keyed by owner and class, not by `run_remote_endpoint`. Instead a learner becomes a student owner only when its `runnable_url` host is one of the applications that write CLUE documents, `collaborative-learning.concord.org` (any path, branch builds included) and `dataflow-app.concord.org` (the standalone Dataflow 3.0 app), checked by a new `ReportServer.Clue.writes_clue_documents?/1`: an `http` or `https` URL whose host, compared case-insensitively, is on the list (so a lookalike such as `collaborative-learning.concord.org.example.com` fails). All 32 of the portal's Dataflow curriculum assignments in Scott's cohort pass (5,509 student runs); the `dataflow-app.concord.org` host comes from the inventory, since no portal URL for it was at hand, and R24's superset check is what confirms it. `is_clue_url?/1` is left as is, since widening it would send Dataflow 3.0 activities into the CLUE answer report's text-tile query (`resource_data.ex:78`). So a run with no CLUE assignment exports nothing rather than its students' offering-less CLUE work. In Scott's corpus, 74 of the 90 owners of offering-less documents have no offering-scoped document and hold 865 of the 890; they are Dataflow 3.0 students (`clue-data-inventory.md:405-414`), which is why that host is on the list.
- **R7.** An owner's candidate documents are those it holds in its class: Firestore metadata with `context_id == class_hash` and `uid == owner`, or RTDB metadata under `classes/{class_hash}/users/{owner}/documentMetadata`. The candidate set is the union of the two stores. A candidate is in scope when it has no offering, or when its offering is in the owner's offering set: for a student owner the run's offerings for that learner, for a group owner its own offering, for the class owner the run's offerings in that class. A document's offering is RTDB `offeringId` (stamped from the launching user's offering when a problem, planning or publication document is created, collaborative-learning `5b2a13bfa` `src/lib/db.ts:809` and `:845`), then Firestore `offeringId`, then for a group document the offering in its owner id (RTDB group metadata carries none on staging), taking the first that is present. CLUE types `offeringId` as a string that is `""` for a launch outside a portal (`shared/shared.ts:182`), so `""`, `null` and a missing field all count as absent and fall through; a document with no present offering has no offering. A present value that is not an integer puts the document out of every scope, without trying the next source. On staging the two agree on all 24 documents of class `7be899cf…` (probed); the union costs nothing, since the documents route reads both stores anyway, and guards against a document present in only one store, which nothing has ruled out on production. Teacher documents are not in scope (no teacher is a scope owner).
- **R8.** An empty scope (no learners, or no learner with a class hash) answers a terminal page `{items: [], next_page_token: null, total_endpoints: 0}` and still writes its intent row, as the bulk endpoints do.

### Paging

- **R9.** The envelope and token are the bulk endpoints', so cc-data's paging code applies unchanged: `{items, next_page_token, total_endpoints}`, `limit` (default and maximum 500, only lowering the cap), `page_token` (the same opaque `{s, i, c}` encoding, where `i` indexes the scope owners and `c` is the route's inner cursor). `total_endpoints` is the number of scope owners. Termination is `next_page_token == null` alone; an empty page with a token is a legitimate mid-export page. Expiry is 410 `EXPIRED_CURSOR` after an hour idle; replaying the terminal token re-serves the final page. The scratch row is bound to its route by `data_type`, so a token from one CLUE route is 404 on another.
- **R10.** Inner cursors, each validated in Elixir before the function is called (malformed is 400 `BAD_REQUEST`):
  - `/clue/documents` and `/clue/content`: `{docId}`, the last document served for the current owner, in document-key order.
  - `/clue/history`: `{docId, index, entryId}`, the last entry served, so a document with more entries than one page resumes mid-document. Within a document, entries are ordered by `(index, entryId)`, because 73 documents in Scott's corpus have duplicate or gapped `index` values and the duplicates are distinct entries.
  - Every id refuses the characters no RTDB key may hold (`/ . # $ [ ]`), and `index` is an integer from 0 to 9,007,199,254,740,991 (JavaScript's `Number.MAX_SAFE_INTEGER`), the range the function accepts, so a cursor it would refuse is a 400 here. The next cursor in each answer meets the same checks, and an answer that would not advance the export (an unfinished owner, the slice's first one, with the cursor it was sent) is a 500 with no page row, so no token can resume where it started.
- **R11.** A page stops at the first of: `limit` items, 250 owners walked, 5,000 raw reads, or the response byte budget (8 MB, matching `bulk_read`). The budget always admits one whole item, so a page makes progress even when one item is larger than the budget. Paging is at-least-once: a retried page may re-deliver items, and every item has a stable identity for the client to de-duplicate on (`doc_id`, or `(doc_id, entry_id)`).
- **R12.** Never a partial record. An item is either whole or absent: a history entry is never split, a document's content string is never truncated, and a document row is built only after both metadata stores have been read for it. A read failure in the function fails the whole page (500 `SERVER_ERROR`) with no audit row and no cursor advance, and the same token can be retried.

### Item shapes

- **R13. `/clue/documents`**, one item per document in scope:

  | Field | Source |
  |---|---|
  | `doc_id` | Firestore document id, which equals the RTDB key |
  | `uid`, `context_id`, `portal_class_id` | the scope owner (`portal_class_id` from R5) |
  | `owner_kind` | `student`, `group` or `class` (R5) |
  | `type`, `visibility`, `title`, `unit`, `investigation`, `problem`, `group_id`, `network` | Firestore metadata, falling back to RTDB metadata where only RTDB has the field |
  | `offering_id` | the document's offering as R7 determines it (RTDB, then Firestore, then a group's owner id), as an integer, else `null` |
  | `tools` | Firestore `tools` as a list, `null` when the field is absent (absent is not empty) |
  | `created_at` | metadata `createdAt` (epoch ms) |
  | `metadata_sources` | which stores held metadata: `["firestore"]`, `["rtdb"]` or both |
  | `firestore_metadata`, `rtdb_metadata` | the raw metadata objects, `null` when that store has none |

- **R14. `/clue/history`**, one item per entry of each document in scope (documents with no history contribute nothing):

  | Field | Source |
  |---|---|
  | `doc_id`, `entry_id` | the parent document id and the history document id |
  | `idx`, `prev_entry_id`, `server_created` | stored `index`, `previousEntryId`, `created` (ISO 8601 UTC) |
  | `created` | the entry JSON's `created` (client clock), ISO 8601 UTC, `null` if it does not parse |
  | `model`, `action_raw`, `undoable`, `state` | the entry JSON's `model`, `action`, `undoable`, `state` |
  | `n_records` | length of the entry JSON's `records` |
  | `is_revert`, `entry_uid` | the entry JSON's `isRevert` (`false` when absent) and `uid` (`null` when absent) |
  | `parse_ok` | whether the entry JSON parsed; when false every extracted field is `null` |
  | `entry_json` | the stored `entry` string, byte for byte |

- **R15. `/clue/content`**, one item per document in scope, including documents with no content: `doc_id`, `uid`, `context_id`, `found` (whether an RTDB document node exists), `type`, `version`, `change_count`, `last_history_entry_id`, `self` (the node's raw `self` object, which Scott's `content.parquet` keeps as `self_uid`, `self_doc_key` and `self_class_hash`; `null` when absent), and `content_json` (the stored `content` string byte for byte, `null` when `found` is false or the node has no content).

### Audit

- **R16.** Scratch rows and audit rows use the new `data_type`s `clue_documents_bulk`, `clue_history_bulk` and `clue_content_bulk` (added to `ExportScratch` and `DataAccessLogEntry`'s allow-lists). The intent row (`export_scoped`) and each page row (`bulk_read`) carry the run, caller, slug, filter, export id and page token as today; `endpoint_set` holds owner keys of the form `clue:<class_hash>:<uid>` (all owners on the intent row, the owners served on a page row, taken from the function's `served_owner_offsets` (R17), since `/clue/history` items carry no owner); and a new nullable integer column `item_count` holds the page's item count (null on the intent row and on existing kinds). Writes are fail-closed and the first page's scratch and intent rows are written atomically, as today.

### The CLUE function

- **R17.** One HTTPS (`onRequest`, 2nd generation) function in CLUE's `functions-v2`, exported from its `index.ts` and deployed to both CLUE projects, taking one POST per page shaped like `bulk_read`'s request: the collection (`documents`, `history` or `content`), the portal host, the ordered owner slice from the current index, the inner cursor and the three limits. It answers like `bulk_read`: the items, the offset of the owner it stopped in, the next inner cursor, and whether that owner is exhausted, plus `served_owner_offsets`, the slice offsets of the owners that contributed at least one item (R16). It has no `touched_endpoints`: there is no LTI tuple to cache. A fourth operation, `owners`, is called once on the first page with the portal host and each in-scope class's run offerings, and answers the `group_<offeringId>_*` owner keys under `classes/{class_hash}/users`, read with one `orderByKey` range from `group_<offeringId>_` to `group_<offeringId>_\uf8ff` per offering (on the emulator with Admin SDK 12.3.1, offerings 12, 123 and 1234 each get only their own groups, and an offering with none gets nothing). The Admin SDK has no keys-only read, so the range returns the group owners' subtrees; the function answers keys only. On production that read is at most 9,171 bytes in any class (9 group documents in 2 classes across all portals, probed 2026-10-22). It initializes the Admin SDK bare, as the rest of `functions-v2` does, so each project reads its own Firestore and RTDB; it never names a database URL (CLUE's `functions-v1` hard-codes production's, `functions-v1/src/index.ts:8-10`, which on staging would read production).
- **R18.** It is authorization-blind by design (report-server decides scope) and gated by a header-only bearer: a dedicated secret (`defineSecret`) in each CLUE project, compared in constant time, refused when sent as a query or body value, and shared with nothing else. It validates its input shape (class hashes 48 lowercase hex, uids numeric or a synthetic owner, document ids plain path segments, the portal host on an allow-list of that project's portals) and caps the limits it accepts, so a leaked bearer cannot read past the request shape.
- **R19.** It reads and never writes. It runs as a dedicated service account holding only read roles on Firestore and the RTDB (and access to its own secret), so a write is refused by IAM, not just absent from the code.

### Configuration per environment

- **R20.** report-server reads `CLUE_EXPORT_URLS`, a JSON object of portal server to function URL (validated at boot like `PACKAGE_BUCKETS`), and `CLUE_EXPORT_TOKEN`, the bearer. Each URL must be `https` with a host, or report-server refuses to boot. A portal with no entry answers 503 `SERVICE_UNAVAILABLE` ("CLUE export is not configured for this portal") before any scratch or audit row is written.

  | report-server | report-service Firebase | Portal | CLUE project | CLUE `{portal}` | Credential |
  |---|---|---|---|---|---|
  | staging (`report-service-qa` stack) | `report-service-dev` | `learn.portal.staging.concord.org` | `collaborative-learning-staging` | `learn_portal_staging_concord_org` | the function's read-only service account in `collaborative-learning-staging`; bearer in that project's Secret Manager and in the stack's `CLUE_EXPORT_TOKEN` |
  | production (`report-service-prod` stack) | `report-service-pro` | `learn.concord.org` | `collaborative-learning-ec215` | `learn_concord_org` | the same, in `collaborative-learning-ec215`, with its own bearer |

  The two bearers differ, so a staging secret can never read production. Both settings reach report-server through its stack, so REPORT-109 also changes the sibling `cloud-formation` repository: `fargate/report-server.yml` gains a `ClueExportUrls` parameter and a `NoEcho` `ClueExportToken` parameter injected as these variables, beside `ReportServiceToken` (`fargate/report-server.yml:232`), and each stack is updated with its own values.

### The CLUE pre-pull flag (also in REPORT-109's Jira)

- **R21.** report-server stops parsing a manifest's `clue_prepull` (`ReportServer.Packages.Manifest`), stops storing it (`PackageVersion`) and stops returning it from the list and the resolve (`PackageJSON`), and a migration drops `package_versions.clue_prepull` (migrated on staging only). A manifest that still carries the key keeps validating: the manifest has no unknown-key check, so the key is ignored. rigse's resolve reader treats an absent `clue_prepull` as false (`catalog.rb:30`), so the order relative to RIGSE-369 does not matter.

### Documentation, tests and acceptance

- **R22.** The README documents the three routes under a "CLUE document export" heading, and says plainly that `/clue/history` is CLUE **document** history while `/history` is LARA interactive-state history from report-service's own Firestore.
- **R23.** Tests: controller tests with a stubbed client for each route (first page, resume, terminal replay, expiry, cross-route token 404, empty scope, unconfigured portal 503); a denied-access test that a run the caller does not own is 404 and a token without a report role is 401; a test that a caller whose grants exclude every learner of their own run gets an empty terminal page, not an error (D2: grants narrow); scope tests (the `:portal_db` fixture's `portal_clazzes` has a `class_hash` column for these, with class 601 hashed, 602 NULL and 603 empty) that a learner with no class hash is left out, that a learner whose `runnable_url` is not a CLUE-writing host contributes no owner (and a class with only such learners contributes no class owner) while `collaborative-learning.concord.org` branch builds and `dataflow-app.concord.org` learners do, that owners are frozen across pages, that a student's document in an offering outside the run is left out while one with no offering is kept, and that group owners of the run's offerings (from a stubbed `owners` answer) and the class owner are included and other offerings' groups are not; a pagination test that resumes inside a document with more entries than one page and ends with no duplicate and no gap; audit tests for both row kinds and `item_count`, and that a page row names only the owners that served items; function tests that it refuses a missing, wrong or query-string bearer and a malformed request (on a hand-built request, no emulator needed) and, against the emulator, that it never writes, never splits an item, and that `owners` returns exactly the group keys of the requested offerings and none of another offering's; a `LearnerData.fetch` test over the fixture's class 602, whose learner 904 has both id lists NULL and raises today; and the manifest tests for R21.
- **R24. Acceptance on staging and production.** On staging, the three routes are checked against a direct read of a known staging class (class `7be899cf…` holds a 26,632-entry document, so the history check resumes mid-document): document, entry and content counts match the read, with no duplicate and no gap. The superset check against Scott's corpus (every one of his August capture's 4,674 documents present, including the 73, and the additional documents accounted for) runs on production after the production deploy, and is REPORT-109's last acceptance step (Doug, 2026-10-15). REPORT-109's Jira states that criterion under class scoping; under D1's offering rule a document of his in an offering the reconciliation run does not select is out of scope by design, so the check runs on a run filtered by class only, to every class his corpus covers (Doug, 2026-10-22). Two populations are out of scope by design under any run, and are counted and listed as expected exclusions rather than failures: documents owned by a teacher (no teacher is a scope owner, R7) and documents of a student with no learner row in that class (`LearnerBaseQuery` joins `portal_student_clazzes`, so a student no longer enrolled has none). Every other document of his must be present. The teacher exclusion is not empty: in his September capture, 33 owners are portal teachers, holding at least 162 documents, 139 of them in the analysis population (problem documents with history), across 41 classes (Verification).

## Technical Notes

- **The RTDB paging model** REPORT-109's Jira names as its main risk is settled by the owner walk: the outer cursor is the owner index, and within an owner the documents are the keys of one small node (`documentMetadata`, ten documents for a staging student), read with `orderByKey` and a start key (probed on staging). Only history needs a per-document inner cursor.
- **Queries need no new index.** `context_id == X && uid == Y` ordered by document id, and `uid in [...]` with `context_id`, both run on CLUE staging's automatic single-field indexes (probed). History ordered by `index` uses the automatic single-field index.
- **Response sizes.** A 2nd-generation HTTPS function answers up to 32 MB; R11's 8 MB budget leaves room for one RTDB content string at its 10 MB ceiling. report-server's `bulk_read` receive timeout (310 s) applies.
- **Run dates narrow learners, not documents.** The learner rows come from `LearnerBaseQuery`, whose filter bounds `portal_runs.start_time` with the run's `start_date` and `end_date` (`learner_base_query.ex:128-129`). Since REPORT-182 (`2f3de10`) the end date includes its last day: `apply_end_date/3` bounds below the next day's midnight (`report_utils.ex:41-48`). The CLUE routes inherit both through `LearnerData.fetch`, as `/answers` and `/history` do: a learner is in scope when one of its runs started within the range, and its documents are then exported whole, including edits made outside the range. The scope does not inherit anything else from REPORT-182, whose other changes are to log reports, and `scope_by_allowed_projects` itself is unchanged apart from its line numbers.
- **Overlap with CLUE-693.** CLUE-693 is client code and Firestore rules only, with no runtime or `functions-v2` overlap; both still release through `releasing-clue`, R18 keeps its own validation patterns, and its per-learner `changed` map could later drive an incremental export (out of scope).
- **Overlap with REPORT-150.** REPORT-150 (PR #444) also edits `DataAccessLogEntry`'s `event` and `data_type` allow-lists (adding `recent_logs_read` and `recent_logs`), makes `report_run_id` nullable for run-less events, and adds a `data_access_log` migration. R16's allow-list additions and `item_count` migration touch the same changeset and table, so whichever lands second rebases onto the other's list and migration timestamp.
- **For REPORT-110: coverage.** cc-data's shared paging code computes a download's coverage from the distinct `remote_endpoint`s in its membership file (`internal/fetch/paged.go`, `computeCoverage`). CLUE items have none, so reused unchanged it would report every owner empty. The envelope and token reuse holds; the coverage count needs the owner key (`context_id`, `uid`) on REPORT-110's side.
- **cc-data-cli** refuses locally a package that sets `clue_prepull` (`internal/packages/run.go:79`). REPORT-152 drops the flag from `package init`; the refusal goes with it.
- **Documents can move.** CLUE's Sep 2025 consolidation renamed Firestore document ids from `{network}_{key}` or `uid:{uid}_{key}` to bare `{key}` (CLUE `scripts/check-metadata-doc-ids.ts`); `clue-data-inventory.md` line 743 still describes the old form.

## Out of Scope

- The cc-data commands and stores (REPORT-110, REPORT-152), the views (REPORT-111) and the retired recipes (REPORT-122).
- Document comments (`.../documents/{docId}/comments`), teacher documents, exemplars, supports and curriculum content.
- Logs: no log query is involved in scoping (D1), and the class-scoped recent-logs route is REPORT-150's.
- Incremental export from CLUE-693's activity documents, and content as of a point in history (reconstructing a document from its patches is study code).
- Replay links (D6) and de-duplicating publications against their source documents (a publication is its own document).
- Portals other than the two in R20.

## Not Yet Implemented

- The `clueExport` function in CLUE's `functions-v2` (R17 to R19): built in collaborative-learning under CLUE-742 ([collaborative-learning#3052](https://github.com/concord-consortium/collaborative-learning/pull/3052), branch `CLUE-742-clue-export-function`), and deployed through `releasing-clue`. Its plan (the handler, the walk, the `owners` read and their tests) is in this spec's history at `f30b579`, the last commit before the spec folder was closed.
- The rollout and acceptance checks (R24): the staging check of class `7be899cf…` and the production superset check against Scott's corpus run after each environment's deploy, the production one as REPORT-109's last acceptance step.

## Decisions

### Design decisions (REPORT-108)

### D1. Scope derivation: the run's learners resolve to CLUE owners, narrowed by the run's offerings

**Decision.** Derive the run's learners exactly as the bulk endpoints do (`LearnerData.fetch` over the run's stored filter and the caller's allowed projects), then resolve each learner to a **scope owner** `(class_hash, uid)`: `class_hash` from `portal_clazzes` for the learner's `class_id`, `uid` the learner's `user_id`. The documents in scope are those a scope owner holds in that class whose offering is one of the run's offerings, or which belong to no offering; group and class documents of those offerings and classes are in scope too (R5 to R7). No log query is involved.

**Why.** The intended cohort definer is a REPORT-91 Student ID Mapping run, a Portal run with no Athena log output, so log-derived scoping is unavailable for the main use case. Narrowing by offering keeps the export inside the run's filter and the caller's grants, which both work at the offering (`scope_by_allowed_projects`, `report_utils.ex:139-175`), while the no-offering rule keeps the roughly 890 personal, learning log and publication documents. Group documents are collaborative student work of the cohort. Scoping by learner rather than by tile content also recovers the 72 (now 73) documents whose Dataflow tile was deleted, which Scott's tile-filtered corpus could reach only through a log patch.

**Rejected.** (a) `documentKey` from the run's log rows via `ClueLinkToWork`: needs log output a Portal run does not have, and misses documents with no log events. (c) Both, reconciled: the same dependency on log output, for no documents (b) misses. Scoping by `offering_id` alone: drops the roughly 890 documents that legitimately have no offering. Class only (the 2026-09-07 text): returns a student's documents from every offering in the class, and in CLUE each assigned problem is its own offering, so a run filtered to one problem would return every problem's documents, possibly from projects the caller has no grant for. Students' own documents only: leaves out group work, the next "72".

**Rechecked.** Three corrections to the 2026-09-07 text. The learner rows do not carry the class hash, so the export needs one portal query from class id to class hash (R5). `uid` is `user_id`, not `primary_user_id`: CLUE stamps the id of the account that launched. And "scope to the run's classes, not its offering" reached past the run's filter and the caller's grants, so Doug replaced it on 2026-10-15 with the offering rule above and brought group and class documents into scope.

### D2. Who may export: exactly the bulk endpoints' rule

**Decision.** The CLUE routes share the bulk endpoints' gates with no second model: an API token whose user passes `can_access_reports?/1` (admin, project admin or project researcher; `server/lib/report_server_web/auth.ex:63`), a run the caller owns whose slug is in `Tree.api_report_slugs()` (`Reports.get_api_report_run/2`, `server/lib/report_server/reports.ex:93`), a report with `derives_learner_data`, and learners intersected with `PortalDbs.get_allowed_project_ids/1`.

**Why.** A second authorization model in the same controller family would be the defect. A filter broader than the caller's current grants narrows rather than grants, because the intersection runs at export time, not at run creation.

**Rejected.** A CLUE-specific permission (a portal role or an allow-list of CLUE researchers): nothing in the portal models one, and it would diverge from answers and history for the same students.

**Rechecked.** The 2026-09-07 text says membership "is checked on every request". It is checked once per **export**, on the first page, and frozen in the scratch row for the rest of that export; later pages re-check only the token and the stored role flags (REPORT-76, "Snapshot-at-start authorization"). The CLUE routes keep that behavior.

### D3. Credential: a function in CLUE's own project, called with its own bearer

**Decision.** A new HTTPS function in CLUE's `functions-v2` codebase reads CLUE's Firestore and RTDB with that project's own application default credentials. report-server calls it over HTTPS with a bearer secret used for nothing else. No service-account key changes hands, and report-service's own functions gain no access to CLUE.

**Why.** It is the `bulk_read` shape with the data owner holding the credential: the code that reads CLUE's data is reviewed and deployed by CLUE's repository, revoking it is deleting a function or rotating one secret, and the only shared secret reaches only what the function exposes. `functions-v2` calls `admin.initializeApp()` bare (CLUE `functions-v2/src/index.ts:26`) and deploys per project (`.firebaserc`: `staging`, `production`).

**Rejected.**
- *A service-account key for CLUE's project held by report-server.* A standing credential to all of CLUE in a second system, which is the barrier this work removes, moved rather than removed.
- *Cross-project IAM: grant report-service's function runtime read on CLUE's project and read from report-service's own `functions`.* No code in CLUE's repository, but report-service's `api` function sits behind one shared `AUTH_BEARER_TOKEN` that rigse and other services also hold (`functions/src/index.ts`; `final-design.md` 17 item 1), so every holder of that bearer would gain a path to CLUE's corpus.
- *Rules-enforced reads with a per-researcher CLUE token (the model RIGSE-365's runner used).* The boundary would be CLUE's own rules, which is stronger in principle, but cc-data's credential is a report-server API token, not a portal session, so report-server would have to hold a rigse-facing credential to mint CLUE tokens, which the Researcher Dashboard design deliberately avoids. Worse, CLUE's RTDB rules grant `.write` as well as `.read` on `classes/$class_hash` to any token carrying that class hash (CLUE `database.rules.json:27-29`), so the minted token would be a write credential to student work. RIGSE-369 deletes the runner's mint.

**Rechecked.** `functions-v2` has no HTTPS function yet: its 15 exports on `master` are triggers or `onCall`, so this is its first `onRequest` and its first bearer secret. And deploys are not automatic: no GitHub workflow deploys functions, and CLUE's `releasing-clue` skill deploys the whole codebase by hand, staging then production, with approval steps and a "Deploy timing" callout in each PR. So the 2026-09-07 "no external sign-off is required" does not hold for the deploy. Decided (Doug, 2026-10-15): Doug reviews, merges and deploys the CLUE half through `releasing-clue`, including the secret and the service account in both CLUE projects.

### D4. Audit: the bulk endpoints' two row kinds, with an item count

**Decision.** Each export writes one `export_scoped` intent row on its first page and one `bulk_read` row per served page, as `/answers` and `/history` do, with three new `data_type` values (R16). Rows name scope owners rather than `remote_endpoint`s, and a new nullable `item_count` records how many documents or entries the page served.

**Why.** Matching the existing rows keeps the admin audit page and its export-id filter working unchanged. CLUE items carry no `remote_endpoint`, so the owner key is the student identity the row can name, and the count is what REPORT-109's Jira asks to be recorded.

**Rejected.** One row per request with no intent row: loses the distinction between "scoped to" and "actually exported" that REPORT-76 introduced. Recording each document id: a page can carry hundreds of documents or thousands of entries, which would bloat the log for no question anyone has asked.

**Rechecked.** Existing bulk exports do log, fail-closed: a failed audit write fails the page. Both export controllers write the intent row through `BulkExport.empty_page/4` or `BulkExport.freeze/5` (the atomic first-page pair in `Exports.create_scratch_with_intent/2`), and each page row in their `serve_page` (`bulk_export_controller.ex:104`).

### D5. Retention: nothing is retained

**Decision.** The export is read-through. report-server persists only the scratch row (the frozen scope owners, never exported content), with the existing one-hour sliding TTL, the 410 on expiry and the periodic sweep (`exports.ex`). No CLUE metadata, history or content is stored by report-service.

**Why and rechecked.** Unchanged from 2026-09-07 and confirmed against `exports.ex` and `export_scratch.ex`. Landing CLUE data in a durable local dataset is REPORT-110's concern.

**Rejected.** Caching pages server-side to make a resume cheaper: it would make report-server a second store of student work with its own retention questions.

### D6. Downstream sensitivity

**Decision.** The responses are student work, including free text in titles, content and history patches, and get the bulk endpoints' `Cache-Control: no-store` and `Pragma: no-cache`. The endpoints return no replay links. Anything built on them that emits CLUE replay links (`Clue.HistoryLink`) inherits the constraint Scott's `review.md` states: not suitable for any venue without access control.

**Rejected.** Adding `Clue.HistoryLink` URLs to document rows: convenient, but it turns every downstream copy of the export into a set of links into student work.

### D7. Data shape: Scott's columns, raw payload kept

**Decision.** Rows align with the columns of Scott's `history.parquet` and `content.parquet` (`clue-data-inventory.md`, lines 103-118) so his recipes port with renames only, and every row keeps its raw source alongside the extracted fields (R10 to R12). Columns that belong to the document (`unit`, `problem`, `portal_class_id`, the owner) appear only on document rows and are joined by `doc_id`, not repeated on every entry.

**Why.** The raw payload is what a later question re-derives from, and the inventory found that every derived column it trusted was eventually wrong somewhere. Keeping each document fact in one place means one value to get right.

**Rejected.** Normalized `action`, `tile_id` and `shared_model_id` on history rows: they are SQL over `action_raw`, which REPORT-111 already puts in its views. One row per patch from the API: REPORT-111's `clue_patches` view does that over the stored entries.

---

### Requirements decisions

### Write REPORT-109's requirements directly rather than a separate REPORT-108 spike document
**Context**: REPORT-108's Jira names this file as its deliverable.
**Options considered**:
- A) One spec: REPORT-109's requirements with a Decisions section.
- B) A REPORT-108 decisions document plus REPORT-109's requirements.

**Decision**: A. Two documents would hold every decision twice and drift. REPORT-109's implementation spec (stages 5 to 7) follows Doug's review of this file.

---

### Keep the envelope key `total_endpoints` for scope owners
**Context**: CLUE items have no `remote_endpoint`, so the bulk endpoints' unit does not exist here.
**Options considered**:
- A) Keep `total_endpoints`, defined as the scope-owner count.
- B) A new key such as `total_owners`.

**Decision**: A. cc-data reads `total_endpoints` in its shared paging code (`internal/fetch/paged.go`), and REPORT-110 depends on that code applying unchanged. The README defines the unit for these routes.

---

### A dedicated read-only service account for the CLUE function
**Context**: A 2nd-generation function runs as the project's default compute account unless told otherwise, which usually holds Editor.
**Options considered**:
- A) A dedicated account with read roles only (R19).
- B) The default account, with "never writes" enforced by code and tests.

**Decision**: A. The function is the one place in CLUE's project that hands student work to another system on a bearer; making it unable to write costs one account and three role bindings. Whether the Admin SDK's RTDB reads work under `roles/firebasedatabase.viewer` is checked in REPORT-109's staging deploy, not assumed.

---

### Do the run's offerings narrow the documents, or only its classes?
**Context**: D1 as decided on 2026-09-07 scopes to the run's classes, to keep the roughly 890 documents with no offering. But a learner row is one student in one **offering**, and both the run's filter (an `assignment` filter) and the caller's grants (`scope_by_allowed_projects` requires the assignment to be in an allowed project, `report_utils.ex:139-175`) work at the offering. Class scoping therefore returns a student's documents from other offerings in the same class: other CLUE units the run did not select, possibly in projects the caller has no grant for. Staging's class `7be899cf…` shows the shape (probed 2026-10-15): six offerings, 1241 to 1246, each holding problem documents, so in CLUE each assigned problem is its own offering, and one student (uid 114) has problem documents in both 1241 and 1242. Under A, a run filtered to one problem returns every problem's documents for its students. This changes a contract other stories consume, so it is Doug's call.
**Options considered**:
- A) Class only, as decided on 2026-09-07.
- B) A document is in scope when its offering (RTDB `offeringId`, then Firestore) is one of the run's offerings for that owner, **or** it has no offering. Keeps the 890 and the 73, and respects the filter and the grants. Needs the RTDB metadata the documents route reads anyway.
- C) B for problem and planning documents, A for everything else.

**Decision**: B (Doug, 2026-10-15). In D1 and R7.

---

### Are group and class documents in scope?
**Context**: CLUE documents owned by `group_<offeringId>_<groupId>` (collaborative group work) and `class_<classHash>` exist on staging today (the newer "axes" documents). No learner's `user_id` matches them, so R7 as written leaves them out. Scott's corpus had none (every `entry_uid` was null, and only concurrent documents stamp it), so his reconciliation cannot show the gap. On staging, the RTDB metadata of the two group documents has no `offeringId` (Firestore's has `1241`); the offering is the middle segment of the owner id.
**Options considered**:
- A) Out of scope: students' own documents only.
- B) Add synthetic owners: each `group_<offeringId>_*` in an in-scope class whose offering is one of the run's offerings, and `class_<classHash>` for each in-scope class. Rows are marked with an `owner_kind`.
- C) B for groups only.

**Decision**: B (Doug, 2026-10-15). In R5, R7 and R13's `owner_kind`.

---

### Who reviews and deploys the CLUE half?
**Context**: REPORT-108's Jira says no external sign-off is needed because the code goes into CLUE's own repository. But `functions-v2` is deployed only by hand through CLUE's `releasing-clue` process, whole codebase, staging then production, with approval steps (D3, rechecked), and `final-design.md` 17 item 5 already treats CLUE-693's deploy as the CLUE team's. The function also needs a secret and a service account created in both CLUE projects.
**Options considered**:
- A) Doug reviews, merges and deploys through `releasing-clue`, as for CLUE-693.
- B) The CLUE team reviews and deploys; REPORT-109 is blocked on that deploy.
- C) Ship it with CLUE-693 in one CLUE release.

**Decision**: A (Doug, 2026-10-15). In D3.

---

### Where can the reconciliation against Scott's corpus run?
**Context**: REPORT-109's Jira asks for a reconciliation "on staging" against Scott's `download-history.ts` counts, and its first acceptance criterion names his 4,674 documents. His corpus is production (`learn_concord_org`); CLUE staging holds 26 documents in two classes, none of them his. So the superset check can only run against production, after the production deploy, which `plan.md` puts in sprint 29.
**Options considered**:
- A) Staging proves the mechanics on a known staging class (counts against a direct read of the same class); the superset check against Scott's counts runs after the production deploy and is REPORT-109's last acceptance step.
- B) Deploy the CLUE function to production early, read-only, for the reconciliation within sprint 28.
- C) Drop the superset criterion and keep the staging check only.

**Decision**: A (Doug, 2026-10-15). In R24.

---

### The stack template is a third repository in scope
R20's two settings can only reach report-server through `fargate/report-server.yml` in `cloud-formation`, where `REPORT_SERVICE_TOKEN` arrives today as the `ReportServiceToken` parameter (line 232). REPORT-109's Jira lists only the functions and report-service. R20 now names the template change and the per-stack update.

---

### A copied database URL would read production from staging
CLUE's `functions-v1` initializes with production's hard-coded `databaseURL` (`functions-v1/src/index.ts:8-10`). Copying that pattern into the new function would make the staging deploy read production's RTDB. R17 now requires the bare initialization `functions-v2` already uses.

---

### "A caller outside the role rules is refused" has two outcomes
R23 asked for a denied-access test "for a caller whose grants exclude the run's learners", but such a caller is not refused: the intersection empties the scope and the export ends with an empty terminal page (D2, R8), as `/answers` does (`EndpointSet.derive_endpoint_set/2`). R23 now names the three outcomes: 404 for a run not owned, 401 for a token with no report role, an empty terminal page for grants that exclude every learner.

---

### Reusing cc-data's paging unchanged would misreport coverage
`computeCoverage` in `internal/fetch/paged.go` counts distinct `remote_endpoint`s in the membership file; CLUE items carry none. The API contract is unaffected, so the fix is a note for REPORT-110 in Technical Notes rather than an API change.

---

### Synthetic owners cannot be enumerated as R5 says
report-server has no RTDB access and the Admin SDK has no keys-only read. Options were an `owners` operation using an `orderByKey` range per offering (A), the same over REST `?shallow=true` (B, a second RTDB client that must name a database URL), or group owners from `offerings/{offeringId}/groups` (C, silently incomplete if a group with documents lacks a node). **Decision**: A (Doug, 2026-10-22), measured at kilobytes on production. In R5, R17 and R23.

---

### A learner from a non-CLUE offering brings in that student's offering-less CLUE documents
A run filtered to a LARA activity in a mixed class would have exported its students' offering-less CLUE work. Options were accepting it (A), keeping only learners passing `is_clue_url?` (B, which drops 865 of the 890 offering-less documents in Scott's corpus, the Dataflow 3.0 students'), or a host list of the applications that write CLUE documents (B2). REPORT-189's population (problem documents with history, all on `collaborative-learning.concord.org` offerings) works under any of them. **Decision**: B2 (Doug, 2026-10-22). In R5, R6 and R23.

---

### R23 put the bearer tests on the emulator
R23 asked for "function tests against the emulator" of the bearer and request-shape refusals, while the implementation runs them on a hand-built request with no emulator (it reaches them before any read, and `firebase-functions` 5.1.1 params read `process.env`, `lib/params/types.js:273` and `:303`). R23 now splits the two: refusals on a hand-built request, never-writes, never-splits and `owners` on the emulator.

---

### Implementation decisions

### R24's superset criterion under offering scoping
**Context**: requirements R24 leaves to this spec whether to require a run that selects every offering Scott's corpus covers, or to restate the criterion.
**Options considered**:
- A) Keep the criterion and fix the run: filter by class only, to every class his corpus covers. Under D1 a class-only filter gives each student owner every offering they have a learner in, and the no-offering rule keeps the rest, so the superset follows unless a document sits in an offering where its owner has no learner row.
- B) Restate the criterion as "every document of his in an offering the run selects".

**Decision**: A, with two named exclusions (Doug, 2026-10-22): teacher-owned documents and documents of a student with no learner row in the class are counted and listed, not failures. It tests the claim as Jira states it for every population the design covers, and B is weaker by construction: a run that selects nothing satisfies it. Including teacher documents in scope was considered and left out of this story.

---

### A separate controller over shared helpers, not a parametrized `BulkExportController`
**Context**: the CLUE routes repeat the bulk routes' page skeleton but differ in the scope, the wire shape (`stop_owner_offset`, `served_owner_offsets`, no `touched_endpoints`), the 503 gate and the audit keys.
**Options considered**:
- A) `ClueExportController`, with the gates and helpers extracted into `EndpointSet.fetch_learners/2` and `BulkExport`.
- B) One controller with a per-route strategy module.

**Decision**: A. B threads a strategy through every branch of a controller whose tests already pin it; A changes the bulk controller only by moving its shared helpers and page steps into `BulkExport`, which its existing tests guard.

---

### The function applies the offering rule, report-server supplies it
**Context**: R7's offering test needs the document metadata, which only the function reads.
**Options considered**:
- A) Send each owner's offerings in the request; the function filters.
- B) The function returns every candidate; report-server filters.

**Decision**: A. B would send out-of-scope student work across the wire and count it against the page budget, and the function would still need a second pass for history and content of in-scope documents only. The function stays authorization-blind in the sense R18 means: it trusts the request's scope and only validates its shape.

---

### The portal allow-list is a deploy-time param, not code
**Context**: R18 asks the function to refuse portals outside its project's.
**Options considered**:
- A) `defineString("CLUE_EXPORT_PORTALS")` in each `.env.<project>` file.
- B) A map from project id to portals in the source.

**Decision**: A. The per-project env files are where `functions-v2` already keeps per-project config, and `deploy-env-files.test.ts` fails if either file lacks the param.

---

### An empty `offeringId` would have been read as offering 0
CLUE types `offeringId` as a string that is `""` outside a portal (`shared/shared.ts:182`, `src/lib/db-types.ts:71`), and the first draft compared it with `Number()`, which makes `""` offering 0 and puts the document out of scope, the opposite of R7's no-offering rule. The walk now treats `""`, `null` and a missing field as no offering at each source and falls through to the next.

---

### Each page sent every remaining owner to the function
The draft copied `bulk_read`'s `Enum.drop(endpoints, index)`, so page 1 of a large run would POST every owner's class hash, uid and offerings although the function walks at most 250. The controller now sends `Enum.take(@owner_limit)` of the slice and the function refuses more than 250, which also bounds the request a leaked bearer can make. The cursor math is unchanged: offsets are relative to the slice either way.

---

### A budget stop at an owner boundary lost the next owners' documents
The walk said "the cursor names the last admitted item" and did not limit the incoming cursor to the slice's first owner. A page that stopped before owner `k`'s first item answered `k` with owner `k - 1`'s last id as the cursor, and the resumed walk dropped every id of `k` that sorts at or below it. A throwaway simulation through `serve_page`'s cursor math (3 owners, 5 documents, budget 10) delivered 2 documents as worded and all 5, once each, with the fix. `bulk_read` never hits this because it admits each endpoint's first item (`bulk-read.ts:72`) and starts only offset 0 from the cursor (`:238`). Walk steps 3 and 5 now say both rules, and an emulator test pins them.

---

### Elixir accepted cursor ids the function refuses
The drafted clauses reused `check_doc_id/1`, which refuses only `/`. A throwaway run of the clauses accepted `a.b`, `a#b`, `a$b`, `a[b` and `a]b`, which the function's id pattern refuses, so a hand-made token got the function's 400 collapsed to 500, against R10. The CLUE clauses now use `check_clue_key/1` with the function's character set (checked with `elixir -e`), and the cursor test covers `.` and `#`.

---

### The audit page cannot show `item_count`
Rollout step 3 reads `item_count` off the audit page, but its Access cell renders only `data_type`, `event`, `source` and the job id (`audit_log_live/index.html.heex:50-51`), and no step changed it. The schema step now adds the count to that cell, with a LiveView test. Checking the column directly would instead need a staging database session, which the acceptance otherwise does without.

---

### A run over more than 1,000 classes could never start
First-page step 4 sent every class in one `owners` call, and the function refuses more than 1,000 `classes`, so such a run would answer 500 on every first page. Step 4 now sends chunks of at most `@owner_limit` classes and concatenates the groups, within the existing wire contract; a controller test pins the split at 251 classes.

---

### A history batch could be sized zero
Walk step 4 sized a batch `min(remaining items, remaining reads, 500)`, which reaches 0 or below only on the page's first item, which step 5 admits "whatever the read count". On the emulator (Admin SDK 12.3.1) `limit(0)` returned all 5 seeded entries and `limit(-1)` threw `INVALID_ARGUMENT`. The batch now has a floor of 1, and step 5 says neither limit stops the walk before the page's first item, which is what keeps "`k` is never 0 there" true.

---

### The `config/test.exs` line could not take effect
`runtime.exs` runs under `mix test` (a throwaway test read `:portal_report`, which only `runtime.exs` sets) and a later `config` for the same key wins, so the drafted block's unconditional `config :report_server, :clue_export` replaced the `test.exs` line. The line is dropped; the client step now says the unset default is what gives the 503.

---

### Dropping `clue_prepull` breaks the image the release replaces
The release skill migrates before the stack update (`.claude/skills/release-report-server/SKILL.md`, step 6), and Ecto names every schema field, so the old image's `SELECT` includes `clue_prepull` (a throwaway `to_sql` of `PackageVersion` showed it). From the drop until the new tasks replace the old ones, the catalog's list, resolve and publish fail; a rollback to the previous image breaks them until the migration is rolled back. The skill counts this as a destructive migration the user must be told about.
**Options considered**:
- A) Keep R21 as one release, and add to rollout step 2 that the catalog fails during the stack update and that a rollback past this release needs the migration rolled back first.
- B) Ship the field removal in REPORT-109's release and the drop migration in the next report-server release, so the image that meets the dropped column never reads it. R21 still holds; only the migration's release moves.

**Decision**: A (Doug, 2026-10-22). Production has no package tables, so its release creates `package_versions` and drops the column in the same migration run, and no running image there ever reads it; the window exists only on staging, for the minutes of the stack update. Rollout step 2 says so.

Checked with no finding: rigse writes `class_hash` only as `SecureRandom.hex(24)` and backfilled every class (`rails/app/models/portal/clazz.rb:301-302`, `rails/db/migrate/20170202190333_add_class_hash.rb`), so every hash passes the function's 48-hex check; learner `class_id`, `user_id` and `offering_id` are integers, so `portal_class_id`, `uid` and `offerings` always pass; CLUE stamps `context_id` on every kind's Firestore metadata and keeps synthetic owners' RTDB nodes under `users/{owner}` (`src/lib/db.ts:681-685`, `:800-805`), so R7's candidate reads find group and class documents; CLUE deletes documents only by an `isDeleted` property or a dev-mode admin action, so the production superset check is not undercut by deletions; the item-count span and its LiveView test work with `audit_log_live_test.exs`'s `create_entry/3`; both new migrations are reversible and sort after REPORT-150's `20261021180000`; two concurrent exports share no row, and the TTL bump is an absolute `SET`, so a retried page racing it converges; every R-number is cited by a step, R9 through "R8 to R12".
