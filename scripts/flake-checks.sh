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
# anything else fails. A result is recorded only after the exit status of
# every command producing it was checked. A failed item does not stop the
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
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flake-checks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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
  RESULTS+=("$(printf '%-8s %s%s' "$1" "$2" "${3:+  ($3)}")")
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

# nix_to FILE ARGS... — nix with the lock flags, stdout to FILE; returns nix's
# own exit status (callers branch on it directly).
nix_to() {
  local out=$1
  shift
  nix "$@" "${NIX_FLAGS[@]}" >"$out"
}

# read_names INSTALLABLE LABEL OUT_FILE — the ONE choke point for attribute
# names: `builtins.attrNames` of INSTALLABLE, each name decoded from its JSON
# form and accepted only if it contained no escape (so no newline, quote or
# control character) and matches NAME_RE as a whole string. Valid names go to
# OUT_FILE one per line; nothing is rewritten. Every failure (nix, jq, a bad
# name) is recorded as FAIL under LABEL and returns 1.
read_names() {
  local installable=$1 label=$2 out=$3 json="$WORK/names.json" lines="$WORK/names.lines" line name bad=0
  : >"$out"
  if ! nix_to "$json" eval --json "$installable" --apply builtins.attrNames; then
    record FAIL "$label" "could not enumerate"
    return 1
  fi
  if ! jq -c 'if type == "array" then .[] else error("not a list of names") end' "$json" >"$lines"; then
    record FAIL "$label" "could not decode attribute names"
    return 1
  fi
  while IFS= read -r line; do
    name=""
    case $line in
      *\\*) ;;
      \"*\")
        name=${line#\"}
        name=${name%\"}
        ;;
    esac
    if [ -n "$name" ] && [[ $name =~ $NAME_RE ]]; then
      printf '%s\n' "$name" >>"$out"
    else
      record FAIL "$label" "unsupported attribute name $line"
      bad=1
    fi
  done <"$lines"
  return "$bad"
}

# count_lines FILE — sets COUNT; returns nonzero if it cannot be read.
count_lines() {
  local n
  n=$(wc -l <"$1") || return 1
  COUNT=$((n + 0))
}

# ---- platform handling -----------------------------------------------------

# native_systems — `system` plus `extra-platforms`; exits 2 if unreadable.
native_systems() {
  local sys extra
  sys=$(nix config show system) || refuse "could not read \`nix config show system\`"
  extra=$(nix config show extra-platforms) || refuse "could not read \`nix config show extra-platforms\`"
  tr ' ' '\n' <<<"$sys $extra" | sed '/^$/d'
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# builder_entries SPEC — one machine entry per line, following Nix's
# expandBuilderLines (src/libstore/machines.cc): split SPEC on newlines,
# drop everything from '#' to the end of each line, THEN split on ';', trim,
# skip blanks, and expand `@FILE` recursively (a missing FILE is skipped as
# nix does; an unreadable one makes nix fail, so it fails here).
builder_entries() {
  local spec=$1 depth=${2:-0} line entry path entries
  [ "$depth" -le 8 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    IFS=';' read -r -a entries <<<"$line" || true
    for entry in ${entries[@]+"${entries[@]}"}; do
      entry=$(trim "$entry")
      [ -n "$entry" ] || continue
      case $entry in
        @*)
          path=$(trim "${entry#@}")
          if [ ! -e "$path" ]; then
            continue
          fi
          if [ ! -r "$path" ]; then
            echo "flake-checks: builders file $path is not readable" >&2
            return 1
          fi
          builder_entries "$(cat "$path")" $((depth + 1)) || return 1
          ;;
        *) printf '%s\n' "$entry" ;;
      esac
    done
  done <<<"$spec"
  return 0
}

# require_buildable SYSTEM REMOTE — exit 2 unless SYSTEM may be built here.
require_buildable() {
  local system=$1 remote=$2 natives spec entries uri systems maxjobs usable="" unusable=""
  natives=$(native_systems) || exit 2
  if grep -qxF "$system" <<<"$natives"; then
    return 0
  fi
  if [ "$remote" != true ]; then
    refuse "$system is not native here (native: $(tr '\n' ' ' <<<"$natives" | sed 's/ $//')). Pass --remote-builder to allow delegation to a configured builder, or leave it to CI."
  fi
  spec=$(nix config show builders) || refuse "--remote-builder given, but \`nix config show builders\` failed; refusing $system"
  entries=$(builder_entries "$spec") || refuse "--remote-builder given, but the builders setting could not be expanded; refusing $system"
  while read -r uri systems _ maxjobs _; do
    [ -n "${uri:-}" ] || continue
    # Field 2 unset or "-" means the local system, never a non-native one.
    tr ',' '\n' <<<"${systems:--}" | grep -qxF "$system" || continue
    case ${maxjobs:--} in
      -) maxjobs=1 ;;
      *[!0-9]*) maxjobs=0 ;;
    esac
    if [ "$maxjobs" -gt 0 ]; then
      usable="$usable $uri ($maxjobs jobs)"
    else
      unusable="$unusable $uri"
    fi
  done <<<"$entries"
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
  local kind_spec kind path name names="$WORK/config-names" out="$WORK/config-drv"
  for kind_spec in "${CONFIG_KINDS[@]}"; do
    read -r kind path <<<"$kind_spec"
    read_names "$FLAKE#$kind" "eval $kind" "$names" || true
    if ! count_lines "$names"; then
      record FAIL "eval $kind" "could not read the name list"
      continue
    fi
    if [ "$COUNT" -eq 0 ]; then
      record FAIL "eval $kind" "no usable configurations; every configuration kind must be non-empty"
      continue
    fi
    while IFS= read -r name; do
      group_start "eval $kind.$name"
      if nix_to "$out" eval --raw "$FLAKE#$kind.\"$name\".$path.drvPath" && cat "$out" && echo; then
        record PASS "eval $kind.$name"
      else
        record FAIL "eval $kind.$name"
      fi
      group_end
    done <"$names"
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
  local system=$1 name ex skip built=0 names="$WORK/build-names"
  shift
  if ! read_names "$FLAKE#checks.$system" "build checks.$system" "$names"; then
    record NOT-RUN "build checks.$system" "check names could not be enumerated and validated"
    return
  fi
  if ! count_lines "$names" || [ "$COUNT" -eq 0 ]; then
    record FAIL "build checks.$system" "no checks; a selected system must have at least one"
    return
  fi
  while IFS= read -r name; do
    skip=false
    for ex in "$@"; do
      if [ "$ex" = "$name" ]; then skip=true; fi
    done
    [ "$skip" = false ] || continue
    built=$((built + 1))
    group_start "build checks.$system.$name"
    if nix build --no-link --print-build-logs "$FLAKE#checks.$system.\"$name\"^*" "${NIX_FLAGS[@]}"; then
      record PASS "build checks.$system.$name"
    else
      record FAIL "build checks.$system.$name"
    fi
    group_end
  done <"$names"
  if [ "$built" -eq 0 ]; then
    record FAIL "build checks.$system" "nothing left to build after exclusions"
  fi
}

# The `task check` preset: everything this machine can execute, and an
# explicit DEFERRED (or NOT-RUN, when evaluation failed) line per system it
# cannot build. Names of deferred checks go through read_names like any other.
stage_local() {
  local native=$1 system systems="$WORK/check-systems" names="$WORK/deferred-names" listed footer=""
  stage_lock
  if [ "$FAILED" -ne 0 ]; then
    record NOT-RUN "eval, lint and check builds" "lock check failed"
    return
  fi
  stage_eval_configs
  stage_eval_outputs
  stage_lint "$native"
  stage_build_checks "$native" pre-commit
  read_names "$FLAKE#checks" "enumerate checks systems" "$systems" || true
  while IFS= read -r system; do
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
    if ! read_names "$FLAKE#checks.$system" "build checks.$system" "$names" ||
      ! count_lines "$names" || ! listed=$(tr '\n' ' ' <"$names"); then
      record NOT-RUN "build checks.$system" "check names could not be enumerated and validated"
      continue
    fi
    record DEFERRED "build checks.$system" \
      "$COUNT checks evaluated by nix flake check --no-build, not built on $native: ${listed% }"
    case $system in
      x86_64-linux) footer="$footer
flake-checks: x86_64-linux checks were evaluated but NOT built here; build them with \`task check:linux\` (remote builder) or rely on the CI checks/lint jobs." ;;
      *) footer="$footer
flake-checks: $system checks were evaluated but NOT built; they remain deferred (no local task or CI job builds them)." ;;
    esac
  done <"$systems"
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
