#!/bin/bash
# Migrates .runtimeconfig.json to .env + .secret.local for local emulator development.
# Run from the functions/ directory.
#
# Usage: bash scripts/migrate-config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FUNCTIONS_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$FUNCTIONS_DIR/.runtimeconfig.json"
ENV_FILE="$FUNCTIONS_DIR/.env"
SECRET_FILE="$FUNCTIONS_DIR/.secret.local"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: $CONFIG_FILE not found." >&2
  echo "Generate it with: firebase functions:config:get > .runtimeconfig.json" >&2
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE already exists. Delete it first to re-run." >&2
  exit 1
fi

if [ -f "$SECRET_FILE" ]; then
  echo "Error: $SECRET_FILE already exists. Delete it first to re-run." >&2
  exit 1
fi

# Parse values from .runtimeconfig.json using node (available in functions/ context)
read_config() {
  node -e "
    const config = require('$CONFIG_FILE');
    const key = '$1'.split('.').reduce((o, k) => o && o[k], config);
    if (key !== undefined && key !== null) {
      process.stdout.write(String(key));
    } else {
      process.exit(1);
    }
  "
}

# Extract values
MISSING=0
S3_BUCKET=$(read_config "aws.s3_bucket") || { echo "Warning: aws.s3_bucket not found in config" >&2; S3_BUCKET=""; MISSING=$((MISSING+1)); }
AWS_KEY=$(read_config "aws.key") || { echo "Warning: aws.key not found in config" >&2; AWS_KEY=""; MISSING=$((MISSING+1)); }
AWS_SECRET=$(read_config "aws.secret_key") || { echo "Warning: aws.secret_key not found in config" >&2; AWS_SECRET=""; MISSING=$((MISSING+1)); }
BEARER=$(read_config "auth.bearer_token") || { echo "Warning: auth.bearer_token not found in config" >&2; BEARER=""; MISSING=$((MISSING+1)); }

# Write .env (non-secret)
{
  [ -n "$S3_BUCKET" ] && echo "AWS_S3_BUCKET=$S3_BUCKET"
} > "$ENV_FILE"
echo "Created $ENV_FILE"

# Write .secret.local (secrets)
{
  [ -n "$AWS_KEY" ] && echo "AWS_KEY=$AWS_KEY"
  [ -n "$AWS_SECRET" ] && echo "AWS_SECRET_KEY=$AWS_SECRET"
  [ -n "$BEARER" ] && echo "AUTH_BEARER_TOKEN=$BEARER"
} > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
echo "Created $SECRET_FILE (secrets - do not commit)"

echo ""
if [ "$MISSING" -gt 0 ]; then
  echo "Warning: $MISSING key(s) were missing from config. Review the files and fill in any blank values." >&2
fi
echo "Migration complete. These files are for local emulator use only."
echo "For deployed environments, set secrets via: firebase functions:secrets:set SECRET_NAME"
