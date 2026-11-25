# shellcheck shell=bash
# Wait until authentik's worker has APPLIED the named blueprint files
# (instance status "successful" in /api/v3/managed/blueprints/), not merely
# until Django serves /-/health/ready/. See the authentik-blueprint-ready-*
# units in modules/apps/authentik.nix and #682.
#
# usage: blueprint-ready <blueprint-file>...
#        Each argument is the file's path relative to authentik's
#        blueprints_dir, exactly as authentik stores it in the instance
#        `path` column (every contributed file sits at the root, so it is
#        the bare filename, e.g. sparkyfitness.yaml).
# env:   AUTHENTIK_HOST   base URL of the local authentik API
#        CREDENTIALS_DIRECTORY/bootstrap_token   admin API token (systemd credential)
#        BUDGET           seconds to keep polling before degrading (default 120)
#
# DEGRADES, NEVER FAILS: if the blueprint is not applied within BUDGET, this
# logs a warning and exits 0. A failed unit makes switch-to-configuration
# report the whole switch as failed (exit 4) even for a `wants` dependency,
# and the dependent app is meant to start anyway (local-auth fallback).
#
# writeShellApplication sets -euo pipefail; every network/parse step below is
# guarded so a transient 503/502 during startup retries instead of aborting
# (the authentik-ldap-token-fetcher precedent: no `set -e` over curl).

budget="${BUDGET:-120}"

degrade() {
  echo "WARNING: authentik blueprint gate degraded, continuing without it: $*" >&2
  exit 0
}

token="$(cat "$CREDENTIALS_DIRECTORY/bootstrap_token" 2>/dev/null)" ||
  degrade "cannot read bootstrap_token credential"

# One exact-match lookup per file: `?path=` is a django-filter exact filter
# on BlueprintInstance.path (authentik/blueprints/api.py filterset_fields),
# so it needs no pagination and cannot miss a result on page 2.
#
# Hardening of the admin-token request:
#   -q            first arg: ignore ~/.curlrc and any default config
#   --noproxy '*' never send the token through http(s)_proxy / ALL_PROXY
#   -f            HTTP >= 400 (e.g. 503 while starting) is a curl failure, so
#                 a body that merely looks right can never open the gate
#   -H @-         headers are read from stdin as raw lines: not argv (visible
#                 in /proc/<pid>/cmdline), not config-file syntax (so a `"`
#                 or `\` in the token is passed through unaltered)
#   -m 3          bound each request (#762)
# The caller checks curl's exit status BEFORE looking at the body, so a
# truncated transfer is also a failure. The token is never echoed or logged.
applied() {
  local f="$1" body
  body="$(
    printf 'Authorization: Bearer %s\n' "$token" |
      curl -q -sS -f -m 3 --noproxy '*' -H @- -G \
        --data-urlencode "path=$f" \
        "$AUTHENTIK_HOST/api/v3/managed/blueprints/" 2>/dev/null
  )" || return 1
  printf '%s' "$body" | jq -e --arg f "$f" \
    '[.results[]? | select(.path == $f and .status == "successful")] | length > 0' \
    >/dev/null 2>&1
}

all_applied() {
  local f
  for f in "$@"; do
    applied "$f" || return 1
  done
}

while true; do
  if all_applied "$@"; then
    exit 0
  fi
  # SECONDS is bash's own elapsed-time counter; the loop is bounded in time,
  # not attempts, so slow requests cannot stretch it past BUDGET + one round.
  if [ "$SECONDS" -ge "$budget" ]; then
    degrade "not applied after ${budget}s: $*"
  fi
  sleep 2
done
