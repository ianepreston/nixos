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
#        BOOTSTRAP_TOKEN_FILE   path of the file holding the admin API token
#                         (the sops secret path; the unit runs as root). It is
#                         read here, not via systemd LoadCredential=, because a
#                         missing credential file fails the unit during
#                         credential setup, before this script can degrade.
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

token="$(cat "$BOOTSTRAP_TOKEN_FILE" 2>/dev/null)" ||
  degrade "cannot read the bootstrap token file"

# Monotonic clock in centiseconds. /proc/uptime is CLOCK_BOOTTIME, immune to
# wall-clock steps (NTP, suspend resume); EPOCHREALTIME is only the fallback
# for non-Linux dev machines running the offline test.
now_cs() {
  local up
  if read -r up _ 2>/dev/null </proc/uptime; then
    echo $((10#${up/./}))
  else
    up="${EPOCHREALTIME/[.,]/}"
    echo $((10#${up} / 10000))
  fi
}

fmt_cs() { printf '%d.%02d' $(($1 / 100)) $(($1 % 100)); }

# One exact-match lookup per file: `?path=` is a django-filter exact filter
# on BlueprintInstance.path (authentik/blueprints/api.py filterset_fields),
# so it needs no pagination and cannot miss a result on page 2.
#
# Every request and sleep is capped to the time remaining until `deadline`,
# so the total wait cannot exceed BUDGET however slow the API is.
#
# Hardening of the admin-token request:
#   -q            first arg: ignore ~/.curlrc and any default config
#   --noproxy '*' never send the token through http(s)_proxy / ALL_PROXY
#   -f            HTTP >= 400 (e.g. 503 while starting) is a curl failure, so
#                 a body that merely looks right can never open the gate
#   -H @-         headers are read from stdin as raw lines: not argv (visible
#                 in /proc/<pid>/cmdline), not config-file syntax (so a `"`
#                 or `\` in the token is passed through unaltered)
#   -m            bound each request to min(3s, time left) (#762)
# The caller checks curl's exit status BEFORE looking at the body, so a
# truncated transfer is also a failure. The token is never echoed or logged.
applied() {
  local f="$1" body left tmo
  left=$((deadline - $(now_cs)))
  [ "$left" -gt 0 ] || return 1
  tmo=$((left < 300 ? left : 300))
  body="$(
    printf 'Authorization: Bearer %s\n' "$token" |
      curl -q -sS -f -m "$(fmt_cs "$tmo")" --noproxy '*' -H @- -G \
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

deadline=$(($(now_cs) + budget * 100))

while true; do
  if all_applied "$@"; then
    exit 0
  fi
  left=$((deadline - $(now_cs)))
  if [ "$left" -le 0 ]; then
    degrade "not applied after ${budget}s: $*"
  fi
  nap=$((left < 200 ? left : 200))
  sleep "$(fmt_cs "$nap")"
done
