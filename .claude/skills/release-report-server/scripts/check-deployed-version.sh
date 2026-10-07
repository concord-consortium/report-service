#!/usr/bin/env bash
# Verify an environment is serving an expected version, and that its API is wired up.
#
# usage: check-deployed-version.sh <staging|production> <version> [streak] [max-seconds]
#   version is the mix.exs version WITHOUT a v prefix, e.g. 1.11.0 or 1.11.0-pre.1
#
# The version in the header comes from mix.exs (compiled into :vsn and read by
# app.html.heex), not from the Docker tag, so this check catches the specific failure
# where an image was built without bumping mix.exs: the deploy succeeds and the app
# still reports the old version.
#
# Require consecutive agreement: a rollout serving both task generations would flap,
# and a single curl could catch either one.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env-config.sh
. "$here/env-config.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: $(basename "$0") <staging|production> <version> [streak] [max-seconds]" >&2
  echo "  e.g. $(basename "$0") staging 1.11.0" >&2
  exit 2
fi
rs_env "$1" || exit 2
EXPECTED="$2"; NEED="${3:-5}"; MAX="${4:-600}"
BASE="https://$RS_HOST"
DEADLINE=$((SECONDS + MAX))
streak=0

while :; do
  got=$(curl -s --max-time 20 "$BASE/" | grep -o 'Version [0-9][^<]*' | head -1 | sed 's/^Version //')
  if [ "$got" = "$EXPECTED" ]; then
    streak=$((streak + 1))
  else
    [ "$streak" -gt 0 ] && echo "$(date +%H:%M:%S) streak broken by '${got:-<no version served>}'"
    streak=0
  fi
  if [ "$streak" -ge "$NEED" ]; then
    echo "version $EXPECTED served $NEED times in a row on $RS_HOST"
    break
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "FAILED: wanted $EXPECTED, last saw '${got:-<no version served>}' after ${MAX}s" >&2
    exit 1
  fi
  sleep 5
done

# The root is unauthenticated and is what serves the header above, so on its own it
# proves only that something is up. The token endpoint proves the authenticated API is
# mounted: 401 is the pass, and a 404 means the API routes are missing entirely, which
# is what an older image looks like.
root=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/")
tokens=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/api/v1/tokens/current")
echo "GET /            $root  (want 200)"
echo "GET /api/v1/tokens/current  $tokens  (want 401)"
[ "$root" = 200 ] && [ "$tokens" = 401 ] || { echo "FAILED: unexpected status codes" >&2; exit 1; }
echo "OK ($RS_ENV on $EXPECTED)"
