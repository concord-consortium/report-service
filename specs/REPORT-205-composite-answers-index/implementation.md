# Implementation Plan: Composite answers indexes for the class-scoped answers query

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-205
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Two commits change the repo; the rest is operations. The dev deploy runs from the branch before the PR, because dev's results feed CLASSDASH-122 and the PR. The production deploy runs from `master` after merge, one approved command at a time.

### Add the two answers indexes

**Summary**: R1 and R2. The only change to `firestore.indexes.json`.

**Files affected**:
- `firestore.indexes.json`: two entries inserted before the first `answers` entry

**Estimated diff size**: ~40 lines

The file is ordered by collection, then by field list as `firebase firestore:indexes` prints it. `context_id` sorts before `platform_user_id`, so both new entries go first among the `answers` entries, 3-field before 4-field:

```json
    {
      "collectionGroup": "answers",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "platform_id", "order": "ASCENDING" },
        { "fieldPath": "resource_link_id", "order": "ASCENDING" },
        { "fieldPath": "context_id", "order": "ASCENDING" }
      ]
    },
    {
      "collectionGroup": "answers",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "platform_id", "order": "ASCENDING" },
        { "fieldPath": "resource_link_id", "order": "ASCENDING" },
        { "fieldPath": "context_id", "order": "ASCENDING" },
        { "fieldPath": "platform_user_id", "order": "ASCENDING" }
      ]
    },
```

Shown compact; write each field object over four lines like the rest of the file. Nothing else in the file changes (`git diff --stat` shows insertions only). Check, from the repo root with Node 22 on `PATH`:

```bash
functions/node_modules/.bin/firebase deploy --only firestore:indexes --project report-service-dev --non-interactive --dry-run
```

It ends `Dry run complete!` and deploys nothing, which shows only that the file is JSON and the rules compile (requirements, Technical Notes). The entries are checked by the dev comparison, then by `validateSpec` at the start of the deploy, before anything is created. A fresh worktree has no `functions/node_modules`, so run `npm ci` in `functions/` first; every `firebase` command in this plan means that binary.

---

### Document when an equality-only query needs a composite index

**Summary**: R7. One new paragraph in `functions/README.md`'s Indexes section, after the paragraph ending "and those have to be declared.", and two existing lines reworded.

**Files affected**:
- `functions/README.md`

**Estimated diff size**: ~11 lines

```markdown
A query with only `==` filters never fails for want of a composite index: Firestore merges the
single-field indexes instead. On a large collection that merge can scan far more entries than it
returns, and slow enough to hit the query deadline. Such a query never uses a composite index with
a field it does not pin with `==`, and only one whose fields are exactly its equality fields serves
it alone. To see which indexes a slow query uses and how many entries it scans, run it
with `explain({ analyze: true })` from `@google-cloud/firestore` 7.5.0 or later.
```

The paragraph starting "A release that adds a new query shape" would otherwise contradict this one, so its first sentence becomes "A release that adds a query shape needing a composite index has to add it to the file."

The release checklist's bullet "if the release adds a new query shape, deploy its index too" assumes the same thing, so its opening becomes "if the release adds a composite index, deploy it too", keeping the command and the link.

---

### Tools for the deploys and checks (not committed)

**Summary**: Two throwaway scripts, set up once in a scratch directory outside the repo. They are not committed: the repo's `@google-cloud/firestore` is 4.15.1, which has no `explain`, and both scripts exist to produce figures for the story, not to be maintained.

```bash
mkdir -p <scratch>/rs205 && cd <scratch>/rs205 && npm init -y >/dev/null && npm install @google-cloud/firestore@7.11.6
```

The `firebase` binary is `functions/node_modules/.bin/firebase` from `npm ci` in `functions/`, in this worktree for dev and in the `master` checkout for production. The scripts need Node 22 and ADC (`gcloud auth application-default login` if `gcloud auth application-default print-access-token` fails). Both scripts and the live listings stay in `<scratch>/rs205`: the steps below run from the repo root, so they name that path, and the repo's `.gitignore` does not cover the listings.

`explain-answers.js` runs the class-scoped answers query, plan-only by default, and prints metrics only. Run against dev on 2026-11-04 in all three modes:

```js
// Usage: node explain-answers.js <project> <platform_id> <resource_link_id> <context_id> [--analyze] [--user <id>] [--in <id>,<id>...]
const {Firestore} = require("@google-cloud/firestore");
const [project, platformId, resourceLinkId, contextId, ...rest] = process.argv.slice(2);
const analyze = rest.includes("--analyze");
const userAt = rest.indexOf("--user");
const inAt = rest.indexOf("--in");
let q = new Firestore({projectId: project}).collection("sources/activity-player.concord.org/answers")
  .where("platform_id", "==", platformId)
  .where("resource_link_id", "==", resourceLinkId)
  .where("context_id", "==", contextId);
if (userAt >= 0) {
  q = q.where("platform_user_id", "==", rest[userAt + 1]);
}
if (inAt >= 0) {
  q = q.where("platform_user_id", "in", rest[inAt + 1].split(","));
}
q.explain({analyze}).then(({metrics}) => {
  console.log("indexes used:");
  for (const i of metrics.planSummary.indexesUsed) {
    console.log("  " + i.properties);
  }
  const s = metrics.executionStats;
  if (s) {
    const ms = Number(s.executionDuration.seconds) * 1000 + s.executionDuration.nanoseconds / 1e6;
    console.log(`results returned: ${s.resultsReturned}`);
    console.log(`index entries scanned: ${s.debugStats.index_entries_scanned}`);
    console.log(`execution time: ${ms.toFixed(0)} ms`);
  }
}).catch(e => {
  console.error(e.message);
  process.exit(1);
});
```

`compare-indexes.py` diffs a live index listing against the file the way a deploy does: it gives each file index the trailing `__name__` a deploy adds, in the direction of its last ordered field, and compares the full field list plus `apiScope`, `density` and `multikey` with firebase-tools' defaults (`processIndex`, `indexMatchesSpec`). It compares each override's `ttl` as well as its indexes, since a deploy rewrites an override whose `ttl` differs. Run against dev's listing on 2026-11-05 (requirements, Technical Notes):

```python
import json, sys
live, filed = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
def fields(i):
    fs = [(f["fieldPath"], f.get("order") or f.get("arrayConfig")) for f in i["fields"]]
    if fs[-1][0] != "__name__":
        fs.append(("__name__", next((o for _, o in reversed(fs) if o in ("ASCENDING", "DESCENDING")), "ASCENDING")))
    return tuple(fs)
def idx(d):
    return {(i["collectionGroup"], i["queryScope"], i.get("apiScope", "ANY_API"),
             i.get("density", "SPARSE_ALL"), i.get("multikey", False), fields(i))
            for i in d["indexes"]}
def ov(d):
    return {(o["collectionGroup"], o["fieldPath"]): (o.get("ttl", False), sorted(json.dumps(x, sort_keys=True) for x in o.get("indexes", [])))
            for o in d.get("fieldOverrides", [])}
L, F = idx(live), idx(filed)
for t in sorted(F - L): print("FILE ONLY ", t)
for t in sorted(L - F): print("LIVE ONLY ", t)
lo, fo = ov(live), ov(filed)
for k in sorted(set(lo) | set(fo)):
    if lo.get(k) != fo.get(k): print("OVERRIDE DIFFERS", k)
```

The READY check reads the Firestore Admin API with ADC, which worked on 2026-11-04 while gcloud's user login had expired. The endpoint lists every collection group's indexes despite the `answers` in its path, so the filter keeps only the two new ones, by their exact field lists and ascending order, and prints `MISSING` for either that does not exist:

```bash
curl -sS --fail -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "x-goog-user-project: <project>" \
  "https://firestore.googleapis.com/v1/projects/<project>/databases/(default)/collectionGroups/answers/indexes" \
  | python3 -c '
import json, sys
want = ["platform_id,resource_link_id,context_id", "platform_id,resource_link_id,context_id,platform_user_id"]
found = {}
for i in json.load(sys.stdin)["indexes"]:
    f = ",".join(x["fieldPath"] for x in i["fields"] if x["fieldPath"] != "__name__")
    asc = all(x.get("order") == "ASCENDING" for x in i["fields"])
    if "/collectionGroups/answers/" in i["name"] and i["queryScope"] == "COLLECTION" and asc and f in want:
        found[f] = i["state"]
for f in want:
    print(found.get(f, "MISSING"), f)'
```

`gcloud firestore indexes composite list --project <project>` shows the same once logged in.

---

### Deploy and verify on report-service-dev

**Summary**: R3. Runs on the branch after the two commits, from the repo root, with the functions' firebase-tools (`functions/node_modules/.bin/firebase`, 15.24.0) and Node 22.

1. Compare: `firebase firestore:indexes --project report-service-dev > <scratch>/rs205/dev-live.json`, then `python3 <scratch>/rs205/compare-indexes.py <scratch>/rs205/dev-live.json firestore.indexes.json`. Expected: the two new indexes as `FILE ONLY`, dev's three untracked indexes as `LIVE ONLY`, no `OVERRIDE DIFFERS`. Anything else stops here.
2. Deploy: `firebase deploy --only firestore:indexes --project report-service-dev --non-interactive`. Never `--force`. The log notes the three live-only indexes and leaves them.
3. Wait for both to show `READY` in the READY check (`CREATING` while building). `NEEDS_REPAIR` means the build failed and `MISSING` that the index was not created: stop and take it to Doug.
4. Plan and measure with `node <scratch>/rs205/explain-answers.js report-service-dev https://learn.portal.staging.concord.org 622 00e009be2b4782b5aecd7a20cbbf6fff4acff076af96566b`, adding the flags:

| Run | Before (2026-11-04) | Expected after |
|---|---|---|
| `--analyze` | three single-field indexes; 25 returned, 4,516 entries scanned | `(platform_id ASC, resource_link_id ASC, context_id ASC, __name__ ASC)` alone; entries scanned about 25 |
| `--user 81` | four single-field indexes | the 4-field composite alone |
| `--in 81,82` | single-field indexes, one `platform_user_id` scan per value | the 4-field composite, once per value |

If the 3-field or 4-field run does not use its composite, stop: the requirements' premise is wrong and the story goes back to Doug. If only the `--in` run does not, carry on (requirements, judgment call on the `in` branches).

5. Comment on CLASSDASH-122 with the `--in` plan, whichever way it went, and that the answers indexes are on dev.

---

### Deploy and verify on report-service-pro

**Summary**: R4 to R6. After the PR merges, from an up-to-date `master` checkout. **Each numbered command is shown to Doug and run only on his go**, read-only ones included.

1. Compare: `firebase firestore:indexes --project report-service-pro > <scratch>/rs205/pro-live.json`, then `python3 <scratch>/rs205/compare-indexes.py <scratch>/rs205/pro-live.json firestore.indexes.json`. Go on only if `FILE ONLY` lists exactly the two new indexes and there is no `OVERRIDE DIFFERS`. List every `LIVE ONLY` entry in the record; they are left alone.
2. Deploy: `firebase deploy --only firestore:indexes --project report-service-pro --non-interactive`.
3. Poll the READY check against `report-service-pro` until both show `READY`. The build covers the whole production `answers` collection; check back hourly rather than watching. `NEEDS_REPAIR` means the build failed and `MISSING` that the index was not created: stop and take it to Doug. If either is still `CREATING` 24 hours after the deploy, record the states and take it to Doug; that limit is a point to decide, not a measured build time, and the build carries on meanwhile.
4. Get the class hash: in the browser console of a `learn.concord.org` tab signed in as an admin, run `fetch("/api/v1/offerings/75098?researcher=true").then(r => r.json()).then(o => console.log(o.clazz_id, o.clazz_hash))` (`rigse` `Api::V1::Offering`). Print only those two fields: `researcher=true` anonymizes student names, but the response still carries each student's username, user id, return URL and progress. This avoids reading it off an answer document, whose `context_id` `move_student_work` may have rewritten.
5. Measure: `node <scratch>/rs205/explain-answers.js report-service-pro https://learn.concord.org 75098 <clazz_hash> --analyze`. Expected: the 3-field composite alone, entries scanned of the order of results returned (13,905 when the story was written), execution time well under 60 s. The script prints metrics only, never documents (R5).
6. Dashboard (R6): open `https://learn.concord.org/portal/classes/<clazz_id>/materials?researcher=true`, then the offering's Class Dashboard, which is listed there only if that report has `supports_researchers`. It loads without the `RECEIVE_ANSWERS` deadline error. If the researcher view fails for an unrelated reason, ask Scott to confirm with the teacher instead.
7. Record on REPORT-205: the plan, entries scanned and execution time from 5, next to the story's 3,204,240 and 57.7 s; any `LIVE ONLY` entries from 1; and the dashboard result.

## Open Questions

### RESOLVED: Judgment call: commit the probe and compare scripts, or keep them throwaway?
**Context**: Both are needed again for production, and possibly for CLASSDASH-122.
**Options considered**:
- A) Commit them under `scripts/` with `@google-cloud/firestore` 7 as a dependency
- B) Keep them in the spec, set up in a scratch directory

**Decision**: B. Committing means a second Firestore client version in the repo and code nothing tests, for a one-off measurement. The spec holds both in full, run as written against dev.

### RESOLVED: Judgment call: deploy to dev before the PR or after merge?
**Context**: The story wants the index on `master` and READY in both projects.
**Options considered**:
- A) Everything after merge
- B) Dev from the branch before the PR, production from `master` after merge

**Decision**: B. Dev's plans prove the premise before review, give the PR measured figures, and unblock CLASSDASH-122. An index on dev that the PR later drops costs nothing; production only ever gets what `master` has.

### RESOLVED: Judgment call: READY check through the REST API or gcloud?
**Context**: gcloud's user login had expired on 2026-11-04, and `firebase firestore:indexes` shows no state.
**Options considered**:
- A) `gcloud firestore indexes composite list`, after `gcloud auth login`
- B) The Admin REST endpoint with ADC

**Decision**: B as the written command, since it was run and needs no interactive login; A named as the equivalent.

## Self-Review

### Commit Reviewer

#### RESOLVED: The plan's firebase binary does not exist in a fresh worktree
Every `firebase` command names `functions/node_modules/.bin/firebase` (15.24.0), but this worktree has no `functions/node_modules`; only the main checkout does. Added `npm ci` in `functions/` as the prerequisite, for the branch and for the `master` checkout used in production.

#### RESOLVED: The new README paragraph contradicted one below it
The Indexes section says a release's new query shape "needs its index" and otherwise fails at runtime, which the new paragraph shows is untrue of equality-only shapes. R7 and the README step now reword that sentence.

#### RESOLVED: The release checklist kept the same assumption
`functions/README.md:135`, above the Indexes section, tells a release with a new query shape to "deploy its index too", though an equality-only shape may have none. R7 and the README step now reword that bullet as well.

---

### Operator

#### RESOLVED: The READY check printed indexes from other collections
`collectionGroups/answers/indexes` returned all 30 of dev's indexes, every collection group, so `grep context_id` would also print five already-READY `ap_runs`, `interactive_state_histories` and `object_store_metadata` indexes. The filter now matches the collection group and the two new field lists (run against dev: `MISSING` for both before the deploy).

#### RESOLVED: The comparison could not see a `ttl` difference
`compare-indexes.py` dropped `ttl`, so a listing with `ttl: true` on `answers_async.updated` passed clean, while a deploy would patch that override and clear the TTL policy. The script now compares `ttl` (the same altered listing prints `OVERRIDE DIFFERS`).

#### RESOLVED: The steps ran the scratch scripts from the repo root
`python3 compare-indexes.py` and `node explain-answers.js` both fail there, and `> dev-live.json` left an unignored file in the repo. The steps now name `<scratch>/rs205/` for all of them.

#### RESOLVED: `--dry-run` was credited with validating the index file
`prepareIndexes` only loads the JSON and `validateSpec` runs in the skipped deploy phase: a misspelled `order` passes `loadCJSON` and fails `validateSpec`. The notes and the check now claim only that the file parses and the rules compile.

#### RESOLVED: The READY wait had no exit for a failed build
Index state can also be `NEEDS_REPAIR` (firebase-tools `api-types`), so "wait until `READY`" would never end. Both READY steps now stop on it.

#### RESOLVED: The Research Classes route may not reach this class
Its nav link needs a project role, and it lists only classes whose teacher is in a cohort of that project (`research_project_links`, `classes_query`), while a portal admin passes `materials?` for any class. Production step 6 now opens the materials URL directly, using `clazz_id` from step 4.

---

### Security Engineer

#### RESOLVED: The class-hash lookup showed a production class's student names
`Api::V1::OfferingsController#show` anonymizes students only for `researcher=true` or a user without full access, and an admin has full access. Production step 4 now adds `?researcher=true`; `clazz_hash` is unchanged by it.

---

### Outside Reviewer

#### RESOLVED: The comparison could not see an index that differs only in `__name__`
It dropped `__name__`, but a deploy compares the whole field list (`indexMatchesSpec`), and 5 of dev's 30 indexes end in `__name__ DESCENDING`. The script now adds `__name__` to file indexes as `processIndex` does, and compares `apiScope`, `density` and `multikey` too.

#### RESOLVED: `researcher=true` hides names, not all student data
`Api::V1::Offering` still returns each student's `username`, `user_id`, `endpoint_url` and progress. Production step 4 now fetches in the browser console and prints only `clazz_id` and `clazz_hash`.

#### RESOLVED: The READY check could mislead, and its wait had no limit
A live-only index starting with the same fields would add a line, a missing index printed nothing, and a stuck build could be polled forever. The filter now matches the exact field lists, prints `MISSING`, and `curl` fails on an HTTP error; production stops at 24 hours for Doug to decide.

#### RESOLVED: The READY filter ignored sort direction
A live-only variant of the same fields in another direction could overwrite the target's state and report `READY` early. The filter now requires every field, `__name__` included, to be ascending.
