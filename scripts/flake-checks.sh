#!/usr/bin/env bash
# Shared flake validation driver (#1021). `task check` and the CI stages in
# .github/workflows/check.yml run the same modes, so local and CI validation
# follow one implementation. Scheduling, fork/trust guards, runner selection
# and the split between lint (no private inputs) and private-input evaluation
# stay in the workflow YAML; this script only decides WHAT to evaluate/build.
#
#   flake-checks.sh [--flake REF] MODE [options]
#
# Modes (compose them; each is one CI step):
#   lock           assert flake.lock matches flake.nix without re-locking
#   eval-configs   evaluate every nixos/darwin/home configuration's drvPath,
#                  one at a time (names are discovered, never listed here)
#   eval-outputs   evaluate the drvPath of every checks/packages/devShells/
#                  formatter entry for every system, and that overlays and
#                  nixosModules have module/overlay shape (what
#                  `nix flake check --all-systems` evaluated)
#   lint           build checks.<system>.pre-commit (git-hooks.nix settings)
#   build-checks   build every checks.<system>.* attribute, one at a time
#   local          the `task check` preset: lock, eval-configs, eval-outputs,
#                  lint and build-checks for THIS machine's system; checks of
#                  every other system are reported as DEFERRED, not passed
#
# Options:
#   --flake REF       flake to check (default: the checkout holding this script)
#   --system S        lint/build-checks platform (default: `nix config show system`)
#   --remote-builder  allow a --system this machine cannot build natively, after
#                     verifying a configured builder (`nix config show builders`)
#                     declares it; without this flag a non-native system is refused
#   --exclude NAME    build-checks: skip this check (repeatable), e.g. pre-commit
#                     when the lint stage builds it
#
# Every nix call passes --no-update-lock-file: the committed lock is what is
# checked, and nothing here writes flake.lock. Evaluation and builds run
# sequentially on purpose: parallel `nix flake check` evaluation raced on
# concurrent addToStore for filtered sub-paths of flake inputs on the Linux
# runner (see check.yml). A failed item does not stop the remaining items of
# its stage, so one run reports every failure; the exit status is
#   0  every executed item passed (DEFERRED items were not executed)
#   1  at least one item failed, or a stage could not run
#   2  usage error, or a platform this machine may not build
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FLAKE=$(cd "$SCRIPT_DIR/.." && pwd)
NIX_FLAGS=(--no-update-lock-file)
# Derivation-valued per-system outputs `nix flake check` evaluates.
PER_SYSTEM_OUTPUTS=(checks packages devShells formatter)
# nixosConfigurations/darwinConfigurations share the toplevel path; Home
# Manager configurations expose activationPackage instead.
CONFIG_KINDS=(
  "nixosConfigurations config.system.build.toplevel"
  "darwinConfigurations config.system.build.toplevel"
  "homeConfigurations activationPackage"
)

RESULTS=()
FAILED=0

die_usage() {
  echo "flake-checks: $*" >&2
  echo "usage: flake-checks.sh [--flake REF] {lock|eval-configs|eval-outputs|lint|build-checks|local} [--system S] [--remote-builder] [--exclude NAME]..." >&2
  exit 2
}

in_ci() { [ "${GITHUB_ACTIONS:-}" = true ]; }
group_start() { if in_ci; then echo "::group::$1"; else echo "==> $1"; fi; }
group_end() { if in_ci; then echo "::endgroup::"; fi; }

# record STATUS LABEL [DETAIL] — STATUS is PASS, FAIL, DEFERRED or NOT-RUN.
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

# attr_names INSTALLABLE — one attribute name per line; nonzero if it fails.
attr_names() {
  local json
  json=$(nix eval "${NIX_FLAGS[@]}" --json "$1" --apply builtins.attrNames) || return 1
  jq -r '.[]' <<<"$json"
}

nix_config() { nix config show "$1"; }

# ---- platform handling -----------------------------------------------------

native_systems() {
  local sys extra
  sys=$(nix_config system)
  extra=$(nix_config extra-platforms || true)
  tr ' ' '\n' <<<"$sys $extra" | sed '/^$/d'
}

# builder_systems SPEC — systems declared by a `builders` value: entries split
# on ';' or newlines, `@FILE` includes, field 2 a comma-separated system list.
builder_systems() {
  local spec=$1 depth=${2:-0} line uri systems
  [ "$depth" -le 4 ] || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    read -r uri systems _ <<<"$line" || true
    [ -n "${uri:-}" ] || continue
    case $uri in
      @*)
        if [ -r "${uri#@}" ]; then
          builder_systems "$(cat "${uri#@}")" $((depth + 1))
        fi
        ;;
      *)
        if [ -n "${systems:-}" ] && [ "$systems" != - ]; then
          tr ',' '\n' <<<"$systems"
        fi
        ;;
    esac
  done < <(tr ';' '\n' <<<"$spec")
  return 0
}

# require_buildable SYSTEM REMOTE — exit 2 unless SYSTEM can be built here.
require_buildable() {
  local system=$1 remote=$2 natives
  natives=$(native_systems)
  if grep -qxF "$system" <<<"$natives"; then
    return 0
  fi
  if [ "$remote" != true ]; then
    echo "flake-checks: $system is not native here (native: $(tr '\n' ' ' <<<"$natives" | sed 's/ $//'))." >&2
    echo "flake-checks: pass --remote-builder to delegate it to a configured builder, or leave it to CI." >&2
    exit 2
  fi
  if ! builder_systems "$(nix_config builders || true)" | grep -qxF "$system"; then
    echo "flake-checks: --remote-builder given, but no configured builder (nix config show builders) declares $system." >&2
    exit 2
  fi
  echo "flake-checks: $system is not native; building through a configured remote builder."
}

# ---- stages ----------------------------------------------------------------

stage_lock() {
  group_start "lock: flake.lock matches flake.nix"
  if nix flake metadata "${NIX_FLAGS[@]}" "$FLAKE" >/dev/null; then
    record PASS lock
  else
    record FAIL lock "flake.lock does not match flake.nix; it was not rewritten"
  fi
  group_end
}

stage_eval_configs() {
  local kind_spec kind path names name
  for kind_spec in "${CONFIG_KINDS[@]}"; do
    read -r kind path <<<"$kind_spec"
    if ! names=$(attr_names "$FLAKE#$kind"); then
      record FAIL "eval $kind" "could not enumerate"
      continue
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      group_start "eval $kind.$name"
      if nix eval "${NIX_FLAGS[@]}" --raw "$FLAKE#$kind.\"$name\".$path.drvPath"; then
        echo
        record PASS "eval $kind.$name"
      else
        record FAIL "eval $kind.$name"
      fi
      group_end
    done <<<"$names"
  done
}

stage_eval_outputs() {
  local output systems system count
  # A derivation (formatter.<system>) or an attrset of derivations.
  local apply='x: if (x.type or null) == "derivation" then { _ = x.drvPath; } else builtins.mapAttrs (_: d: d.drvPath) x'
  for output in "${PER_SYSTEM_OUTPUTS[@]}"; do
    if ! systems=$(attr_names "$FLAKE#$output"); then
      record FAIL "eval $output" "could not enumerate systems"
      continue
    fi
    while IFS= read -r system; do
      [ -n "$system" ] || continue
      group_start "eval $output.$system"
      if count=$(nix eval "${NIX_FLAGS[@]}" --json "$FLAKE#$output.$system" --apply "$apply" | jq 'length'); then
        record PASS "eval $output.$system" "$count drvPaths"
      else
        record FAIL "eval $output.$system"
      fi
      group_end
    done <<<"$systems"
  done
  group_start "eval overlays and nixosModules shape"
  local shape='o: builtins.all (v: builtins.isFunction v || builtins.isAttrs v || builtins.isPath v) (builtins.attrValues o)'
  if [ "$(nix eval "${NIX_FLAGS[@]}" --json "$FLAKE#overlays" --apply 'o: builtins.all builtins.isFunction (builtins.attrValues o)')" = true ]; then
    record PASS "eval overlays"
  else
    record FAIL "eval overlays" "every overlay must be a function"
  fi
  if [ "$(nix eval "${NIX_FLAGS[@]}" --json "$FLAKE#nixosModules" --apply "$shape")" = true ]; then
    record PASS "eval nixosModules"
  else
    record FAIL "eval nixosModules" "every module must be a function, attrset or path"
  fi
  group_end
}

stage_lint() {
  local system=$1
  group_start "lint: checks.$system.pre-commit"
  if nix build "${NIX_FLAGS[@]}" --no-link --print-build-logs "$FLAKE#checks.$system.pre-commit"; then
    record PASS "lint checks.$system.pre-commit"
  else
    record FAIL "lint checks.$system.pre-commit"
  fi
  group_end
}

# stage_build_checks SYSTEM [EXCLUDED...]
stage_build_checks() {
  local system=$1 names name ex skip
  shift
  if ! names=$(attr_names "$FLAKE#checks.$system"); then
    record FAIL "build checks.$system" "could not enumerate"
    return
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    skip=false
    for ex in "$@"; do
      if [ "$ex" = "$name" ]; then skip=true; fi
    done
    [ "$skip" = false ] || continue
    group_start "build checks.$system.$name"
    if nix build "${NIX_FLAGS[@]}" --no-link --print-build-logs "$FLAKE#checks.$system.\"$name\""; then
      record PASS "build checks.$system.$name"
    else
      record FAIL "build checks.$system.$name"
    fi
    group_end
  done <<<"$names"
}

# The `task check` preset: everything this machine can execute, and an
# explicit DEFERRED line for every check it cannot.
stage_local() {
  local native systems system names count
  native=$(nix_config system)
  stage_lock
  if [ "$FAILED" -ne 0 ]; then
    record NOT-RUN "eval, lint and check builds" "lock check failed"
    return
  fi
  stage_eval_configs
  stage_eval_outputs
  stage_lint "$native"
  stage_build_checks "$native" pre-commit
  if ! systems=$(attr_names "$FLAKE#checks"); then
    record FAIL "enumerate checks systems"
    return
  fi
  while IFS= read -r system; do
    [ -n "$system" ] && [ "$system" != "$native" ] || continue
    if names=$(attr_names "$FLAKE#checks.$system"); then
      count=$(grep -c . <<<"$names" || true)
      record DEFERRED "build checks.$system" \
        "$count checks evaluated, not built on $native: $(tr '\n' ' ' <<<"$names" | sed 's/ $//')"
    else
      record FAIL "enumerate checks.$system"
    fi
  done <<<"$systems"
  case $native in
    *-darwin)
      echo
      echo "flake-checks: Linux checks were evaluated but NOT built on this Mac."
      echo "flake-checks: build them with \`task check:linux\` (remote builder) or rely on the CI checks/lint jobs."
      ;;
  esac
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

  if [ "$mode" = lint ] || [ "$mode" = build-checks ]; then
    [ -n "$system" ] || system=$(nix_config system)
    require_buildable "$system" "$remote"
  fi

  case $mode in
    lock) stage_lock ;;
    eval-configs) stage_eval_configs ;;
    eval-outputs) stage_eval_outputs ;;
    lint) stage_lint "$system" ;;
    build-checks) stage_build_checks "$system" ${excludes[@]+"${excludes[@]}"} ;;
    local) stage_local ;;
  esac
  finish
}

main "$@"
