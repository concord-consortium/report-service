# Firebase Functions v3 to v4 Upgrade Analysis

## Overview

The Node.js 12 runtime was decommissioned by Google Cloud Functions, requiring an upgrade to Node.js 22. This in turn requires upgrading `firebase-functions` from v3 to v4, since v3 does not recognize Node.js 18+ as a valid runtime. The `firebase-tools` CLI must also be upgraded to v13+ to support deploying to Node.js 18+ runtimes.

### Changes Made

| File | Change | Reason |
|---|---|---|
| `package.json` | `engines.node`: `"12"` -> `"22"` | Node 12, 16, and 18 runtimes are all decommissioned by Google Cloud Functions |
| `package.json` | `firebase-functions`: `"^3.22.0"` -> `"^4.0.0"` | v3 SDK does not recognize Node 18+ as valid |
| `package.json` | `typescript`: `"^4.0"` -> `"~4.9"` | `@types/node@22.x` requires TypeScript 4.7+ (was resolving to 4.2.4) |
| `package.json` | Added `@types/node`: `"^22.0.0"` | Pin Node type definitions to match the engine version |
| `tsconfig.json` | Added `"skipLibCheck": true` | Avoids type conflicts between third-party `.d.ts` files (`@grpc/grpc-js`, `@types/express`) under stricter TS 4.9 checking. Does not affect type checking of project source code. |

### Prerequisites

- **`firebase-tools` CLI must be v13+.** Versions 11.x and 12.x only support Node 10-16 and will reject Node 18+ in `engines.node`. Upgrade with:
  ```bash
  npm install -g firebase-tools@latest
  ```

## Breaking Changes in firebase-functions v4.0.0

The following breaking changes were introduced in v4 (per the [official release notes](https://github.com/firebase/firebase-functions/releases/tag/v4.0.0)):

1. **App Check enforcement** — Disabled by default on callable functions. Requests with invalid App Check tokens are no longer denied unless explicitly enabled.
2. **Dropped Node.js 8, 10, 12 support** — Minimum is now Node.js 14.
3. **Dropped Admin SDK 8 and 9 support** — Minimum is now Admin SDK v10.
4. **Removed `functions.handler` namespace** — No longer available.
5. **Removed `__trigger` object** on function handlers.
6. **Realtime Database DataSnapshot** — Now matches the Admin SDK DataSnapshot, with null values removed.
7. **Source code reorganization** — Affects apps that import internal file paths instead of standard entry points.
8. **Removed lodash** as a runtime dependency.

## Codebase Impact Analysis

### File-by-File Audit

All 18 TypeScript files in `src/` were reviewed for firebase-related patterns.

#### Files with Firebase usage

| File | Firebase Patterns | v4 Compatible? |
|---|---|---|
| `src/index.ts` | `admin.initializeApp()`, `functions.https.onRequest()` | Yes |
| `src/auto-importer.ts` | `functions.config()`, `functions.logger`, `functions.firestore.document().onWrite()`, `functions.pubsub.schedule().onRun()`, `firestore.Timestamp`, `admin.firestore()` | Yes (config deprecated but functional) |
| `src/middleware/bearer-token-auth.ts` | `functions.config()` | Yes (config deprecated but functional) |
| `src/api/fake-answer.ts` | `functions.logger` | Yes |
| `src/api/move-student-work.ts` | `admin.firestore()` | Yes |
| `src/api/helpers/paths.ts` | `admin.firestore()` | Yes |

#### Files with no Firebase usage (no changes needed)

| File | Description |
|---|---|
| `src/api/get-resource.ts` | Express route handler only |
| `src/api/get-answer.ts` | Express route handler only |
| `src/api/get-plugin-states.ts` | Express route handler only |
| `src/api/get-student-feedback-metadata.ts` | Express route handler only |
| `src/api/import-run.ts` | Express route handler only |
| `src/api/import-structure.ts` | Express route handler only |
| `src/api/helpers/portal-types.ts` | TypeScript interfaces only |
| `src/api/helpers/lara-types.ts` | TypeScript interfaces only |
| `src/shared/s3-answers.ts` | S3/Parquet utilities only |
| `src/middleware/response-methods.ts` | Express middleware only |
| `src/local-types/response-methods/index.d.ts` | TypeScript declarations only |
| `src/test/import-run.test.ts` | Unit test only |

### Breaking Changes — Not Applicable (Not Used in Codebase)

| Breaking Change | Status |
|---|---|
| `functions.handler` namespace removed | Not used in any file |
| `__trigger` object removed | Not used in any file |
| Realtime Database DataSnapshot change | Only Firestore is used |
| App Check enforcement change | No callable functions (`onCall`) used |
| Internal file path imports | All imports use standard entry points |

### Deprecation Warning: `functions.config()`

`functions.config()` is deprecated in v4 but **still works for 1st gen functions**. It will log deprecation warnings. This is used in two files:

**`src/middleware/bearer-token-auth.ts` (line 15):**
```typescript
const authConfig = functions.config().auth
const serverBearerToken = authConfig && authConfig.bearer_token
```

**`src/auto-importer.ts` (lines 167-168, 205, 234):**
```typescript
functions.config().aws.key
functions.config().aws.secret_key
functions.config().aws.s3_bucket
```

**No action required now.** These will continue to work. To suppress the deprecation warnings in the future, migrate to parameterized configuration using `defineString()` from `firebase-functions/params`.

## Issues Encountered During Deployment

### 1. Node runtime decommissioned
Google Cloud Functions has decommissioned Node.js 12, 16, and 18 runtimes. Node 20 and 22 are currently supported. We chose Node 22 to match the local development environment.

### 2. firebase-functions v3 SDK rejects Node 18+
The v3 SDK hardcodes the list of valid Node versions (10-16). Upgrading to v4 was required.

### 3. firebase-tools CLI v11 rejects Node 18+
The CLI also validates the engine version and v11.x only knows about Node 10-16. Upgrading to v13+ was required.

### 4. @types/node incompatibility with TypeScript 4.2
The `@types/node` package for Node 18+ uses TypeScript syntax not available in TS 4.2. Upgrading TypeScript to 4.9 resolved this.

### 5. Third-party .d.ts type conflicts under TS 4.9
`@grpc/grpc-js` and `@types/express-serve-static-core` had type definition conflicts with the newer `@types/node`. Adding `"skipLibCheck": true` to `tsconfig.json` resolved this without affecting project source type checking.

## Deployment Steps

```bash
# Ensure firebase-tools is v13+
npm install -g firebase-tools@latest
firebase --version

cd functions
rm -rf node_modules
npm install
npm test
npm run build
firebase use report-service-dev   # for staging
npm run deploy
```

## References

- [firebase-functions v4.0.0 Release Notes](https://github.com/firebase/firebase-functions/releases/tag/v4.0.0)
- [Upgrade 1st gen to 2nd gen docs](https://firebase.google.com/docs/functions/2nd-gen-upgrade)
