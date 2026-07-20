#!/usr/bin/env bash
# One-off ECS Fargate migration runner for report-server (any account / env).
#
# Clones the *live* service task definition (so it inherits DATABASE_URL and all env),
# swaps in the target image + the release migrator command, and runs it as a one-off
# Fargate task in the service's own subnets/security-groups. Migrations therefore run
# INSIDE the VPC where DB access already exists — no ssh tunnel, no bastion, no DB
# exposure. Waits for completion, reports the exit code + migration log, then
# deregisters the one-off task def.
#
# Run this BEFORE flipping the service/stack to the new image (migrate-then-serve):
# fail-closed paths (e.g. data_access_log) need their tables present before traffic.
#
# Usage:
#   scripts/run-migrate-task.sh --profile qa   --image concordconsortium/report-server:1.9.0-pre.0
#   scripts/run-migrate-task.sh --profile prod --image concordconsortium/report-server:1.9.0 --yes
#
# Flags (env-var fallback in parens):
#   --profile  AWS CLI profile / account       (PROFILE)         required
#   --image    full image ref to migrate       (IMAGE)           required
#   --cluster  ECS cluster                      (CLUSTER)         default: fargate-public-cluster
#   --service  ECS service to clone from        (SERVICE)         default: report-server
#   --family   one-off task-def family name     (MIGRATE_FAMILY)  default: report-server-migrate
#   --yes      skip the confirmation prompt     (ASSUME_YES=1)
#   --keep     leave the one-off task def registered afterwards
set -euo pipefail

PROFILE="${PROFILE:-}"; IMAGE="${IMAGE:-}"
CLUSTER="${CLUSTER:-fargate-public-cluster}"
SERVICE="${SERVICE:-report-server}"
MIGRATE_FAMILY="${MIGRATE_FAMILY:-report-server-migrate}"
ASSUME_YES="${ASSUME_YES:-}"; KEEP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --image)   IMAGE="$2";   shift 2;;
    --cluster) CLUSTER="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --family)  MIGRATE_FAMILY="$2"; shift 2;;
    --yes)     ASSUME_YES=1; shift;;
    --keep)    KEEP=1; shift;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$PROFILE" ] || { echo "ERROR: --profile (or PROFILE) required" >&2; exit 2; }
[ -n "$IMAGE" ]   || { echo "ERROR: --image (or IMAGE) required"   >&2; exit 2; }

AWS=(aws --profile "$PROFILE")

# --- Resolve account + the live service task def & network config (nothing pinned) --
ACCOUNT=$("${AWS[@]}" sts get-caller-identity --query Account --output text)
read -r TASKDEF SUBNETS SGS PUBIP < <("${AWS[@]}" ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].[taskDefinition,join(`,`,networkConfiguration.awsvpcConfiguration.subnets),join(`,`,networkConfiguration.awsvpcConfiguration.securityGroups),networkConfiguration.awsvpcConfiguration.assignPublicIp]' \
  --output text)
[ -n "${TASKDEF:-}" ] && [ "$TASKDEF" != "None" ] || {
  echo "ERROR: could not resolve a task def for service '$SERVICE' on cluster '$CLUSTER'" >&2; exit 1; }

cat <<EOF

  Migration plan
  --------------
  account : $ACCOUNT   (profile: $PROFILE)
  cluster : $CLUSTER
  service : $SERVICE
  from TD : $TASKDEF   (cloned live -> inherits DATABASE_URL + all env)
  image   : $IMAGE     (migrations run from THIS image)
  network : subnets=[$SUBNETS] sgs=[$SGS] publicIp=$PUBIP
  one-off : $MIGRATE_FAMILY$([ -n "$KEEP" ] && echo " (kept)" || echo " (deregistered after)")

EOF

if [ -z "$ASSUME_YES" ]; then
  read -r -p "Proceed with migrations against account $ACCOUNT? type 'yes': " ans
  [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

WORKDIR="$(mktemp -d)"

# --- Clone the live task def into a one-off migrate task def -----------------------
"${AWS[@]}" ecs describe-task-definition --task-definition "$TASKDEF" \
  --query 'taskDefinition' --output json > "$WORKDIR/td-src.json"

jq --arg fam "$MIGRATE_FAMILY" --arg img "$IMAGE" '{
  family: $fam,
  networkMode: .networkMode,
  requiresCompatibilities: .requiresCompatibilities,
  cpu: .cpu,
  memory: .memory,
  executionRoleArn: .executionRoleArn,
  containerDefinitions: [
    ( .containerDefinitions[0]
      | .image     = $img
      | .command   = ["/app/bin/report_server","eval","ReportServer.Release.migrate"]
      | .essential = true
      | del(.portMappings) )   # not needed for a batch task
  ]
} + (if .taskRoleArn then {taskRoleArn: .taskRoleArn} else {} end)' \
  "$WORKDIR/td-src.json" > "$WORKDIR/td-migrate.json"

# --- Register + run ----------------------------------------------------------------
"${AWS[@]}" ecs register-task-definition --cli-input-json "file://$WORKDIR/td-migrate.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text

TASK_ARN=$("${AWS[@]}" ecs run-task \
  --cluster "$CLUSTER" --launch-type FARGATE --task-definition "$MIGRATE_FAMILY" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SGS],assignPublicIp=$PUBIP}" \
  --started-by "migrate:${IMAGE##*:}" \
  --query 'tasks[0].taskArn' --output text)
echo "launched: $TASK_ARN"
# assignPublicIp mirrors the service; the public subnets have no NAT, so a public IP
# is required to pull the image from the registry.

# --- Wait + exit code (0 == migrations succeeded) ---------------------------------
"${AWS[@]}" ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"
RESULT=$("${AWS[@]}" ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].{status:lastStatus,exitCode:containers[0].exitCode,stopReason:stoppedReason,containerReason:containers[0].reason}' \
  --output json)
echo "$RESULT"
EXIT=$(printf '%s' "$RESULT" | jq -r '.exitCode // empty')

# --- Migration log (get-log-events; works on AWS CLI v1, which has no `logs tail`) --
TASK_ID="${TASK_ARN##*/}"
LOG_GROUP=$(jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]'         "$WORKDIR/td-src.json")
LOG_PREFIX=$(jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-stream-prefix"]' "$WORKDIR/td-src.json")
CONTAINER=$(jq -r '.containerDefinitions[0].name'                                                "$WORKDIR/td-src.json")
echo "--- migration log ($LOG_GROUP : $LOG_PREFIX/$CONTAINER/$TASK_ID) ---"
"${AWS[@]}" logs get-log-events --log-group-name "$LOG_GROUP" \
  --log-stream-name "$LOG_PREFIX/$CONTAINER/$TASK_ID" \
  --start-from-head --query 'events[].message' --output text || true

# --- Cleanup the one-off task def --------------------------------------------------
if [ -z "$KEEP" ]; then
  MIG_TD=$("${AWS[@]}" ecs describe-task-definition --task-definition "$MIGRATE_FAMILY" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  "${AWS[@]}" ecs deregister-task-definition --task-definition "$MIG_TD" \
    --query 'taskDefinition.status' --output text >/dev/null
  echo "deregistered one-off task def: $MIG_TD"
fi

if [ "${EXIT:-}" = "0" ]; then
  echo "✅ migrations applied (exit 0). Now safe to flip the service/stack image to: $IMAGE"
else
  echo "❌ migration task exit code: ${EXIT:-unknown} — check the log above; do NOT flip the image." >&2
  exit 1
fi
