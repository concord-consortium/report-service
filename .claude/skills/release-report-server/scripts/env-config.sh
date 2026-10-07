#!/usr/bin/env bash
# Shared environment table for the release-report-server scripts.
#
# Sourced, not run. Call `rs_env <staging|production>` and read the RS_* variables
# it sets. Keeping the table in one file is what stops the three scripts from
# drifting apart, since every one of them needs the same account, cluster and
# network facts.
#
# The stack names are the trap worth knowing: they are report-serv*ice*, matching
# the repo, while the ECS service inside them is report-serv*er*, matching the app.

rs_env() {
  case "${1:-}" in
    staging)
      RS_ENV=staging
      RS_PROFILE=${RS_PROFILE_STAGING:-concord-qa}
      RS_ACCOUNT=816253370536
      RS_STACK=report-service-qa
      RS_HOST=report-server.concordqa.org
      RS_SUBNETS='"subnet-0389f885433d5e6c4","subnet-044202bee99d9d426"'
      RS_SGS='"sg-0d0082e5fb836a3fb","sg-0d2f373cc18d37ddb"'
      ;;
    production|prod)
      RS_ENV=production
      RS_PROFILE=${RS_PROFILE_PRODUCTION:-default}
      RS_ACCOUNT=612297603577
      RS_STACK=report-service-prod
      RS_HOST=report-server.concord.org
      RS_SUBNETS='"subnet-0f6cf711b2389abab","subnet-0b6a86fb40289fe47"'
      RS_SGS='"sg-0499d3304790241e8","sg-0152d7bf3a0f9fa5e"'
      ;;
    *)
      echo "environment must be 'staging' or 'production', got '${1:-}'" >&2
      return 2
      ;;
  esac
  RS_CLUSTER=fargate-public-cluster
  RS_SERVICE=report-server
  RS_LOG_GROUP=/ecs/report-server
  export RS_ENV RS_PROFILE RS_ACCOUNT RS_STACK RS_HOST RS_SUBNETS RS_SGS \
         RS_CLUSTER RS_SERVICE RS_LOG_GROUP
}

# Fail early and loudly if the credentials in play are for the other account. Staging
# and production are separate accounts, which is why each environment names a profile
# rather than relying on ambient credentials: a release touches both in sequence.
rs_check_account() {
  local got var
  got=$(aws sts get-caller-identity --profile "$RS_PROFILE" --query Account --output text 2>/dev/null)
  if [ "$got" != "$RS_ACCOUNT" ]; then
    [ "$RS_ENV" = staging ] && var=RS_PROFILE_STAGING || var=RS_PROFILE_PRODUCTION
    echo "profile '$RS_PROFILE' resolves to account ${got:-<none>}, expected $RS_ACCOUNT ($RS_ENV)" >&2
    echo "configure that profile for account $RS_ACCOUNT, or set $var to one that is" >&2
    return 1
  fi
}
