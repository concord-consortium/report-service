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

### Configuring AWS credentials

First we need a bucket to write to, e.g. `concord-staging-report-data`. We need to set this as an environment variable
for the auto_update function:

`firebase functions:config:set aws.s3_bucket=concord-staging-report-data`

In order to write to S3, a user needs to be created in AWS IAM with permission to write to the S3 bucket.
For instance there exists a user, `report-service-qa`, within the AminConcordQA role, with permission to write
to the `concord-staging-report-data` S3 bucket.

We can download the AWS key and Secret Key for this user (check 1Password), and then push it up to Firebase with

`firebase functions:config:set aws.key=<VALUE>`
`firebase functions:config:set aws.secret_key=<VALUE>`

These three values are now accessible to the Functions via `functions.config().aws.s3_bucket`, `key` and `secret_key`

For local development via the emulator, or just to check that they are set correctly, the firebase environment config
can be saved to `.runtimeconfig.json`, a special file that the emulator looks for to set the environment variables.

To create that file use:

`firebase functions:config:get > .runtimeconfig.json`

The `.runtimeconfig.json` file is present in the `.gitignore` so it won't be committed.

## Deploying

### To deploy to the development server:

* set the current project to dev: `firebase use report-service-dev`
* deploy the functions: `npm run deploy` (this generates the build info)

### To deploy to the production server:

* update the version number in functions/package.json
* set the current project to production: `firebase use report-service-pro`
* deploy the functions:`npm run deploy` (this generates the build info)
* Return to the safety of development: `firebase use report-service-dev`

Deploying will also run the firebase linter, and may also ask you to update or add new indexes to the database,
depending on the queries it finds.

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

The value of the bearer token is set with the `firebase` cli using the following
command:

`firebase functions:config:set auth.bearer_token=<VALUE>`

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