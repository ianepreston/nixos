#!/usr/bin/env bash
# Build, copy, then activate a NixOS host configuration with enforced identity
# checks (#1018). Every Task entry point that activates a closure goes through
# here; nothing else should call nixos-rebuild or switch-to-configuration.
#
#   activate-nixos.sh --host <flake-host> [options]
#
# Steps, each its own explicit command (no retry, no fallback, stop on error):
#   1. build   the closure (locally, on --build-host, or on the target with
#              --remote-flake) and, before anything is copied, validate it:
#              exactly /nix/store/<hash>-nixos-system-<host>-<version>, and its
#              own etc/hostname equal to <host> (the name alone is ambiguous
#              for hyphenated hosts);
#   2. copy    it to the target, one single-host connection at a time;
#   3. activate through ONE ssh (or sudo, when local) running
#              scripts/_activate-nixos/activate.sh, which re-asserts hostname
#              == <host>, the closure name and its etc/hostname in the same
#              process as switch-to-configuration, and prints nonce-bearing
#              sentinels; the activation fails unless both come back.
#
# Options:
#   --host H            flake configuration AND the identity the target must report
#   --dest ADDR         ssh destination host; omit to activate this machine
#   --user U            ssh user on the target (default: ipreston)
#   --port N            ssh port on the target
#   --target-ssh-opt O  extra ssh option for target connections (repeatable);
#                       one token each, from an allowlist of connection
#                       settings: -oKey=value (ForwardAgent, ControlPath,
#                       ControlMaster, IdentityFile, ProxyJump, ...), -iFILE,
#                       -JJUMP, -4, -6, -A, -C, -q, -v. Anything that changes
#                       what ssh runs or its stdin (-n, -N, -f, -W, -O, -S, -F,
#                       RemoteCommand, ...) and any whitespace is rejected.
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
# With --build-host, every ssh connection to EITHER host (build, pull, push,
# activate; including the transports nix copy spawns) is forced to
# -oControlMaster=no -oControlPath=none, placed before any user option so it
# wins (ssh keeps the first value it sees, and command-line -o beats
# ~/.ssh/config, `Match` blocks included). Nothing is multiplexed, so no socket
# can carry a command meant for one host to the other; isolation does not
# depend on parsing or comparing socket paths. A jump host would be a separate
# ssh client that never sees those forced options (and could reuse a shared
# master), so split-host mode also rejects -J/-oProxyJump and forces
# -oProxyJump=none -oProxyCommand=none, overriding any jump or proxy from
# ~/.ssh/config. Single-host mode keeps -J/-oProxyJump allowed.
#
# Every ssh to the target passes -T, so `RequestTTY force` in client config
# cannot allocate a tty (merging stderr into stdout, adding CRs); -t, -tt and
# -oRequestTTY are not in the option allowlist.
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

matches() { # matches NAME VALUE REGEX: anchored pattern check, dies otherwise
  [[ $2 =~ $3 ]] || die "invalid $1: '$2'"
}

host_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
addr_re='^[A-Za-z0-9]([A-Za-z0-9._:-]*[A-Za-z0-9])?$'
user_re='^[a-z_][a-z0-9_-]*$'

# Every extra ssh option must be one whitespace-free token (so the
# whitespace-split NIX_SSHOPTS keeps the same argument boundaries as ssh's argv)
# and a pure connection setting: nothing that changes what runs remotely, where
# stdin goes, or which config/socket ssh uses for other hosts.
check_ssh_opt() { # check_ssh_opt WHICH OPTION
  local o=$2 key
  case $o in
    "" | *[!A-Za-z0-9_./:@=+,%~-]*) die "$1 ssh option '$o' contains whitespace or shell metacharacters" ;;
  esac
  case $o in
    -4 | -6 | -A | -C | -q | -v | -vv | -vvv) return 0 ;;
    -i?* | -J?*) return 0 ;;
    -o?*=?*)
      key=${o#-o}
      key=$(printf '%s' "${key%%=*}" | tr '[:upper:]' '[:lower:]')
      ;;
    *) die "$1 ssh option '$o' is not allowed (only connection settings: -oKey=value, -iFILE, -JJUMP, -4, -6, -A, -C, -q, -v)" ;;
  esac
  case $key in
    addressfamily | batchmode | certificatefile | compression | connecttimeout | \
      controlmaster | controlpath | controlpersist | forwardagent | hostkeyalias | \
      identitiesonly | identityagent | identityfile | loglevel | \
      preferredauthentications | proxyjump | pubkeyauthentication | \
      serveralivecountmax | serveraliveinterval | stricthostkeychecking | \
      updatehostkeys | userknownhostsfile) ;;
    *) die "$1 ssh option '$o' is not allowed (-o$key is not an allowlisted connection setting)" ;;
  esac
}

[ -n "$host" ] || die "--host is required"
matches host "$host" "$host_re"
case $action in switch | boot | test | check) ;; *) die "unsupported --action '$action'" ;; esac
[ -z "$dest" ] || matches dest "$dest" "$addr_re"
[ -z "$build_host" ] || matches build-host "$build_host" "^([a-z_][a-z0-9_-]*@)?${addr_re#^}"
if [ -n "$remote_flake" ]; then
  matches remote-flake "$remote_flake" '^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
  case /$remote_flake/ in */../*) die "invalid remote-flake: '$remote_flake'" ;; esac
fi
if [ -n "$port" ]; then
  matches port "$port" '^[0-9]{1,5}$'
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "invalid port: '$port'"
fi
matches user "$user" "$user_re"
for o in ${target_opts[@]+"${target_opts[@]}"}; do check_ssh_opt target "$o"; done
for o in ${build_opts[@]+"${build_opts[@]}"}; do check_ssh_opt build "$o"; done
[ -z "$build_host" ] || [ -z "$remote_flake" ] || die "--build-host and --remote-flake are mutually exclusive"
[ -z "$build_host" ] || [ -n "$dest" ] || die "--build-host needs --dest (a local activation builds locally)"
[ -z "$remote_flake" ] || [ -n "$dest" ] || die "--remote-flake needs --dest"
[ -f "$activate_script" ] || die "missing $activate_script"

# Split-host mode: forbid connection sharing outright. Forced options come first
# so they take precedence over anything the caller or ssh_config supplies. A
# jump host is its own ssh client that the forced options never reach, so
# explicit jumps are refused and config-supplied ones are disabled.
reject_jump() { # reject_jump WHICH OPTION
  local key
  case $1 in -J*) die "$2 ssh option '$1' is not allowed with --build-host: a jump host's ssh client would not inherit ControlMaster=no/ControlPath=none" ;; esac
  case $1 in
    -o*=*)
      key=${1#-o}
      key=$(printf '%s' "${key%%=*}" | tr '[:upper:]' '[:lower:]')
      [ "$key" != proxyjump ] ||
        die "$2 ssh option '$1' is not allowed with --build-host: a jump host's ssh client would not inherit ControlMaster=no/ControlPath=none"
      ;;
  esac
}
if [ -n "$build_host" ]; then
  for o in ${target_opts[@]+"${target_opts[@]}"}; do reject_jump "$o" target; done
  for o in ${build_opts[@]+"${build_opts[@]}"}; do reject_jump "$o" build; done
  no_mux=(-oControlMaster=no -oControlPath=none -oProxyJump=none -oProxyCommand=none)
  target_opts=("${no_mux[@]}" ${target_opts[@]+"${target_opts[@]}"})
  build_opts=("${no_mux[@]}" ${build_opts[@]+"${build_opts[@]}"})
fi

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
  ssh ${port:+-p "$port"} ${target_opts[@]+"${target_opts[@]}"} -T "$target" "$@"
}

ssh_build() {
  # shellcheck disable=SC2029 # client-side expansion is intended; values are validated by safe()
  ssh ${build_opts[@]+"${build_opts[@]}"} "$build_host" "$@"
}

store_dir=/nix/store

# Same anchored shape activate.sh enforces on the target: the store prefix, a
# 32-char hash, then nixos-system-<host>-<version starting YY.MM>.
check_name() {
  local re="^${store_dir}/[0-9abcdfghijklmnpqrsvwxyz]{32}-nixos-system-${host}-[0-9]{2}\\.[0-9]{2}[0-9A-Za-z._+-]*\$"
  [[ $1 =~ $re ]] || die "refusing: '$1' is not a nixos-system-$host closure"
}

# The independent exact check: the closure's own configured hostname.
check_closure_hostname() {
  local configured
  [ -r "$1/etc/hostname" ] || die "refusing: closure has no etc/hostname: $1"
  configured=$(<"$1/etc/hostname")
  [ "$configured" = "$host" ] || die "refusing: closure is configured for host '$configured', expected '$host'"
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
  configured=$(nix eval --raw "$flake#nixosConfigurations.$host.config.networking.hostName" ${override_args[@]+"${override_args[@]}"})
  [ "$configured" = "$host" ] || die "refusing: configuration is for host '$configured', expected '$host'"
  printf 'plan: host=%s action=%s closure=%s\n' "$host" "$action" "$closure"
  if [ -z "$dest" ]; then
    printf 'plan: activate locally: sudo bash %s %s %s %s <nonce>\n' "$activate_script" "$host" "$closure" "$action"
  else
    [ -z "$build_host" ] || printf 'plan: build on %s, pull to this machine, then copy\n' "$build_host"
    printf 'plan: nix copy --to ssh-ng://%s (NIX_SSHOPTS=%s)\n' "$target" "$(target_nix_sshopts)"
    printf 'plan: ssh -T %s sudo bash -s -- %s %s %s <nonce>  < activate.sh\n' "$target" "$host" "$closure" "$action"
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
if [ -n "$build_host" ]; then
  # Pull to this machine (a single-host command) so the closure can be checked
  # here and pushed to the target separately.
  NIX_SSHOPTS=$(sshopts_string ${build_opts[@]+"${build_opts[@]}"}) nix copy --from "ssh-ng://$build_host" "$closure"
fi
# A --remote-flake closure exists only on the target; activate.sh checks it there.
[ -n "$remote_flake" ] || check_closure_hostname "$closure"

# --- 2. copy ------------------------------------------------------------------
# Local activation needs no copy. A remote build host's closure was pulled to
# this machine above and is pushed to the target here, as two separate
# single-host commands with multiplexing disabled, so neither host's options (or
# control socket) can reach the other. The identity-only `check` action copies
# nothing to the target.
if [ -n "$dest" ] && [ -z "$remote_flake" ] && [ "$action" != check ]; then
  printf '[+] Copying closure to %s\n' "$target" >&2
  NIX_SSHOPTS=$(target_nix_sshopts) nix copy --to "ssh-ng://$target" "$closure"
fi

# --- 3. activate (identity checks + switch in one process on the target) ------
# activate.sh echoes a fresh nonce in two sentinel lines; without both, the
# script did not run to completion (e.g. ssh never fed it to bash) and this
# fails even if every exit status was 0.
nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
transcript=$(mktemp)
trap 'rm -f "$transcript"' EXIT

if [ -z "$dest" ]; then
  printf '[+] Activating %s locally (%s)\n' "$host" "$action" >&2
  if [ "$(id -u)" -eq 0 ]; then
    bash "$activate_script" "$host" "$closure" "$action" "$nonce" | tee "$transcript" ||
      die "activation of $host failed (not retried)"
  else
    sudo bash "$activate_script" "$host" "$closure" "$action" "$nonce" | tee "$transcript" ||
      die "activation of $host failed (not retried)"
  fi
else
  printf '[+] Activating %s on %s (%s)\n' "$host" "$target" "$action" >&2
  # `check` copies nothing to the target; only then, and only for a closure this
  # machine already verified locally, may it be absent there.
  verified=""
  [ "$action" != check ] || [ -n "$remote_flake" ] || verified=" caller-verified"
  ssh_target "sudo bash -s -- $host $closure $action $nonce$verified" <"$activate_script" | tee "$transcript" ||
    die "activation of $host on $target failed (not retried); inspect the target before doing anything else"
fi

grep -qx "ACTIVATE-NIXOS-VERIFIED $nonce $host $action" "$transcript" ||
  die "activation script never confirmed its identity checks on $host; treat the result as unknown and inspect the target"
grep -qx "ACTIVATE-NIXOS-DONE $nonce" "$transcript" ||
  die "activation script on $host did not report completion; inspect the target"
