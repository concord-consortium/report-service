# Report Service
Ingest student runs and activity structure in order to run
report queries later.

### One way to develop this:
This command should start up a firestore emulator, and compile typescript
in the background from the `functions` directory.

The firebase CLI needs to be installed globally: `npm install -g firebase-tools`

Then

```
cd functions
npm run serve
```

### Some routes:
- `api/` -- json based documentation of routes
- `api/import_run` -- used to ingest learner runs, requires bearer token
- `api/import_structure` -- used to ingest activity structure, requires bearer token
- `api/resource` -- used to get a resource under source with given url

## Bearer Tokens

All api endpoints except for the root (`api/`) require a bearer token.
The code looks for the bearer token in the `bearer` query parameter first,
then the post body and finally falls back to the `Bearer` HTTP header.

The value of the bearer token is set with the `firebase` cli using the following
command:

`firebase functions:config:set auth.bearer_token=<VALUE>`

for local development the current Firebase environment config must be saved in
`.runtimeconfig.json`, a special file that the emulator looks for to set the
environment variables.  To create that file use:

`firebase functions:config:get > .runtimeconfig.json`

The `.runtimeconfig.json` file is present in the `.gitignore` so it won't be committed.

### AWS secrets

In order to write to S3, a user needs to be created in AWS IAM with permission to write to the S3 bucket.
For instance there exists a user, `report-service-qa`, within the AminConcordQA role, with permission to write
to the `concordqa-report-data` S3 bucket.

We can download the AWS key and Secret Key for this user, and then push it up to Firebase with

`firebase functions:config:set auth.aws.key=<VALUE>`
`firebase functions:config:set auth.aws.seret_key=<VALUE>`

These are then accessible to the Functions via `functions.config().aws.key` and `functions.config().aws.secret_key`.

## Deploying rules and functions:

### Requirements:

 * You should install the firebase CLI via: `npm i -g firebase-tools`
 * You should be logged in to firebase: `firebase login`

You deploy firebase functions and rules directly from the working directory using
the `firebase deploy` command. You can see `firebase deploy help` for more info.

See which project you have access to and which you are currently using via: `firebase list`

### To deploy to the development server:

* set the current project to dev: `firebase use report-service-dev`
* deploy the rules: `firebase deploy --only firestore:rules`
* deploy the functions: `cd functions && npm run deploy` (this generates the build info)

### To deploy to the production server:

* update the version number in functions/package.json
* set the current project to production: `firebase use report-service-pro`
* deploy the rules:  `firebase deploy --only firestore:rules`
* deploy the functions:`cd functions && npm run deploy` (this generates the build info)
* Return to the safety of development: `firebase use report-service-dev`

## Rules

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

### Anonymous Reports

Currently per student reports are supported using the run_key property of student work documents.

#### Anonymous Class reports

These aren't currently supported, but they could be.

For student work this could be extended to support anonymous class reports using anonymous `resource_link_id`
property. This would let a teacher view a report of multiple anonymous students that ran from
a the same "resource link".  The rules do not allow a request for a resource_link_id based
query of the answers, so they would need to be updated.

For user settings, it doesn't seem to make a lot of sense to support user settings for anonymous
teachers. However this might cause problems in the portal-report code, so that probably needs updating

For feedback, we'd need a new read option that matches a context_id, resource_link_id, and run_key
One of the reasons to support anonymous feedback is to simplify testing, but if the data and code paths
for this anonymous feedback is different it won't be as good for testing.
So switching from run_key to platform_user_id (see below) might simplify the code paths

### Possible improvement of run_key approach

Our 'run_key' essentially represents: (platform_id, platform_user_id, resource_link_id)
So we might be able to simplify some of the logic here by using those 3 properties instead of a run_key
- The platform_id should be left unset since that is how the anonymous rules prevent injecting
data into the authenticated data.
- The platform_user_id could be the randomly generated 'run_key'
- The resource_link_id would be an optional randomly generated id that can correlate
multiple platform_users so a teacher gets an anonymous class report.

If we follow that to its conclusion would also allow students/teachers to re-use the
same anonymous platform_user_id for multiple anonymous assignments. There isn't a great
reason to use this right away, but it would match the current logged in case better.
In the future it would allow anonymous teachers to correlate data across multiple assignments
for a single student. The issue is that most LMS would not support something like this
out of the box. They'd need some option which lets the user supply a template for the URL which
the LMS then populates with a student id. So using generic LMS support the student would need
to know their special id and paste it into some field when they run the activity.

### Possible improvements for data validity

The rules are not currently checking the resource_link_id (or resourceLinkId). In some
cases this property is required for the documents to be valid. It is often queried on by the
portal-report code. The rules could be updated to enforce that it is set and used in queries.

The rules do not check that the platformStudentId is set for question_feedbacks and
activity_feedbacks. These documents are specific to students and should have this property
set on all of them.

The user settings are stored under a path that includes the platform_user_id. The rules
only check that this id in the path matches the authorized platform_user_id. It would be
better if the rules also checked the platform_id since the platform_user_id could overlap
between different platforms.
