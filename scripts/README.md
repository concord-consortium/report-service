# Running the export-answers script

This script finds all student answers in a Firetore report-service database, collects all the answers for a single
user's assignment into a single Parquet file, and uploads all the files to S3 for querying by the Athena database.

```
// build the shared library
cd functions
npm install
npm run build:shared

// build the scripts
cd scripts
npm install
```

Copy the `config.json.sample` file to `config.json` and fill in the AWS credentials for the S3 bucket. This should
be available in 1Password as one of the report-service AWS accounts.

Download the `credentials.json` file for the appropriate Firebase project from e.g.
https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743

Run the script by passing in the destination S3 bucket and the source key for the Firestore database. e.g.

```
node export-answers.js concordqa-report-data authoring.staging.concord.org
```
