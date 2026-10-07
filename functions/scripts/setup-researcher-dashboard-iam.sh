#!/usr/bin/env bash
# Creates and checks the service account researcherDashboard runs as, with the grants its code needs.
#
#   setup-researcher-dashboard-iam.sh apply <project>                   create what is missing; safe to rerun
#   setup-researcher-dashboard-iam.sh check <project>                   report what is missing; changes nothing
#   setup-researcher-dashboard-iam.sh grant-deployer <project> <member>   let <member> deploy functions as it
#   setup-researcher-dashboard-iam.sh grant-operator <project> <member>   let <member> mint its ID tokens for a live check
#   setup-researcher-dashboard-iam.sh revoke-operator <project> <member>
#
# <project> is report-service-dev or report-service-pro; <member> is e.g. user:someone@concord.org.
# apply and check print the account's unique ID, which the runner stack takes as a parameter.
# Never delete and recreate the account: a new account gets a new unique ID, and the runner stack's
# roles then refuse every token until the stack is updated to match.

set -euo pipefail

# Must match SERVICE_ACCOUNT_ID in src/researcher-dashboard/config.ts.
SERVICE_ACCOUNT_ID=researcher-dashboard

# Project-level roles the account holds.
PROJECT_ROLES=(
  roles/datastore.user
)

# Roles the account holds on itself. Service Account User lets it name itself in a Cloud Task's
# OIDC token, which createTask requires even when the caller is that account.
SELF_ROLES=(
  roles/iam.serviceAccountUser
)

DEPLOYER_ROLE=roles/iam.serviceAccountUser
OPERATOR_ROLE=roles/iam.serviceAccountOpenIdTokenCreator

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[[ $# -ge 2 ]] || usage
command=$1
project=$2
email="${SERVICE_ACCOUNT_ID}@${project}.iam.gserviceaccount.com"

# Only a not-found answer means the account is missing; any other failure (expired credentials, no
# permission) is printed and stops the script, so check never reports a missing account it could not see.
account_exists() {
  local out
  if out=$(gcloud iam service-accounts describe "$email" --project="$project" --format='value(email)' 2>&1); then
    return 0
  fi
  if grep -q 'NOT_FOUND' <<<"$out"; then
    return 1
  fi
  echo "$out" >&2
  exit 2
}

# The roles the account holds, one per line, on the project or on itself. A failure stops the
# script under set -e.
held_project_roles() {
  gcloud projects get-iam-policy "$project" --flatten='bindings[].members' \
    --filter="bindings.members=serviceAccount:$email" --format='value(bindings.role)' --verbosity=error
}

held_self_roles() {
  gcloud iam service-accounts get-iam-policy "$email" --project="$project" --flatten='bindings[].members' \
    --filter="bindings.members=serviceAccount:$email" --format='value(bindings.role)' --verbosity=error
}

# A new account takes a few seconds to become visible to IAM policy writes, which answer "does not
# exist" until then, so that answer alone is retried, for up to a minute.
retry_while_propagating() {
  local out attempt
  for attempt in 1 2 3 4 5 6 7; do
    if out=$("$@" 2>&1); then
      return 0
    fi
    if ! grep -q 'does not exist' <<<"$out" || [[ $attempt -eq 7 ]]; then
      echo "$out" >&2
      exit 1
    fi
    sleep 10
  done
}

print_unique_id() {
  echo "Unique ID of $email: $(gcloud iam service-accounts describe "$email" --project="$project" --format='value(uniqueId)')"
}

apply() {
  if account_exists; then
    echo "Exists: $email"
  else
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_ID" --project="$project" \
      --display-name="Researcher Dashboard function" \
      --description="Runtime account of researcherDashboard; the runner stack's roles trust only this account"
    echo "Created: $email"
  fi
  local held
  held=$(held_project_roles)
  for role in "${PROJECT_ROLES[@]}"; do
    if grep -qx "$role" <<<"$held"; then
      echo "Has: $role"
    else
      retry_while_propagating gcloud projects add-iam-policy-binding "$project" --member="serviceAccount:$email" \
        --role="$role" --condition=None --format=none
      echo "Granted: $role"
    fi
  done
  held=$(held_self_roles)
  for role in "${SELF_ROLES[@]}"; do
    if grep -qx "$role" <<<"$held"; then
      echo "Has on itself: $role"
    else
      retry_while_propagating gcloud iam service-accounts add-iam-policy-binding "$email" --project="$project" \
        --member="serviceAccount:$email" --role="$role" --format=none
      echo "Granted on itself: $role"
    fi
  done
  print_unique_id
}

check() {
  if ! account_exists; then
    echo "Missing: $email (run: $0 apply $project)"
    exit 1
  fi
  local missing=0 held
  held=$(held_project_roles)
  for role in "${PROJECT_ROLES[@]}"; do
    if grep -qx "$role" <<<"$held"; then
      echo "Has: $role"
    else
      echo "Missing: $role"
      missing=1
    fi
  done
  held=$(held_self_roles)
  for role in "${SELF_ROLES[@]}"; do
    if grep -qx "$role" <<<"$held"; then
      echo "Has on itself: $role"
    else
      echo "Missing on itself: $role"
      missing=1
    fi
  done
  print_unique_id
  exit "$missing"
}

account_binding() {
  local action=$1 member=$2 role=$3
  gcloud iam service-accounts "$action" "$email" --project="$project" --member="$member" --role="$role" --format=none
  echo "${action%%-*}: $role for $member on $email"
}

case "$command" in
  apply) apply ;;
  check) check ;;
  grant-deployer) [[ $# -eq 3 ]] || usage; account_binding add-iam-policy-binding "$3" "$DEPLOYER_ROLE" ;;
  grant-operator) [[ $# -eq 3 ]] || usage; account_binding add-iam-policy-binding "$3" "$OPERATOR_ROLE" ;;
  revoke-operator) [[ $# -eq 3 ]] || usage; account_binding remove-iam-policy-binding "$3" "$OPERATOR_ROLE" ;;
  *) usage ;;
esac
