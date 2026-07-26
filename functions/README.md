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
* deploy the functions:`npm run deploy` (this generates the build info)
* if `../firestore.rules` changed, also deploy the rules (see [Deploying rules](#deploying-rules))
* if the release adds a new query shape, exercise it in production and create any index it asks for (see [Indexes](#indexes))
* Return to the safety of development: `firebase use report-service-dev`

Deploying will also run the firebase linter, and may also ask you to update or add new indexes to the database,
depending on the queries it finds.

**`npm run deploy` does not deploy the firestore rules.** It resolves to `firebase deploy --only functions`,
so a release that changes `../firestore.rules` needs the separate rules deploy called out above. Missing it
is easy to misdiagnose, because the symptom is a `permission-denied` in the *client* rather than any error
from the functions deploy.

### Indexes

`../firestore.indexes.json` does not currently track any composite indexes, so a query needing one is not
covered by a deploy. Firestore auto-creates single-field indexes, but a query combining an equality filter
with an `orderBy` on a different field needs a composite index that has to be created explicitly.

In development these usually get created ad hoc, by following the console link in the "requires an index"
error the first time the query runs. That link only creates the index in the project you were testing
against, so an index added while testing `report-service-dev` will **not** exist in `report-service-pro`.

**For now**, after deploying a release that adds a new query shape, exercise the new feature against
production and create any index it asks for by clicking the link shown in the console error. The index
takes a few minutes to build, and the query keeps failing until it finishes.

**FUTURE**: populate `../firestore.indexes.json` with the composite indexes we actually rely on, so
`firebase deploy --only firestore:indexes` creates them per project and this stops being a manual
post-deploy step.

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

`cd .. && firebase deploy --only firestore:rules`

This deploys to whichever project `firebase use` currently selects, so check that first. Nothing in CI
deploys the rules, and `npm run deploy` in this folder only deploys functions, so a rules change reaches
an environment only when someone runs this command against it.
