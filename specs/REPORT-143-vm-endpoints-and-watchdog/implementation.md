# Implementation Plan: report-service: everything the VM calls, and the watchdog

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-143
**Requirements Spec**: [requirements.md](requirements.md)
**Branch**: `REPORT-143-vm-endpoints-and-watchdog`, from `master` (`f5adf65`), no child branch
**Status**: **In Development**

## Implementation Plan

Six steps, one commit each except step 3, which is two, on top of `master` (`f5adf65`), then the suspend-hook check (R1), which is a task run against staging after the deploy and not a commit.

1. The queue leaves by result status and keeps the last finished run, the VM record gains `launched_at`, a wake writes `resumed_at`, and the launch passes the egress connector's ARN (R5, R7, R8, R8a, R19's `resumed_at`, R20's fields, R28a).
2. The keyless storage broker and its param (R12 to R14a, R15's unit tests, R26, R26a).
3. The VM's authentication, its three routes, their wiring, the setup script's grants and `id-token`, and the live check (R2 to R6a, R9 to R11, R14, R15's live check, R27a, R27b).
4. The watchdog and its indexes (R16 to R21, R28).
5. The rules, their emulator tests, and the CI trigger (R22 to R25).
6. The README (R27).

The functions' tests run on Node 22 with `npm test` and `npm run test:emulator`; the rules tests run in `tests/` with the emulator started by the functions' firebase-tools 15 on Node 22 and Jest under Node 18, as CI's rules job does. Write `emulators:exec`'s output to a file rather than piping it into `head`: closing the pipe leaves the emulator's Java child holding its port. Each run needs a fresh emulator, since the existing `chat-rules.test.js` counts documents an earlier run left. Select each Node by `PATH` (`speccing.md`, "Machine setup"); on a machine with nvm:

```bash
cd tests && PATH=$HOME/.nvm/versions/node/v22.17.1/bin:$PATH ../functions/node_modules/.bin/firebase \
  -c ../firebase.json emulators:exec --only firestore --project report-service-dev \
  "PATH=$HOME/.nvm/versions/node/v18.20.4/bin:\$PATH npm test"
```

### Step 1: the queue leaves by result status, and the VM record gains `launched_at` and `resumed_at`

**Summary**: A shared module reads the researcher's queue with each entry's result, inside the caller's transaction, and classifies each entry as queued, running or finished. `/run-package` then dedupes and caps against outstanding entries only, rewrites `scopes` from what it read, and mirrors only queued entries onto the runner document; each appended package's queued result carries the last finished run as `previous`. The launch record gains `launched_at` and clears `resumed_at`, a wake writes `resumed_at`, and the MicroVM wrapper gains `suspend` and `terminate` and launches with the egress connector's ARN. Covers R5, R7, R8, R8a, R19's `resumed_at`, R20's fields and R28a.

**Files affected**:
- `functions/src/researcher-dashboard/queue.ts`: new, with `toMillis`, the only way any dashboard module compares or measures a stored time. Two Admin SDK reads of one Firestore `Timestamp` are `isEqual` but not `===`, and `FakeDb` hands back the same object on every read, so a raw comparison passes every unit test and fails in production; the emulator tests in steps 3 and 4 are what catch it.
- `functions/src/researcher-dashboard/run-package.ts`: `queuePackages`, and `WorkDoc` gains `session_token`, `firebase_project` and `updated_at`
- `functions/src/researcher-dashboard/ensure-vm.ts`: `MAXIMUM_DURATION_SECONDS` moves here from `microvm.ts`, `recordLaunch` writes `launched_at` and `resumed_at: null`, and the private `resume` becomes the exported `wakeSuspended(deps, who, vm: {microvm_id, image_version})`, with `deps` the `db`, `timestamp` and `microvms` slice, which `ensureVm` calls with the `vms/` document it read and the watchdog calls too (R19). Before `ResumeMicrovm` it runs a transaction that merges `resumed_at: timestamp()` into `vms/{platform_user_id}` only while that document's `microvm_id` is this VM. Its header comment says the watchdog wakes a suspended VM with *queued* work
- `functions/src/researcher-dashboard/microvm.ts`: `suspend` and `terminate`; `REGION` moves to a new pure module, `region.ts`, which `microvm.ts` and the broker's modules import, so the region is defined once; and `run` passes ``egressNetworkConnectors: [`arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS`]`` (R28a)
- `functions/src/test/researcher-dashboard-fake-db.ts`: a transaction refuses a read after a write, as Firestore does, so a transaction that reads after writing fails here rather than only in production, with a test in `researcher-dashboard-fake-db.test.ts`
- `functions/src/researcher-dashboard/run-package.test.ts`, `ensure-vm.test.ts`, `microvm.test.ts`

**Estimated diff size**: ~230 lines

```ts
// queue.ts
export type Standing = "queued" | "running" | "finished"
const standing = (status: unknown): Standing =>
  status === "running" ? "running" : status === "done" || status === "failed" ? "finished" : "queued"

/** Reads the researcher's queue and each entry's result, inside the caller's transaction. */
export async function readQueue(db: Db, tx: Transaction, who: Researcher): Promise<QueueRead> {
  const ref = db.doc(workPath(who.portal, who.platformUserId))
  const work = (await tx.get(ref)).data() as WorkDoc | undefined
  const entries: StoodEntry[] = []
  for (const entry of work?.packages ?? []) {
    const path = resultPath(who.portal, entry.class_hash, who.platformUserId, packageKey(entry.identity))
    const result = (await tx.get(db.doc(path))).data() as ResultDoc | undefined
    entries.push({ entry, standing: standing(result?.status), result })
  }
  return { ref, work, entries }
}

export const withStanding = (q: QueueRead, ...wanted: Standing[]) => q.entries.filter(e => wanted.includes(e.standing)).map(e => e.entry)
export const outstanding = (q: QueueRead) => withStanding(q, "queued", "running")

/** Drops finished entries, and the scopes nothing outstanding names, when there are any. */
export function prune(tx: Transaction, q: QueueRead) {
  if (!q.entries.some(e => e.standing === "finished")) {
    return
  }
  const packages = outstanding(q)
  tx.set(q.ref, { packages, scopes: keptScopes(q.work, packages) }, { mergeFields: ["packages", "scopes"] })
}
```

`queuePackages` keeps its shape: `existing` becomes `outstanding(q)`, the cap counts `existing` plus the appended, the work document is written with `mergeFields: ["packages", "scopes", "session_token", "firebase_project", "updated_at"]` and `scopes: { ...keptScopes(q.work, packages), [classHash]: {scope, class_tokens} }`, and the runner document's `queue` is `mirror([...withStanding(q, "queued"), ...appended])`. After `readQueue` and before the first `tx.set`, it reads each appended package's result with `tx.get` (R8a; a finished entry still in `work/` was read already, and reading it again is harmless), and each queued result is written whole with `previous: previousOf(current)` when that is defined. `previousOf` is a pure function in `queue.ts`: a `done` result gives the six fields it has, any other gives its own `previous`, and none gives `undefined`, in which case the key is left out of the write. REPORT-141 wrote `scopes.<class_hash>` by field path so that other classes' entries survived. Rewriting `scopes` from the transaction's own read keeps them just as well and also drops a finished class's entry. The pruning write is skipped when nothing is finished, so `/work` and `/idle` do not write on every call.

`queue.ts` imports only types from `run-package.ts`, which imports functions from it, so the cycle is erased at compile time. A missing result counts as queued, since every appended entry gets one written in the same transaction.

**Tests**:
- A finished package is appended again and its result written `queued`, landing after the outstanding entries.
- A running package is skipped as already queued and left out of the mirrored `queue`.
- `previous` (R8a): a `done` result re-queued gives exactly its six fields, without its own `previous`; one missing `summary` gives five and no `undefined`; a `failed` result re-queued carries its `previous` forward unchanged, and one with none writes none; a first run writes no `previous`. A `FakeDb` that refuses a read after a write fails the build if the appended results are read after the work document is written.
- With a cap of 2, a class whose two packages failed does not count against it, and its `scopes` entry is dropped.
- `recordLaunch` writes `launched_at` and `resumed_at: null`, and the wrapper sends `SuspendMicrovm` and `TerminateMicrovm` by id.
- `recordLaunch` over a `vms/` that holds an old `resumed_at` leaves it null.
- `wakeSuspended` writes `resumed_at` before it calls `ResumeMicrovm` (the fake's `resume` reads `vms/` and finds it), and writes nothing when `vms/` records another VM; `ensureVm`'s resume path writes it too.
- `RunMicrovm`'s input pins `egressNetworkConnectors` as `arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS` (`microvm.test.ts`'s existing launch case, which pins the bare name on `master`).
- `microvm.test.ts`'s source test ("never mints a MicroVM auth token") reads every non-test module in the directory instead of its fixed list of six, so every file this story adds is covered.

### Step 2: the keyless storage broker and its param

**Summary**: The session policy as a pure function, which refuses a widening id or bucket; the broker, which is the only code handed the broker role and assumes it with `fromWebToken` and a token minted for the call, always with the policy; the broker's emulator refusal; and the `RD_BROKER_ROLE_ARN` param as a launch setting in both `.env` files, which joins the QA stack's other launch settings already on `master`. No route yet. Covers R12, R13, R14a, R15's unit tests, R26, R26a.

**Files affected**:
- `functions/src/researcher-dashboard/storage-policy.ts`: new, with `PLATFORM_USER_ID` and `BrokerRefusal`
- `functions/src/researcher-dashboard/storage-broker.ts`: new
- `functions/src/researcher-dashboard/aws-credentials.ts`: `brokerIdToken`
- `functions/src/researcher-dashboard/config.ts`: `rdBrokerRoleArn` beside the launcher role and the audience, and in `unsetLaunchSettings`
- `functions/.env.report-service-dev`: `RD_BROKER_ROLE_ARN=arn:aws:iam::816253370536:role/researcher-dashboard-runner-staging-broker` beside the launch settings `master` already points at the QA stack (R26a)
- `functions/.env.report-service-pro`: `RD_BROKER_ROLE_ARN=` (empty)
- `functions/src/researcher-dashboard/storage-policy.test.ts`, `storage-broker.test.ts`: new; `aws-credentials.test.ts`, `config.test.ts`: new cases

**Estimated diff size**: ~250 lines. No dependency changes: `@aws-sdk/credential-provider-web-identity` and `@aws-sdk/client-s3` are already direct dependencies.

```ts
// storage-policy.ts
export const PLATFORM_USER_ID = /^[1-9][0-9]*$/
const BUCKET = /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/
export class BrokerRefusal extends Error {}

export function sessionPolicy(bucket: string, platformUserId: string): string {
  if (!PLATFORM_USER_ID.test(platformUserId)) {
    throw new BrokerRefusal(`platform_user_id ${JSON.stringify(platformUserId)} is not a positive integer`)
  }
  if (!BUCKET.test(bucket)) {
    throw new BrokerRefusal(`bucket ${JSON.stringify(bucket)} is not an S3 bucket name`)
  }
  return JSON.stringify({ Version: "2012-10-17", Statement: [
    { Effect: "Allow", Action: "s3:ListBucket", Resource: `arn:aws:s3:::${bucket}`, Condition: { StringLike: { "s3:prefix": `researchers/${platformUserId}/*` } } },
    { Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource: `arn:aws:s3:::${bucket}/researchers/${platformUserId}/*` },
    { Effect: "Allow", Action: "s3:GetObject", Resource: `arn:aws:s3:::${bucket}/packages/*` }
  ] })
}

// storage-broker.ts
// The broker role's MaxSessionDuration
const SESSION_SECONDS = 3600

export interface StorageBroker {
  /** One researcher's session. The policy is built here, so no caller can leave it out. */
  assume(input: { roleArn: string; audience: string; bucket: string; platformUserId: string }): Promise<StorageCredentials>
}

/**
 * The broker, assuming the runner stack's BrokerRole directly with the function's own Google ID
 * token. This is the only call that assumes BrokerRole, and it always carries the session policy.
 */
export function makeStorageBroker(idToken: IdTokenSource): StorageBroker {
  return {
    async assume({ roleArn, audience, bucket, platformUserId }) {
      const policy = sessionPolicy(bucket, platformUserId)
      const assume = async () => fromWebToken({
        roleArn,
        roleSessionName: `researcher-${platformUserId}`,
        webIdentityToken: await idToken(audience),
        policy,
        durationSeconds: SESSION_SECONDS,
        clientConfig: { region: REGION, maxAttempts: 1 }
      })()
      const c = await within(assume(), UPSTREAM_TIMEOUT_MS)
      if (!c.accessKeyId || !c.secretAccessKey || !c.sessionToken || !c.expiration) {
        throw new Error("AssumeRoleWithWebIdentity returned no credentials")
      }
      return { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey, sessionToken: c.sessionToken, expiration: c.expiration }
    }
  }
}

// aws-credentials.ts
/**
 * The ID token source for the storage broker, whose sessions come only from the function's own
 * identity. The emulator has none, so there the broker refuses whatever RD_EMULATOR_AWS says.
 */
export function brokerIdToken(env: NodeJS.ProcessEnv = process.env, idToken: IdTokenSource = metadataIdToken): IdTokenSource {
  if (env.FUNCTIONS_EMULATOR !== "true") {
    return idToken
  }
  return async () => {
    throw new Error("the storage broker makes no AWS call in the emulator, which has no service account")
  }
}
```

`storage-broker.ts` imports `IdTokenSource` from `aws-credentials.ts` as a type and `within` and `UPSTREAM_TIMEOUT_MS` from `ensure-vm.ts`, as `aws-credentials.ts` does, so the token and STS together get one upstream call's 10 seconds. The policy is built, and refuses, before a token is minted. `fromWebToken` loads its STS client only when called, so the module imports cleanly under Jest 24, and a value import of it from `vm-routes.ts` is harmless; `vm-routes.ts` still imports `StorageBroker` as a type, since it needs nothing else.

**The live check** (R15, in step 3, since it calls step 3's `id-token`) is `storage-broker.live.ts`, which Jest never collects (its name does not match `testRegex`) and `tsc` compiles to `lib/`. It skips unless `RD_LIVE_PROJECT`, `RD_LIVE_AUDIENCE`, `RD_LIVE_ROLE_ARN`, `RD_LIVE_BUCKET` and `RD_LIVE_PACKAGE_KEY` are set, and prints the account, audience, role and bucket before any call. Its token source runs `scripts/setup-researcher-dashboard-iam.sh id-token <project> <audience>` with `execFileSync` (the script's own refusal reaching the operator on stderr). It hands that source to the real `makeStorageBroker`, so it exercises the function's own call. It assumes a session for each of two ids no portal user will have (999999001 and 999999002), writes one object under the second's prefix, and asserts with real calls that the first session reads, writes, lists and deletes its own prefix; is refused a read, a list, a write and a delete of the second's existing object and a list of `researchers/`; reads the published archive `RD_LIVE_PACKAGE_KEY`; and is refused a write and a delete of a probe key under `packages/` and a list of `packages/`. The write and delete refusals use a probe key, not the archive, so a wrong grant cannot overwrite or delete a published package; S3 answers a refused write or delete with 403 whether or not the key exists. The first line disables tslint's `no-implicit-dependencies` and `no-floating-promises` for the file, since `node:test` has no unprefixed name and its runner awaits `test()` itself.

**Tests**:
- `sessionPolicy` equals the contract exactly for bucket `researcher-dashboard-runner-staging` and id `136`; every resource is the bucket, `researchers/136/…` or `packages/*`; the only action on `packages/` is `s3:GetObject`; and at a 63-character bucket and a 20-digit id it stays under 2,048 characters.
- It refuses the ids `*`, `1*`, `?`, `0`, `-1`, `1.5`, `""`, `" 1"`, `1/2` and `01`, and the buckets `""`, `*`, `bucket*`, `b?`, `Bucket` and `a`.
- With `jest.mock("@aws-sdk/credential-provider-web-identity", factory)`, as `aws-credentials.test.ts` mocks it: `fromWebToken` gets exactly `{roleArn, roleSessionName: "researcher-136", webIdentityToken, policy: sessionPolicy(bucket, "136"), durationSeconds: 3600, clientConfig: {region: "us-east-1", maxAttempts: 1}}`, the token minted for the stack's audience; every session mints a new token; a `*` id is refused before a token is minted; an answer without a session token or expiry is refused; and a token that never arrives is given up after 10 seconds without `fromWebToken` being called.
- The source guard (R13): `fromWebToken(` appears in `aws-credentials.ts` and `storage-broker.ts` and no other module of the directory; the broker's call passes `policy`; and no module, nor `functions/src/index.ts`, names `client-sts`, `AssumeRoleCommand` or `AssumeRoleWithWebIdentityCommand`. That is the test for "no code path assumes the broker role without the policy", and for Jira's "a session requested without a session policy". Its third part, that only the wiring hands the broker the role, needs step 3's wiring and lands there.
- `brokerIdToken` is the given source when deployed, and refuses in the emulator without calling it, even with `RD_EMULATOR_AWS=default-chain`.
- `config.test.ts`: `unsetLaunchSettings()` includes `RD_BROKER_ROLE_ARN`; and every param `config.ts` declares appears in both `.env` files.

### Step 3: the VM's authentication, its three routes, their wiring, and the setup script's grants

**Summary**: `runnerAuth` verifies the VM's Firebase ID token and requires the runner claim; `/work`, `/idle` and `/storage-credentials` go on `researcherDashboardApp` behind it, which takes a third deps factory; and rigse's two routes get their assertion middleware per route instead of app-wide, so neither credential opens the other's routes. The dashboard's wiring builds the VM routes' deps with the broker, the setup script grants what `/work`'s mint needs and gains `id-token`, and the broker's live check, which calls it, lands here. Covers R2 to R6a, R9 to R11, R14, R15's live check, R27a, R27b.

**Files affected**:
- `functions/src/researcher-dashboard/vm-auth.ts`: new
- `functions/src/researcher-dashboard/vm-routes.ts`: new, `VmRouteDeps`, `makeWork`, `makeIdle`, `makeStorageCredentials`
- `functions/src/researcher-dashboard/app.ts`: per-route middleware, and `researcherDashboardApp(deps, deriveDeps, vmDeps)`
- `functions/src/researcher-dashboard/index.ts`: the broker, `vmRouteDeps()`, the third factory passed in
- `functions/scripts/setup-researcher-dashboard-iam.sh`: Token Creator on itself; the `SERVICES` list with `iamcredentials.googleapis.com`, enabled by `apply` and checked by `check`; and `id-token`
- `functions/src/researcher-dashboard/storage-broker.live.ts`: new, the live check under `node --test` (step 2 describes it)
- `functions/src/researcher-dashboard/vm-routes.test.ts`: new
- `functions/src/researcher-dashboard/vm-routes.emulator.test.ts`: new; against the emulator's real Timestamps, `/work` mints fresh tokens for a VM whose `launched_at` is within its life and passes rigse's through for one past it
- `run-package.test.ts`, `derive-profile-route.test.ts`: pass a third factory that throws
- `storage-broker.test.ts`: the guard's wiring case; `config.test.ts`: the script's grants

**Estimated diff size**: ~730 lines, so step 3 is two commits: 3a, the VM's authentication, the three routes and their wiring and tests; 3b, the setup script's grants and `id-token`, the live check, and `config.test.ts`'s script case

```ts
// vm-auth.ts
export function runnerFromClaims(claims: RunnerClaims): Runner | null {
  if (claims.researcher_dashboard_runner !== true || claims.user_type !== "researcher") {
    return null
  }
  const id = claims.platform_user_id
  const platformUserId = typeof id === "number" ? String(id) : id
  if (typeof platformUserId !== "string" || !PLATFORM_USER_ID.test(platformUserId)) {
    return null
  }
  const uid = Number(platformUserId)
  if (!Number.isSafeInteger(uid) || !platformUrl(claims.platform_id)) {   // http or https only
    return null
  }
  const platformId = claims.platform_id as string
  return { uid, platformUserId, platformId, portal: portalSegment(platformId), firebaseUid: claims.uid }
}
// runnerAuth: no Bearer, or verify() throws => 401; runnerFromClaims null => 403; else res.locals.runner

// app.ts
const fromRigse = portalAssertionAuth(() => deps().keys())
const fromVm = runnerAuth(() => vmDeps().verifyIdToken)
app.post("/run-package", fromRigse, (req, res) => makeRunPackage(deps())(req, res))
app.post("/derive-profile", fromRigse, (req, res) => makeDeriveProfile(deriveDeps())(req, res))
app.post("/work", fromVm, (req, res) => makeWork(vmDeps())(req, res))
app.post("/idle", fromVm, (req, res) => makeIdle(vmDeps())(req, res))
app.post("/storage-credentials", fromVm, (req, res) => makeStorageCredentials(vmDeps())(req, res))

// researcher-dashboard/index.ts
// Holds no credentials: each session is assumed with a token minted for it.
const storageBroker = makeStorageBroker(brokerIdToken())

function vmRouteDeps(): VmRouteDeps {
  return {
    db: admin.firestore() as unknown as Db,
    verifyIdToken: t => admin.auth().verifyIdToken(t) as Promise<RunnerClaims>,
    microvms: microvmApi(),
    broker: storageBroker,
    // Signs as the function's own account through the IAM Service Account Credentials API, which
    // needs Token Creator on itself (scripts/setup-researcher-dashboard-iam.sh).
    mint: (uid, claims) => admin.auth().createCustomToken(uid, claims),
    ownProject: process.env.GCLOUD_PROJECT ?? "",
    now: Date.now,
    log: functions.logger,
    config: { bucket: rdDataBucket.value(), brokerRoleArn: rdBrokerRoleArn.value(), audience: rdAwsAudience.value() }
  }
}

export const researcherDashboard = functions
  .runWith({ serviceAccount: `${SERVICE_ACCOUNT_ID}@`, timeoutSeconds: 60 })
  .https.onRequest(researcherDashboardApp(researcherDashboardDeps, deriveProfileDeps, vmRouteDeps))
```

**The middleware is per route, not per router.** A router mounted at the root with `router.use(auth)` runs its middleware for every request that reaches it, including the other credential's routes, so rigse's requests would meet the VM's check first. Attaching each middleware to its routes is the smallest shape that keeps the two apart. An unknown path now gets express's 404 rather than a 401; nothing depends on that.

**`/work`**, in one transaction: read `vms/{platform_user_id}` and refuse (409) any `microvm_id` but the recorded one; `readQueue`; `prune`; take the queued entries. After the transaction, `scopes` is built from `work.scopes` for the classes handed out only, copied, so the stored tokens are never modified. Then, when the recorded VM's `launched_at` is within `MAXIMUM_DURATION_SECONDS`, and `work.firebase_project` is the function's own project, the session token and each handed-out class's `class_tokens[firebase_project]` are replaced with fresh mints:

```ts
const identity = (who: Runner) => ({ platform_id: who.platformId, platform_user_id: who.uid, user_type: "researcher", researcher_dashboard_runner: true })
// Each mint is a signBlob call; together they get one upstream call's time.
const [session, ...classTokens] = await within(Promise.all([
  mint(who.firebaseUid, identity(who)),
  ...hashes.map(hash => mint(who.firebaseUid, { ...identity(who), class_hash: hash }))
]), UPSTREAM_TIMEOUT_MS)
```

A mint failure, or mints still unanswered after 10 seconds, is 502 naming the reason, loud rather than a silent fall back to rigse's older tokens. The 200 body is `{success: true, packages, scopes, session_token, firebase_project}`, `success` being the repository's envelope on every answer (`response-methods.ts`).

**`/idle`**, in one transaction: read `vms/`, `readQueue`, and when nothing is queued answer `run_in_progress` if a `running` entry's result names this VM, else refuse any `microvm_id` but the recorded one, then `prune`. Every read comes before `prune`'s write, since Firestore refuses a read after a write in a transaction. With work queued it answers `{success: true, suspended: false, work_queued: true}` without checking the id. Otherwise it calls `suspend` after the transaction, since a transaction must not span a network call (REPORT-141's decision), and answers `{success: true, suspended: true}` or 502.

**`/storage-credentials`**: 503 naming whichever of `RD_BROKER_ROLE_ARN`, `RD_DATA_BUCKET` and `RD_AWS_AUDIENCE` is empty; `broker.assume({roleArn, audience, bucket, platformUserId})`; 200 with R14's body; a `BrokerRefusal` (a malformed bucket) is 503 "misconfigured"; any other failure, the emulator's refusal included, is 502 "the storage broker failed: <reason>".

**The setup script** keeps its shape: `SELF_ROLES` gains `roles/iam.serviceAccountTokenCreator` with a comment saying `/work` signs through it, a new `SERVICES=(iamcredentials.googleapis.com)` list is read with `gcloud services list --enabled --format='value(config.name)'`, `apply` enables what is missing with `gcloud services enable` before the account and its bindings, and `check` reports `Not enabled: <service>` and exits 1. The header's first line says it also manages the APIs. A new header line documents `id-token <project> <audience>`, so `usage` prints lines 2 to 14.

`id-token` (R27b, Q12):

```bash
# The account's ID token for <audience>, minted with the caller's own login through generateIdToken,
# which needs only the OpenID Token Creator role grant-operator gives. gcloud's
# --impersonate-service-account is not used: it mints an access token first, which needs Token Creator.
id_token() {
  local audience=$1 answer token
  if [[ ! $audience =~ ^[A-Za-z0-9._:/-]+$ ]]; then
    echo "Not an audience: $audience" >&2
    exit 2
  fi
  answer=$(curl -sS -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H 'Content-Type: application/json' -d "{\"audience\":\"$audience\"}" \
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$email:generateIdToken")
  token=$(sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' <<<"$answer")
  if [[ -z $token ]]; then
    echo "$answer" >&2
    echo "Minting needs OpenID Token Creator on $email: $0 grant-operator $project user:<you>@concord.org" >&2
    exit 1
  fi
  echo "$token"
}
```

with `id-token) [[ $# -eq 3 ]] || usage; id_token "$3" ;;` in the `case`.

**Tests** (`vm-routes.test.ts`, the real app on an ephemeral port under `@jest-environment node` with `express.json()` in front, `FakeDb`, a fake verifier that maps bearer strings to claims, and fakes for the MicroVM API, the broker and the mint):
- Each route: 401 with no token and with one the verifier refuses; 403 for the browser's token for the same researcher (no runner claim), with no token, credential or suspend in the answer; 403 for the claim as the string `"true"`, a `learner`, an id `4*` or `0`, and a `platform_id` that is not a URL; the researcher is the token's even when the body names another.
- `/work`: the queued packages in order, a running one left out, only their classes' scopes, with a mint for the session and each of those classes alone; two calls return the same packages; a `done` entry and its class's scope are pruned while its result is left alone; the session and this project's class tokens are minted for the verified uid with exactly the identity claims, and CLUE's class token is passed through; rigse's tokens pass through when the VM's `launched_at` is nine hours old; a mint failure is 502 naming the reason; a stray `microvm_id` is 409, a missing one 400; an empty queue still carries a fresh session token; mints that never answer give 502 "no answer within 10 seconds" (the test makes the ten-second `setTimeout` fire at once).
- `/idle`: suspends the recorded VM when nothing is queued; does not when something is; does not, answering `run_in_progress: true`, when a `running` result names this VM; does when the only `running` result names another VM; 409 for a stray id with no suspend; 502 with the reason when `SuspendMicrovm` fails.
- `/storage-credentials`: the exact body and the broker's arguments, `audience` included; 503 naming all three unset settings with no call to the broker; 503 "misconfigured" for a `BrokerRefusal`; 502 with STS's reason.
- The source guard's wiring case (`storage-broker.test.ts`): `rdBrokerRoleArn` is named only in `config.ts` and `researcher-dashboard/index.ts`, twice there (the import and `brokerRoleArn: rdBrokerRoleArn.value()`), and never inside a `webIdentityCredentials(` or `functionCredentials(` call.
- `config.test.ts`: the script's `SELF_ROLES` contains Token Creator and its `SERVICES` is exactly the IAM Credentials API; its `OPERATOR_ROLE` is OpenID Token Creator, it calls `generateIdToken`, and no line but a comment names `--impersonate-service-account`.

### Step 4: the watchdog and its indexes

**Summary**: `runWatchdog`, pure logic over the `Db` slice, a query interface and the MicroVM API; the Admin SDK adapter for its two collection-group queries, with an emulator test; the scheduled function; and the two indexes. Covers R16 to R21, with R19a.

**Files affected**:
- `functions/src/researcher-dashboard/watchdog.ts`: new
- `functions/src/researcher-dashboard/watchdog-queries.ts`: new, the only watchdog module importing `firebase-admin`
- `functions/src/researcher-dashboard/firestore-paths.ts`: `parseResultPath` and `parseVmPath`
- `functions/src/researcher-dashboard/index.ts`: `researcherDashboardWatchdog`, beside `researcherDashboard`
- `functions/src/index.ts`: imports it and keys it in `module.exports` (R28)
- `firestore.indexes.json`: one composite index and one field override
- `functions/src/researcher-dashboard/watchdog.test.ts`, `watchdog-queries.emulator.test.ts`: new

**Estimated diff size**: ~640 lines

```ts
// researcher-dashboard/index.ts
// Every minute: ends runs whose heartbeat has stopped, fails work no VM took, suspends idle VMs,
// resumes a suspended VM with work queued behind its suspend, and marks a gone VM's runner document
// terminated. Runs as the same account, for the launcher role.
export const researcherDashboardWatchdog = functions
  .runWith({ serviceAccount: `${SERVICE_ACCOUNT_ID}@`, timeoutSeconds: 60 })
  .pubsub.schedule("every 1 minutes")
  .onRun(async () => {
    await runWatchdog({
      db: admin.firestore() as unknown as Db,
      queries: makeWatchdogQueries(admin.firestore()),
      microvms: microvmApi(),
      now: Date.now,
      timestamp: () => admin.firestore.FieldValue.serverTimestamp(),
      log: functions.logger
    })
  })

// watchdog-queries.ts
db.collectionGroup("results").where("status", "==", "running").where("updated_at", "<", at(ms))
db.collectionGroup("results").where("status", "==", "queued").where("updated_at", "<", at(ms))
db.collectionGroup("vms").where("launched_at", ">", at(ms))
// each doc's path goes through parseResultPath / parseVmPath, and anything outside
// researcher_dashboard/ is dropped
```

`runWatchdog` takes its start time once and checks `BUDGET_MS` before every upstream call, starting none after it (30 seconds: a call can take 20, 10 to refresh the launcher's credentials and 10 for itself, and its write must still fit the 60). **Pass 1** asks `runningUpdatedBefore(start - LEASE_FLOOR_MS)`, with `HEARTBEAT_MIN_SECONDS = 30`, `HEARTBEAT_MAX_SECONDS = 120`, `LEASE_BEATS = 5` and `LEASE_FLOOR_MS = LEASE_BEATS * HEARTBEAT_MIN_SECONDS * 1000` exported from `watchdog.ts`; `StaleResult` gains `heartbeatSeconds`. For each result it skips one whose `heartbeatSeconds` is not an integer from `HEARTBEAT_MIN_SECONDS` to `HEARTBEAT_MAX_SECONDS`, reads `vms/` and `runners/` (Firestore, not upstream), and computes `since = max(updatedAt, vms.microvm_id === result's VM ? toMillis(vms.resumed_at) : 0)`; the lease has lapsed when `start - since > LEASE_BEATS * heartbeatSeconds * 1000`, and the suspended bound when `start - updatedAt > (min(expected, 28800) s + 10 min)`; it goes on only if either has, and every branch but `SUSPENDED` needs the lease lapsed. Then, in order: **moved on** (`runners.microvm_id` is the result's VM, `runners.state` is neither `terminated` nor `failed`, `runners.current_package` is not `{classHash, packageKey}`, and `toMillis(runners.updated_at) > updatedAt`) fails it with `cause: moved_on` and no upstream call and no runner write; otherwise, within budget, `GetMicrovm` on the result's `microvm_id`: null or `TERMINATED` fails it with `cause: vm_gone`, guarding the runner write on the VM; `TERMINATING` and `SUSPENDING` do nothing; `PENDING` and `RUNNING` are terminated, within budget, logging `watchdog.vm_terminated` with `reason: lease`; `SUSPENDED` is terminated with `reason: suspended_mid_run` only when `start - updatedAt > (min(expected, 28800) s + 10 min)`, measured from `updatedAt` alone, else left. A terminate writes nothing, and a failed one is `watchdog.upstream_failed`. Every failure uses the one constant `MACHINE_STOPPED`, "The machine running it stopped before the run finished; run it again.", which replaces `VM_STOPPED` and `RUN_INTERRUPTED`. `failResult` runs a transaction that writes the result only if it is still `running` with the `updated_at` that was read, and writes the runner document `terminated` only when asked to (the gone-VM case), its `microvm_id` is that VM and its `state` is neither `terminated` nor `failed`. Pass 1 then asks `queuedUpdatedBefore(start - 8 h - 10 min)` and, for each result whose researcher's `vms/` has no `launched_at` after that same cutoff, fails it with the `NOT_CLAIMED` message through `failResult` with `queued` as the status it must still have (R17a); this half makes no upstream call, so the budget does not stop it. The same `(status, updated_at)` index serves both queries. **Pass 2** asks `vmsLaunchedAfter(start - 8 h - 10 min)`. For each VM it gets the state, then reads the runner document and the queue, and prunes the queue, in one transaction, reads first. `SUSPENDED` with queued work is woken through `ensure-vm.ts`'s `wakeSuspended`, within budget, with the `image_version` that `vmsLaunchedAfter` returns beside each VM, which writes `resumed_at` first; a failure is logged as `watchdog.upstream_failed`. `RUNNING` is suspended when nothing is queued, no `running` result names this VM, `current_package` is empty or names a result the transaction read as not `running` (the result is read with the others, before the prune), and the latest of the launch, the runner document's `updated_at` and the work document's `updated_at` is 30 minutes old. `GetMicrovm` null or `TERMINATED` (not `TERMINATING`) writes the runner document `{state: "terminated", current_package: null, updated_at}` in the same transaction when its `microvm_id` is this VM and its `state` is neither `terminated` nor `failed`, and logs `watchdog.runner_terminated` only when it wrote (R19a). Every action and every upstream failure is one `log.info` line whose message is the event name (`watchdog.result_failed`, `watchdog.vm_terminated`, `watchdog.vm_suspended`, `watchdog.vm_resumed`, `watchdog.runner_terminated`, `watchdog.upstream_failed`) with the researcher, portal, VM and, where there is one, the class and package, and `vm_terminated`'s `reason` and `result_failed`'s `cause` (R21). A failure on one item goes on to the next.

**First generation, not `firebase-functions/v2/scheduler`.** It is the repository's pattern (`monitorSyncDocCount`), Jest 24 cannot resolve the v2 subpath, and the built `lib/researcher-dashboard/index.js` exports `researcherDashboardWatchdog` with a schedule trigger, `every 1 minutes`, `serviceAccountEmail: "researcher-dashboard@"`, a 60-second timeout and no secret environment variables, the same account as `researcherDashboard`. The watchdog shares the module's cached `microvmApi()`, so in its own instance it builds one MicroVM client whose launcher credentials refresh themselves.

The indexes, which firebase-tools' own `FirestoreApi.validateSpec` accepted with the file's existing 26 indexes and one override:

```json
{"collectionGroup": "results", "queryScope": "COLLECTION_GROUP", "fields": [
  {"fieldPath": "status", "order": "ASCENDING"}, {"fieldPath": "updated_at", "order": "ASCENDING"}]}
```
```json
{"collectionGroup": "vms", "fieldPath": "launched_at", "ttl": false, "indexes": [
  {"order": "ASCENDING", "queryScope": "COLLECTION"}, {"order": "DESCENDING", "queryScope": "COLLECTION"},
  {"arrayConfig": "CONTAINS", "queryScope": "COLLECTION"}, {"order": "ASCENDING", "queryScope": "COLLECTION_GROUP"}]}
```

The override repeats the three collection-scope defaults, as the file's `answers_async.updated` override does, because an override replaces a field's automatic indexes rather than adding to them.

**Tests** (`watchdog.test.ts`, `FakeDb`, fake queries, a fake MicroVM API whose states a table sets, and a controllable clock):
- The lease: at `heartbeat_seconds` 60, a result quiet 299 seconds is left and one quiet 301 is acted on; at 30 the threshold is 150 seconds and at 120 it is 600; a result with `heartbeat_seconds` missing, 29, 121 or `60.5` is skipped with no upstream call.
- A stale run whose VM is not found or `TERMINATED` is failed with `MACHINE_STOPPED`, `cause: vm_gone`, exactly `status`, `error`, `finished_at` and `updated_at` merged, and the runner document of that VM marked `terminated`; a runner document already `failed` (the hook's incomplete flush) or `terminated` is left exactly as it was.
- `TERMINATING` and `SUSPENDING` leave the result and terminate nothing.
- `PENDING` and `RUNNING` are terminated, nothing is written, and the line is `watchdog.vm_terminated` with `reason: lease`; on the next run, with the VM `TERMINATED`, the result is failed. A terminate that throws is `watchdog.upstream_failed` and writes nothing.
- `SUSPENDED` is left until `updated_at` is older than the declared duration plus 10 minutes, then terminated with `reason: suspended_mid_run` and nothing written; a declared duration above the cap is capped, and a missing one is taken as the cap. A `vms/.resumed_at` a minute old, as a resume that keeps failing leaves it, does not postpone the termination.
- Moved on: with `runners/` recording the result's VM, another `current_package` (a different package key, and separately the same key in another class) or none, and an `updated_at` after the result's, the result is failed with `cause: moved_on`, `GetMicrovm` is never called, and the runner document is unchanged. With the same `current_package`, or an `updated_at` before the result's, or another VM recorded, or a runner `state` of `terminated` or `failed`, it falls through to `GetMicrovm` (and, with the VM gone, logs `cause: vm_gone`).
- Resume: a result whose `updated_at` is an hour old, on a `RUNNING` VM whose `vms/.resumed_at` is a minute old, is left; the same `resumed_at` on a `vms/` recording another VM does not count.
- The budget: with each `GetMicrovm` advancing the clock 25 seconds, the second stale result's `TerminateMicrovm` is not called once the first has spent the budget.
- A result queued more than 8 h 10 min ago is failed with `NOT_CLAIMED` and the runner document is untouched; one queued 8 h ago is not; one as old whose researcher's VM was launched within the last 8 h 10 min is not; one claimed (`running`) since the query is not overwritten.
- A result the runner has written since the query is not overwritten.
- A failed run, and a `NOT_CLAIMED` one, keep the result's `previous` exactly as it was.
- A newer VM's runner document is left alone.
- One VM's `GetMicrovm` failing is logged and the next result is still failed.
- No result is ever deleted: a source test that no non-test module of the directory calls `.delete(`, `recursiveDelete` or `FieldValue.delete`.
- An awake VM idle past the threshold is suspended; inside it, or with work queued, a run of its own, or a current package whose result is `running`, it is not; a current package whose result is `failed` does not keep it awake, nor does a stale run claimed by another VM.
- A suspended VM with queued work is resumed, with `resumed_at` written, and one without is not.
- A VM `GetMicrovm` does not know, or `TERMINATED`, marks a `starting`, `ready` or `suspended` runner document of that VM `terminated`, clears `current_package`, keeps `queue`, and logs `watchdog.runner_terminated`; `TERMINATING`, `RUNNING`, `PENDING`, `SUSPENDING` and `SUSPENDED` leave it; a document naming another VM is left; one already `terminated` or `failed` is not written and nothing is logged.
- The queue is pruned as it is read.
- Nothing starts after the budget: each `GetMicrovm` advances the clock 35 seconds, which passes at a 30-second budget and fails at 40.

`watchdog-queries.emulator.test.ts`, under `npm run test:emulator`: the first query returns the stale timestamped result with its fields, and not a fresh one, a `done` one, one whose `updated_at` is an ISO string, or one under `elsewhere/`; the second returns only a VM launched within the window; and `failResult`, given a stalled result as the first query returned it, fails it, so its `updated_at` check holds on a real Timestamp; and the lease's `since` reads a stored `resumed_at` Timestamp through `toMillis`.

### Step 5: the rules, their emulator tests, and the CI trigger

**Summary**: The `researcher_dashboard/{portal}` block, with Q2's option A in it (`rdServerTime` and `rdRunningFields`), its emulator suite, and the rules job's trigger paths. Covers R22 to R25, and R22a (Q2's option A, Doug, 2026-09-25).

**Files affected**:
- `firestore.rules`: the block below, before the database match's closing brace
- `tests/researcher-dashboard-rules.test.js`: new
- `functions/src/researcher-dashboard/rules-constants.test.ts`: new, asserting the rules' `expected_duration_seconds <= 28800` bound is `MAXIMUM_DURATION_SECONDS`, and their `heartbeat_seconds >= 30` and `<= 120` bounds are `watchdog.ts`'s `HEARTBEAT_MIN_SECONDS` and `HEARTBEAT_MAX_SECONDS`, each read from `firestore.rules`
- `.github/workflows/firestore-and-query-creator-tests.yml`: `firestore.rules`, `firestore.indexes.json`, `firebase.json` and `tests/**` added to `on.push.paths`

**Estimated diff size**: ~190 lines

```
match /researcher_dashboard/{portal} {
  function rdAuthed() {
    return request.auth != null
      && request.auth.token.platform_id.split('://')[1].split('/')[0].split('\\.')
         == portal.split('_');
  }
  function rdIsRunner() { return request.auth.token.get("researcher_dashboard_runner", false) == true; }
  function rdIsResearcher() { return rdAuthed() && request.auth.token.user_type == "researcher"; }
  function rdTokenUserId() { return string(request.auth.token.platform_user_id); }
  function rdSamePlatform(data) { return request.auth.token.platform_id == data.platform_id; }
  function rdReadable() { return resource == null || rdSamePlatform(resource.data); }
  function rdServerTime() { return request.resource.data.updated_at == request.time; }
  function rdStartedAt() {
    return request.resource.data.get("started_at", null) == null
      || request.resource.data.started_at == request.time
      || (resource != null && request.resource.data.started_at == resource.data.get("started_at", null));
  }

  match /runners/{platformUserId} {
    allow get: if rdIsResearcher() && rdTokenUserId() == platformUserId && rdReadable();
    allow create, update: if rdIsResearcher() && rdIsRunner() && rdTokenUserId() == platformUserId
      && rdSamePlatform(request.resource.data) && rdServerTime();
  }

  match /classes/{classHash} {
    function rdResearcherOfClass() { return rdIsResearcher() && request.auth.token.class_hash == classHash; }
    allow get: if rdResearcherOfClass() && rdReadable();

    match /researchers/{platformUserId} {
      function rdOwnScope() { return rdResearcherOfClass() && rdTokenUserId() == platformUserId; }
      allow get: if rdOwnScope() && rdReadable();
      allow create, update: if rdOwnScope() && rdIsRunner() && rdSamePlatform(request.resource.data);

      match /results/{packageKey} {
        function rdRunningFields() {
          return request.resource.data.status != "running"
            || (request.resource.data.expected_duration_seconds is int
                && request.resource.data.expected_duration_seconds >= 1
                && request.resource.data.expected_duration_seconds <= 28800
                && request.resource.data.microvm_id is string
                && request.resource.data.heartbeat_seconds is int
                && request.resource.data.heartbeat_seconds >= 30
                && request.resource.data.heartbeat_seconds <= 120);
        }
        allow get: if rdOwnScope() && rdReadable();
        allow list: if rdOwnScope();
        allow create, update: if rdOwnScope() && rdIsRunner() && rdSamePlatform(request.resource.data)
          && rdServerTime() && rdStartedAt() && rdRunningFields();
      }
    }
  }
}
```

The committed block carries comments for each choice (the label split, `.get` with a default, the missing-document read, server time, and why reads are `get`/`list` and writes `create, update`), which are omitted above.

**Tests** (`@firebase/rules-unit-testing` 1.x as the other suites use it, one app per token shape built once, since the v8 client does not survive an app per call, and distinct document ids per test instead of clearing the emulator):
- `work/` and `vms/` refuse a browser token, a session runner token and a class runner token for get, set and a collection list.
- No client writes `classes/{class_hash}`; its researcher reads it; another class's researcher cannot; a runner cannot delete it.
- The runner document: the session token writes it with `serverTimestamp()`, and is refused with a client `Date` or with an update that leaves `updated_at` alone; the browser reads and cannot write it; another researcher cannot read it; another portal's runner cannot write it; nothing deletes it; a researcher can read their own before it exists.
- Results: a class runner token writes a `running` result with `expected_duration_seconds`, `microvm_id` and `heartbeat_seconds`, and is refused one at 28,801, one with a null `microvm_id`, one without `heartbeat_seconds`, with 29, with 121 and with 60.5, one with a string `updated_at` and one with a client `Date` as `started_at`; a later update that keeps the claimed `started_at` is allowed, and so is a heartbeat, a merge of only `platform_id` and a server-time `updated_at`; a session token (no `class_hash`) cannot write one; it moves to `done`; nothing deletes one; no token writes another researcher's; the browser cannot write one.
- Reads: the researcher gets and lists their own; another class's researcher, another researcher and an anonymous caller are refused both.
- The scope document is written by the class runner without `updated_at`, and read but not written by the browser.
- A listener on a result that does not exist yet receives a snapshot with `exists` false.
- An existing document of another platform is not readable.

### Step 6: the README

**Summary**: `functions/README.md` documents the three routes, the watchdog, `RD_BROKER_ROLE_ARN` in the settings table, the broker's identity, and the deploy steps. Covers R27.

**Files affected**: `functions/README.md`

**Estimated diff size**: ~35 lines

In the "Researcher Dashboard function" section:
- After the two rigse routes, a paragraph on the VM's three routes (the VM's Firebase ID token, the runner claim, the researcher from the token only) with one bullet each, the broker's saying it assumes `RD_BROKER_ROLE_ARN` for one hour with the function's own Google ID token under the session policy; then one paragraph on `researcherDashboardWatchdog`, which runs every minute as the same account, terminates the VM of a run whose heartbeat has stopped for five beats and fails the run once the VM is gone (or at once when the runner has moved on), fails work no VM took, suspends idle VMs, wakes a suspended VM with work queued, marks a gone VM's runner document `terminated`, and logs each action as `watchdog.<action>`.
- The table gains "Broker role", between "Launcher role" and "AWS audience", whose purpose says the audience is the stack's name.
- The settings paragraph names the broker role among the settings that make `run-package` answer 503, and says `storage-credentials` answers 503 while the broker role, bucket or audience is empty.
- **AWS credentials** adds that the broker mints its own token per session and always passes the session policy, and that the broker refuses in the emulator whatever `RD_EMULATOR_AWS` says.
- **Deploy order**: `apply` also enables the IAM Service Account Credentials API, which `work` signs through. Then one paragraph: deploy with `firebase deploy --only firestore:rules,firestore:indexes,functions:researcherDashboard,functions:researcherDashboardWatchdog,functions:deriveProfileWorker`; the watchdog's queries fail until both indexes finish building.
- **The broker's live check**: `grant-operator`, `npm run build`, the five `RD_LIVE_*` settings and `node --test lib/researcher-dashboard/storage-broker.live.js`, then `revoke-operator`, saying `id-token` mints the account's ID tokens with the operator's own login, which needs only OpenID Token Creator, and that any check needing the account's token uses `id-token`, not `gcloud … --impersonate-service-account`.

The README asks for no secret, and nothing here adds one.

### After the deploy: the suspend-hook check (R1)

Not a commit, and not a gate on the merge (Doug, 2026-09-25); the story is not closed until its answer is recorded. Once RD-4 pass 2's runner is released to the QA stack (`landing-tracker.md` 3.4) and this story is deployed to `report-service-dev`:

1. From the staging portal's dashboard, run any package for a staging class, which launches a VM on RD-4 pass 2's image.
2. Wait for the runner's CloudWatch log group (`/aws/lambda-microvms/researcher-dashboard-runner-staging`) to show the package finishing, then wait out the runner's 5-minute idle period for its `/idle` call, which suspends the VM through the API (R10).
3. Read the same log group for the `/suspend` hook's lines between the last activity and the VM reaching `SUSPENDED`; run another package to resume it, and check that no `lifecycle.resume_without_suspend` warning follows.
4. Record the answer, with the `microvm_id` and the times, in this spec's requirements (R1) and in `final-design.md` 7.2(b), and terminate the VM.

The same launch shows whether `/run`'s body carries `microvmId` (requirements, Technical Notes, "The VM's own id"): the runner logs it as `microvm_id` on every line.

## Open Questions

### RESOLVED: Judgment call: are `/work`'s mints bounded each, or together?
**Options considered**:
- A) Run them together under one 10-second bound.
- B) Bound each at 10 seconds, one after another.

**Decision** (2026-10-07): A. With up to 20 classes, B's worst case is 210 seconds, far past the function's 60; A's is 10, and the signBlob calls are independent.

### RESOLVED: Judgment call: is the live check the function's code, or RD-1's shell helper?
**Options considered**:
- A) A `node --test` file driving `makeStorageBroker` with an operator's token source.
- B) RD-1's `assume` helper with the policy pasted in, as RD-1's own broker check already does.

**Decision** (2026-10-07): A. RD-1's check proves the stack's ceiling and a hand-written policy; this story's has to prove its own code builds and sends the policy, which only running that code shows (`oidc-launcher-plan.md`, acceptance gate step 4: "through the function's real provider").

## Requirements coverage

R5, R7, R8, R8a, R19's `resumed_at`, R20's fields and R28a are step 1; R12 to R14a, R15's unit tests, R26 and R26a are step 2; R2 to R6a, R9 to R11, R14, R15's live check, R27a and R27b are step 3; R16 to R21, R19a and R28 are step 4; R22 to R25 and R22a are step 5; R27 is step 6; R1 is the after-deploy check. R29 is met by the code and the source tests rather than a step of its own.
