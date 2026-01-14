# Report Server

A Phoenix LiveView application for generating reports from portal and log data.

## Available Reports

The server provides several categories of reports:

### Assignment Reports
- **Summary Metrics by Assignment**: Total schools, teachers, classes, and learners per resource
- **Detailed Metrics by Assignment**: Teacher and school information with class and student counts per resource
- **Assignment Usage by Student**: Student-level usage data including questions and answers

### Student Reports
- **Student Actions**: Low-level log event stream for learners including model-level interactions
- **Student Actions with Metadata**: Student actions plus portal metadata (student, teacher, class, school info)
- **Student Answers**: Complete student answer details for all questions in assignments

### Teacher Reports
- **Teacher Actions**: Log events for teacher actions in activities and dashboards
- **Teacher Status**: Activities assigned by teachers and student completion status

### School Reports
- **Detailed Metrics by School**: School-level data including districts, teachers, classes, students, grade levels, and subject areas

### Subject Area Reports
- **Summary Metrics by Subject Area**: Subject area data including countries, states, schools, teachers, classes, students, and grade levels

## Development Setup

First install the `asdf` version manager: <https://asdf-vm.com/guide/getting-started.html>

Install the necessary plugins:

```shell
asdf plugin add elixir
asdf plugin add erlang
```

Then run `asdf install` in this project's directory.  It will use the `.tool-versions` file to install the proper version of Erlang and Elixir.

If you see an error about your SSL library missing do the following: if you are on a Mac run `brew install openssl` and on Linux run `sudo apt-get install libssl-dev`.

Finally if you are on Linux install the inotify tools via `sudo apt-get install inotify-tools`.

### Environment Settings

The server needs several environment variables set in order to start.  The easiest way to do this is create an `.env` file (which is in `.gitignore` already) with
the following keys set.  The values of the keys are secrets and can be found in the CloudFormation parameter values for the staging stack.

```shell
export SERVER_ACCESS_KEY_ID=         # AWS access key for the report server user
export SERVER_SECRET_ACCESS_KEY=     # AWS secret key for the report server user
export REPORT_SERVICE_TOKEN=         # Authentication token for report service
export REPORT_SERVICE_URL=           # URL of the report service
export PORTAL_REPORT_URL=            # URL of the portal report endpoint
export LEARN_PORTAL_STAGING_CONCORD_ORG_DB=mysql://<username>:<password>@<host>:<port>

# Optional: disable the stats server for development
export DISABLE_STATS_SERVER=true
```

Note that if you cannot directly connect to the database (eg, it is in an AWS cluster), you may need to
establish an ssh port-forwarding tunnel to it, something like:

```shell
ssh -L 127.0.0.1:4001:<actual-database-host>:<port> <user>@<gatewayserver>
```

In which case you'd use `127.0.0.1:4001` as the `<host>:<port>`
in the LEARN_PORTAL_STAGING_CONCORD_ORG_DB environment variable
instead of the real address.

## Development

To start the Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start ssh tunnel if needed (see above)
* Run `source .env` (created in step above) to load the environment variables
* Run `docker compose up` (or `docker-compose up` for older Docker installs) to start the MySQL database
* If this is the first time running the app:
  * Run `mix ecto.create` to create the database
  * Run `mix ecto.migrate` to run database migrations
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### Testing

To run the test suite:

```shell
mix test
```

Tests will automatically create and migrate a test database on first run.

### Key Dependencies

- **Phoenix LiveView**: Real-time UI for report generation and monitoring
- **Ecto/MyXQL**: Database access for portal data
- **Explorer**: DataFrame library for data analysis and transformation
- **AWS SDK**: Access to S3 and Athena for log data queries
- **CSV**: Export functionality for reports

## Deploying

The report server is deployed using Docker on CloudFormation.  Here are the steps to deploy:

1. Run `docker build . -t concordconsortium/report-server:VERSION` where `VERSION` is a semver version.  For staging deployments use `-pre.N` suffixes like `1.1.0-pre.0`.
2. Once the build is complete run `docker push concordconsortium/report-server:VERSION` to push to the container registry.
3. In AWS CloudFormation select the `report-server` stack in the QA account or `report-server-prod` in the production account and run an update using the newly uploaded tagged container as the value for the "ImageUrl" parameter in the update process.

## Server Setup

### AWS User Permissions

The server uses the authenticated user's AWS permissions only to list and retrieve the Athena queries for the user.  Otherwise it uses user credentials passed via the `SERVER_ACCESS_KEY_ID` and `SERVER_SECRET_ACCESS_KEY` environment variables.  These permissions must be defined in the following staging and production policies and assigned to the staging and production users:

#### Staging Policy

This staging policy has been created under the name `report-server` and assigned to the user `report-server-staging`.  The access keys for that user can be found in the `Report Server Staging AWS Access Keys` document on 1Password.

```json
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Effect": "Allow",
   "Action": [
    "s3:GetObject",
    "transcribe:GetTranscriptionJob",
    "s3:ListBucket"
   ],
   "Resource": [
    "arn:aws:s3:::concord-staging-report-data/workgroup-output/*",
    "arn:aws:s3:::token-service-files-private/interactive-attachments/*",
    "arn:aws:transcribe:us-east-1:816253370536:transcription-job/*"
   ]
  },
  {
   "Effect": "Allow",
   "Action": [
    "s3:PutObject",
    "s3:GetObject",
    "s3:ListBucket"
   ],
   "Resource": "arn:aws:s3:::report-server-output/*"
  },
  {
   "Effect": "Allow",
   "Action": "transcribe:StartTranscriptionJob",
   "Resource": "*"
  }
 ]
}
```

#### Production Policy

This production policy has been created under the name `report-server-prod` and assigned to the user `report-server-prod`.  The access keys for that user can be found in the `Report Server Prod AWS Access Keys` document on 1Password.

```json
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Effect": "Allow",
   "Action": [
    "s3:GetObject",
    "transcribe:GetTranscriptionJob",
    "s3:ListBucket"
   ],
   "Resource": [
    "arn:aws:s3:::concord-report-data/workgroup-output/*",
    "arn:aws:s3:::cc-student-work/interactive-attachments/*",
    "arn:aws:transcribe:us-east-1:612297603577:transcription-job/*"
   ]
  },
  {
   "Effect": "Allow",
   "Action": [
    "s3:PutObject",
    "s3:GetObject",
    "s3:ListBucket"
   ],
   "Resource": "arn:aws:s3:::report-server-output-prod/*"
  },
  {
   "Effect": "Allow",
   "Action": "transcribe:StartTranscriptionJob",
   "Resource": "*"
  }
 ]
}
```

# S3 Log Partitioning

Here is the DDL to create the two tables.  Note that the S3 bucket for production is `log-ingester-production` and for staging it is `log-ingester-qa`.
The DDL below is for production, to use on staging you'll need to change the bucket in `LOCATION` and in `storage.location.template`.

NOTE: when new applications are added these tables need to be recreated on AWS.

```
CREATE EXTERNAL TABLE `logs_by_app_and_secure_key`(
  `id` string,
  `session` string,
  `username` string,
  `application` string,
  `activity` string,
  `event` string,
  `event_value` string,
  `time` bigint,
  `parameters` string,
  `extras` string,
  `run_remote_endpoint` string,
  `timestamp` bigint)
PARTITIONED BY (
  `app` string,
  `year` int,
  `month` int,
  `secure_key` string)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  's3://log-ingester-production/logs_by_app_and_secure_key'
TBLPROPERTIES (
  'projection.app.type'='enum',
  'projection.app.values'='Activity_Player,CEASAR,CLUE,CODAP,CollabSpace,Dataflow,DEVOPS,GeniStarDev,GRASP,HASBot-Dashboard,IS,LARA-log-poc,none,portal-report,rigse-log',
  'projection.enabled'='true',

  'projection.year.type'='integer',
  'projection.year.range'='2014,2050',
  'projection.year.interval'='1',

  'projection.month.type'='integer',
  'projection.month.range'='1,12',
  'projection.month.interval'='1',
  'projection.month.digits'='2',

  'projection.secure_key.type'='injected',

  'storage.location.template'='s3://log-ingester-production/logs_by_app_and_secure_key/${app}/${year}/${month}/${secure_key}/'
)

CREATE EXTERNAL TABLE `logs_by_app`(
  `id` string,
  `session` string,
  `username` string,
  `application` string,
  `activity` string,
  `event` string,
  `event_value` string,
  `time` bigint,
  `parameters` string,
  `extras` string,
  `run_remote_endpoint` string,
  `timestamp` bigint)
PARTITIONED BY (
  `app` string,
  `year` int,
  `month` int)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  's3://log-ingester-production/logs_by_app_and_secure_key'
TBLPROPERTIES (
  'projection.app.type'='enum',
  'projection.app.values'='Activity_Player,CEASAR,CLUE,CODAP,CollabSpace,Dataflow,DEVOPS,GeniStarDev,GRASP,HASBot-Dashboard,IS,LARA-log-poc,none,portal-report,rigse-log',
  'projection.enabled'='true',

  'projection.year.type'='integer',
  'projection.year.range'='2014,2050',
  'projection.year.interval'='1',

  'projection.month.type'='integer',
  'projection.month.range'='1,12',
  'projection.month.interval'='1',
  'projection.month.digits'='2',

  'storage.location.template'='s3://log-ingester-production/logs_by_app_and_secure_key/${app}/${year}/${month}/'
)
```