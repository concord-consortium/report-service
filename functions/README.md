# Report Service Firebase functions

This sub-project allows us to deploy the Firebase functions needed to auto-update the learner data to S3 everytime
it is changed in the report-service Firestore DB, as well as some api functions for managing data for the reports.

## Develpment

Install the Firebase CLI and login

```
npm install -g firebase-tools
firebase login
```

Then install the dependencies

`npm install`

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

```
firebase use report-service-dev
firebase functions:secrets:set AWS_KEY
firebase functions:secrets:set AWS_SECRET_KEY
firebase functions:secrets:set AUTH_BEARER_TOKEN
```

Repeat for `report-service-pro`.

### Local Development (Emulator)

For the emulator, secrets are read from `functions/.secret.local` and non-secret config from `functions/.env`.

**Migrating from `.runtimeconfig.json`**: If you have an existing `.runtimeconfig.json`, run the migration script:

```
cd functions
bash scripts/migrate-config.sh
```

This creates `.env` and `.secret.local` from your existing config. These files are gitignored.

**Manual setup** (without migration script):

1. Create `functions/.env`:
   ```
   AWS_S3_BUCKET=concord-staging-report-data
   ```

2. Create `functions/.secret.local`:
   ```
   AWS_KEY=<your-aws-access-key>
   AWS_SECRET_KEY=<your-aws-secret-key>
   AUTH_BEARER_TOKEN=<your-bearer-token>
   ```

Then run: `firebase emulators:start --only functions` (or with `--import=./emulator-data --export-on-exit` to persist data)

### Portal OIDC Authentication (Emulator)

When running in the Firebase emulator, the shared `portalOidcFetch` utility (used by pipeline steps
like lock-activity and send-email) requires a pre-generated OIDC token since `GoogleAuth` cannot
mint tokens in the emulator environment.

1. Ensure you have the `iam.serviceAccountTokenCreator` role on the target service account:
   ```bash
   gcloud iam service-accounts add-iam-policy-binding \
     button-function@report-service-dev.iam.gserviceaccount.com \
     --member="user:<your-email>" \
     --role="roles/iam.serviceAccountTokenCreator"
   ```

2. Generate a token (expires in 1 hour):
   ```bash
   gcloud auth print-identity-token \
     --impersonate-service-account=button-function@report-service-dev.iam.gserviceaccount.com \
     --audiences=https://learn.portal.staging.concord.org
   ```

3. Set the environment variable before starting the emulator:
   ```bash
   export PORTAL_OIDC_TOKEN="<token-from-step-2>"
   firebase emulators:start --only functions
   ```

The token expires after 1 hour. Regenerate it if you see 401 errors from the Portal.

## Deploying

### First-time setup (after migration)

Before the first deploy with parameterized config, set secrets for each project:

```
firebase use report-service-dev
firebase functions:secrets:set AWS_KEY
firebase functions:secrets:set AWS_SECRET_KEY
firebase functions:secrets:set AUTH_BEARER_TOKEN

firebase use report-service-pro
firebase functions:secrets:set AWS_KEY
firebase functions:secrets:set AWS_SECRET_KEY
firebase functions:secrets:set AUTH_BEARER_TOKEN
```

The deploy will fail with clear instructions if any required secrets are missing.

### To deploy to the development server:

* set the current project to dev: `firebase use report-service-dev`
* deploy the functions: `npm run deploy` (this generates the build info)
* if `../firestore.rules` changed, also deploy the rules (see [Deploying rules](#deploying-rules))

### To deploy to the production server:

* update the version number in functions/package.json
* set the current project to production: `firebase use report-service-pro`
* deploy the functions: `npm run deploy` (this generates the build info)
* if `../firestore.rules` changed, also deploy the rules (see [Deploying rules](#deploying-rules))
* if the release adds a new query shape, deploy its index too: `firebase deploy --only firestore:indexes` (see [Indexes](#indexes))
* Return to the safety of development: `firebase use report-service-dev`

Deploying will also run the firebase linter, and may also ask you to update or add new indexes to the database,
depending on the queries it finds.

**`npm run deploy` does not deploy the firestore rules.** It resolves to `firebase deploy --only functions`,
so a release that changes `../firestore.rules` needs the separate rules deploy called out above. Missing it
is easy to misdiagnose, because the symptom is a `permission-denied` in the *client* rather than any error
from the functions deploy.

### Indexes

Composite indexes are tracked in `../firestore.indexes.json` and deployed with
`firebase deploy --only firestore:indexes`. Firestore auto-creates single-field indexes, but a query
combining an equality filter with an `orderBy` on a different field needs a composite index, and those
have to be declared.

That file is the source of truth for a deploy: it CREATES indexes it lists that the project is missing,
and it proposes DELETING indexes the project has that the file does not list. Read the plan before
confirming, especially against production.

A release that adds a new query shape needs its index added to the file. If one is missing the query fails
at runtime with `failed-precondition`, and the error carries a console link that creates the index, but
only in the project you were running against, which is how the two projects drift apart. Clicking the link
is a fine way to unblock yourself; adding the same index to the file is what stops it recurring in the
other project. A newly created index takes a few minutes to build, and the query keeps failing until it
finishes.

## API functions

Some routes:

- `api/` -- json based documentation of routes
- `api/import_run` -- used to ingest learner runs, requires bearer token
- `api/import_structure` -- used to ingest activity structure, requires bearer token
- `api/resource` -- used to get a resource under source with given url

### Bearer Tokens

All api endpoints except for the root (`api/`) require a bearer token.
The code looks for the bearer token in the `bearer` query parameter first,
then the post body and finally falls back to the `Bearer` HTTP header.

The bearer token value is managed as a secret in Google Cloud Secret Manager:

`firebase functions:secrets:set AUTH_BEARER_TOKEN`

## Researcher Dashboard function

`researcherDashboard` is a separate HTTPS function, not a route on `api`, and the shared `AUTH_BEARER_TOKEN` does not open it. rigse calls it with a short-lived RS256 assertion it signs (`aud: report-service-functions`) in the `Authorization: Bearer` header, and the function takes the researcher and portal from that assertion, never from the body.

- `researcherDashboard/run-package` queues a researcher's packages under `researcher_dashboard/{portal}/work/{platform_user_id}`, then launches, resumes or leaves that researcher's MicroVM, and answers 202 without waiting for it. Only on a launch does it relay rigse's `aud: report-server` assertion to report-server's `POST /api/v1/dashboard-tokens` for the VM's token.

Its URL, `https://us-central1-<project>.cloudfunctions.net/researcherDashboard`, is also the `function_url` the runner calls back, derived at runtime from the project. `RD_FUNCTION_URL` overrides it only if the function moves region or behind a custom domain.

| Parameter | Type | Env Var Name | Purpose |
|---|---|---|---|
| Portal public keys | `defineString` | `PORTAL_PUBLIC_KEYS` | JSON array of `{"kid", "iss", "pem"}`, one entry per rigse signing key |
| MicroVM image | `defineString` | `RD_MICROVM_IMAGE_ARN` | The runner stack's image |
| Execution role | `defineString` | `RD_EXECUTION_ROLE_ARN` | The runner stack's VM execution role |
| Data bucket | `defineString` | `RD_DATA_BUCKET` | The runner stack's bucket, passed to the VM |
| report-server URL | `defineString` | `RD_REPORT_SERVER_URL` | Where the launch mints the VM's report-server token |
| Function URL | `defineString` | `RD_FUNCTION_URL` | Optional override of `function_url` |
| Queue cap | `defineInt` | `RD_QUEUE_CAP` | Packages outstanding per researcher before a 409 (default 20) |
| Launcher access key | `defineSecret` | `RD_AWS_KEY` | The runner stack's launcher user |
| Launcher secret key | `defineSecret` | `RD_AWS_SECRET_KEY` | The runner stack's launcher user |

Each `PORTAL_PUBLIC_KEYS` entry is what `rake portal_signing_key:public` prints on that portal, with the portal's site URL (for example `https://learn.portal.staging.concord.org/`) as `iss`. A key is trusted only for its own `iss`, so staging and production portals must have their own entries, and a malformed value is answered 500 rather than trusted. Until the image, role, bucket and report-server URL are all set, `run-package` answers 503 and writes nothing. Every one of these params must still appear in each `.env.<project>` file, with an empty value where it has none yet: a deploy prompts for a declared param the file does not list, whatever its default, and fails outright when it cannot prompt.

**Deploy order.** A deploy of a function that declares an unset secret fails, and `researcherDashboard` declares the launcher's two keys, so set them in each project before the first deploy that includes it, even in a project with no runner stack yet (any placeholder value will do there, since the 503 stops the function using them):

```
firebase use report-service-dev
firebase functions:secrets:set RD_AWS_KEY
firebase functions:secrets:set RD_AWS_SECRET_KEY
```

Repeat for `report-service-pro`. Deploy report-server before the function, since a launch calls report-server's mint endpoint.

## Rules

The firestore rules are maintained in `../firestore.rules`

### request.resource

The rules refer to `request.resource` a lot. This represents the pending document
that will be saved during a create or update operation.  With a create the uploaded
document must be the full document, but during an update the uploaded document is
just the properties of the original document that should be changed.

Based on this doc: https://firebase.google.com/docs/firestore/security/rules-conditions

> For update operations that only modify a subset of the document fields,
> the request.resource variable will contain the pending document state after the operation.

So even if the client code uses an update to change some other property we can still verify that
the pending document matches all of the correct identifying properties

### Testing the rules

The firebase emulator is used to test the rules: https://firebase.google.com/docs/firestore/security/test-rules-emulator

The tests are in the `tests` folder.

Within the `tests` folder install the dependencies

    npm install

Start the emulator

    npx firebase -c ../firebase.json emulators:start --only firestore

In a new terminal run

    FIRESTORE_EMULATOR_HOST=localhost:8080 npm test

To run the emulator you need java installed.

### Deploying rules

    cd .. && firebase deploy --only firestore:rules

This deploys to whichever project `firebase use` currently selects, so check that first. Nothing in CI
deploys the rules, and `npm run deploy` in this folder only deploys functions, so a rules change reaches
an environment only when someone runs this command against it.
