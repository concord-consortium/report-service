# Deploy checklist — REPORT-76 cc-data bulk read + attachment API

These steps run against the **live** target project (not the emulator). Emulator green does **not** prove
real-project coverage: the emulator serves the history query with no composite index, and the dev/pro projects
carry only `context_id`-prefixed indexes that cannot serve this walker's `context_id`-less query.

## 1. Firestore composite index for the history query (blocking for `/history`)

The `/history` walker queries `interactive_state_histories` filtered by
`(platform_id, platform_user_id, resource_link_id)` and ordered by `created_at`, with **no `context_id`
equality**. It needs a composite index whose leading fields are exactly those three equality fields followed by
`created_at` (with `__name__` appended automatically). The pre-existing `context_id`-**prefixed** indexes on this
collection do **not** satisfy it — a missing index surfaces as `FAILED_PRECONDITION`.

Verify it exists before exercising `/history`:

```
firebase firestore:indexes --project <project>
# expect a composite on interactive_state_histories:
#   (platform_id ASC, platform_user_id ASC, resource_link_id ASC, created_at ASC)   [__name__ ASC appended]
# NOTE: dev/pro also carry context_id-PREFIXED indexes on this collection — those do NOT satisfy this query.
```

If missing, create it (already done on `report-service-dev` and present on `report-service-pro`, 2026-07-15):

```
gcloud firestore indexes composite create \
  --project=<project> \
  --collection-group=interactive_state_histories \
  --query-scope=COLLECTION \
  --field-config field-path=platform_id,order=ascending \
  --field-config field-path=platform_user_id,order=ascending \
  --field-config field-path=resource_link_id,order=ascending \
  --field-config field-path=created_at,order=ascending
```

(Or use the console, or follow the click-to-create link the first `FAILED_PRECONDITION` query emits.)

Project convention is **manual/console** index management (`firestore.indexes.json` intentionally empty), so this
index is created out-of-band and not tracked in `firestore.indexes.json`.

## 2. Cloud Function timeout + proxy idle timeout

- Registering `/bulk_read` raised the shared `api` function `timeoutSeconds` from 60 → **300** for **every**
  co-located route (`import_run`, `move_student_work`, `get-answer`, …). It is a ceiling, not a cost floor —
  call this out in deploy review.
- Sanity-check the ALB/proxy idle timeout against ~300 s so a legitimately-slow bulk page isn't cut off upstream.

## 3. Migrations

Two new migrations run on deploy:
- `20260714120000_create_export_scratch`
- `20260714120100_add_export_id_to_data_access_log`

## 4. Source-fidelity live validation (the real-data half of the validation milestone)

This cannot be a hermetic controller test (it needs live portal + Firestore). Run once against the target
project before `/answers` + `/history` are exercised for real:

```
# For a KNOWN run + learner with known real answers (fill in the identifiers for the target env):
#   REPORT_RUN_ID=<id>  KNOWN_REMOTE_ENDPOINT=<endpoint>  EXPECT_NONEMPTY=true
# 1. Hit GET /api/v1/reports/:id/answers (page 1) as the run owner.
# 2. Assert the page returns that learner's items (NOT an empty set) — i.e. the SourceKey-derived `source`
#    matches the Firestore `sources/{source}` where their answers actually live.
# PASS -> URL-derived source fidelity confirmed for this env's real runs.
# FAIL/empty -> the URL-derived `source` diverges from the answer's authoritative `source_key`
#    (rehosted/migrated activity or per-question source_key); do NOT ship /history for that class until reconciled.
```

## 5. Attachment endpoint (POST /reports/:id/attachments)

- The `report-server-*` IAM already grants `s3:GetObject` on `<private-bucket>/interactive-attachments/*` in both
  accounts (added for audio transcription), and `TOKEN_SERVICE_PRIVATE_BUCKET` already selects the per-env
  private bucket — **no new infra or IAM**. Confirm both are set for the target env.
- The real S3 presign → GET path is not unit-testable (needs live creds + the private bucket); it was validated
  once on staging (2.9 MB CODAP fetch, 2026-07-15).
