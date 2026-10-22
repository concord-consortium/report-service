# Report Server

A Phoenix LiveView application for generating reports from portal and log data.

## Available Reports

The server provides several categories of reports:

### Assignment Reports
- **Summary Metrics by Assignment**: Total schools, teachers, classes, and learners per resource
- **Detailed Metrics by Assignment**: Teacher and school information with class and student counts per resource
- **Assignment Usage by Student**: Student-level usage data including questions and answers

### Student Reports
- **Student Actions**: Low-level log event stream for learners including model-level interactions. The date range selects events by the day the log server received them (UTC), not the student device's clock. It also selects students: only those who launched the activity within the range (UTC) are included, so a student who launched it before the range and kept working is left out.
- **Student Actions with Metadata**: Student actions plus portal metadata (student, teacher, class, school info). Its date range works as Student Actions' does.
- **Student Answers**: Complete student answer details for all questions in assignments
- **Student ID Mapping**: One row per selected learner carrying only identifiers, including the `run_remote_endpoint` that joins a learner to their stored answers, history and attachments. No names.
- **Student Metadata**: One row per the same learners carrying the human-readable context: name, username, class, school, teachers and permission forms. Anonymized when hide-names is on.

### Teacher Reports
- **Teacher Actions**: Log events for teacher actions in activities and dashboards. The date range selects events by the day the log server received them (UTC), not the teacher's device clock.
- **Teacher Status**: Activities assigned by teachers and student completion status

### School Reports
- **Detailed Metrics by School**: School-level data including districts, teachers, classes, students, grade levels, and subject areas

### Subject Area Reports
- **Summary Metrics by Subject Area**: Subject area data including countries, states, schools, teachers, classes, students, and grade levels

### Student ID Mapping and Student Metadata column contracts

These two run against the portal database rather than Athena, so they return in seconds, and they are
the pair a consumer joins locally. Four things about them are not inferable from the column names.

**The grain is one row per learner, not per student.** A `learner_id` is one student's participation
in one offering, so a student who did N assignments appears in N rows. Group back to a student with
`user_id`, or with `primary_user_id` when the portal has merged accounts. The two reports emit the
same learners in the same order for the same filter, so they join 1:1 on `learner_id`.

**`run_remote_endpoint` is the join key to stored work.** It is byte-identical to the
`remote_endpoint` recorded against a learner's answers, history and attachments, which is what makes
a local join possible without running an Athena query first. A learner whose portal record has no
`secure_key` yields the trailing-slash form of the URL, which is emitted rather than dropped and
joins to nothing; the trailing slash is how you spot those rows.

`runnable_url` answers a different question. The bulk endpoints (`/answers`, `/history` and
`POST /attachments`) derive each learner's storage `source` from it, and skip any learner whose
source cannot be derived as a single usable path segment, so a row present in this report can be
absent from those endpoints. `runnable_url` is what identifies the rows that affects.

**The five teacher columns are aligned by index.** `teacher_user_ids`, `teacher_names`,
`teacher_emails`, `teacher_districts` and `teacher_states` each carry one entry per teacher on the
class, in the same order, so entry *i* is the same teacher in all five. A teacher who belongs to more
than one school contributes one district and one state, both read from the same school (the one with
the lowest portal school id), so the pair is always a real school rather than two schools' halves. A
teacher with no school at all still occupies its position, as an empty entry.

**Every list column separates on a bare comma**, with no space: the five teacher columns and
`permission_forms`. The portal stores some of them with `", "`, and the reports normalize so the file
has one splitting rule. Values containing commas are not a concern because the portal replaces a
comma inside a value with a space before joining.

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
export PORTAL_PUBLIC_KEYS='[]'        # rigse's RS256 public keys (see below); optional for development
export PACKAGE_BUCKETS='{}'          # the package catalog's runner bucket per portal (see below); optional for development
export PACKAGES_AWS_ACCESS_KEY_ID=   # required whenever PACKAGE_BUCKETS names a portal
export PACKAGES_AWS_SECRET_ACCESS_KEY=
export PACKAGES_CORS_ORIGINS=        # comma-separated origins that may read the catalog with an access token
export PACKAGES_UNREVIEWED_RUNS=     # "true" lets a non-official package run; leave unset (see below)
export CLUE_EXPORT_URLS='{}'         # portal server to CLUE's clueExport function URL (see "CLUE document export")
export CLUE_EXPORT_TOKEN=            # the bearer clueExport checks; required whenever CLUE_EXPORT_URLS names a portal

# Optional: disable the stats server for development
export DISABLE_STATS_SERVER=true
```

`PORTAL_PUBLIC_KEYS` is a JSON array of `{"kid", "iss", "pem"}`, one entry per rigse signing key, each what `rake portal_signing_key:public` prints on that portal, with the portal's site URL as `iss`. It authenticates rigse's signed assertions on `POST /api/v1/dashboard-tokens`, which mints a Researcher Dashboard VM's token, and researchers' access tokens on the package catalog's reads. One report-server serves several portals, so it lists one entry per portal, and a key is trusted only for its own `iss`: the staging key can never sign for production. An entry it cannot trust (a missing field, an unreadable PEM, a `kid` listed twice) is logged and ignored. Unset, every assertion is refused: no VM token can be minted, and the catalog answers only its anonymous list.

### The package catalog

The Researcher Dashboard's package catalog lives in report-server: `POST /api/v1/packages` publishes a package zip with the publisher's cc-data token, `POST /api/v1/packages/<origin>/<name>/<state>` changes its visibility, official flag, archived flag or current version with an audit row per change, and `GET /api/v1/packages` and `GET /api/v1/packages/resolve` are the dashboard app's list and rigse's run-path resolve. The list answers anonymously with a portal's official packages (named with `?portal=`), or with a researcher's access token (verified with `PORTAL_PUBLIC_KEYS`) with every package that researcher may see; the resolve always needs the access token. `POST /api/v1/packages/list` answers the same list with each package marked `applies: true|false` against the `scope_urls` it is sent (required, possibly empty, bounded as for applies), since a class's URLs cannot travel in a GET; the GET carries no `applies`. These three reads are the only routes with CORS. A JSON POST is preflighted, so a preflight that does not ask for `authorization` is answered to every origin, as the anonymous read is, while one that does is answered only for `PACKAGES_CORS_ORIGINS`.

`POST /api/v1/packages/validate` takes what publish takes and runs every check publish runs, in publish's order and with its codes, but writes nothing: it answers what a publish of that zip would record. Two conditions that decide only whether the zip can be published now are reported rather than refused: `already_published` (publish would answer `ALREADY_EXISTS`) and `publishing_unavailable` (the portal has no bucket in `PACKAGE_BUCKETS`). `cc-data package build` and `package run` call it, and read a 404 as a server without the route, so it never answers 404.

`POST /api/v1/packages/applies` holds the URL glob matcher that cc-data, the dashboard app and the runner are designed to ask rather than each keeping a copy (`ReportServer.Packages.Patterns`; its cases are `fixtures/url-patterns.json`). It takes `{urls: {all, any, none}, assignment_urls, scope_urls}` with a cc-data or Researcher Dashboard token and answers whether the patterns apply, in the runner's words. Scope URLs are matched as given (at most 1,000, each at most 2,048 characters). Assignment URLs are followed to their interactive URLs by report-service's `derive_urls`, through `REPORT_SERVICE_URL` and `REPORT_SERVICE_TOKEN`, with a 270-second wait; a deriver that refuses the URLs is a 400 and any other failure a 503, so this route never answers 404 either.

Publish holds a package to the runner's own rules, so nothing it accepts is refused on a VM: `expected_duration_seconds` is at most 7,200 (the runner's `PACKAGE_MAX_DURATION_SECONDS` default, recorded in `fixtures/package-contract.json`), and an archive holding a symbolic-link entry is refused, since `unzip` would restore it as a link.

- `PACKAGE_BUCKETS` is a JSON object of portal server to that environment's runner bucket, for example `{"learn.portal.staging.concord.org": "researcher-dashboard-runner-staging"}`. Package identities are portal ids, which overlap between portals, so report-server refuses to boot if two portals share a bucket. A portal it does not name cannot publish.
- `PACKAGES_AWS_ACCESS_KEY_ID` and `PACKAGES_AWS_SECRET_ACCESS_KEY` are the runner stack's dedicated IAM user, which may only `s3:PutObject` under `packages/`. They are required whenever `PACKAGE_BUCKETS` names a portal, and the server's own credentials are never used for it.
- `PACKAGES_CORS_ORIGINS` lists the dashboard app's origins. A browser read with an access token from any other origin is refused, while the anonymous read is answered to every origin.
- The access token's `aud` list must name this deployment by its own URL, which is `PHX_HOST` (`ReportServerWeb.Endpoint.url/0`). Each portal it serves holds the same URL as its `REPORT_SERVER_URL` and writes it into the tokens it signs, so a portal pointed at a hostname this server does not answer to has its catalog reads refused.
- `PACKAGES_UNREVIEWED_RUNS=true` lets the resolve answer a non-official, non-archived package as runnable. It stays unset until the per-researcher storage broker is live and S3 has been taken off the runner's shared execution role, since until then a stranger's package would run with every researcher's data in reach.

The publisher role, which alone may set `official`, is held by every portal site admin and by any user an operator grants it, for example the cc-data-studies release pipeline's service user once it has logged in to report-server:

```shell
bin/report_server eval 'ReportServer.Release.grant_package_publisher("learn.concord.org", 123)'
bin/report_server eval 'ReportServer.Release.revoke_package_publisher("learn.concord.org", 123)'
```

**Deploy order.** Run the catalog's migrations and set these variables before anyone publishes with `cc-data package publish`. Publishing in an environment also waits on its runner stack's `packages/*` user.

Note that if you cannot directly connect to the database (eg, it is in an AWS cluster), you may need to
establish an ssh port-forwarding tunnel to it, something like:

```shell
ssh -L 127.0.0.1:4001:<actual-database-host>:<port> <user>@<gatewayserver>
```

In which case you'd use `127.0.0.1:4001` as the `<host>:<port>`
in the LEARN_PORTAL_STAGING_CONCORD_ORG_DB environment variable
instead of the real address.

### CLUE document export

Three routes page a report run's CLUE documents out of CLUE's own Firebase project, with the same API token, ownership rule and page envelope as `/answers` and `/history`:

- `GET /api/v1/reports/:id/clue/documents`: one row per document, its metadata.
- `GET /api/v1/reports/:id/clue/history`: one row per history entry of each document.
- `GET /api/v1/reports/:id/clue/content`: one row per document, its current content.

`/clue/history` is CLUE **document** history, the edit entries CLUE keeps for each document. It is not `/history`, which is LARA interactive-state history from report-service's own Firestore.

**Scope.** The run's learners are derived as `/answers` derives them, and only learners on an application that writes CLUE documents count: `collaborative-learning.concord.org` (branch builds included) or the Dataflow 3.0 app at `dataflow-app.concord.org`. Each student with such a learner in a class that has a class hash is one student owner in that class. A student owner's document is in scope when its offering is one of the run's offerings for that student, or when it has no offering, as personal documents, learning logs and their publications do; an offering that is present but not an integer puts the document out of scope. Each class with a student owner also has a class owner, narrowed the same way by the class's run offerings, and one owner per group of the run's offerings. Teacher documents are not exported.

**Paging.** The owners are frozen on the first page, so a later change to the run's learners does not move an export already under way. The envelope is `{items, next_page_token, total_endpoints}`, where `total_endpoints` counts the scope owners above. Pass `limit` (at most 500) and the previous `page_token`, and stop when `next_page_token` is `null`; an empty page with a token is normal. A token expires after an hour idle (410 `EXPIRED_CURSOR`), and a token from one CLUE route is 404 on another. Paging is at-least-once: a retried page may repeat items, so de-duplicate on `doc_id`, or on `(doc_id, entry_id)` for history. No item is ever split across pages.

`/clue/documents` rows:

| Field | Meaning |
|---|---|
| `doc_id` | the document id (Firestore's, which equals the RTDB key) |
| `uid`, `context_id`, `portal_class_id` | the owner, the class hash and the portal class id |
| `owner_kind` | `student`, `group` or `class` |
| `type`, `visibility`, `title`, `unit`, `investigation`, `problem`, `group_id`, `network` | Firestore metadata, falling back to RTDB metadata |
| `offering_id` | RTDB `offeringId`, then Firestore's, then a group's owner id, as an integer; an empty `offeringId` counts as none; else `null` |
| `tools` | Firestore `tools`, `null` when absent |
| `created_at` | metadata `createdAt` (epoch ms) |
| `metadata_sources` | which stores held metadata: `["firestore"]`, `["rtdb"]` or both |
| `firestore_metadata`, `rtdb_metadata` | the raw metadata, `null` when that store has none |

`/clue/history` rows:

| Field | Meaning |
|---|---|
| `doc_id`, `entry_id` | the document and the history entry |
| `idx` | the stored `index` when it is a safe integer (from -(2^53 - 1) to 2^53 - 1), else `null` |
| `prev_entry_id`, `server_created` | the stored `previousEntryId` and `created` (ISO 8601 UTC) |
| `created` | the entry's own `created` (the client clock), ISO 8601 UTC, `null` if it does not parse or falls outside years 1 to 9999 |
| `model`, `action_raw`, `undoable`, `state` | the entry's `model`, `action`, `undoable` and `state` |
| `n_records` | the number of the entry's `records` |
| `is_revert`, `entry_uid` | the entry's `isRevert` (`false` when absent) and `uid` (`null` when absent) |
| `parse_ok` | whether the entry parsed; when false every extracted field is `null` |
| `entry_json` | the stored entry string, byte for byte |

`/clue/content` rows:

| Field | Meaning |
|---|---|
| `doc_id`, `uid`, `context_id` | the document, its owner and its class hash |
| `found` | whether an RTDB document node exists |
| `type`, `version`, `change_count`, `last_history_entry_id` | from the document node |
| `self` | the node's raw `self` object, `null` when absent |
| `content_json` | the stored content string, byte for byte, `null` when `found` is false or the node has no content |

The reads are done by CLUE's `clueExport` function in that portal's CLUE project, which report-server calls with `CLUE_EXPORT_TOKEN`. `CLUE_EXPORT_URLS` is a JSON object of portal server to an `https://` function URL, for example `{"learn.portal.staging.concord.org": "https://clueexport-<hash>-uc.a.run.app"}`; report-server refuses to boot on any other shape, or when it names a portal and `CLUE_EXPORT_TOKEN` is unset. A portal with no entry in `CLUE_EXPORT_URLS` answers 503 `SERVICE_UNAVAILABLE` on these routes, before any scratch or audit row is written. Each export writes the bulk endpoints' audit rows, naming owners as `clue:<class_hash>:<uid>`, and each page row records its `item_count`.

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

The test database is the same MySQL container the development setup uses, so `docker compose up` has to be running; `config/test.exs` fixes the connection at `localhost:3406` with user `root` and password `xyzzy`, and `DATABASE_URL` is not read outside production.

Four secrets are another matter: `config/runtime.exs` raises without them in every environment, including test, even though no test uses their values.  Placeholders are the right thing here:

```shell
export SERVER_ACCESS_KEY_ID=FAKE SERVER_SECRET_ACCESS_KEY=FAKE
export REPORT_SERVICE_TOKEN=FAKE HIDE_USERNAME_HASH_SALT=FAKE
```

Do not `source .env` to run the tests.  That file is for running the server (see above) and its values point at live services, so the form tests fail against them whenever the portal database tunnel is not open.

CI also runs `mix compile --warnings-as-errors`, so a warning fails the build even when every test passes.

### Key Dependencies

- **Phoenix LiveView**: Real-time UI for report generation and monitoring
- **Ecto/MyXQL**: Database access for portal data
- **Explorer**: DataFrame library for data analysis and transformation
- **AWS SDK**: Access to S3 and Athena for log data queries
- **CSV**: Export functionality for reports

## Deploying

The `release-report-server` skill in [../.claude/skills/release-report-server/](../.claude/skills/release-report-server/) automates everything below, including the pre-flight checks, the migration task and the verification, and it ships helper scripts for the parts that are easy to get wrong.  The steps are kept here so the release can be driven by hand.

The report server is deployed using Docker on CloudFormation.  Here are the steps to deploy:

1. Run `docker build . -t concordconsortium/report-server:VERSION` where `VERSION` is a semver version.  For staging deployments use `-pre.N` suffixes like `1.1.0-pre.0`.
2. Once the build is complete run `docker push concordconsortium/report-server:VERSION` to push to the container registry.
3. Before updating the stack to the new image, apply any new migrations by running `bin/report_server eval "ReportServer.Release.migrate"` in a one-off task/container built from the new image.  On ECS this means registering a task definition revision that differs from the running one only in its image, because `run-task --overrides` can change the container's command but not its image; deregister that revision once the stack update has registered its own.  (A workstation with DB access can run `MIX_ENV=prod mix ecto.migrate` instead, but `config/runtime.exs` raises unless `SERVER_ACCESS_KEY_ID`, `SERVER_SECRET_ACCESS_KEY`, `REPORT_SERVICE_TOKEN` and `HIDE_USERNAME_HASH_SALT` are also set — migrations do not use them, so any non-empty placeholder works.)
4. In AWS CloudFormation select the `report-service-qa` stack in the QA account (816253370536) or `report-service-prod` in the production account (612297603577) and run an update using the newly uploaded tagged container as the value for the "ImageUrl" parameter in the update process.  Note that the stack names use `report-service` (matching this repo), not `report-server`.

Step 3 is not optional whenever the new image contains code that reads a table the running image does not have: those paths fail closed, so the migration must land before the new image serves traffic.  The `data_access_log` table added in the REPORT-74 release is the canonical example.

The version shown in the app header comes from the `version:` field in `mix.exs` (compiled into the release), not from the Docker tag, so bump it in the same commit that cuts a release.  Staging builds carry the `-pre.N` suffix; production builds drop it.

Both report server databases are reachable only from inside their VPC, which is why step 3 runs inside the cluster: there is no working SSH bastion for them, and a workstation cannot connect directly.  Anything you generate from a task definition or a `describe-stacks` call holds `DATABASE_URL`, `SECRET_KEY_BASE` and the AWS keys in plaintext, so write those files outside the repo and do not print them.

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

Here is the DDL for the three hand-made log tables. `logs_by_time`, the Firehose schema table, is defined in the log-ingester CloudFormation stack.  Note that the S3 bucket for production is `log-ingester-production` and for staging it is `log-ingester-qa`.
The DDL below is for production, to use on staging you'll need to change the bucket in `LOCATION` and in `storage.location.template`.
To run a block through the AWS CLI, pass it in a quoted heredoc (`<<'SQL'`), which keeps `${dt}`, `${app}`, `${year}` and `${month}` in `storage.location.template` literal. In a double-quoted string or an unquoted heredoc, bash expands them to nothing.

NOTE: when new applications are added, the two `app`-partitioned tables need to be recreated on AWS, and
the projected values also have to be updated in `ReportServer.Reports.Athena.AthenaConfig`, which is
what the report form offers and what the log report SQL validates against. The same applies to the year
and month ranges, which the partition estimate is derived from. `athena_config_test.exs` asserts the
Elixir values against every `app`, `year` and `month` declaration in the DDL below, so forgetting any of
them fails the test suite rather than silently narrowing a report. `logs_by_hour` has no `app` partition
and needs no change.

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
  'projection.app.values'='Activity_Player,CEASAR,CLUE,CODAP,CODAPV3,CollabSpace,Dataflow,DEVOPS,GeniStarDev,GRASP,HASBot-Dashboard,IS,LARA-log-poc,none,portal-report,rigse-log',
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
  'projection.app.values'='Activity_Player,CEASAR,CLUE,CODAP,CODAPV3,CollabSpace,Dataflow,DEVOPS,GeniStarDev,GRASP,HASBot-Dashboard,IS,LARA-log-poc,none,portal-report,rigse-log',
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

CREATE EXTERNAL TABLE `logs_by_hour`(
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
  `dt` string)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  's3://log-ingester-production/processed_logs_with_id/'
TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.dt.type'='date',
  'projection.dt.format'='yyyy/MM/dd/HH',
  'projection.dt.range'='2014/03/01/00,NOW',
  'projection.dt.interval'='1',
  'projection.dt.interval.unit'='HOURS',
  'storage.location.template'='s3://log-ingester-production/processed_logs_with_id/${dt}/'
)
```

## Querying recent logs

`logs_by_hour` reads the raw log landing zone, `processed_logs_with_id/YYYY/MM/DD/HH/`, which Firehose
writes about a minute behind live. The folders are UTC hours, and each object goes in the folder of the
hour its 60-second buffer opened. The nightly partitioner (02:00 UTC) copies each day from here into
`logs_by_app_and_secure_key/`. `logs_by_time`, the Firehose schema table, reads the same prefix but has
no partitions, so every query on it reads all of history. That makes `logs_by_hour` the only partitioned
table with today's logs. A query on it has to know the following.

1. **Always give `dt` a lower bound.** The projection spans every hour since 2014, so a query with no
   `dt` predicate plans over more than 100,000 partition locations. An upper bound is optional, since
   Athena never projects hours after `NOW`. `dt` is a string such as `2026/10/14/15`, and range
   predicates on it compare in time order because every level is zero-padded.
2. **Window on `timestamp`, not `time`.** `timestamp` is server receipt time in epoch milliseconds, the
   clock the folders follow. `time` is the client's clock in epoch seconds, and is only as right as the
   student's device (it falls back to receipt time, in seconds, when the client sends none). Every row
   has a `timestamp`: no null or zero value was found in `logs_by_app` over staging's whole history
   (25.8M rows) or production's April of every year 2014 to 2026 (377.7M rows), and staging's raw 2014,
   2020 and 2021 objects (216,539 rows, day files included) agree.
3. **Pad the `dt` range by one hour on each side, then filter on `timestamp`.** An event can sit in the
   folder of the hour before its own, because a buffer opened at 15:59 holds events up to about two
   minutes into 16:00. In production's 2026-10-14 14, 15 and 16 hour folders, 1,984 of 576,743 events
   sat one folder early, none sat more than one early or in a later folder, and the largest lag behind
   an object's name time was 60.1 s (119.8 s on staging, 2026-10-12). To read events with `timestamp` in
   `[T1, T2)`, scan `dt` from `hour(T1) - 1h` to `hour(T2) + 1h`, both ends inclusive (`dt BETWEEN`).
   The upper pad covers sub-second rounding and costs at most one extra hour. A window that runs to now
   needs only the lower bound.
4. **The current hour is partial**, and an hour folder can still receive objects for about two minutes
   after it ends.
5. **The nightly copy of day D is exactly the raw folders `D/00` to `D/23`** (see Reconciliation below),
   so by `timestamp` it can hold events from the first two minutes of D+1, and miss some from the first
   two minutes of D, which sit in D-1's copy. The partitioner files D under D's own `year` and `month`,
   so on a month's last day the first minutes of the next month sit in the earlier month's partition.
   D's nightly copy exists only after the partitioner's 02:00 UTC run for D finishes, and nothing marks
   that: it writes no completion marker and its Batch job has no retry, so a failed run leaves D missing
   until it is rerun, and a run still uploading leaves D partial.
6. **Scope by row, not by prefix.** There is no `app` or `secure_key` level, so a learner or class
   filter (`run_remote_endpoint`, `username`) is a row predicate: a query reads every application's
   bytes for the hours in range, whatever the number of learners. Unlike `logs_by_app_and_secure_key`,
   which needs one prefix per learner, there is no per-learner ceiling. The remaining limit is Athena's
   262,144-byte query text.
7. **`application` is the raw client value** (`Activity Player`), not the sanitized `app` partition
   value (`Activity_Player`) that `AthenaConfig` lists.

**Before the Firehose cutover**, the point where `processed_logs_with_id/` switches from one file per
day to Firehose's per-hour files (2022-01-01 00:00 UTC in production, 2021-12-20 14:00 UTC on staging),
each day with data is one file, `YYYY-MM-DD.parquet`, in its `00` hour folder. So hour-level filters on
that history are wrong and only whole-day ranges are meaningful. Most projected hours before the cutover
are empty, so a multi-year query pays for listing them.

**Measured cost** in production, on 2026-10-20. Athena answers `count(*)` from Parquet metadata
and scans no bytes for it, so the column-reading query is the guide to what a real query pays.

| Query | Range | Data in range | Rows | Bytes scanned | Total time |
|---|---|---|---|---|---|
| `count(*)` | hour, 2026-10-14 15:00 | 14.8 MB | 180,763 | 0 | 1.1 s |
| `count(*)` | day, 2026-10-14 | 170 MB | 1,849,364 | 0 | 2.1 s |
| `count(*)` | month, September 2026 | 4.84 GB | 31,609,940 | 0 | 4.7 s |
| `count(DISTINCT run_remote_endpoint)` | day, 2026-10-14 | 170 MB | 1,849,364 | 2.35 MB | 1.4 s |

**Reconciliation.** The table's rows for `dt` from `<D>/00` to `<D>/23` were compared by `id` with the
nightly copy's files for D (read through `logs_by_app` with
`regexp_like("$path", '/<DD>_[0-9]+\.parquet$')`). In production, 2026-10-14 has 1,849,364 rows on each
side, no `id` on one side only and no repeated `id`; the query scanned 88 MB, so the `$path` predicate
skipped the rest of the month. On staging, 2026-10-06 (15,432 rows) and 2026-10-12 (6,564 rows)
reconcile the same way.

**`logs_by_app`** reads the nightly copy by `app`, `year` and `month`, with no `secure_key` partition,
so it reads every secure-key folder under the month. It is a route for an app-scoped cohort with no
learner bound, over days the nightly copy already holds, and the only way to read the nightly copy
without a learner list, as the reconciliation above does. `secure_key` on `logs_by_app_and_secure_key`
is an `injected` projection, and Athena fails a query that does not give it a value. `logs_by_app`'s
cost was measured in production on 2026-10-20, for CLUE in September 2026 (844 MB in 547 folders: one
per secure key, plus `none` for rows with no secure key in their `run_remote_endpoint`), and compared
with the same month read through `logs_by_app_and_secure_key` with 20 learner keys, `none` excluded:

| Table | Query | Rows | Bytes scanned | Planning time | Total time |
|---|---|---|---|---|---|
| `logs_by_app` | `count(*)` | 208,307 | 0 | 0.3 s | 1.6 s |
| `logs_by_app` | `count(DISTINCT session)` | 208,307 | 8.37 MB | 0.5 s | 1.8 s |
| `logs_by_app_and_secure_key`, 20 keys | `count(*)` | 6,642 | 0 | 0.2 s | 1.1 s |
| `logs_by_app_and_secure_key`, 20 keys | `count(DISTINCT session)` | 6,642 | 0.27 MB | 0.2 s | 0.9 s |

Listing 547 folders kept planning to 0.5 s or less on `logs_by_app`, against 0.2 s with 20 keys (one run
of each), so the missing `secure_key` partition costs little in planning for an app-month of this size.
The column-reading query scanned about 40 bytes per row on both tables, so the bytes it scans follow the
rows it reads, not the number of folders listed.
