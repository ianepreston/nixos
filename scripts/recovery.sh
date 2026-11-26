#!/usr/bin/env bash
# Operator-side restore driver behind `task recovery:*` (#1025).
#
#   recovery.sh app --app NAME [--manifest-file F] [--manifest-host H] COMMON
#   recovery.sh all [--manifest-file F] [--manifest-host H] COMMON
#   recovery.sh template volume|pg|sqlite --app NAME --units S --paths S
#               [--db D] [--swaps S] COMMON
#   recovery.sh template health --app NAME --url U [--expect E]
#               [--retries N] [--sleep N] COMMON
#
#   COMMON: --host H [--dest D] [--source-host S] [--ssh-port P]
#           [--target-user U] [--repo-mount M]
#
# `app` restores one entry of the Nix-generated recovery manifest
# (`myRecovery.manifest`, app-owned metadata from `myRecovery.apps`) and then
# runs its health probe, if it has one. `all` runs every entry through `app`
# in `order` and stops at the first failure. The manifest comes from
# --manifest-file when it is non-empty, otherwise from `nix eval` of
# --manifest-host (in the current directory's flake).
#
# `template` keeps the hidden `recovery:_restore-*` / `recovery:_health` Task
# entry points working with their historical space-joined UNITS/PATHS and
# `staged:live:owner` SWAPS strings: it converts them into a one-entry
# manifest and goes through the same validation and restore code. Nothing in
# this repo produces those encodings any more.
#
# An empty option means "use the default", matching the Task variables: DEST
# and SOURCE_HOST default to HOST, SSH_PORT to 22, TARGET_USER to ipreston
# and REPO_MOUNT to /mnt/backups (/mnt/<otherEnv>-backups reads another
# environment's repository).
#
# Trust boundary: manifest values and operator arguments are validated here
# with jq and reach the target only as jq `@sh`-quoted bash assignments
# appended to scripts/_recovery/remote.sh, which is sent as the remote shell's
# stdin. They are never part of an ssh command line, so the target user's
# login shell parses nothing but the fixed `sudo bash -se` / `bash -se`. The
# restic password stays on the target (/run/secrets/restic/password).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
remote_script=$script_dir/_recovery/remote.sh

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "$*" >&2
  exit 1
}

green() {
  printf '\033[32m%s\033[0m\n' "$1"
}

command -v jq >/dev/null || die "recovery.sh needs jq on the operator machine"

# Validate one manifest entry and print it, normalized, as compact JSON. The
# checks mirror the myRecovery.apps option types, so an entry the Nix module
# can generate always passes; anything else stops before a connection.
# shellcheck disable=SC2016 # jq program, not shell
validate_jq='
  def bad($why): error("recovery app \($app): \($why)");
  def strings($field):
    if type == "array" and all(.[]; type == "string" and length > 0) then .
    else bad("\($field) must be a list of non-empty strings") end;
  def string($field):
    if type == "string" and length > 0 then . else bad("\($field) must be a non-empty string") end;
  def count($field):
    if type == "number" and . == floor and . >= 0 then . else bad("\($field) must be a non-negative integer") end;

  (if has($app) then .[$app] else error("unknown recovery app: \($app)") end)
  | if type == "object" then . else bad("entry must be an object") end
  | if (.kind | IN("volume", "postgres", "sqlite")) then . else error("unknown recovery kind: \(.kind)") end
  | {
      kind,
      units: (.units | strings("units")),
      paths: (.paths | strings("paths")),
      database: (if .kind == "postgres" then (.database | string("database")) else null end),
      swaps: (
        if .kind == "sqlite" then
          (.swaps | if type == "array" then . else bad("swaps must be a list") end
            | map(if type == "object" then . else bad("each swap must be an object") end
              | {staged: (.staged | string("swap staged")),
                 live: (.live | string("swap live")),
                 owner: (.owner | string("swap owner"))}))
        else [] end),
      health: (
        if .health == null then null
        else .health
          | if type == "object" then . else bad("health must be an object or null") end
          | {url: (.url | string("health url")),
             expect: (.expect | string("health expect")),
             retries: (.retries | count("health retries")),
             sleep: (.sleep | count("health sleep"))}
        end)
    }
'

# Bash assignments for remote.sh, one value per single-quoted word.
# shellcheck disable=SC2016 # jq program, not shell
restore_preamble_jq='
  "APP=\($app | @sh)",
  "REPO=\($repo | @sh)",
  "UNITS=(\(.units | @sh))",
  "PATHS=(\(.paths | @sh))",
  (if .kind == "postgres" then "DB=\(.database | @sh)" else empty end),
  (if .kind == "sqlite" then
    "SWAP_STAGED=(\([.swaps[].staged] | @sh))",
    "SWAP_LIVE=(\([.swaps[].live] | @sh))",
    "SWAP_OWNER=(\([.swaps[].owner] | @sh))"
  else empty end),
  {volume: "restore_volume", postgres: "restore_pg", sqlite: "restore_sqlite"}[.kind]
'

# shellcheck disable=SC2016 # jq program, not shell
health_preamble_jq='
  "APP=\($app | @sh)",
  "URL=\(.health.url | @sh)",
  "EXPECT=\(.health.expect | @sh)",
  "RETRIES=\(.health.retries | @sh)",
  "SLEEP=\(.health.sleep | @sh)",
  "health"
'

host="" dest="" source_host="" ssh_port="" target_user="" repo_mount=""
app="" manifest_file="" manifest_host=""
units="" paths="" db="" swaps="" url="" expect="" retries="" sleep_s=""

parse_args() {
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "recovery.sh: $1 needs a value"
    case "$1" in
      --host) host=$2 ;;
      --dest) dest=$2 ;;
      --source-host) source_host=$2 ;;
      --ssh-port) ssh_port=$2 ;;
      --target-user) target_user=$2 ;;
      --repo-mount) repo_mount=$2 ;;
      --app) app=$2 ;;
      --manifest-file) manifest_file=$2 ;;
      --manifest-host) manifest_host=$2 ;;
      --units) units=$2 ;;
      --paths) paths=$2 ;;
      --db) db=$2 ;;
      --swaps) swaps=$2 ;;
      --url) url=$2 ;;
      --expect) expect=$2 ;;
      --retries) retries=$2 ;;
      --sleep) sleep_s=$2 ;;
      *) die "recovery.sh: unknown option $1" ;;
    esac
    shift 2
  done
  [ -n "$host" ] || die "recovery.sh: --host is required"
  [ -n "$app" ] || [ "$mode" = all ] || die "recovery.sh: --app is required"
  dest=${dest:-$host}
  source_host=${source_host:-$host}
  ssh_port=${ssh_port:-22}
  target_user=${target_user:-ipreston}
  repo_mount=${repo_mount:-/mnt/backups}
}

# Leaves manifest_file naming a readable file holding the manifest JSON.
load_manifest() {
  if [ -n "$manifest_file" ]; then
    [ -r "$manifest_file" ] || die "recovery.sh: cannot read manifest $manifest_file"
    return
  fi
  [ -n "$manifest_host" ] || manifest_host=$host
  manifest_file=$(mktemp)
  owned_manifest=$manifest_file
  nix eval --json ".#nixosConfigurations.$manifest_host.config.myRecovery.manifest" >"$manifest_file"
}

owned_manifest=""
cleanup() {
  if [ -n "$owned_manifest" ]; then rm -f "$owned_manifest"; fi
}
trap cleanup EXIT

validate_entry() { # name -> normalized entry JSON on stdout
  local out
  # jq reports `error(...)` as "jq: error (at <file>:<n>): <message>"; the
  # operator only needs the message.
  if ! out=$(jq -ce --arg app "$1" "$validate_jq" "$manifest_file" 2>&1); then
    die "${out#"jq: error (at "*"): "}"
  fi
  printf '%s\n' "$out"
}

ssh_target() {
  printf '%s@%s' "$target_user" "$dest"
}

restore_entry() { # name entry
  local name=$1 entry=$2 kind label
  kind=$(jq -r .kind <<<"$entry")
  case "$kind" in
    volume) label=volume-only ;;
    postgres) label="postgres + paths" ;;
    sqlite) label=sqlite-quiesce ;;
  esac
  green "[+] Restoring $name on $host ($label) from $source_host's restic repo"
  {
    cat "$remote_script"
    jq -r --arg app "$name" --arg repo "$repo_mount/restic/$source_host" \
      "$restore_preamble_jq" <<<"$entry"
  } | ssh -p "$ssh_port" -oForwardAgent=yes "$(ssh_target)" 'sudo bash -se'
}

# The probe's ssh reads its program from this pipe, never from the caller's
# stdin: under `all` it would otherwise drain the remaining app list.
health_entry() { # name entry
  local name=$1 entry=$2
  green "[+] Asserting HTTP $(jq -r .health.expect <<<"$entry") on $name ($(jq -r .health.url <<<"$entry"))"
  {
    cat "$remote_script"
    jq -r --arg app "$name" "$health_preamble_jq" <<<"$entry"
  } | ssh -p "$ssh_port" "$(ssh_target)" 'bash -se'
}

run_app() { # name [phase: both|restore|health]
  local name=$1 phase=${2:-both} entry
  entry=$(validate_entry "$name")
  if [ "$phase" != health ]; then
    restore_entry "$name" "$entry"
  fi
  if [ "$phase" != restore ] && [ "$(jq -r '.health != null' <<<"$entry")" = true ]; then
    health_entry "$name" "$entry"
  fi
}

run_all() {
  local name names=() list
  # NUL-terminated names in a file: no app name can be re-split, and a jq
  # failure stops the run instead of yielding an empty, "successful" loop.
  list=$(mktemp)
  jq -j 'to_entries | sort_by(.value.order) | .[] | .key + "\u0000"' "$manifest_file" >"$list" ||
    {
      rm -f "$list"
      exit 1
    }
  while IFS= read -r -d '' name; do
    names+=("$name")
  done <"$list"
  rm -f "$list"
  [ "${#names[@]}" -gt 0 ] || return 0
  # Validate every entry before the first restore touches the target.
  for name in "${names[@]}"; do
    validate_entry "$name" >/dev/null
  done
  for name in "${names[@]}"; do
    run_app "$name" </dev/null
  done
}

# Historical template inputs -> one-entry manifest. UNITS and PATHS split on
# whitespace like the old unquoted `for u in {{.UNITS}}`; each SWAPS triple
# splits like `IFS=: read -r src dst owner` (the owner keeps any further
# colons).
# shellcheck disable=SC2016 # jq program, not shell
template_jq='
  def words: [splits("[ \t\n]+")] | map(select(length > 0));
  {($app): {
    # `health` restores nothing; any valid kind satisfies the validator.
    kind: (if $kind == "health" then "volume" else $kind end),
    order: 0,
    units: ($units | words),
    paths: ($paths | words),
    database: (if $kind == "postgres" then $db else null end),
    swaps: ($swaps | words | map(split(":") | {staged: .[0], live: .[1], owner: (.[2:] | join(":"))})),
    health: (if $kind == "health" then
      {url: $url, expect: $expect, retries: ($retries | tonumber), sleep: ($sleep | tonumber)}
      else null end)
  }}
'

run_template() { # kind
  local kind=$1 phase=restore
  case "$kind" in
    volume | sqlite) ;;
    pg) kind=postgres ;;
    health)
      phase=health
      [ -n "$url" ] || die "recovery.sh: --url is required"
      ;;
    *) die "recovery.sh: unknown template $kind" ;;
  esac
  manifest_file=$(mktemp)
  owned_manifest=$manifest_file
  jq -n --arg app "$app" --arg kind "$kind" --arg units "$units" --arg paths "$paths" \
    --arg db "$db" --arg swaps "$swaps" --arg url "$url" --arg expect "${expect:-200}" \
    --arg retries "${retries:-30}" --arg sleep "${sleep_s:-2}" "$template_jq" >"$manifest_file"
  run_app "$app" "$phase"
}

[ "$#" -ge 1 ] || usage
mode=$1
shift
case "$mode" in
  app)
    parse_args "$@"
    load_manifest
    run_app "$app"
    ;;
  all)
    parse_args "$@"
    load_manifest
    run_all
    ;;
  template)
    [ "$#" -ge 1 ] || usage
    template_kind=$1
    shift
    parse_args "$@"
    run_template "$template_kind"
    ;;
  *) usage ;;
esac
