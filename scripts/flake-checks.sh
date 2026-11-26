#!/usr/bin/env bash
# Shared flake validation driver (#1021). `task check` and the CI stages in
# .github/workflows/check.yml run the same modes, so local and CI validation
# follow one implementation. Scheduling, fork/trust guards, runner selection
# and the split between lint (no private inputs) and private-input evaluation
# stay in the workflow YAML; this script only decides WHAT to evaluate/build.
# Requires nix, bash and jq on PATH.
#
#   flake-checks.sh [--flake REF] MODE [options]
#
# Modes (compose them; each is one CI step):
#   lock           assert flake.lock matches flake.nix without re-locking
#   eval-configs   evaluate every nixos/darwin/home configuration's toplevel
#                  (activationPackage for home) one at a time and check it is a
#                  real derivation; names are discovered, never listed here.
#                  Each of the three kinds must exist and be non-empty.
#   eval-outputs   what `nix flake check --all-systems` evaluated: force every
#                  top-level output and check system keys, overlays, modules
#                  and apps (_flake-checks/toplevel.nix, on the locked source
#                  via builtins.getFlake), then check derivation identity of
#                  every checks/packages/devShells/formatter entry for every
#                  system (_flake-checks/derivations.nix)
#   lint           build checks.<system>.pre-commit (git-hooks.nix settings)
#   build-checks   identity-check, then build every checks.<system>.*, one at
#                  a time; the selected system must have at least one check
#   local          the `task check` preset: lock, eval-configs, eval-outputs,
#                  lint and build-checks for THIS machine's system; checks of
#                  every other system are reported as DEFERRED, never passed
#
# Options:
#   --flake REF       flake to check (default: the checkout holding this script)
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
# derivation's outputs (`^*`), as `nix flake check` did. Evaluation and builds
# run sequentially on purpose: parallel `nix flake check` evaluation raced on
# concurrent addToStore for filtered sub-paths of flake inputs on the Linux
# runner (see check.yml). Attribute names outside [A-Za-z0-9_][A-Za-z0-9_+.-]*
# are reported as failures, never skipped or rewritten. A failed item does not
# stop the remaining items of its stage, so one run reports every failure.
# Exit status:
#   0  every executed item passed (DEFERRED items were not executed)
#   1  at least one item failed, or a stage could not run
#   2  usage error, a nix setting could not be read, or a platform this
#      machine may not build
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/_flake-checks"
FLAKE=$(cd "$SCRIPT_DIR/.." && pwd)
NIX_FLAGS=(--no-update-lock-file)
NAME_RE='^[A-Za-z0-9_][A-Za-z0-9_+.-]*$'
SYSTEM_RE='^[a-z0-9_]+-[a-z0-9_]+$'
# Derivation-valued per-system outputs; formatter.<system> is one derivation.
DERIVATION_OUTPUTS=(checks packages devShells formatter)
# nixosConfigurations/darwinConfigurations share the toplevel path; Home
# Manager configurations expose activationPackage instead.
CONFIG_KINDS=(
  "nixosConfigurations config.system.build.toplevel"
  "darwinConfigurations config.system.build.toplevel"
  "homeConfigurations activationPackage"
)

RESULTS=()
FAILED=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flake-checks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/eval"

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
# Must run in the main shell (never inside $(...)), or the result is lost.
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

# nix_to FILE ARGS... — run nix with the lock flags, stdout to FILE; returns
# nix's own exit status (callers branch on it directly).
nix_to() {
  local out=$1
  shift
  nix "$@" "${NIX_FLAGS[@]}" >"$out"
}

# split_names JSON_FILE LABEL OUT_FILE — names (array elements, or object
# keys) one per line into OUT_FILE. A name the driver cannot pass losslessly
# as an attribute path is recorded as FAIL (JSON-escaped). Returns 1 when jq
# fails or any name is unsupported.
split_names() {
  local json=$1 label=$2 out=$3 tag value bad=0
  local lines="$WORK/split.$$"
  : >"$out"
  if ! jq -r --arg re "$NAME_RE" '
      (if type == "object" then keys else . end)
      | .[]
      | if type == "string" and test($re) then "ok\t" + . else "bad\t" + tojson end
    ' "$json" >"$lines"; then
    record FAIL "$label" "could not read attribute names"
    return 1
  fi
  while IFS=$'\t' read -r tag value; do
    if [ "$tag" = ok ]; then
      printf '%s\n' "$value" >>"$out"
    else
      record FAIL "$label" "unsupported attribute name $value"
      bad=1
    fi
  done <"$lines"
  return "$bad"
}

json_length() { jq 'length' "$1"; }

# drv_apply SYSTEM_OR_NULL SINGLE LABEL — the --apply expression for
# _flake-checks/derivations.nix. Arguments are validated names, so they are
# safe inside a Nix string literal.
drv_apply() {
  local system=null
  [ "$1" = null ] || system="\"$1\""
  printf '(%s) { system = %s; single = %s; label = "%s"; }' \
    "$(cat "$LIB/derivations.nix")" "$system" "$2" "$3"
}

# ---- platform handling -----------------------------------------------------

# native_systems — `system` plus `extra-platforms`; exits 2 if unreadable.
native_systems() {
  local sys extra
  sys=$(nix config show system) || refuse "could not read \`nix config show system\`"
  extra=$(nix config show extra-platforms) || refuse "could not read \`nix config show extra-platforms\`"
  tr ' ' '\n' <<<"$sys $extra" | sed '/^$/d'
}

# builder_entries SPEC — "<uri> <systems> <maxJobs>" per machine of a
# `builders` value: entries split on ';' or newlines, `@FILE` includes.
builder_entries() {
  local spec=$1 depth=${2:-0} line uri systems maxjobs
  [ "$depth" -le 4 ] || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    uri="" systems="" maxjobs=""
    read -r uri systems _ maxjobs _ <<<"$line" || true
    [ -n "$uri" ] || continue
    case $uri in
      @*)
        if [ -r "${uri#@}" ]; then
          builder_entries "$(cat "${uri#@}")" $((depth + 1))
        else
          echo "flake-checks: builders file ${uri#@} is not readable; ignoring it" >&2
        fi
        ;;
      *) echo "$uri ${systems:--} ${maxjobs:--}" ;;
    esac
  done < <(tr ';' '\n' <<<"$spec")
  return 0
}

# require_buildable SYSTEM REMOTE — exit 2 unless SYSTEM may be built here.
require_buildable() {
  local system=$1 remote=$2 natives spec uri systems maxjobs usable="" unusable=""
  natives=$(native_systems) || exit 2
  if grep -qxF "$system" <<<"$natives"; then
    return 0
  fi
  if [ "$remote" != true ]; then
    refuse "$system is not native here (native: $(tr '\n' ' ' <<<"$natives" | sed 's/ $//')). Pass --remote-builder to allow delegation to a configured builder, or leave it to CI."
  fi
  spec=$(nix config show builders) || refuse "--remote-builder given, but \`nix config show builders\` failed; refusing $system"
  while read -r uri systems maxjobs; do
    tr ',' '\n' <<<"$systems" | grep -qxF "$system" || continue
    case $maxjobs in
      -) maxjobs=1 ;;
      *[!0-9]* | "") maxjobs=0 ;;
    esac
    if [ "$maxjobs" -gt 0 ]; then
      usable="$usable $uri ($maxjobs jobs)"
    else
      unusable="$unusable $uri"
    fi
  done < <(builder_entries "$spec")
  if [ -z "$usable" ]; then
    refuse "--remote-builder given, but no configured builder declares $system with a build slot${unusable:+ (zero-slot or malformed entries ignored:$unusable)}"
  fi
  echo "flake-checks: $system is not native here; \`nix config show builders\` declares it on:$usable."
  echo "flake-checks: nix picks the machine per build and reachability is not probed here; an output already in the store or a substituter is not rebuilt, so a pass shows the output exists, not that a builder ran it."
}

# ---- stages ----------------------------------------------------------------

stage_lock() {
  group_start "lock: flake.lock matches flake.nix"
  if nix flake metadata "${NIX_FLAGS[@]}" "$FLAKE" >/dev/null; then
    record PASS lock
  else
    record FAIL lock "flake.lock does not match flake.nix, or the flake could not be read; nothing was rewritten"
  fi
  group_end
}

stage_eval_configs() {
  local kind_spec kind path name names_json="$WORK/config-names.json" names="$WORK/config-names" out="$WORK/config-drv.json"
  for kind_spec in "${CONFIG_KINDS[@]}"; do
    read -r kind path <<<"$kind_spec"
    if ! nix_to "$names_json" eval --json "$FLAKE#$kind" --apply builtins.attrNames; then
      record FAIL "eval $kind" "could not enumerate"
      continue
    fi
    if [ "$(json_length "$names_json")" = 0 ]; then
      record FAIL "eval $kind" "no configurations; every configuration kind must be non-empty"
      continue
    fi
    split_names "$names_json" "eval $kind" "$names" || true
    while IFS= read -r name; do
      group_start "eval $kind.$name"
      if nix_to "$out" eval --json "$FLAKE#$kind.\"$name\".$path" \
        --apply "$(drv_apply null true "$kind.$name.$path")" &&
        jq -r '.[""]' "$out"; then
        record PASS "eval $kind.$name"
      else
        record FAIL "eval $kind.$name"
      fi
      group_end
    done <"$names"
  done
}

# eval_derivations OUTPUT SYSTEM — identity-check OUTPUT.SYSTEM; on success
# leaves $WORK/eval/OUTPUT.SYSTEM.json ({name: drvPath}) and returns 0.
eval_derivations() {
  local output=$1 system=$2 single=false label="$1.$2"
  local out="$WORK/eval/$output.$system.json" tmp="$WORK/eval/.tmp.json"
  [ "$output" != formatter ] || single=true
  [ ! -e "$out" ] || return 0
  [ ! -e "$out.failed" ] || return 1
  group_start "eval $label"
  if nix_to "$tmp" eval --json "$FLAKE#$output.$system" \
    --apply "$(drv_apply "$system" "$single" "$label")"; then
    mv "$tmp" "$out"
    record PASS "eval $label" "$(json_length "$out") derivations"
    group_end
    return 0
  fi
  record FAIL "eval $label"
  : >"$out.failed"
  group_end
  return 1
}

stage_eval_outputs() {
  local prefetch="$WORK/prefetch.json" top="$WORK/toplevel.json" src hash output system
  group_start "eval top-level outputs"
  if nix_to "$prefetch" flake prefetch --json "$FLAKE" &&
    src=$(jq -er '.storePath' "$prefetch") && hash=$(jq -er '.hash' "$prefetch") &&
    [[ $src =~ ^/[A-Za-z0-9/._+-]+$ ]] && [[ $hash =~ ^sha256-[A-Za-z0-9+/=]+$ ]] &&
    nix_to "$top" eval --json --expr \
      "($(cat "$LIB/toplevel.nix")) (builtins.getFlake \"path:$src?narHash=$hash\").outputs"; then
    record PASS "eval top-level outputs" "$(jq -r 'join(" ")' "$top")"
  else
    record FAIL "eval top-level outputs"
  fi
  group_end
  for output in "${DERIVATION_OUTPUTS[@]}"; do
    if ! nix_to "$WORK/systems.$output.json" eval --json "$FLAKE#$output" --apply builtins.attrNames; then
      record FAIL "eval $output" "could not enumerate systems"
      : >"$WORK/systems.$output"
      continue
    fi
    split_names "$WORK/systems.$output.json" "eval $output" "$WORK/systems.$output" || true
    while IFS= read -r system; do
      if [[ ! $system =~ $SYSTEM_RE ]]; then
        record FAIL "eval $output" "invalid system name $system"
        continue
      fi
      eval_derivations "$output" "$system" || true
    done <"$WORK/systems.$output"
  done
}

stage_lint() {
  local system=$1
  group_start "lint: checks.$system.pre-commit"
  if nix build "${NIX_FLAGS[@]}" --no-link --print-build-logs "$FLAKE#checks.$system.pre-commit^*"; then
    record PASS "lint checks.$system.pre-commit"
  else
    record FAIL "lint checks.$system.pre-commit"
  fi
  group_end
}

# stage_build_checks SYSTEM [EXCLUDED...]
stage_build_checks() {
  local system=$1 name ex skip built=0 names="$WORK/build-names.$1"
  shift
  if ! eval_derivations checks "$system"; then
    record NOT-RUN "build checks.$system" "evaluation failed"
    return
  fi
  if [ "$(json_length "$WORK/eval/checks.$system.json")" = 0 ]; then
    record FAIL "build checks.$system" "no checks; a selected system must have at least one"
    return
  fi
  split_names "$WORK/eval/checks.$system.json" "build checks.$system" "$names" || true
  while IFS= read -r name; do
    skip=false
    for ex in "$@"; do
      if [ "$ex" = "$name" ]; then skip=true; fi
    done
    [ "$skip" = false ] || continue
    built=$((built + 1))
    group_start "build checks.$system.$name"
    if nix build "${NIX_FLAGS[@]}" --no-link --print-build-logs "$FLAKE#checks.$system.\"$name\"^*"; then
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
# explicit DEFERRED (or NOT-RUN, when its evaluation failed) line per system
# it cannot build.
stage_local() {
  local native=$1 system names footer=""
  stage_lock
  if [ "$FAILED" -ne 0 ]; then
    record NOT-RUN "eval, lint and check builds" "lock check failed"
    return
  fi
  stage_eval_configs
  stage_eval_outputs
  stage_lint "$native"
  stage_build_checks "$native" pre-commit
  while IFS= read -r system; do
    [ "$system" != "$native" ] || continue
    if [ -e "$WORK/eval/checks.$system.json" ]; then
      names=$(jq -r 'keys | join(" ")' "$WORK/eval/checks.$system.json")
      record DEFERRED "build checks.$system" \
        "$(json_length "$WORK/eval/checks.$system.json") checks evaluated, not built on $native: $names"
      case $system in
        x86_64-linux) footer="$footer
flake-checks: x86_64-linux checks were evaluated but NOT built here; build them with \`task check:linux\` (remote builder) or rely on the CI checks/lint jobs." ;;
        *) footer="$footer
flake-checks: $system checks were evaluated but NOT built; they remain deferred (no local task or CI job builds them)." ;;
      esac
    else
      record NOT-RUN "build checks.$system" "evaluation failed, see above"
      footer="$footer
flake-checks: $system checks FAILED evaluation; nothing for $system was built."
    fi
  done <"$WORK/systems.checks"
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
