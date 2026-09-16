---
name: release-report-server
description: Release and deploy the Elixir report server to staging or production on AWS ECS. Bumps the mix.exs version, builds and pushes the Docker image, applies Ecto migrations as a one-off Fargate task, updates the CloudFormation stack to the new image, verifies the deployed version, and tags the release. Use when asked to release, deploy, cut a version, ship to staging or production, or push the report server to AWS.
---

# Release the report server

Releases the Elixir/Phoenix server in `server/` by bumping its version, building and
pushing a Docker image, migrating the environment's database with a one-off Fargate
task, and pointing the environment's CloudFormation stack at the new image.

**Deploying is a real, user-visible change.** The report server holds researcher and
teacher data and is used by staff against live portals. Never run the production path
without an explicit confirmation from the user in the same conversation, and never
skip the pre-flight checks to save time.

## What this skill does not cover

- **The Firebase functions release**, which is versioned separately in `functions/`,
  tagged `report-service-vX.Y.Z`, and committed as `chore: functions X.Y.Z`. Server
  tags are `report-service-server-X.Y.Z`. The two release tracks share this repo and
  nothing else, so do not bump one while releasing the other.
- **cc-data-cli releases**, which live in the sibling `cc-data-cli` repo. They are
  coupled in one direction only: CLI features that call a new server endpoint are
  inert until the server ships, so **the server release goes first**. If the user is
  releasing both, finish this one, including production, before tagging the CLI.

## Environment parameter

Takes `staging`, `production`, or both.

**If the argument is absent, ask the user in chat before doing anything else.** Do
not infer it from the branch or from the last release. The usual request is the full
sequence: staging first, verified, then production, with the same image promoted
rather than rebuilt. Steps 1 to 5 happen once; steps 6 to 8 happen per environment.

## Environment configuration

The scripts hold this same table in `scripts/env-config.sh`, so prefer them to
re-deriving it. **The stack names are the trap**: they are report-serv*ice*, matching
this repo, while the ECS service inside them is report-serv*er*, matching the app.

| | staging | production |
|---|---|---|
| CloudFormation stack | `report-service-qa` | `report-service-prod` |
| AWS account | 816253370536 | 612297603577 |
| AWS CLI profile | `concord-qa` | `default` |
| Host | `report-server.concordqa.org` | `report-server.concord.org` |
| Portal it talks to | learn.portal.staging.concord.org | learn.concord.org |
| Firebase app | report-service-dev | report-service |

Both environments share the cluster name `fargate-public-cluster`, the ECS service
name `report-server`, and the CloudWatch log group `/ecs/report-server`, and each
stack carries 35 parameters. Neither stack has any `Capabilities`, so `update-stack`
needs no `--capabilities` flag. Region is `us-east-1` and the image repo is
`concordconsortium/report-server` on Docker Hub.

Both environments run the **same image**: a `-pre.N` suffix marks a pre-release
during development, not an environment.

## Helper scripts

Three scripts ship with this skill in its own `scripts/` directory. **Their paths are
relative to the skill, not to the repo**, and this repo has its own top-level
`scripts/`, so a bare `scripts/migrate-task.sh` resolves to the wrong thing. Set
`SKILL_DIR` from the base directory reported when the skill was loaded:

```bash
SKILL_DIR=<the skill's base directory>   # as reported on load
```

| script | answers |
|---|---|
| `migrate-task.sh <env> <status\|apply> [image]` | which migrations exist and which are applied, and applies them, verifying the result |
| `update-stack.sh <env> <image>` | points the stack at an image and waits for it to settle |
| `check-deployed-version.sh <env> <version> [streak] [max-seconds]` | is the new image actually serving, and is the API mounted |

All three resolve the profile from the environment and refuse to run if that profile
resolves to the wrong AWS account. The profiles default to `concord-qa` and `default`
and are overridden with `RS_PROFILE_STAGING` and `RS_PROFILE_PRODUCTION`.
`env-config.sh` is sourced by the others and is not run directly.

## The database is only reachable from inside the VPC

Both RDS instances refuse connections from a workstation, so migrations run as a
one-off Fargate task in the same account as the stack. The task definition already
carries `DATABASE_URL` and every other environment variable the app needs, which is
what makes this work with no extra configuration.

**Do not go looking for an SSH tunnel or a bastion.** Older notes in the oob store
describe one, and it is gone: the host in the shell history no longer answers and is
not an instance in either account, and the one EC2 instance in the QA account tagged
`concordqa.bastion` has never been confirmed as a route to this database. Starting a
stopped EC2 instance on the strength of its name tag is a mistake that has already
been made once here. The bastion documented for the *portal* database is for the
portal Aurora cluster and is unrelated.

**`run-task --overrides` can change the command but not the image.** Reading or
applying migrations with the release's image therefore needs a task definition
revision, which `migrate-task.sh` registers when passed an image and deregisters again
on exit. Each account otherwise holds exactly one active revision, CloudFormation's
own, so anything left behind reads as drift to whoever looks next. A deregistered
revision can still be described, which is all an audit trail needs, but it cannot be
run, so a retry registers a fresh one.

Any file generated from a task definition or a stack description holds
`DATABASE_URL`, `SECRET_KEY_BASE` and the AWS keys in plaintext. The scripts write
them with a restrictive umask and delete them on exit. If you generate one by hand,
put it in a scratchpad, never in the repo, and never print it.

## Steps

### 1. Preconditions

- Working tree clean, on `master`, and `git pull` done. Releases are normally cut
  from master. Building from an unmerged branch is an accepted pattern for a
  pre-release so a story requester can verify their own story, but it is never the
  default: surface the branch and its open PR and ask.
- Report what is deployed now, before changing anything:

```bash
curl -s https://report-server.concordqa.org/ | grep -o 'Version [0-9][^<]*'
curl -s https://report-server.concord.org/  | grep -o 'Version [0-9][^<]*'
```

- Confirm both stacks are settled (`UPDATE_COMPLETE`). `update-stack.sh` refuses to
  deploy onto a stack that is mid-update or sitting in a rollback, which is how a
  stack gets stuck.

### 2. Choose the version

The version lives in `server/mix.exs` under `version:`. Bump it from the commits
since the last server release: any `feat:` commit means a minor bump, otherwise a
patch bump.

```bash
FROM_TAG=$(git tag --sort=-v:refname | grep -- -server- | head -1)
git log --oneline "$FROM_TAG"..HEAD -- server
```

Confirm the version with the user before touching anything. Note that the last tag
may be far behind: a release can carry a hundred commits and a dozen tickets, and
the ticket list is worth reporting since it is what the Jira release notes need.

### 3. Pre-flight checks

Run all four and report them together **before** bumping or building.

**a. Migrations that will apply.**

```bash
git diff --name-only "$FROM_TAG"..HEAD -- server/priv/repo/migrations
```

Empty output means step 6 is skipped entirely. Say so rather than running the task as
a no-op.

Then read the database's own account of what is applied, which is the only thing that
can distinguish "this release adds it" from "it is already there":

```bash
"$SKILL_DIR"/scripts/migrate-task.sh staging status
```

With no image argument this runs the task definition the service is running now and
registers nothing. **The image decides which migration files exist and the database
decides which are applied**, so a read against the deployed image does not list the
release's new migrations at all. That is expected here, not an error. Anything
reported `down` before you start is a leftover from an earlier release and needs
explaining first.

**b. CI is green for the commit being built.** Do not deploy an untested commit.

```bash
gh run list --limit 10 --json headSha,name,conclusion,createdAt
```

**Match on `headSha`, not on branch.** `gh run list --branch master` has returned
runs months old while the actual run for the current commit was listed under the tag
ref that triggered it, which makes a stale pass look current. If the only green run
is for an earlier commit, check whether the difference touches `server/`: a
docs-only commit on top of a tested commit leaves the server code identical, and
saying so explicitly is better than implying the head commit was tested.

**c. Direction of the deploy.** Compare what is deployed against what is about to
ship, per environment, and **ask before proceeding on anything that is not a clean
forward move.** Production is normally one release behind staging, so staging may
already be running a `-pre.N` of the version being released. A rollback is a
legitimate deliberate downgrade, so the point is to distinguish it from an accident,
not to refuse it.

**d. Anything expected in this release that has not merged.** `gh pr list` and a
glance at the release's Jira fix version. A release that silently omits a story
someone is waiting on is worse than a late one.

### 4. Bump the version

Edit `server/mix.exs` and commit:

```
build: Update report server version to X.Y.Z
```

Branch protection on master allows an admin to push a version bump directly, without
a PR, and that is the normal route for this commit. It has deliberately been left
uncommitted once, for a pre-release built from a branch, so **ask rather than
defaulting either way**.

The version in the app header comes from this field, compiled into `:vsn` and read by
`app.html.heex`, **not** from the Docker tag. An image built without bumping it
deploys successfully and still reports the old version, which reads as a silently
failed deploy.

### 5. Build, verify, and push the image

```bash
cd server
docker build . -t concordconsortium/report-server:X.Y.Z
```

About 5 minutes cold, much faster warm. It emits four harmless lint warnings
(FromAsCasing, LegacyKeyValueFormat x3). The local machine and the Fargate tasks are
both x86_64, so no `--platform` flag is needed; on an ARM Mac it would need
`--platform linux/amd64`.

Verify the version is really baked in **before** pushing, which catches a forgotten
bump in seconds:

```bash
docker run --rm --entrypoint sh concordconsortium/report-server:X.Y.Z \
  -c 'ls /app/lib | grep report_server'          # expect report_server-X.Y.Z
```

The same trick lists the migrations an image contains, which is how to tell whether a
running image could have applied a given migration:

```bash
docker run --rm --entrypoint sh concordconsortium/report-server:X.Y.Z \
  -c 'ls /app/lib/report_server-*/priv/repo/migrations'
```

Then push, and record the digest it prints for the report:

```bash
docker push concordconsortium/report-server:X.Y.Z
```

A Docker Hub credential is normally already in `~/.docker/config.json`; run
`docker login` only if the push comes back unauthorized.

### 6. Apply migrations (per environment)

Skip if step 3a found none. Otherwise migrate **before** the stack update for that
environment: the new image's paths fail closed against a table or column it expects
and the database does not have. An additive change such as a nullable column is safe
to land while the old image is still serving, because the old image ignores it.

```bash
"$SKILL_DIR"/scripts/migrate-task.sh <env> apply concordconsortium/report-server:X.Y.Z
```

One call does the whole thing: it registers a revision on the release image, runs the
migration, re-reads the applied set, fails if anything is still `down`, and
deregisters the revision on the way out. That second read is the assertion that
matters, because exit 0 from the migrate task says only that the container exited
cleanly. Record the apply task's id, which is the handle on its CloudWatch stream
later.

**If the apply fails, do not assume the database is untouched.** MySQL DDL is not
transactional, so a run that fails partway through several migrations leaves the
earlier ones committed and recorded while the later ones are not. The script reads the
applied set again after a failed apply for exactly this reason: report how far it got
and resolve forward. Do not re-run blindly and do not start the stack update.

### 7. Update the stack (per environment)

**For production, confirm with the user immediately before this**, even if they
already said "staging then production". Staging must be verified first.

```bash
"$SKILL_DIR"/scripts/update-stack.sh <env> concordconsortium/report-server:X.Y.Z
```

Three to four minutes from `UPDATE_IN_PROGRESS` to `UPDATE_COMPLETE`. Anything
containing `ROLLBACK` means the new task failed its health check and ECS reverted;
the script prints the failing resource's reason and stops.

### 8. Verify (per environment)

```bash
"$SKILL_DIR"/scripts/check-deployed-version.sh <env> X.Y.Z
```

This asserts the served version, a 200 from the root, and a 401 from
`/api/v1/tokens/current`. The 401 is the check with teeth: it proves the
authenticated API is mounted, where a 404 is what an older image looks like.

For a functional check of the release's own surfaces, the `cc-data` CLI is the
fastest route when the release touches the API:

```bash
cc-data reports filter-options --dimension class --portal staging   # read-only
cc-data reports create --portal staging --report-slug student-answers \
  --report-filter '{"class":[164]}'                                 # writes a run
```

`reports create` leaves a real run in `queued` that the server's poller will pick up
and run an Athena query for, so use it deliberately and say so in the report.

### 9. Tag

**After production is verified**, so the tag only ever points at something that
shipped:

```bash
git tag report-service-server-X.Y.Z <commit>
git push origin report-service-server-X.Y.Z
```

Pushing any tag in this repo also fires the Report Server and Firestore/Functions
test workflows, which is expected and is not part of the release.

### 10. GitHub release and Jira

The user normally does both by hand. **Offer, do not assume**, and do not create a
GitHub release object before production is verified.

### 11. Report

State, per environment: the version deployed and the version it replaced, the image
digest, which migrations applied and the apply task's id (or that there were none),
the verification results, and the tag. Mention anything deferred or skipped,
including a GitHub release or Jira transition you did not do. If `migrate-task.sh`
ever reports that it could not deregister a revision, say so: that is the one case
where an account is left holding more than CloudFormation's own.

## Rollback

Re-run step 7 with the previous image tag, which is the version the environment was
running before. Nothing else is needed: the image is the only thing the release
changed in the stack.

**Migrations are not rolled back.** An additive migration is safe to leave in place,
since the older image ignores the new column. A destructive or non-additive migration
is not, and the user must be told directly rather than discovering it when the older
code meets a schema it does not expect.
