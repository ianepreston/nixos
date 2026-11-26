#!/usr/bin/env bash
# Shared flake validation driver (#1021). `task check` and the CI stages in
# .github/workflows/check.yml run the same modes, so local and CI validation
# follow one implementation. Scheduling, fork/trust guards, runner selection
# and the split between lint (no private inputs) and private-input evaluation
# stay in the workflow YAML; this script only decides WHAT to evaluate/build,
# in what order, and how to report what it did not run. Output-shape and
# derivation validation is nix's own: `eval-outputs` IS
# `nix flake check --no-build --all-systems`, not a re-implementation.
# Requires nix, bash and jq on PATH.
#
#   flake-checks.sh [--flake REF] MODE [options]
#
# Modes (compose them; each is one CI step):
#   lock           assert flake.lock matches flake.nix without re-locking
#   eval-configs   evaluate the drvPath of every nixos/darwin configuration
#                  toplevel and home activationPackage, one at a time (as CI
#                  did); names are discovered, never listed here, and each of
#                  the three kinds must exist and be non-empty
#   eval-outputs   `nix flake check --no-build --all-systems`: nix's own
#                  output-shape, derivation, overlay, module and app checks
#                  for every system, evaluated but not built (local only; its
#                  parallel evaluation is what raced on the CI runner)
#   lint           build checks.<system>.pre-commit (git-hooks.nix settings)
#   build-checks   build every checks.<system>.*, one at a time; the selected
#                  system must have at least one check after --exclude
#   local          the `task check` preset: lock, eval-configs, eval-outputs,
#                  lint and build-checks for THIS machine's system; checks of
#                  every other system are reported as DEFERRED, never passed
#
# Options:
#   --flake REF       flake to check (default: the checkout holding this script);
#                     every stage passes REF to nix verbatim (git metadata,
#                     ?dir= and all), so every stage checks the same flake
#   --system S        lint/build-checks platform (default: `nix config show system`)
#   --remote-builder  allow a --system this machine cannot build natively, once
#                     `nix config show builders` declares a machine for it with
#                     at least one build slot; without this flag it is refused.
#                     That is all this verifies: nix picks the machine per
#                     build, reachability is not probed, and an output already
#                     in the store or a substituter is not rebuilt.
#   --exclude NAME    build-checks: skip this check (repeatable), e.g. pre-commit
#                     when the lint stage builds it
#
# Every nix call passes --no-update-lock-file: the committed lock is what is
# checked, and nothing here writes flake.lock. Every build requests all of a
# derivation's outputs (`^*`), as `nix flake check` did. Configurations and
# checks are evaluated/built sequentially: parallel `nix flake check`
# evaluation raced on concurrent addToStore on the Linux runner (check.yml).
# Every attribute name passes one validator (read_names): a whole-string match
# of [A-Za-z0-9_][A-Za-z0-9_+.-]*, decoded from JSON without rewriting;
# anything else fails the whole list. A result is recorded only after the exit
# status of every command producing it was checked. Nothing is written to a
# temporary file: lists are held in bash arrays filled from status-checked
# command substitutions and split without redirects (split_on), so no
# unchecked write or read can truncate a list. A failed item does not stop the
# rest of its stage, so one run reports every failure. Exit status:
#   0  every executed item passed (DEFERRED items were not executed)
#   1  at least one item failed, or a stage could not run
#   2  usage error, a nix setting could not be read, or a platform this
#      machine may not build
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FLAKE=$(cd "$SCRIPT_DIR/.." && pwd)
NIX_FLAGS=(--no-update-lock-file)
NAME_RE='^[A-Za-z0-9_][A-Za-z0-9_+.-]*$'
SYSTEM_RE='^[a-z0-9_]+-[a-z0-9_]+$'
# nixosConfigurations/darwinConfigurations share the toplevel path; Home
# Manager configurations expose activationPackage instead.
CONFIG_KINDS=(
  "nixosConfigurations config.system.build.toplevel"
  "darwinConfigurations config.system.build.toplevel"
  "homeConfigurations activationPackage"
)

RESULTS=()
FAILED=0
EVAL_OUTPUTS=not-run
NAMES=()
PARTS=()
BUILDERS=()
NATIVES=()
TRIMMED=""

die_usage() {
  echo "flake-checks: $*" >&2
  echo "usage: flake-checks.sh [--flake REF] {lock|eval-configs|eval-outputs|lint|build-checks|local} [--system S] [--remote-builder] [--exclude NAME]..." >&2
  exit 2
}

refuse() {
  echo "flake-checks: $*" >&2
  exit 2
}

in_ci() { [ "${GITHUB_ACTIONS:-}" = true ]; }
group_start() { if in_ci; then echo "::group::$1"; else echo "==> $1"; fi; }
group_end() { if in_ci; then echo "::endgroup::"; fi; }

# record STATUS LABEL [DETAIL] — STATUS is PASS, FAIL, DEFERRED or NOT-RUN.
# Must run in the main shell (never inside $(...)), or the result is lost;
# DETAIL must already be computed and status-checked by the caller.
record() {
  local line
  printf -v line '%-8s %s%s' "$1" "$2" "${3:+  ($3)}"
  RESULTS+=("$line")
  case $1 in FAIL | NOT-RUN) FAILED=1 ;; esac
}

summary() {
  local line
  echo
  echo "flake-checks summary:"
  for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "  $line"; done
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo '```'
      for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "$line"; done
      echo '```'
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

finish() {
  summary
  if [ "$FAILED" -ne 0 ]; then
    echo "flake-checks: FAILED" >&2
    exit 1
  fi
  exit 0
}

# split_on SEP TEXT — sets PARTS to TEXT split on the characters in SEP, with
# no redirect or subprocess (word splitting with globbing off, so `*` and `?`
# stay literal). Empty fields from whitespace separators are dropped.
split_on() {
  local saved_ifs=$IFS
  set -f
  IFS=$1
  # shellcheck disable=SC2206 # deliberate split on IFS; globbing is off
  PARTS=($2)
  IFS=$saved_ifs
  set +f
}

# trim TEXT — sets TRIMMED to TEXT without leading/trailing whitespace.
trim() {
  TRIMMED=${1#"${1%%[![:space:]]*}"}
  TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}
}

# read_names INSTALLABLE LABEL — the ONE choke point for attribute names. Sets
# NAMES to `builtins.attrNames` of INSTALLABLE: every name is decoded from its
# JSON form and accepted only if it contained no escape (so no newline, quote
# or control character) and matches NAME_RE as a whole string; nothing is
# rewritten. nix and jq run in status-checked command substitutions and the
# list never touches disk. On ANY failure — nix, jq, or a single unsupported
# name — a FAIL is recorded under LABEL, NAMES is empty and it returns 1, so a
# caller never sees a partial list. Callers must treat 1 as failure.
read_names() {
  local installable=$1 label=$2 json decoded line name bad=0
  local -a accepted=() lines=()
  NAMES=()
  if ! json=$(nix eval --json "$installable" --apply builtins.attrNames "${NIX_FLAGS[@]}"); then
    record FAIL "$label" "could not enumerate"
    return 1
  fi
  if ! decoded=$(jq -c 'if type == "array" then .[] else error("not a list of names") end' <<<"$json"); then
    record FAIL "$label" "could not decode attribute names"
    return 1
  fi
  split_on $'\n' "$decoded"
  lines=(${PARTS[@]+"${PARTS[@]}"})
  for line in ${lines[@]+"${lines[@]}"}; do
    name=""
    case $line in
      *\\*) ;;
      \"*\")
        name=${line#\"}
        name=${name%\"}
        ;;
    esac
    if [ -n "$name" ] && [[ $name =~ $NAME_RE ]]; then
      accepted+=("$name")
    else
      record FAIL "$label" "unsupported attribute name $line"
      bad=1
    fi
  done
  if [ "$bad" -ne 0 ]; then
    return 1
  fi
  NAMES=(${accepted[@]+"${accepted[@]}"})
  return 0
}

# ---- platform handling -----------------------------------------------------

# native_systems — sets NATIVES to `system` plus `extra-platforms`; exits 2
# if either setting cannot be read.
native_systems() {
  local sys extra
  sys=$(nix config show system) || refuse "could not read \`nix config show system\`"
  extra=$(nix config show extra-platforms) || refuse "could not read \`nix config show extra-platforms\`"
  split_on $' \t\n' "$sys $extra"
  NATIVES=(${PARTS[@]+"${PARTS[@]}"})
}

# builder_entries SPEC — appends each machine entry to BUILDERS, following
# Nix's expandBuilderLines (src/libstore/machines.cc): split SPEC on newlines,
# drop everything from '#' to the end of each line, THEN split on ';', trim,
# skip blanks, and expand `@FILE` recursively. A missing FILE (ENOENT) is
# skipped as nix does; any other read error (unreadable, a directory, a failed
# read) is fatal in nix, so it returns 1 here. The file is read into a variable
# with cat's own status checked before anything in it is used.
builder_entries() {
  local spec=$1 depth=${2:-0} line entry path content
  local -a lines entries
  [ "$depth" -le 8 ] || return 1
  split_on $'\n' "$spec"
  lines=(${PARTS[@]+"${PARTS[@]}"})
  for line in ${lines[@]+"${lines[@]}"}; do
    split_on ';' "${line%%#*}"
    entries=(${PARTS[@]+"${PARTS[@]}"})
    for entry in ${entries[@]+"${entries[@]}"}; do
      trim "$entry"
      entry=$TRIMMED
      [ -n "$entry" ] || continue
      case $entry in
        @*)
          trim "${entry#@}"
          path=$TRIMMED
          if [ ! -e "$path" ]; then
            continue
          fi
          if ! content=$(cat -- "$path"); then
            echo "flake-checks: builders file $path could not be read" >&2
            return 1
          fi
          builder_entries "$content" $((depth + 1)) || return 1
          ;;
        *) BUILDERS+=("$entry") ;;
      esac
    done
  done
  return 0
}

# in_list WORD ITEMS... — status 0 if WORD equals one of ITEMS.
in_list() {
  local word=$1 item
  shift
  for item in "$@"; do
    if [ "$item" = "$word" ]; then return 0; fi
  done
  return 1
}

# require_buildable SYSTEM REMOTE — exit 2 unless SYSTEM may be built here.
require_buildable() {
  local system=$1 remote=$2 spec entry uri systems maxjobs usable="" unusable=""
  local -a fields
  native_systems
  if in_list "$system" ${NATIVES[@]+"${NATIVES[@]}"}; then
    return 0
  fi
  if [ "$remote" != true ]; then
    refuse "$system is not native here (native: ${NATIVES[*]-none}). Pass --remote-builder to allow delegation to a configured builder, or leave it to CI."
  fi
  spec=$(nix config show builders) || refuse "--remote-builder given, but \`nix config show builders\` failed; refusing $system"
  BUILDERS=()
  builder_entries "$spec" || refuse "--remote-builder given, but the builders setting could not be expanded; refusing $system"
  for entry in ${BUILDERS[@]+"${BUILDERS[@]}"}; do
    split_on $' \t' "$entry"
    fields=(${PARTS[@]+"${PARTS[@]}"})
    uri=${fields[0]-}
    [ -n "$uri" ] || continue
    # Field 2 unset or "-" means the local system, never a non-native one.
    systems=${fields[1]:--}
    maxjobs=${fields[3]:--}
    split_on ',' "$systems"
    in_list "$system" ${PARTS[@]+"${PARTS[@]}"} || continue
    case $maxjobs in
      -) maxjobs=1 ;;
      *[!0-9]*) maxjobs=0 ;;
    esac
    if [ "$maxjobs" -gt 0 ]; then
      usable="$usable $uri ($maxjobs jobs)"
    else
      unusable="$unusable $uri"
    fi
  done
  if [ -z "$usable" ]; then
    refuse "--remote-builder given, but no configured builder declares $system with a build slot${unusable:+ (zero-slot or malformed entries ignored:$unusable)}"
  fi
  echo "flake-checks: $system is not native here; \`nix config show builders\` declares it on:$usable."
  echo "flake-checks: nix picks the machine per build and reachability is not probed here; an output already in the store or a substituter is not rebuilt, so a pass shows the output exists, not that a builder ran it."
}

# ---- stages ----------------------------------------------------------------

stage_lock() {
  group_start "lock: flake.lock matches flake.nix"
  if nix flake metadata "$FLAKE" "${NIX_FLAGS[@]}" >/dev/null; then
    record PASS lock
  else
    record FAIL lock "flake.lock does not match flake.nix, or the flake could not be read; nothing was rewritten"
  fi
  group_end
}

stage_eval_configs() {
  local kind_spec kind path name drv
  local -a names
  for kind_spec in "${CONFIG_KINDS[@]}"; do
    kind=${kind_spec%% *}
    path=${kind_spec#* }
    if ! read_names "$FLAKE#$kind" "eval $kind"; then
      record NOT-RUN "eval $kind" "configuration names could not be enumerated and validated"
      continue
    fi
    if [ "${#NAMES[@]}" -eq 0 ]; then
      record FAIL "eval $kind" "no configurations; every configuration kind must be non-empty"
      continue
    fi
    names=("${NAMES[@]}")
    for name in "${names[@]}"; do
      group_start "eval $kind.$name"
      if drv=$(nix eval --raw "$FLAKE#$kind.\"$name\".$path.drvPath" "${NIX_FLAGS[@]}") &&
        [ -n "$drv" ] && printf '%s\n' "$drv"; then
        record PASS "eval $kind.$name"
      else
        record FAIL "eval $kind.$name"
      fi
      group_end
    done
  done
}

stage_eval_outputs() {
  group_start "eval outputs: nix flake check --no-build --all-systems"
  if nix flake check --no-build --all-systems "$FLAKE" "${NIX_FLAGS[@]}"; then
    EVAL_OUTPUTS=pass
    record PASS "eval outputs" "nix flake check --no-build --all-systems"
  else
    EVAL_OUTPUTS=fail
    record FAIL "eval outputs" "nix flake check --no-build --all-systems"
  fi
  group_end
}

stage_lint() {
  local system=$1
  group_start "lint: checks.$system.pre-commit"
  if nix build --no-link --print-build-logs "$FLAKE#checks.$system.pre-commit^*" "${NIX_FLAGS[@]}"; then
    record PASS "lint checks.$system.pre-commit"
  else
    record FAIL "lint checks.$system.pre-commit"
  fi
  group_end
}

# stage_build_checks SYSTEM [EXCLUDED...]
stage_build_checks() {
  local system=$1 name built=0
  local -a names
  shift
  if ! read_names "$FLAKE#checks.$system" "build checks.$system"; then
    record NOT-RUN "build checks.$system" "check names could not be enumerated and validated"
    return
  fi
  if [ "${#NAMES[@]}" -eq 0 ]; then
    record FAIL "build checks.$system" "no checks; a selected system must have at least one"
    return
  fi
  names=("${NAMES[@]}")
  for name in "${names[@]}"; do
    if in_list "$name" "$@"; then
      continue
    fi
    built=$((built + 1))
    group_start "build checks.$system.$name"
    if nix build --no-link --print-build-logs "$FLAKE#checks.$system.\"$name\"^*" "${NIX_FLAGS[@]}"; then
      record PASS "build checks.$system.$name"
    else
      record FAIL "build checks.$system.$name"
    fi
    group_end
  done
  if [ "$built" -eq 0 ]; then
    record FAIL "build checks.$system" "nothing left to build after exclusions"
  fi
}

# The `task check` preset: everything this machine can execute, and an
# explicit DEFERRED (or NOT-RUN, when evaluation failed) line per system it
# cannot build. Names of deferred checks go through read_names like any other.
stage_local() {
  local native=$1 system footer=""
  local -a systems=()
  stage_lock
  if [ "$FAILED" -ne 0 ]; then
    record NOT-RUN "eval, lint and check builds" "lock check failed"
    return
  fi
  stage_eval_configs
  stage_eval_outputs
  stage_lint "$native"
  stage_build_checks "$native" pre-commit
  if read_names "$FLAKE#checks" "enumerate checks systems"; then
    systems=(${NAMES[@]+"${NAMES[@]}"})
  else
    record NOT-RUN "build checks of non-native systems" "check systems could not be enumerated and validated"
  fi
  for system in ${systems[@]+"${systems[@]}"}; do
    [ "$system" != "$native" ] || continue
    if [[ ! $system =~ $SYSTEM_RE ]]; then
      record FAIL "enumerate checks systems" "invalid system name $system"
      continue
    fi
    if [ "$EVAL_OUTPUTS" != pass ]; then
      record NOT-RUN "build checks.$system" "nix flake check --no-build failed, see above"
      footer="$footer
flake-checks: $system checks FAILED evaluation; nothing for $system was built."
      continue
    fi
    if ! read_names "$FLAKE#checks.$system" "build checks.$system"; then
      record NOT-RUN "build checks.$system" "check names could not be enumerated and validated"
      continue
    fi
    record DEFERRED "build checks.$system" \
      "${#NAMES[@]} checks evaluated by nix flake check --no-build, not built on $native: ${NAMES[*]-}"
    case $system in
      x86_64-linux) footer="$footer
flake-checks: x86_64-linux checks were evaluated but NOT built here; build them with \`task check:linux\` (remote builder) or rely on the CI checks/lint jobs." ;;
      *) footer="$footer
flake-checks: $system checks were evaluated but NOT built; they remain deferred (no local task or CI job builds them)." ;;
    esac
  done
  if [ -n "$footer" ]; then
    echo "$footer"
  fi
}

# ---- argument parsing ------------------------------------------------------

main() {
  local mode="" system="" remote=false excludes=()
  while [ $# -gt 0 ]; do
    case $1 in
      --flake)
        [ $# -ge 2 ] || die_usage "--flake needs a value"
        FLAKE=$2
        shift 2
        ;;
      --system)
        [ $# -ge 2 ] || die_usage "--system needs a value"
        system=$2
        shift 2
        ;;
      --remote-builder)
        remote=true
        shift
        ;;
      --exclude)
        [ $# -ge 2 ] || die_usage "--exclude needs a value"
        excludes+=("$2")
        shift 2
        ;;
      -h | --help)
        sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
        exit 0
        ;;
      lock | eval-configs | eval-outputs | lint | build-checks | local)
        [ -z "$mode" ] || die_usage "one mode per invocation (got $mode and $1)"
        mode=$1
        shift
        ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$mode" ] || die_usage "no mode given"
  case $mode in
    lint | build-checks) ;;
    *)
      [ -z "$system" ] && [ "$remote" = false ] || die_usage "--system/--remote-builder apply to lint and build-checks only"
      ;;
  esac
  [ "$mode" = build-checks ] || [ ${#excludes[@]} -eq 0 ] || die_usage "--exclude applies to build-checks only"
  command -v jq >/dev/null || refuse "jq is required on PATH"

  if [ "$mode" = lint ] || [ "$mode" = build-checks ] || [ "$mode" = local ]; then
    if [ -z "$system" ]; then
      system=$(nix config show system) || refuse "could not read \`nix config show system\`"
    fi
    [[ $system =~ $SYSTEM_RE ]] || die_usage "invalid system name: $system"
    require_buildable "$system" "$remote"
  fi

  case $mode in
    lock) stage_lock ;;
    eval-configs) stage_eval_configs ;;
    eval-outputs) stage_eval_outputs ;;
    lint) stage_lint "$system" ;;
    build-checks) stage_build_checks "$system" ${excludes[@]+"${excludes[@]}"} ;;
    local) stage_local "$system" ;;
  esac
  finish
}

main "$@"
