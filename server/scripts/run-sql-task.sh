#!/usr/bin/env bash
# One-off ECS Fargate SQL runner for report-server (any account / env).
#
# Adapted from run-migrate-task.sh. Same trick: clones the *live* service task
# definition (so it inherits DATABASE_URL and all env), but instead of running the
# release migrator it evaluates a raw SQL statement through the release's Ecto repo.
# The query therefore runs INSIDE the VPC where DB access already exists: no ssh
# tunnel, no bastion, no publicly-exposed DB, no credentials on your laptop.
#
# The SQL is passed to the container as an env var (SQL_QUERY) rather than being
# interpolated into the command, so quoting in your statement does not need escaping.
#
# Usage:
#   scripts/run-sql-task.sh --profile qa --sql "SELECT VERSION()"
#   scripts/run-sql-task.sh --profile qa --sql-file ./precheck.sql
#   scripts/run-sql-task.sh --profile prod --sql "SELECT COUNT(*) FROM users" --yes
#
# Flags (env-var fallback in parens):
#   --profile   AWS CLI profile / account      (PROFILE)        required
#   --sql       SQL statement to run           (SQL_QUERY)      required unless --sql-file
#   --sql-file  read the SQL from a file       (SQL_FILE)
#   --image     image to run the query from    (IMAGE)          default: the live service image
#   --cluster   ECS cluster                    (CLUSTER)        default: fargate-public-cluster
#   --service   ECS service to clone from      (SERVICE)        default: report-server
#   --family    one-off task-def family name   (SQL_FAMILY)     default: report-server-sql
#   --yes       skip the confirmation prompt   (ASSUME_YES=1)
#   --keep      leave the one-off task def registered afterwards
#
# NOTE: this will run ANY statement you give it, including writes. Statements that
# are not obviously read-only always prompt, even with --yes.
set -euo pipefail

PROFILE="${PROFILE:-}"; IMAGE="${IMAGE:-}"
SQL="${SQL_QUERY:-}"; SQL_FILE="${SQL_FILE:-}"
CLUSTER="${CLUSTER:-fargate-public-cluster}"
SERVICE="${SERVICE:-report-server}"
SQL_FAMILY="${SQL_FAMILY:-report-server-sql}"
ASSUME_YES="${ASSUME_YES:-}"; KEEP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)  PROFILE="$2";  shift 2;;
    --sql)      SQL="$2";      shift 2;;
    --sql-file) SQL_FILE="$2"; shift 2;;
    --image)    IMAGE="$2";    shift 2;;
    --cluster)  CLUSTER="$2";  shift 2;;
    --service)  SERVICE="$2";  shift 2;;
    --family)   SQL_FAMILY="$2"; shift 2;;
    --yes)      ASSUME_YES=1;  shift;;
    --keep)     KEEP=1;        shift;;
    -h|--help)  sed -n '2,33p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$PROFILE" ] || { echo "ERROR: --profile (or PROFILE) required" >&2; exit 2; }
if [ -n "$SQL_FILE" ]; then
  [ -r "$SQL_FILE" ] || { echo "ERROR: cannot read --sql-file '$SQL_FILE'" >&2; exit 2; }
  SQL="$(cat "$SQL_FILE")"
fi
[ -n "$SQL" ] || { echo "ERROR: --sql or --sql-file required" >&2; exit 2; }

AWS=(aws --profile "$PROFILE")

# --- Resolve account + the live service task def & network config (nothing pinned) --
ACCOUNT=$("${AWS[@]}" sts get-caller-identity --query Account --output text)
read -r TASKDEF SUBNETS SGS PUBIP < <("${AWS[@]}" ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].[taskDefinition,join(`,`,networkConfiguration.awsvpcConfiguration.subnets),join(`,`,networkConfiguration.awsvpcConfiguration.securityGroups),networkConfiguration.awsvpcConfiguration.assignPublicIp]' \
  --output text)
[ -n "${TASKDEF:-}" ] && [ "$TASKDEF" != "None" ] || {
  echo "ERROR: could not resolve a task def for service '$SERVICE' on cluster '$CLUSTER'" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

"${AWS[@]}" ecs describe-task-definition --task-definition "$TASKDEF" \
  --query 'taskDefinition' --output json > "$WORKDIR/td-src.json"

# Default to the image the service is already running: we are only reading, so there
# is no reason to pull a different build than the one that owns this schema.
if [ -z "$IMAGE" ]; then
  IMAGE=$(jq -r '.containerDefinitions[0].image' "$WORKDIR/td-src.json")
fi

# --- Read-only heuristic: anything else always prompts, even with --yes ------------
FIRST_WORD=$(printf '%s' "$SQL" | tr -d '[:space:]' | head -c 200 | tr '[:lower:]' '[:upper:]')
READONLY=""
case "$FIRST_WORD" in
  SELECT*|SHOW*|DESCRIBE*|DESC*|EXPLAIN*|WITH*) READONLY=1;;
esac

cat <<EOF

  SQL task plan
  -------------
  account : $ACCOUNT   (profile: $PROFILE)
  cluster : $CLUSTER
  service : $SERVICE
  from TD : $TASKDEF   (cloned live -> inherits DATABASE_URL + all env)
  image   : $IMAGE
  network : subnets=[$SUBNETS] sgs=[$SGS] publicIp=$PUBIP
  one-off : $SQL_FAMILY$([ -n "$KEEP" ] && echo " (kept)" || echo " (deregistered after)")
  mode    : $([ -n "$READONLY" ] && echo "read-only (heuristic)" || echo "*** NOT obviously read-only ***")

  SQL:
$(printf '%s\n' "$SQL" | sed 's/^/    /')

EOF

if [ -z "$ASSUME_YES" ] || [ -z "$READONLY" ]; then
  [ -z "$READONLY" ] && echo "This statement is not obviously read-only; confirming regardless of --yes." >&2
  read -r -p "Run this SQL against account $ACCOUNT? type 'yes': " ans
  [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

# --- Clone the live task def into a one-off SQL task def ---------------------------
# The SQL travels as an env var so the caller never has to escape quotes into JSON.
# The eval body is a fixed string: it reads SQL_QUERY at runtime.
read -r -d '' EVAL_BODY <<'ELIXIR' || true
Application.load(:report_server)
sql = System.get_env("SQL_QUERY")
[repo | _] = Application.fetch_env!(:report_server, :ecto_repos)
{:ok, _, _} =
  Ecto.Migrator.with_repo(repo, fn r ->
    res = Ecto.Adapters.SQL.query!(r, sql, [])
    fmt = fn
      nil -> "NULL"
      v when is_binary(v) -> (if String.printable?(v), do: v, else: Base.encode16(v))
      v -> inspect(v)
    end
    IO.puts(Enum.join(res.columns || [], " | "))
    IO.puts(String.duplicate("-", 60))
    Enum.each(res.rows || [], fn row -> IO.puts(Enum.map_join(row, " | ", fmt)) end)
    IO.puts("(#{res.num_rows} rows)")
  end)
ELIXIR

jq --arg fam "$SQL_FAMILY" --arg img "$IMAGE" --arg sql "$SQL" --arg body "$EVAL_BODY" '{
  family: $fam,
  networkMode: .networkMode,
  requiresCompatibilities: .requiresCompatibilities,
  cpu: .cpu,
  memory: .memory,
  executionRoleArn: .executionRoleArn,
  containerDefinitions: [
    ( .containerDefinitions[0]
      | .image       = $img
      | .command     = ["/app/bin/report_server","eval",$body]
      | .environment = ((.environment // []) + [{name:"SQL_QUERY", value:$sql}])
      | .essential   = true
      | del(.portMappings) )   # not needed for a batch task
  ]
} + (if .taskRoleArn then {taskRoleArn: .taskRoleArn} else {} end)' \
  "$WORKDIR/td-src.json" > "$WORKDIR/td-sql.json"

# --- Register + run ----------------------------------------------------------------
"${AWS[@]}" ecs register-task-definition --cli-input-json "file://$WORKDIR/td-sql.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text

TASK_ARN=$("${AWS[@]}" ecs run-task \
  --cluster "$CLUSTER" --launch-type FARGATE --task-definition "$SQL_FAMILY" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SGS],assignPublicIp=$PUBIP}" \
  --started-by "sql-task" \
  --query 'tasks[0].taskArn' --output text)
echo "launched: $TASK_ARN"
# assignPublicIp mirrors the service; the public subnets have no NAT, so a public IP
# is required to pull the image from the registry.

# --- Wait + exit code (0 == query ran) --------------------------------------------
"${AWS[@]}" ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"
RESULT=$("${AWS[@]}" ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].{status:lastStatus,exitCode:containers[0].exitCode,stopReason:stoppedReason,containerReason:containers[0].reason}' \
  --output json)
echo "$RESULT"
EXIT=$(printf '%s' "$RESULT" | jq -r '.exitCode // empty')

# --- Query output ------------------------------------------------------------------
TASK_ID="${TASK_ARN##*/}"
LOG_GROUP=$(jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]'         "$WORKDIR/td-src.json")
LOG_PREFIX=$(jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-stream-prefix"]' "$WORKDIR/td-src.json")
CONTAINER=$(jq -r '.containerDefinitions[0].name'                                                "$WORKDIR/td-src.json")
echo "--- query output ($LOG_GROUP : $LOG_PREFIX/$CONTAINER/$TASK_ID) ---"
"${AWS[@]}" logs get-log-events --log-group-name "$LOG_GROUP" \
  --log-stream-name "$LOG_PREFIX/$CONTAINER/$TASK_ID" \
  --start-from-head --query 'events[].message' --output text || true

# --- Cleanup the one-off task def --------------------------------------------------
# The task def carries the SQL in plaintext env, so deregistering is the default.
if [ -z "$KEEP" ]; then
  SQL_TD=$("${AWS[@]}" ecs describe-task-definition --task-definition "$SQL_FAMILY" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  "${AWS[@]}" ecs deregister-task-definition --task-definition "$SQL_TD" \
    --query 'taskDefinition.status' --output text >/dev/null
  echo "deregistered one-off task def: $SQL_TD"
fi

if [ "${EXIT:-}" = "0" ]; then
  echo "✅ query completed (exit 0)"
else
  echo "❌ query task exit code: ${EXIT:-unknown}, check the log above." >&2
  exit 1
fi
