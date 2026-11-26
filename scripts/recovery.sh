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
# appended to scripts/_recovery/remote.sh. That program travels on ssh's
# stdin; the ssh command line is a fixed, manifest-independent string
# (`sudo bash -c '<stage and run>'`, see run_remote), so the target user's
# login shell parses nothing derived from the manifest. A run succeeds only
# when the target prints this run's random completion marker. The restic
# password stays on the target (/run/secrets/restic/password).
#
# Exit status: `app` and `all` return 201 (Task's status for the nested task
# they used to run) for any restore or probe failure, 5 for an unknown app or
# malformed entry and 1 for an unknown kind; `template` returns the failing
# command's own status, as the templates always did.
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
# checks are the myRecovery.apps option types and no stricter, so everything
# the previous Task dispatcher accepted still passes: empty strings are
# allowed, empty list elements are dropped (a space-joined list lost them
# too), numeric probe settings may be numbers or strings (`sleep 0.5`), and
# an empty `expect`, `retries` or `sleep` means the old `_health` default
# (200, 30, 2). A wrong shape stops
# before any connection.
# shellcheck disable=SC2016 # jq program, not shell
validate_jq='
  def bad($why): error("recovery app \($app): \($why)");
  def strings($field):
    if type == "array" and all(.[]; type == "string") then map(select(. != ""))
    else bad("\($field) must be a list of strings") end;
  def string($field):
    if type == "string" then . else bad("\($field) must be a string") end;
  def scalar($field):
    if type == "string" or type == "number" then tostring
    else bad("\($field) must be a string or number") end;

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
             expect: (.expect | scalar("health expect") | if . == "" then "200" else . end),
             retries: (.retries | scalar("health retries") | if . == "" then "30" else . end),
             sleep: (.sleep | scalar("health sleep") | if . == "" then "2" else . end)}
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

# Prints the normalized entry. Failure statuses are the old dispatcher's: 1
# for an unknown kind (its own `exit 1`), 5 (jq's error status) otherwise.
validate_entry() { # name
  local out msg
  if ! out=$(jq -ce --arg app "$1" "$validate_jq" "$manifest_file" 2>&1); then
    # jq reports `error(...)` as "jq: error (at <file>:<n>): <message>"; the
    # operator only needs the message.
    msg=${out#"jq: error (at "*"): "}
    echo "$msg" >&2
    case "$msg" in
      "unknown recovery kind: "*) return 1 ;;
      *) return 5 ;;
    esac
  fi
  printf '%s\n' "$out"
}

# The constant remote command: stage the program from ssh's stdin into a
# private temp file, then run it with stdin from /dev/null. Its size never
# depends on the manifest (the program can exceed the ~128 KiB single-argument
# limit), nothing the program starts can read its source or the marker line,
# and the file is removed on exit. Contains no single quote, so it nests in
# one inertly whatever the target user's login shell is.
# shellcheck disable=SC2016 # expanded on the target, not here
stage_and_run='f=$(mktemp) || exit 1; trap "rm -f -- \"\$f\"" EXIT; cat >"$f" || exit 1; bash "$f" </dev/null'

# run_remote LABEL SUDO(yes|no) PROGRAM SSH_ARGS...
#
# Runs PROGRAM (bash source) on the target, as root through sudo or as the
# ssh user. The program goes on ssh's stdin; -T and `-o StdinNull=no` override
# any ssh_config RequestTTY/StdinNull, and the caller never shares that stdin
# (under `all` it would otherwise be the remaining app list). The program ends
# with `recovery_done`, which prints a per-run random nonce on its own line,
# reached only after the action succeeded. The filter requires that line
# (ignoring a trailing CR), removes it and the line break that precedes it,
# and passes everything else through. Returns ssh's (the remote program's)
# status, or 1 when it exited 0 without the marker — an empty or discarded
# program, a truncated one, or one that never ran.
run_remote() {
  local label=$1 sudo=$2 program=$3 nonce remote
  local -a status
  shift 3
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') && [ -n "$nonce" ] || return 1
  remote="bash -c '$stage_and_run'"
  if [ "$sudo" = yes ]; then remote="sudo $remote"; fi
  set +e
  printf 'NONCE=%s\n%s\nrecovery_done\n' "$nonce" "$program" |
    ssh -T -o StdinNull=no "$@" "$remote" |
    awk -v marker="RECOVERY-DONE $nonce" '
      { line = $0; sub(/\r$/, "", line) }
      line == marker { seen = 1; if (blanks > 0) blanks--; next }
      line == "" { blanks++; next }
      { for (; blanks > 0; blanks--) print ""; print; fflush() }
      END { for (; blanks > 0; blanks--) print ""; exit !seen }
    '
  status=("${PIPESTATUS[@]}")
  set -e
  if [ "${status[1]}" -ne 0 ]; then
    return "${status[1]}"
  fi
  if [ "${status[2]}" -ne 0 ]; then
    echo "[!] $label: the remote program did not report completion; treating it as failed" >&2
    return 1
  fi
}

ssh_target() {
  printf '%s@%s' "$target_user" "$dest"
}

# These run under `||` (set -e does not apply there), so every step checks
# its own status.
restore_entry() { # name entry
  local name=$1 entry=$2 kind label program
  kind=$(jq -r .kind <<<"$entry") || return
  case "$kind" in
    volume) label=volume-only ;;
    postgres) label="postgres + paths" ;;
    sqlite) label=sqlite-quiesce ;;
  esac
  green "[+] Restoring $name on $host ($label) from $source_host's restic repo"
  program=$(
    cat "$remote_script" &&
      jq -r --arg app "$name" --arg repo "$repo_mount/restic/$source_host" \
        "$restore_preamble_jq" <<<"$entry"
  ) || return
  run_remote "$name restore" yes "$program" \
    -p "$ssh_port" -oForwardAgent=yes "$(ssh_target)"
}

health_entry() { # name entry
  local name=$1 entry=$2 program
  green "[+] Asserting HTTP $(jq -r .health.expect <<<"$entry") on $name ($(jq -r .health.url <<<"$entry"))"
  program=$(
    cat "$remote_script" &&
      jq -r --arg app "$name" "$health_preamble_jq" <<<"$entry"
  ) || return
  run_remote "$name health probe" no "$program" -p "$ssh_port" "$(ssh_target)"
}

restore_and_probe() { # name entry [phase: both|restore|health]
  local name=$1 entry=$2 phase=${3:-both}
  if [ "$phase" != health ]; then
    restore_entry "$name" "$entry" || return
  fi
  if [ "$phase" != restore ] && [ "$(jq -r '.health != null' <<<"$entry")" = true ]; then
    health_entry "$name" "$entry" || return
  fi
}

# `app` and `all` used to reach the restore templates through a nested
# `task`, so any restore or probe failure surfaced as Task's 201; they keep
# that status (`task --exit-code` shows it). The hidden templates ran the
# restore directly and still return its own status (e.g. restic's 11).
run_one() {
  local entry
  entry=$(validate_entry "$app") || exit
  restore_and_probe "$app" "$entry" || exit 201
}

run_all() {
  local name names=() entries=() entry list i
  # NUL-terminated names in a file: no app name can be re-split, and a jq
  # failure stops the run instead of yielding an empty, "successful" loop.
  list=$(mktemp)
  if ! jq -j 'to_entries | sort_by(.value.order) | .[] | .key + "\u0000"' "$manifest_file" >"$list"; then
    rm -f "$list"
    exit 5
  fi
  while IFS= read -r -d '' name; do
    names+=("$name")
  done <"$list"
  rm -f "$list"
  [ "${#names[@]}" -gt 0 ] || return 0
  # Validate every entry before the first restore touches the target.
  for name in "${names[@]}"; do
    entry=$(validate_entry "$name") || exit 201
    entries+=("$entry")
  done
  for i in "${!names[@]}"; do
    restore_and_probe "${names[$i]}" "${entries[$i]}" </dev/null || exit 201
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
      {url: $url, expect: $expect, retries: $retries, sleep: $sleep}
      else null end)
  }}
'

run_template() { # kind
  local kind=$1 phase=restore entry
  case "$kind" in
    volume | sqlite) ;;
    pg) kind=postgres ;;
    health) phase=health ;;
    *) die "recovery.sh: unknown template $kind" ;;
  esac
  manifest_file=$(mktemp)
  owned_manifest=$manifest_file
  jq -n --arg app "$app" --arg kind "$kind" --arg units "$units" --arg paths "$paths" \
    --arg db "$db" --arg swaps "$swaps" --arg url "$url" --arg expect "${expect:-200}" \
    --arg retries "${retries:-30}" --arg sleep "${sleep_s:-2}" "$template_jq" >"$manifest_file"
  entry=$(validate_entry "$app") || exit
  restore_and_probe "$app" "$entry" "$phase" || exit
}

[ "$#" -ge 1 ] || usage
mode=$1
shift
case "$mode" in
  app)
    parse_args "$@"
    load_manifest
    run_one
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
