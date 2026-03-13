# Try Using Firebase Client Library in Firebase Functions

**Jira**: [REPORT-63](https://concord-consortium.atlassian.net/browse/REPORT-63)

**Status**: **Closed**

## Overview

This proof-of-concept validates that the Firebase client SDK can be used inside Cloud Functions to enforce Firestore security rules on data access. The ai4vs-flvs task handler's evaluate-completion step serves as the test case, reading student answers through a JWT-scoped client SDK instance rather than the unrestricted admin SDK.

## Requirements

- **R1**: Implement a mechanism to initialize a Firebase client SDK instance inside a Cloud Function, authenticated with a JWT that enforces Firestore security rules. The implementation must ensure auth state isolation between invocations (e.g., sign out after use or create a fresh client SDK instance per invocation).
- **R2**: The ai4vs-flvs evaluate-completion step must read student answer documents using the client SDK (not admin SDK), so that access is limited by Firestore rules.
- **R3**: Verify that the client SDK instance respects Firestore security rules — a student-scoped token should only be able to read that student's own answer documents.
- **R4**: The function must still be able to update job status documents using the admin SDK (hybrid approach), since student Firestore rules don't permit job writes.
- **R5**: Document findings on feasibility, performance implications, and any limitations discovered during the experiment.
- **R6**: This is an experiment/proof-of-concept — production-quality error handling and optimization are not required at this stage.
- **R7**: The ai4vs-flvs task handler must return an error if no JWT is present in the Cloud Tasks payload (e.g., anonymous user). The JWT is optional at the `submitTask`/`taskWorker` level — other tasks that don't need client SDK access are unaffected.

## Technical Notes

### Firebase Client SDK in Node.js Functions

The Firebase client SDK (`firebase/app`, `firebase/firestore`, `firebase/auth`) can be used in Node.js environments alongside the admin SDK. Key considerations:

- The client SDK must be initialized with the Firebase project config (apiKey, projectId, authDomain, etc.). These are hardcoded per project and selected at runtime using `process.env.GCLOUD_PROJECT`, matching the existing pattern in `activity-player/src/firebase-db.ts`.
- Authentication is done via `signInWithCustomToken()` — the function uses the JWT forwarded from the client.
- Each client SDK instance maintains its own auth state.
- Multiple client SDK instances can coexist (student client, teacher client).

### Token Flow

The client sends the Firebase JWT as an `Authorization: Bearer` header in the `submitTask` request. The `submitTask` function extracts the JWT from this header (if present) and includes it in the Cloud Tasks HTTP request body. The task worker then passes it to the handler. The JWT is optional at the `submitTask`/`taskWorker` level — not all tasks require it. Individual task handlers decide whether to require the JWT.

### Hybrid SDK Approach

- **Admin SDK**: For job status updates (`markRunning`, `markComplete`, `setProcessingMessage`) — internal operations that student Firestore rules don't permit.
- **Client SDK**: For reading student answer data — enforcing Firestore security rules on data access.

## Out of Scope

- Migrating existing functions (import_run, move_student_work, etc.) to use client SDK — this is an experiment on the ai4vs-flvs handler only.
- Production-quality error handling, retry logic, or performance optimization for the client SDK integration.
- Changes to Firestore security rules — the existing rules are sufficient for this experiment.
- Changes to the submitTask or taskWorker architecture beyond what's needed to pass the JWT through the Cloud Tasks payload.
