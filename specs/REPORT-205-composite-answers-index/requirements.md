# Composite answers indexes for the class-scoped answers query

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-205
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

The Class Dashboard's answers query times out for long-lived classes because Firestore answers it by merging three single-field indexes. This story adds composite indexes on `answers` that cover that query and the per-student version CLASSDASH-122 will add, and deploys them to report-service-dev and report-service-pro.

## Project Owner Overview

A teacher who has reused one class and one offering since fall 2022 can no longer open the Class Dashboard: the query that loads the class's answers runs for about 58 seconds against a 60-second limit, then fails. The work is not wrong, only slow, because the database has no index shaped for "every answer in this class for this assignment" and has to cross-check three general-purpose indexes, scanning over three million entries to return about fourteen thousand answers.

The fix is two new database indexes and no code change. Once they finish building in production, the same query reads roughly the entries it returns, the dashboard loads, and the Portal Report and Activity Player, which run the same query, get faster too. CLASSDASH-122 then trims the dashboard to the current roster, and the second index keeps that per-student version fast.

## Background

The query, from the story: portal-report's `watchCollection` (`js/actions/index.ts:371`) runs, for a teacher or researcher with no `studentId` param, `platform_id == ? AND resource_link_id == ? AND context_id == ?` on `sources/activity-player.concord.org/answers`. For offering 75098 the story's production `explain` shows three single-field indexes zig-zag merged, 3,204,240 index entries scanned, 13,905 documents returned, 57.7 s. The same three filters with no further filter come from the Activity Player's `getAnswerDocsQuery` (`activity-player/src/firebase-db.ts:208`) whenever the user is not a learner. For a learner it adds `platform_user_id`, and with a `questionId` also `question_id`. It backs `watchAnswerDocs` and `getAnswerDocs`, so it runs on every activity load.

Why nobody added an index: equality-only queries never fail with "requires an index", so the console link that created most of this project's indexes was never offered. The 2026-07-26 index audit (global oob `firestore-index-audit.md`, Rule 1) concluded equality-only queries need no composite, which is true for correctness but not for speed.

**The planner does not use a composite for a strict prefix of its fields.** The story proposes one 4-field index and expects it to serve the 3-field query through its leading fields, with a 3-field fallback "if Firestore doesn't pick" it. Plan-only `explain` probes against report-service-dev on 2026-11-04 (no documents read) settled this before any index was built:

| Probe on `answers` | Composite that exists on dev | Indexes the planner chose |
|---|---|---|
| eq `platform_id, resource_link_id, platform_user_id` | `(platform_id, resource_link_id, platform_user_id, question_id, id)` | three single-field indexes |
| eq `resource_link_id, platform_user_id` | `(resource_link_id, platform_user_id, question_id)` | two single-field indexes |
| eq `resource_link_id, platform_user_id, question_id` | `(resource_link_id, platform_user_id, question_id)` | that composite alone |
| eq `remote_endpoint, question_id` | `(remote_endpoint, question_id)` | that composite alone |
| eq `platform_id, resource_link_id, context_id, platform_user_id, question_id` | (as above) | `(resource_link_id, platform_user_id, question_id)` + `(question_id, platform_id)` + `(context_id)` |
| eq `platform_id, resource_link_id, context_id` + `platform_user_id in [2 values]` | none covering it | single-field indexes, one `platform_user_id` scan per `in` value |
| eq `resource_link_id, question_id` + `platform_user_id in [2 values]` | `(resource_link_id, platform_user_id, question_id)` | that composite, once per value |

An equality-only query returns documents in `__name__` order, so it can use an index only where every field before `__name__` is pinned by an equality filter. A prefix leaves the trailing field unpinned and the entries out of `__name__` order. The 4-field index alone would therefore leave the dashboard's query exactly as slow as it is now, and the story's fallback is required, not optional. The last two rows show that an `in` filter runs as one branch per value, each an equality query that uses an exact-match composite when one exists (even with the `in` field in the middle of it), so CLASSDASH-122's branches each pin all four fields and can use the 4-field index.

## Requirements

- **R1.** `firestore.indexes.json` gains two collection-scoped `answers` indexes, all fields ascending:
  - `platform_id, resource_link_id, context_id`
  - `platform_id, resource_link_id, context_id, platform_user_id`
- **R2.** No other index or field override in the file changes.
- **R3.** Both indexes are deployed to report-service-dev and reach READY. Plan-only `explain` on dev then shows the 3-field equality query using the 3-field composite alone, and the 4-field equality query using the 4-field composite alone. The 3-field query plus `platform_user_id in [...]` is also probed, expecting the 4-field composite for each branch, and its plan is reported on CLASSDASH-122 whichever way it goes: that check informs CLASSDASH-122 and does not gate the rollout. `explain` with analyze on dev's offering 622 (platform `https://learn.portal.staging.concord.org`), which on 2026-11-04 scanned 4,516 index entries to return 25 documents, then scans about as many entries as it returns.
- **R4.** Both indexes are deployed to report-service-pro and reach READY. Before the deploy, production's live indexes and field overrides are compared with the file, and the deploy goes ahead only if the file's only entries missing from production are the two new indexes and the field overrides match. Anything else the file has and production lacks stops the deploy until Doug decides it. Indexes production has and the file lacks are listed in the record and left alone, since a `--non-interactive` deploy deletes nothing without `--force`. The same comparison runs before the dev deploy, where dev's three untracked indexes are the expected live-only entries. Every production command, read-only ones included, waits for Doug's approval.
- **R5.** After R4, `explain` with analyze on offering 75098's 3-field query in production shows the 3-field composite in use, index entries scanned of the same order as documents returned (not millions), and an execution time well under the 60 s deadline. The figures are recorded on the story. The probe prints only the explain metrics, never the returned documents, which are student answers.
- **R6.** The Class Dashboard for offering 75098's class loads, opened by Doug as a portal admin in researcher mode.
- **R7.** `functions/README.md`'s Indexes section says that an equality-only query never asks for an index but can still need one for speed, that such a query never uses a composite with a field it does not pin by equality, and that only a composite with exactly its equality fields serves it alone. The section's new-query-shape paragraph stops saying that every new shape fails without an index, and the release checklist's bullet stops implying that every new shape has one.

## Technical Notes

- **Deploying indexes.** `firebase deploy --only firestore:indexes` creates every index and field override the file lists that the project lacks, not only the new ones, which is why R4 compares first. That includes a field override whose `ttl` differs: the file's `ttl: false` entries would clear a live TTL policy (`fieldMatchesSpec`, `patchField`). With `--force` it also deletes every deployed index the file omits; dev has three expected untracked indexes, so `--force` is never used. Without `--force` an interactive run asks whether to delete them and deletes on a yes; `--non-interactive` skips the question and deletes nothing (firebase-tools 15.24.0, `lib/firestore/api.js`, the `shouldDeleteIndexes` and `shouldDeleteFields` branches). `--dry-run` runs only the prepare phase (`lib/deploy/index.js`), so it parses the file as JSON but neither checks the entries (`validateSpec` runs in the deploy phase) nor shows a plan of what it would create. Even with `--only firestore:indexes` the prepare phase compiles `firestore.rules` (it does not release them), so a rules file that fails to compile blocks the index deploy.
- **Rollback.** Removing an index from the file and redeploying does not delete it unless run with `--force` or answered yes at the interactive prompt, and either deletes every other live-only index too (dev's three). To back out, delete the index in the console or with `gcloud firestore indexes composite delete`, then remove it from the file. Run no index deploy until that file change is merged, since a deploy from the old file recreates the index. Queries fall back to today's single-field merge.
- **Build.** A new index builds in the background over the whole `answers` collection. Reads and writes carry on, and queries keep their current plan until the index is READY. Production's build will take much longer than dev's; no estimate is measured.
- **READY check.** `gcloud firestore indexes composite list --project <p>` reports state. `firebase firestore:indexes` does not. gcloud's user login here had expired on 2026-11-04 (ADC still worked), so the check may need `gcloud auth login` first.
- **Write cost.** Each answer write that has all of an index's fields adds one entry per index; documents missing a field get none. Anonymous `run_key` answers omit `platform_id`, `resource_link_id` and `context_id` (`activity-player/src/firebase-db.ts:582`) rather than setting them to `null`, which would count as present. `move_student_work` rewrites `context_id`, which just moves the entries.
- **Value types.** `platform_user_id` and `resource_link_id` are strings on Activity Player answers (repo oob `answer-data-notes.md`). The index is type-agnostic, but CLASSDASH-122's `in` values must be strings to match.
- **Explain tooling.** `explain` needs `@google-cloud/firestore` 7.5.0 or later (7.4.0 lacks it); the installed 4.15.1 lacks it. The probes used 7.11.6 installed in a scratch directory, with ADC. Plan-only `explain()` reads no documents (Firestore's pricing bills it as one read) and returns `metrics.planSummary.indexesUsed`. `explain({analyze: true})` executes the query and adds `metrics.executionStats` (`resultsReturned`, `executionDuration`, and `debugStats.index_entries_scanned` as a string), and also returns the documents in `snapshot`.
- **Comparing live indexes with the file.** `firebase firestore:indexes --project <p>` prints the live indexes and field overrides in the file's format, with a trailing `__name__` field on each index that the file omits. A deploy compares that field too, so the comparison adds it to the file's indexes in the direction of their last ordered field rather than stripping it from the listing. Diffing as sets works: on 2026-11-04 dev against the file plus the two new entries gave exactly the two new indexes as file-only, dev's three untracked indexes (`answers(resource_url, platform_id, resource_link_id, platform_user_id, run_key, id)` and the two `answers_async(updated, resource_url, ...)`) as live-only, and identical field overrides. On 2026-11-05 firebase-tools' own `validateSpec`, `indexMatchesSpec` and `fieldMatchesSpec`, run against dev's live listing, agreed: two indexes to create, nothing to patch.
- **Index audit branch.** `chore/firestore-index-audit-followup` (32da37d) edits the `answers` entries of the same file but touches neither new index, so whichever lands second resolves a textual conflict only. One probe above bears on it: the learner query with `question_id` currently uses `answers(resource_link_id, platform_user_id, question_id)`, which the audit lists as a Medium-confidence dead index. Deleting it would not break that query, but would change its plan.

## Out of Scope

- The portal-report change that limits the dashboard to the current roster (CLASSDASH-122), and any SDK upgrade.
- Indexes for `interactive_state_histories` and the feedback collections under CLASSDASH-122's `in` query.
- Merging or deploying anything from the index audit branch, and deleting any existing index.
- A test asserting the file contains the new entries: it would be true by construction. The `explain` checks are the verification.
- A synthetic key field (for example `platform_id#resource_link_id#context_id`) served by a single-field index: every writer of answers (the Activity Player, `import_run`, `move_student_work`, the collaborator copies) would have to set it, millions of existing documents would need a backfill, and both client queries would change.
- Exempting `platform_id`, `resource_link_id` or `context_id` from single-field indexing to offset the write cost: equality-only queries with no exact composite rely on those indexes, among them the auto-importer's learner and collaborator lookups (`functions/src/auto-importer.ts:351-354`, `487-489`), which would fail.
- Verifying in the Firestore emulator: it does not enforce composite indexes and runs any valid query, so it cannot show which index a query uses.

## Open Questions

### RESOLVED: Judgment call: one 4-field index, or both the 3-field and the 4-field?
**Context**: The story proposes the 4-field index and the 3-field one only as a fallback.
**Options considered**:
- A) 4-field only, as the story's main proposal
- B) Both, deployed together
- C) 3-field only, leaving CLASSDASH-122's query to merge it with the `platform_user_id` single-field index

**Decision**: B. The dev probes show the planner never uses a composite for a strict prefix, so A leaves the dashboard query unchanged and needs a second production build later. C serves today's query but leaves the per-student branches and the Activity Player learner query on a merge, when the story wants an exact match for them.

### RESOLVED: Judgment call: document the rule in the README?
**Context**: Equality-only queries never prompt for an index, which is why nobody added this one.
**Options considered**:
- A) Spec only
- B) A paragraph in `functions/README.md`'s Indexes section (R7)

**Decision**: B. The README is where an engineer adding a query looks, and its current text says only when an index is required.

### RESOLVED: Judgment call: what if the `in` branches do not use the 4-field index on dev?
**Context**: R3's `in` check can only run once the index exists.
**Options considered**:
- A) Block the story until CLASSDASH-122's query is understood
- B) Keep the index, report the plan on CLASSDASH-122, carry on

**Decision**: B. The 4-field index is also an exact match for the Activity Player learner query, the same shape as the full-match probes that did use their composite, so it earns its place either way. The `in` result is CLASSDASH-122's input.

### RESOLVED: Low confidence: who confirms the Class Dashboard loads for offering 75098 (R6)?
**Context**: The class belongs to a production teacher.
**Options considered**:
- A) Doug opens it as a portal admin
- B) Ask the reporter (Scott) or the teacher in #portal-lara to confirm
- C) Treat R5's measured query time as sufficient and drop R6

**Decision**: A, in researcher mode. portal-report passes `researcher=true` through to the portal's JWT request (`portal-report/js/api.ts:168-171`), and the portal grants a researcher token for any class to an admin (`rigse` `User#researcher_clazz_ids` returns every id for the `admin` role). The rules' `researcherOfContext` then allows the read, and the dashboard runs the same 3-field answers query for a researcher as for a teacher. B remains the fallback if the researcher view fails for a reason unrelated to the query.

## Self-Review

### Operator

#### RESOLVED: A production index deploy creates everything the file lists, not just the new indexes
firebase-tools creates every index and field override the file has and the project lacks. If production has drifted from `master`'s file, R4's deploy would carry unreviewed changes with it. R4 now stops on any difference beyond the two new indexes, and the Technical Notes say why.

#### RESOLVED: `--dry-run` does not preview an index deploy
It runs only the prepare phase (`lib/deploy/index.js`), which parses the file and computes no plan. The Technical Notes no longer imply it is a preview; R4's live comparison is the preview.

#### RESOLVED: No rollback path was stated
Removing an index from the file deletes nothing without `--force`. Added a Rollback note: delete through the console or gcloud, then remove the entry from the file.

#### RESOLVED: The rollback note said only `--force` deletes
firebase-tools also deletes on a yes at the interactive prompt (`lib/firestore/api.js`), and either path deletes every live-only index, which on dev includes the three untracked ones. The Rollback note says so.

#### RESOLVED: A deploy during a rollback recreates the index
Found by an outside review. Between deleting an index and merging its removal from the file, a deploy creates it again. The Rollback note now rules out index deploys in that window.

#### RESOLVED: R3 made the `in` plan a requirement the plan lets fail
The decision on the `in` branches and the dev step carry on if it does not use the 4-field index, which would leave R3 unmet. R3 now requires the two equality-only plans and only reports the `in` plan.

#### RESOLVED: R4 still said only `--force` deletes
Its reason for leaving live-only indexes alone contradicted the Deploying and Rollback notes, since an interactive deploy also deletes on a yes. R4 now scopes the claim to a `--non-interactive` deploy, which is what both deploy steps run.

---

### Security Engineer

#### RESOLVED: The production `explain` with analyze returns student answers
In the Node client an analyze run returns the result documents as well as the metrics, about 66 MB of student work for offering 75098. R5 now requires the probe to print metrics only.

---

### Firestore Engineer

#### RESOLVED: The `in` claim was inferred, not probed
The `in` row showed only single-field scans, since no composite covered it. A plan-only probe of `in` against dev's existing `(resource_link_id, platform_user_id, question_id)` showed that composite used once per value, with the `in` field in the middle; added as a table row.

#### RESOLVED: R7 said a composite helps only with exactly the query's fields
The 5-field probe used composites on a subset of its equality fields in a merge. R7 now says an extra unpinned field rules a composite out, and only an exact match serves the query alone.

#### RESOLVED: `explain` is not in every 7.x client
`Query.explain` first appears in `@google-cloud/firestore` 7.5.0 (7.0.0, 7.3.0 and 7.4.0 have none in their published type definitions). The Technical Note now says 7.5.0.

#### RESOLVED: R7's rule read as true of every query
"Firestore never uses a composite with a field the query does not pin" is false for `orderBy` queries, which the README paragraph just above it describes: on dev, eq `resource_url` ordered by `id` uses `(resource_url, id)`. R7 and the README text now scope the rule to equality-only queries.

---

### Commit Reviewer

#### RESOLVED: The audit branch note carried a live status
"Unmerged" goes stale without anyone touching the spec. The note now names the branch and commit only; "whichever lands second" already covers either order.
