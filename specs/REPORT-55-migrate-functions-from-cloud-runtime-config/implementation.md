# Implementation Plan: Migrate Firebase Functions from Cloud Runtime Config

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-55
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **Implemented — Pending Deploy**

## Implementation Plan

### Migrate auto-importer.ts from functions.config() to params API

**Summary**: Replace all `functions.config().aws.*` calls in the auto-importer with `defineString`/`defineSecret` params and bind AWS secrets to `syncToS3AfterSyncDocWritten` via `runWith`. This is the largest code change — 3 of the 4 config values live here.

**Files affected**:
- `functions/src/auto-importer.ts` — Replace config calls, add runWith

**Estimated diff size**: ~20 lines

**Changes**:

Add import (after line 7):
```typescript
// Before:
import * as functions from "firebase-functions";

// After:
import * as functions from "firebase-functions";
import { defineString, defineSecret } from "firebase-functions/params";
```

Add param definitions (after the imports, around line 22):
```typescript
const s3Bucket = defineString("AWS_S3_BUCKET");
const awsKey = defineSecret("AWS_KEY");
const awsSecretKey = defineSecret("AWS_SECRET_KEY");
```

Replace `s3Client()` (lines 163-170):
```typescript
// Before:
// gets AWS creds from firebase config.
const s3Client = () => new S3Client({
  region,
  credentials: {
    accessKeyId: functions.config().aws.key,
    secretAccessKey: functions.config().aws.secret_key,
  }
});

// After:
const s3Client = () => new S3Client({
  region,
  credentials: {
    accessKeyId: awsKey.value(),
    secretAccessKey: awsSecretKey.value(),
  }
});
```

Replace `syncToS3` bucket reference (line 205):
```typescript
// Before:
Bucket: functions.config().aws.s3_bucket,

// After:
Bucket: s3Bucket.value(),
```

Replace `deleteFromS3` bucket reference (line 234):
```typescript
// Before:
Bucket: functions.config().aws.s3_bucket,

// After:
Bucket: s3Bucket.value(),
```

Add `runWith` to `syncToS3AfterSyncDocWritten` (line 456):
```typescript
// Before:
export const syncToS3AfterSyncDocWritten = functions.firestore
  .document(`${answersSyncPathAllSources}/{id}`)
  .onWrite((change, context) => {

// After:
export const syncToS3AfterSyncDocWritten = functions
  .runWith({ secrets: [awsKey, awsSecretKey] })
  .firestore
  .document(`${answersSyncPathAllSources}/{id}`)
  .onWrite((change, context) => {
```

Note: `createSyncDocAfterAnswerWritten` and `monitorSyncDocCount` remain unchanged — they don't access secrets.

**Guardrail**: `s3Client()` calls `awsKey.value()` / `awsSecretKey.value()`, so it must never be called at module load time or from any function that doesn't bind those secrets via `runWith`. Currently it's only reachable from `syncToS3()` and `deleteFromS3()`, which are only called from `syncToS3AfterSyncDocWritten` — this is correct. Future maintainers must preserve this invariant.

---

### Migrate bearer-token-auth.ts and index.ts

**Summary**: Replace `functions.config().auth` with a `defineSecret` param in the bearer token middleware. The key structural change is moving secret access from module scope into the per-request handler. Then wire up `runWith` on the API function in `index.ts`.

**Files affected**:
- `functions/src/middleware/bearer-token-auth.ts` — Replace config, restructure, export param
- `functions/src/index.ts` — Import param, add runWith to API function

**Estimated diff size**: ~25 lines

**Changes to `bearer-token-auth.ts`**:

Full file rewrite (46 lines → ~46 lines):
```typescript
// Before:
import express from "express"
import * as functions from "firebase-functions"

// extracted from https://raw.githubusercontent.com/tkellen/js-express-bearer-token/master/index.js

export default function (req: express.Request, res: express.Response, next: express.NextFunction) {
  let clientBearerToken: string|null = null;

  // no bearer token required for index page, it is the documentation
  if (req.path === "/") {
    next()
    return
  }

  const authConfig = functions.config().auth
  const serverBearerToken = authConfig && authConfig.bearer_token
  if (!serverBearerToken) {
    res.error(500, "No bearer_token set in Firebase auth config!")
    return
  }

  // ... rest unchanged ...
}

// After:
import express from "express"
import { defineSecret } from "firebase-functions/params"

// extracted from https://raw.githubusercontent.com/tkellen/js-express-bearer-token/master/index.js

export const bearerToken = defineSecret("AUTH_BEARER_TOKEN");

export default function (req: express.Request, res: express.Response, next: express.NextFunction) {
  let clientBearerToken: string|null = null;

  // no bearer token required for index page, it is the documentation
  if (req.path === "/") {
    next()
    return
  }

  const serverBearerToken = bearerToken.value()
  if (!serverBearerToken) {
    res.error(500, "No AUTH_BEARER_TOKEN secret set!")
    return
  }

  // ... rest unchanged ...
}
```

Key changes:
- `import * as functions from "firebase-functions"` → `import { defineSecret } from "firebase-functions/params"`
- `bearerToken` param defined at module scope but `.value()` called inside handler (required by `defineSecret` constraint)
- Named export `bearerToken` so `index.ts` can import it for `runWith`
- Error message updated to reference new param name

**Changes to `index.ts`**:

Update import (line 6):
```typescript
// Before:
import bearerTokenAuth from "./middleware/bearer-token-auth"

// After:
import bearerTokenAuth, { bearerToken } from "./middleware/bearer-token-auth"
```

Add `runWith` to API function (line 61):
```typescript
// Before:
const wrappedApi = functions.https.onRequest( (req: express.Request, res: express.Response) =>  {
  if (!req.path) {
    req.url = `/${req.url}` // prepend '/' to keep query params if any
  }
  api(req, res)
})

// After:
const wrappedApi = functions
  .runWith({ secrets: [bearerToken] })
  .https.onRequest( (req: express.Request, res: express.Response) =>  {
    if (!req.path) {
      req.url = `/${req.url}` // prepend '/' to keep query params if any
    }
    api(req, res)
  })
```

---

### Add env files, update gitignore, and create migration script

**Summary**: Create the per-project `.env` files for non-secret config, update `.gitignore` to protect local secret files, and add the migration script for transitioning from `.runtimeconfig.json`.

**Files affected**:
- `functions/.gitignore` — Add `.secret.local` and `.env`
- `functions/.env.report-service-dev` (new) — Staging bucket config
- `functions/.env.report-service-pro` (new) — Production bucket config
- `functions/scripts/migrate-config.sh` (new) — Migration script

**Estimated diff size**: ~60 lines

**Changes to `functions/.gitignore`**:
```diff
 # runtime config (holds environment variables for emulator)
 .runtimeconfig.json
+.env
+.secret.local

 build-info.json
```

**`functions/.env.report-service-dev`** (new file):
```
AWS_S3_BUCKET=concord-staging-report-data
```

**`functions/.env.report-service-pro`** (new file):
```
AWS_S3_BUCKET=concord-report-data
```

**`functions/scripts/migrate-config.sh`** (new file — create `scripts/` directory first):
```bash
#!/bin/bash
# Migrates .runtimeconfig.json to .env + .secret.local for local emulator development.
# Run from the functions/ directory.
#
# Usage: bash scripts/migrate-config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FUNCTIONS_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$FUNCTIONS_DIR/.runtimeconfig.json"
ENV_FILE="$FUNCTIONS_DIR/.env"
SECRET_FILE="$FUNCTIONS_DIR/.secret.local"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: $CONFIG_FILE not found." >&2
  echo "Generate it with: firebase functions:config:get > .runtimeconfig.json" >&2
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE already exists. Delete it first to re-run." >&2
  exit 1
fi

if [ -f "$SECRET_FILE" ]; then
  echo "Error: $SECRET_FILE already exists. Delete it first to re-run." >&2
  exit 1
fi

# Parse values from .runtimeconfig.json using node (available in functions/ context)
read_config() {
  node -e "
    const config = require('$CONFIG_FILE');
    const key = '$1'.split('.').reduce((o, k) => o && o[k], config);
    if (key !== undefined && key !== null) {
      process.stdout.write(String(key));
    } else {
      process.exit(1);
    }
  "
}

# Extract values
MISSING=0
S3_BUCKET=$(read_config "aws.s3_bucket") || { echo "Warning: aws.s3_bucket not found in config" >&2; S3_BUCKET=""; MISSING=$((MISSING+1)); }
AWS_KEY=$(read_config "aws.key") || { echo "Warning: aws.key not found in config" >&2; AWS_KEY=""; MISSING=$((MISSING+1)); }
AWS_SECRET=$(read_config "aws.secret_key") || { echo "Warning: aws.secret_key not found in config" >&2; AWS_SECRET=""; MISSING=$((MISSING+1)); }
BEARER=$(read_config "auth.bearer_token") || { echo "Warning: auth.bearer_token not found in config" >&2; BEARER=""; MISSING=$((MISSING+1)); }

# Write .env (non-secret)
{
  [ -n "$S3_BUCKET" ] && echo "AWS_S3_BUCKET=$S3_BUCKET"
} > "$ENV_FILE"
echo "Created $ENV_FILE"

# Write .secret.local (secrets)
{
  [ -n "$AWS_KEY" ] && echo "AWS_KEY=$AWS_KEY"
  [ -n "$AWS_SECRET" ] && echo "AWS_SECRET_KEY=$AWS_SECRET"
  [ -n "$BEARER" ] && echo "AUTH_BEARER_TOKEN=$BEARER"
} > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
echo "Created $SECRET_FILE (secrets - do not commit)"

echo ""
if [ "$MISSING" -gt 0 ]; then
  echo "Warning: $MISSING key(s) were missing from config. Review the files and fill in any blank values." >&2
fi
echo "Migration complete. These files are for local emulator use only."
echo "For deployed environments, set secrets via: firebase functions:secrets:set SECRET_NAME"
```

---

### Update documentation

**Summary**: Update the README and upgrade doc to reflect the new configuration approach, replacing all references to `functions.config()` and `firebase functions:config:set` with the params API and Secret Manager workflow.

**Files affected**:
- `functions/README.md` — Rewrite configuration and deployment sections
- `functions/firebase-functions-v3-to-v4-upgrade.md` — Update deprecation status

**Estimated diff size**: ~80 lines

**Changes to `functions/README.md`**:

Replace the "Configuring AWS credentials" section (lines 19-44) with:

```markdown
### Configuration

The functions use Firebase's parameterized configuration (`firebase-functions/params`):

| Parameter | Type | Env Var Name | Purpose |
|---|---|---|---|
| S3 bucket | `defineString` | `AWS_S3_BUCKET` | Target bucket for parquet file storage |
| AWS access key | `defineSecret` | `AWS_KEY` | S3 authentication |
| AWS secret key | `defineSecret` | `AWS_SECRET_KEY` | S3 authentication |
| Bearer token | `defineSecret` | `AUTH_BEARER_TOKEN` | API endpoint authentication |

**Non-secret config** is stored in per-project `.env.<alias>` files committed to the repo:
- `.env.report-service-dev` — staging
- `.env.report-service-pro` — production

**Secrets** are stored in Google Cloud Secret Manager, set per project:

\`\`\`
firebase use report-service-dev
firebase functions:secrets:set AWS_KEY
firebase functions:secrets:set AWS_SECRET_KEY
firebase functions:secrets:set AUTH_BEARER_TOKEN
\`\`\`

Repeat for `report-service-pro`.

### Local Development (Emulator)

For the emulator, secrets are read from `functions/.secret.local` and non-secret config from `functions/.env`.

**Migrating from `.runtimeconfig.json`**: If you have an existing `.runtimeconfig.json`, run the migration script:

\`\`\`
cd functions
bash scripts/migrate-config.sh
\`\`\`

This creates `.env` and `.secret.local` from your existing config. These files are gitignored.

**Manual setup** (without migration script):

1. Create `functions/.env`:
   \`\`\`
   AWS_S3_BUCKET=concord-staging-report-data
   \`\`\`

2. Create `functions/.secret.local`:
   \`\`\`
   AWS_KEY=<your-aws-access-key>
   AWS_SECRET_KEY=<your-aws-secret-key>
   AUTH_BEARER_TOKEN=<your-bearer-token>
   \`\`\`

Then run: `firebase emulators:start --only functions` (or with `--import=./emulator-data --export-on-exit` to persist data)
```

Replace the "Bearer Tokens" section (lines 72-81, including the heading and the deprecated `config:set` command) with:

```markdown
### Bearer Tokens

All api endpoints except for the root (`api/`) require a bearer token.
The code looks for the bearer token in the `bearer` query parameter first,
then the post body and finally falls back to the `Bearer` HTTP header.

The bearer token value is managed as a secret in Google Cloud Secret Manager:

`firebase functions:secrets:set AUTH_BEARER_TOKEN`
```

Update the "Deploying" section to add a prerequisite note:

```markdown
### First-time setup (after migration)

Before the first deploy with parameterized config, set secrets for each project:

\`\`\`
firebase use report-service-dev
firebase functions:secrets:set AWS_KEY
firebase functions:secrets:set AWS_SECRET_KEY
firebase functions:secrets:set AUTH_BEARER_TOKEN

firebase use report-service-pro
firebase functions:secrets:set AWS_KEY
firebase functions:secrets:set AWS_SECRET_KEY
firebase functions:secrets:set AUTH_BEARER_TOKEN
\`\`\`

The deploy will fail with clear instructions if any required secrets are missing.
```

**Changes to `functions/firebase-functions-v3-to-v4-upgrade.md`**:

Update the "Deprecation Warning: `functions.config()`" section (lines 81-98):

```markdown
### ~~Deprecation Warning: `functions.config()`~~ RESOLVED

`functions.config()` has been fully migrated to the `firebase-functions/params` API (`defineString`/`defineSecret`). See REPORT-55.

- `functions.config().aws.key` → `defineSecret("AWS_KEY")`
- `functions.config().aws.secret_key` → `defineSecret("AWS_SECRET_KEY")`
- `functions.config().aws.s3_bucket` → `defineString("AWS_S3_BUCKET")`
- `functions.config().auth.bearer_token` → `defineSecret("AUTH_BEARER_TOKEN")`

Secrets are stored in Google Cloud Secret Manager. Non-secret config uses per-project `.env.<alias>` files.
```

---

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

## Self-Review

### Senior Engineer

#### RESOLVED: Migration script creates empty `.env` if bucket config is missing

Acceptable — the script already warns about missing keys. An empty `.env` file is harmless and doesn't break anything.

---

#### RESOLVED: `functions/scripts/` directory doesn't exist yet

Added note to the implementation step that the `scripts/` directory needs to be created when creating the migration script file.

---

### Security Engineer

#### RESOLVED: Migration script suppresses all Node.js stderr with `2>/dev/null`

Removed the `2>/dev/null` redirect from the `read_config` function. Node.js errors (e.g., JSON parse failures) will now be visible to the user, which is the correct behavior — a malformed `.runtimeconfig.json` should produce a visible error, not a silent failure.

---

### DevOps Engineer

No issues found. Step ordering is correct, env file naming matches Firebase convention, and all deployment concerns are addressed in the requirements.

---

### Self-Review Round 3

### Senior Engineer

#### RESOLVED: README line ranges were off, risking stale content

- "Configuring AWS credentials" said lines 19-43 but line 44 (`.runtimeconfig.json` gitignore note) would be left behind. Fixed to lines 19-44.
- "Bearer Tokens" said lines 73-80 but line 81 (`firebase functions:config:set auth.bearer_token=<VALUE>`) would survive. Fixed to lines 72-81.
- Auto-importer param definitions said "around line 16" but last import is line 21. Fixed to "around line 22".

---

### Security Engineer

No new issues.

---

### DevOps Engineer

No new issues.
