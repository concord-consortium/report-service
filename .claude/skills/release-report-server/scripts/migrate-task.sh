#!/usr/bin/env bash
# Read or apply Ecto migrations as a one-off Fargate task, and print what it said.
#
# The database is not reachable from a workstation: both RDS instances refuse
# connections from outside the VPC, and the SSH bastion the older runbooks describe
# is gone. A one-off task needs no tunnel, because the task definition already
# carries DATABASE_URL and the task runs inside the VPC that can reach the database.
#
# usage: migrate-task.sh <staging|production> <status|apply> [image]
#
#   status   print every migration the image contains and whether the database has
#            it, as "MIGRATION up|down <version> <name>"
#   apply    run ReportServer.Release.migrate, then re-read status and require every
#            migration in the image to be up
#
# With no image the task runs the task definition the service is running right now,
# which is what a pre-flight read wants and which registers nothing. The image
# decides which migration files exist and the database decides which are applied, so
# a read against the deployed image cannot show the release's new migrations at all
# (they are absent from its list, not reported as pending). Pass the release image to
# see them, and to apply them.
#
# Passing an image registers a task definition revision, because run-task --overrides
# can change the command but NOT the image. This script deregisters that revision on
# exit: each account otherwise holds exactly one active revision, CloudFormation's, so
# anything left behind shows up as drift for whoever looks next. A deregistered
# revision can still be described, which is what an audit trail needs, but it cannot
# be run, so a retry registers a fresh one.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env-config.sh
. "$here/env-config.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: $(basename "$0") <staging|production> <status|apply> [image]" >&2
  echo "  e.g. $(basename "$0") staging status" >&2
  echo "       $(basename "$0") staging apply concordconsortium/report-server:1.11.0" >&2
  exit 2
fi

rs_env "$1" || exit 2
MODE="$2"
IMAGE="${3:-}"
case "$MODE" in status|apply) ;; *) echo "mode must be 'status' or 'apply'" >&2; exit 2;; esac
if [ "$MODE" = apply ] && [ -z "$IMAGE" ]; then
  echo "apply needs the release image: applying with the deployed image would run the old migration set" >&2
  exit 2
fi
rs_check_account || exit 1

aws_() { aws --profile "$RS_PROFILE" "$@"; }

TMP=""
REGISTERED=""
cleanup() {
  [ -n "$TMP" ] && rm -f "$TMP"
  if [ -n "$REGISTERED" ]; then
    if aws_ ecs deregister-task-definition --task-definition "$REGISTERED" \
         --query 'taskDefinition.status' --output text >/dev/null 2>&1; then
      echo "deregistered $REGISTERED"
    else
      echo "could not deregister $REGISTERED; do it by hand" >&2
    fi
  fi
}
trap cleanup EXIT

STATUS_CODE='Application.load(:report_server); {:ok, _, _} = Ecto.Migrator.with_repo(ReportServer.Repo, fn repo -> Ecto.Migrator.migrations(repo) |> Enum.each(fn {s, v, n} -> IO.puts("MIGRATION #{s} #{v} #{n}") end) end)'
MIGRATE_CODE='ReportServer.Release.migrate'

# Runs one eval task to completion and leaves its output in OUT and its container exit
# code in TASK_EXIT. Returns non-zero if the task could not be started or did not stop.
run_eval() {
  local code="$1" label="$2" overrides network task_arn status
  overrides=$(jq -nc --arg name "$RS_SERVICE" --arg code "$code" \
    '{containerOverrides:[{name:$name,command:["/app/bin/report_server","eval",$code]}]}')
  network="{\"awsvpcConfiguration\":{\"subnets\":[$RS_SUBNETS],\"securityGroups\":[$RS_SGS],\"assignPublicIp\":\"ENABLED\"}}"

  task_arn=$(aws_ ecs run-task --cluster "$RS_CLUSTER" --task-definition "$TD" \
    --launch-type FARGATE --network-configuration "$network" --overrides "$overrides" \
    --started-by "report-server-migrate-$label" --query 'tasks[0].taskArn' --output text)
  if [ -z "$task_arn" ] || [ "$task_arn" = None ]; then
    echo "run-task did not start a task; re-run with --query 'failures' to see why" >&2
    return 1
  fi
  TASK_ID=${task_arn##*/}
  echo "task $TASK_ID ($label)"

  # A task takes about a minute end to end, most of it pulling the image.
  local deadline=$((SECONDS + 600))
  while :; do
    read -r status TASK_EXIT <<<"$(aws_ ecs describe-tasks --cluster "$RS_CLUSTER" --tasks "$TASK_ID" \
      --query 'tasks[0].[lastStatus,containers[0].exitCode]' --output text)"
    echo "$(date +%H:%M:%S) $status exit=$TASK_EXIT"
    [ "$status" = STOPPED ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "task $TASK_ID did not stop within 10 minutes" >&2
      return 1
    fi
    sleep 10
  done

  # The log stream is named for the task id, so there is no scanning and no ambiguity.
  # It can lag the task by a few seconds, so poll for it rather than reading once.
  echo "--- log: ecs/$RS_SERVICE/$TASK_ID ---"
  local log_deadline=$((SECONDS + 120))
  while :; do
    OUT=$(aws_ logs get-log-events --log-group-name "$RS_LOG_GROUP" \
      --log-stream-name "ecs/$RS_SERVICE/$TASK_ID" --limit 200 --start-from-head \
      --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n')
    [ -n "$OUT" ] && break
    if [ "$SECONDS" -ge "$log_deadline" ]; then
      echo "(no log events after 2 minutes; the stream may have been delayed)" >&2
      break
    fi
    sleep 10
  done
  [ -n "$OUT" ] && echo "$OUT"
  return 0
}

TD=$(aws_ ecs describe-services --cluster "$RS_CLUSTER" --services "$RS_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
if [ -z "$TD" ] || [ "$TD" = None ]; then
  echo "could not read the running task definition for $RS_SERVICE" >&2
  exit 1
fi
echo "service task definition: $TD"

# Written with a restrictive umask and deleted on exit: the task definition holds
# DATABASE_URL, SECRET_KEY_BASE and the AWS keys in plaintext. Never print it.
if [ -n "$IMAGE" ]; then
  TMP=$(umask 077; mktemp)
  aws_ ecs describe-task-definition --task-definition "$TD" --output json \
    | jq --arg img "$IMAGE" '
        .taskDefinition
        | del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,
              .registeredAt,.registeredBy,.deregisteredAt)
        | .containerDefinitions[0].image = $img' > "$TMP" || exit 1
  TD=$(aws_ ecs register-task-definition --cli-input-json file://"$TMP" \
    --query 'taskDefinition.taskDefinitionArn' --output text) || exit 1
  REGISTERED="$TD"
  echo "registered $TD"
fi

if [ "$MODE" = apply ]; then
  run_eval "$MIGRATE_CODE" apply || exit 1
  if [ "$TASK_EXIT" != 0 ]; then
    # MySQL DDL is not transactional, so a run that dies partway leaves the earlier
    # migrations committed. The status read below says how far it got.
    echo "FAILED: migrate task exited $TASK_EXIT" >&2
    run_eval "$STATUS_CODE" status-after-failure
    exit 1
  fi
fi

run_eval "$STATUS_CODE" status || exit 1
if [ "$TASK_EXIT" != 0 ]; then
  echo "FAILED: status task exited $TASK_EXIT" >&2
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -q '^MIGRATION '; then
  echo "FAILED: status task exited 0 but printed no MIGRATION lines" >&2
  exit 1
fi

# Exit 0 from the migrate task says the container exited cleanly, not that the schema
# is where it should be, so the applied set is what decides this script's result. A
# standalone status read only reports: a "down" there is a pre-flight observation for
# the caller to explain, not this script's to judge.
if [ "$MODE" = apply ] && printf '%s\n' "$OUT" | grep -q '^MIGRATION down '; then
  echo "FAILED: migrations still down after apply:" >&2
  printf '%s\n' "$OUT" | grep '^MIGRATION down ' >&2
  exit 1
fi
echo "OK ($MODE)"
