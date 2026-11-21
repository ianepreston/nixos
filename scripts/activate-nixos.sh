#!/usr/bin/env bash
# Build, copy, then activate a NixOS host configuration with enforced identity
# checks (#1018). Every Task entry point that activates a closure goes through
# here; nothing else should call nixos-rebuild or switch-to-configuration.
#
#   activate-nixos.sh --host <flake-host> [options]
#
# Steps, each its own explicit command (no retry, no fallback, stop on error):
#   1. build   the closure (locally, on --build-host, or on the target with
#              --remote-flake) and validate its basename
#              (*-nixos-system-<host>-*) before anything is copied;
#   2. copy    it to the target, one single-host connection at a time;
#   3. activate through ONE ssh (or sudo, when local) running
#              scripts/_activate-nixos/activate.sh, which asserts hostname ==
#              <host> and the closure name in the same chain as
#              switch-to-configuration.
#
# Options:
#   --host H            flake configuration AND the identity the target must report
#   --dest ADDR         ssh destination host; omit to activate this machine
#   --user U            ssh user on the target (default: ipreston)
#   --port N            ssh port on the target
#   --target-ssh-opt O  extra ssh option for target connections (repeatable)
#   --build-host ADDR   build on this ssh host instead of locally (user@host)
#   --build-ssh-opt O   extra ssh option for build-host connections (repeatable)
#   --remote-flake DIR  build on the target from DIR (relative to its $HOME);
#                       nothing is built or copied locally (bootstrap rebuild)
#   --flake DIR         local flake (default: the checkout containing this script)
#   --override-input N V  passed to nix build/eval (repeatable)
#   --local-secrets     override nix-secrets with the sibling checkout, found
#                       portably from worktrees ($NIX_SECRETS_PATH wins)
#   --action A          switch (default) | boot | test | check
#                       check = identity assertions only, activates nothing
#   --dry-run           evaluate and print the plan; build/copy/connect to nothing
#
# SSH options are per host and never shared: NIX_SSHOPTS from the environment is
# discarded, and each nix copy sees only the options of the one host it talks to.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
activate_script=$script_dir/_activate-nixos/activate.sh

die() {
  printf 'activate-nixos: %s\n' "$*" >&2
  exit 1
}

# Never inherit a shared option string; per-host options are set per command.
unset NIX_SSHOPTS

host=""
dest=""
user=ipreston
port=""
build_host=""
remote_flake=""
flake=$(cd "$script_dir/.." && pwd)
action=switch
dry_run=false
local_secrets=false
target_opts=()
build_opts=()
overrides=()

while [ $# -gt 0 ]; do
  case $1 in
    --host)
      host=${2:?--host needs a value}
      shift 2
      ;;
    --dest)
      dest=${2:?--dest needs a value}
      shift 2
      ;;
    --user)
      user=${2:?--user needs a value}
      shift 2
      ;;
    --port)
      port=${2:?--port needs a value}
      shift 2
      ;;
    --target-ssh-opt)
      target_opts+=("${2:?--target-ssh-opt needs a value}")
      shift 2
      ;;
    --target-ssh-opt=*)
      target_opts+=("${1#*=}")
      shift
      ;;
    --build-host)
      build_host=${2:?--build-host needs a value}
      shift 2
      ;;
    --build-ssh-opt)
      build_opts+=("${2:?--build-ssh-opt needs a value}")
      shift 2
      ;;
    --build-ssh-opt=*)
      build_opts+=("${1#*=}")
      shift
      ;;
    --remote-flake)
      remote_flake=${2:?--remote-flake needs a value}
      shift 2
      ;;
    --flake)
      flake=${2:?--flake needs a value}
      shift 2
      ;;
    --override-input)
      [ $# -ge 3 ] || die "--override-input needs NAME and VALUE"
      overrides+=("$2=$3")
      shift 3
      ;;
    --local-secrets)
      local_secrets=true
      shift
      ;;
    --action)
      action=${2:?--action needs a value}
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

safe() { # values that are interpolated into remote command strings
  case $2 in
    "" | *[!A-Za-z0-9_./:@=+,%-]*) die "unsafe or empty $1: '$2'" ;;
  esac
}

[ -n "$host" ] || die "--host is required"
safe host "$host"
case $action in switch | boot | test | check) ;; *) die "unsupported --action '$action'" ;; esac
[ -z "$dest" ] || safe dest "$dest"
[ -z "$build_host" ] || safe build-host "$build_host"
[ -z "$remote_flake" ] || safe remote-flake "$remote_flake"
[ -z "$port" ] || safe port "$port"
safe user "$user"
[ -z "$build_host" ] || [ -z "$remote_flake" ] || die "--build-host and --remote-flake are mutually exclusive"
[ -z "$build_host" ] || [ -n "$dest" ] || die "--build-host needs --dest (a local activation builds locally)"
[ -z "$remote_flake" ] || [ -n "$dest" ] || die "--remote-flake needs --dest"
[ -f "$activate_script" ] || die "missing $activate_script"

# nix-secrets sibling checkout: worktrees live elsewhere, so ../nix-secrets from
# the working directory is not reliable. Try the checkout's own parent, then the
# parent of the main checkout the worktree was created from.
resolve_secrets() {
  local cand common
  if [ -n "${NIX_SECRETS_PATH:-}" ]; then
    [ -d "$NIX_SECRETS_PATH" ] || die "NIX_SECRETS_PATH is not a directory: $NIX_SECRETS_PATH"
    (cd "$NIX_SECRETS_PATH" && pwd)
    return
  fi
  cand=$flake/../nix-secrets
  if [ -d "$cand" ]; then
    (cd "$cand" && pwd)
    return
  fi
  if common=$(git -C "$flake" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    cand=$common/../../nix-secrets
    if [ -d "$cand" ]; then
      (cd "$cand" && pwd)
      return
    fi
  fi
  die "cannot find the nix-secrets checkout (set NIX_SECRETS_PATH or use a sibling ../nix-secrets)"
}

if [ "$local_secrets" = true ]; then
  if [ -n "$remote_flake" ]; then
    # Resolved on the target, where bootstrap:sync put the checkout.
    overrides+=("nix-secrets=path:../nix-secrets")
  else
    overrides+=("nix-secrets=path:$(resolve_secrets)")
  fi
fi

override_args=()
for o in ${overrides[@]+"${overrides[@]}"}; do
  safe override "$o"
  override_args+=(--override-input "${o%%=*}" "${o#*=}")
done

attr=nixosConfigurations.$host.config.system.build.toplevel
target=${user}@${dest}

# --- per-host connection helpers: options are scoped to one host each --------
sshopts_string() { # prints the options of one host as a NIX_SSHOPTS string
  local out="" o
  for o in "$@"; do out+="${out:+ }$o"; done
  printf '%s' "$out"
}

target_nix_sshopts() {
  local s
  s=$(sshopts_string ${port:+-p "$port"} ${target_opts[@]+"${target_opts[@]}"})
  printf '%s' "$s"
}

ssh_target() {
  # shellcheck disable=SC2029 # client-side expansion is intended; values are validated by safe()
  ssh ${port:+-p "$port"} ${target_opts[@]+"${target_opts[@]}"} "$target" "$@"
}

ssh_build() {
  # shellcheck disable=SC2029 # client-side expansion is intended; values are validated by safe()
  ssh ${build_opts[@]+"${build_opts[@]}"} "$build_host" "$@"
}

check_name() {
  case ${1##*/} in
    *-nixos-system-"$host"-*) ;;
    *) die "refusing: '$1' is not a nixos-system-$host closure" ;;
  esac
}

single_path() { # the helper's builds must yield exactly one store path
  [ "$(printf '%s\n' "$1" | grep -c .)" -eq 1 ] || die "expected exactly one store path, got: $1"
}

# --- dry run: evaluate only ---------------------------------------------------
if [ "$dry_run" = true ]; then
  [ -z "$remote_flake" ] || die "--dry-run cannot evaluate a --remote-flake (it would need the target)"
  closure=$(nix eval --raw "$flake#$attr.outPath" ${override_args[@]+"${override_args[@]}"})
  single_path "$closure"
  check_name "$closure"
  printf 'plan: host=%s action=%s closure=%s\n' "$host" "$action" "$closure"
  if [ -z "$dest" ]; then
    printf 'plan: activate locally: sudo bash %s %s %s %s\n' "$activate_script" "$host" "$closure" "$action"
  else
    [ -z "$build_host" ] || printf 'plan: build on %s, pull to this machine, then copy\n' "$build_host"
    printf 'plan: nix copy --to ssh-ng://%s (NIX_SSHOPTS=%s)\n' "$target" "$(target_nix_sshopts)"
    printf 'plan: ssh %s sudo bash -s -- %s %s %s  < activate.sh\n' "$target" "$host" "$closure" "$action"
  fi
  exit 0
fi

# --- 1. build -----------------------------------------------------------------
if [ -n "$remote_flake" ]; then
  # Bootstrap: the target builds its own freshly synced checkout.
  printf '[+] Building %s on %s (%s)\n' "$host" "$target" "$remote_flake" >&2
  closure=$(ssh_target "cd $remote_flake && nix build --no-link --print-out-paths .#$attr ${override_args[*]:-}")
elif [ -n "$build_host" ]; then
  printf '[+] Building %s on %s\n' "$host" "$build_host" >&2
  drv=$(nix eval --raw "$flake#${attr}.drvPath" ${override_args[@]+"${override_args[@]}"})
  NIX_SSHOPTS=$(sshopts_string ${build_opts[@]+"${build_opts[@]}"}) nix copy --derivation --to "ssh-ng://$build_host" "$drv"
  closure=$(ssh_build "nix-store --realise $drv")
else
  printf '[+] Building %s locally\n' "$host" >&2
  closure=$(nix build --no-link --print-out-paths "$flake#$attr" ${override_args[@]+"${override_args[@]}"})
fi
single_path "$closure"
check_name "$closure"
safe closure "$closure"

# --- 2. copy ------------------------------------------------------------------
# Local activation needs no copy. A remote build host's closure is pulled to
# this machine and pushed to the target as two separate single-host commands,
# so neither host's options (or control socket) can reach the other. The
# identity-only `check` action copies nothing.
if [ -n "$dest" ] && [ -z "$remote_flake" ] && [ "$action" != check ]; then
  if [ -n "$build_host" ]; then
    NIX_SSHOPTS=$(sshopts_string ${build_opts[@]+"${build_opts[@]}"}) nix copy --from "ssh-ng://$build_host" "$closure"
  fi
  printf '[+] Copying closure to %s\n' "$target" >&2
  NIX_SSHOPTS=$(target_nix_sshopts) nix copy --to "ssh-ng://$target" "$closure"
fi

# --- 3. activate (identity checks + switch in one process on the target) ------
if [ -z "$dest" ]; then
  printf '[+] Activating %s locally (%s)\n' "$host" "$action" >&2
  if [ "$(id -u)" -eq 0 ]; then
    bash "$activate_script" "$host" "$closure" "$action"
  else
    sudo bash "$activate_script" "$host" "$closure" "$action"
  fi
else
  printf '[+] Activating %s on %s (%s)\n' "$host" "$target" "$action" >&2
  ssh_target "sudo bash -s -- $host $closure $action" <"$activate_script"
fi
