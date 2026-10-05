#!/usr/bin/env bash
# Point an environment's CloudFormation stack at a new image and wait for it to settle.
#
# usage: update-stack.sh <staging|production> <image>
#   e.g. update-stack.sh staging concordconsortium/report-server:1.11.0
#
# update-stack requires every parameter to be restated, so the parameter list is
# generated from the live stack with UsePreviousValue on all 35 of them and only
# ImageUrl overridden. Generating it from live state is also what keeps the secret
# parameters (database password, secret key base, AWS keys) out of the command line:
# they are never read, only referred to.
#
# --use-previous-template is deliberate. Template changes live in the sibling
# cloud-formation repo and are deployed from there; a release only ever moves the
# image, and passing the template would silently drag in whatever else has changed.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env-config.sh
. "$here/env-config.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: $(basename "$0") <staging|production> <image>" >&2
  exit 2
fi
rs_env "$1" || exit 2
IMAGE="$2"
rs_check_account || exit 1

aws_() { aws --profile "$RS_PROFILE" "$@"; }

BEFORE=$(aws_ cloudformation describe-stacks --stack-name "$RS_STACK" \
  --query "Stacks[0].[StackStatus,LastUpdatedTime,Parameters[?ParameterKey=='ImageUrl'].ParameterValue|[0]]" --output text)
read -r STATUS BEFORE_UPDATED CURRENT_IMAGE <<<"$BEFORE"
echo "$RS_STACK: $STATUS, currently $CURRENT_IMAGE"

# Deploying onto a stack that is mid-update or sitting in a rollback is how a stack
# gets stuck, so refuse anything but a settled one.
case "$STATUS" in
  UPDATE_COMPLETE|CREATE_COMPLETE) ;;
  *) echo "stack is not settled ($STATUS); resolve that before deploying" >&2; exit 1;;
esac

if [ "$CURRENT_IMAGE" = "$IMAGE" ]; then
  # CloudFormation rejects a no-op update with "No updates are to be performed",
  # and re-pointing the parameter at the image it already holds cannot restart
  # anything, so say what is actually happening rather than failing obscurely.
  echo "stack already holds $IMAGE; nothing to update" >&2
  exit 1
fi

params=$(umask 077; mktemp)
trap 'rm -f "$params"' EXIT
aws_ cloudformation describe-stacks --stack-name "$RS_STACK" \
  --query 'Stacks[0].Parameters[].ParameterKey' --output json \
  | jq --arg img "$IMAGE" 'map(if . == "ImageUrl"
        then {ParameterKey: ., ParameterValue: $img}
        else {ParameterKey: ., UsePreviousValue: true} end)' > "$params" || exit 1
echo "restating $(jq length "$params") parameters, ImageUrl -> $IMAGE"

aws_ cloudformation update-stack --stack-name "$RS_STACK" --use-previous-template \
  --parameters file://"$params" --query 'StackId' --output text || exit 1

# Three to four minutes in both environments. CloudFormation does not report complete
# until the new ECS task is healthy and the old one has drained, which is why the
# version header is already correct the moment this returns.
#
# LastUpdatedTime moves when an update starts, so comparing it against the value read
# before the update is what distinguishes this deploy's terminal status from the one
# the previous deploy left behind. describe-stacks is eventually consistent, and a
# first poll that lands before the update registers otherwise reads UPDATE_COMPLETE
# and reports a deploy that has not begun.
DEADLINE=$((SECONDS + 1800))
while :; do
  read -r s updated <<<"$(aws_ cloudformation describe-stacks --stack-name "$RS_STACK" \
    --query 'Stacks[0].[StackStatus,LastUpdatedTime]' --output text)"
  if [ "$updated" = "$BEFORE_UPDATED" ]; then
    echo "$(date +%H:%M:%S) $s (waiting for the update to register)"
    sleep 20
    continue
  fi
  echo "$(date +%H:%M:%S) $s"
  case "$s" in
    UPDATE_COMPLETE) echo "OK ($RS_STACK now on $IMAGE)"; exit 0;;
    *ROLLBACK*|*FAILED)
      echo "FAILED: $s" >&2
      # The failing resource's reason is the only useful part of the event stream.
      aws_ cloudformation describe-stack-events --stack-name "$RS_STACK" --max-items 20 \
        --query 'StackEvents[?ResourceStatusReason!=null].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output text >&2
      exit 1;;
  esac
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "stack did not settle within 30 minutes" >&2
    exit 1
  fi
  sleep 20
done
