# shellcheck shell=bash
# Wait until authentik's worker has APPLIED the named blueprint files
# (instance status "successful" in /api/v3/managed/blueprints/), not merely
# until Django serves /-/health/ready/. See the authentik-blueprint-ready-*
# units in modules/apps/authentik.nix and #682.
#
# usage: blueprint-ready <blueprint-file>...   (basenames, e.g. sparkyfitness.yaml)
# env:   AUTHENTIK_HOST   base URL of the local authentik API
#        CREDENTIALS_DIRECTORY/bootstrap_token   admin API token (systemd credential)
#        ATTEMPTS         poll attempts, 2s apart (default 60)
#
# writeShellApplication sets -euo pipefail; every network/parse step below is
# guarded with `|| true` so a transient 503/502 during startup retries instead
# of aborting (the authentik-ldap-token-fetcher precedent: no `set -e` over
# curl). `-m 3` bounds each request; without it a wedged API is waited on
# forever (#762).

token="$(cat "$CREDENTIALS_DIRECTORY/bootstrap_token")"
attempts="${ATTEMPTS:-60}"

# The token is handed to curl on stdin as a curl config, never in argv (which
# any local user can read from /proc/<pid>/cmdline) and never echoed. printf
# is a shell builtin, so it does not appear in a process listing either.
fetch() {
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS -m 3 -K - "$AUTHENTIK_HOST/api/v3/managed/blueprints/?page_size=500" \
      2>/dev/null || true
}

all_applied() {
  local resp="$1" f
  shift
  for f in "$@"; do
    # Match on the file's basename: the instance `path` is relative to the
    # merged blueprints dir, where every contributed file sits at the root.
    printf '%s' "$resp" | jq -e --arg f "$f" \
      '[.results[]? | select((.path | split("/") | last) == $f and .status == "successful")] | length > 0' \
      >/dev/null 2>&1 || return 1
  done
}

for _ in $(seq 1 "$attempts"); do
  resp="$(fetch)"
  if all_applied "$resp" "$@"; then
    exit 0
  fi
  sleep 2
done

# Never print the response: it is not secret, but there is no reason to log it.
echo "blueprint(s) not applied after $attempts attempts: $*" >&2
exit 1
