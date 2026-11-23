#!/usr/bin/env bash
# Build, copy, then activate a NixOS host configuration with enforced identity
# checks (#1018). Every Task entry point that activates a closure goes through
# here; nothing else should call nixos-rebuild or switch-to-configuration.
#
#   activate-nixos.sh --host <flake-host> [options]
#
# Steps, each its own explicit command (no retry, no fallback, stop on error):
#   0. preflight the transports, builders and target before any build;
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
#   --local-secrets     override nix-secrets (default: flake.lock) with the sibling checkout, found
#                       portably from worktrees ($NIX_SECRETS_PATH wins)
#   --action A          switch (default) | boot | test | check
#                       check = probe the transport and assert identity, activates nothing
#   --preflight         run only the read-only preflight; build/copy/activate nothing
#   --skip-preflight    bypass the preflight before building
#   --dry-run           evaluate and print the plan; build/copy/connect to nothing
#
# SSH options are per host and never shared: NIX_SSHOPTS from the environment is
# discarded, and each nix copy sees only the options of the one host it talks to.
# Single-host mode REUSES the ssh master you pre-opened (hardware-key ssh auth
# cannot be answered by an agent): the closure is copied over the legacy
# ssh:// store, which runs one plain `ssh` per command, so each of those picks
# up the ControlPath socket from ~/.ssh/config. That is the transport observed
# to work with no touch (#1039); ssh-ng:// is NOT used there. Whether ssh-ng://
# can reuse the master depends on the Nix version and store options: upstream
# Nix 2.24-2.34 starts its own master on a private `-S` socket (which bypasses
# a pre-opened one) only when the store's max-connections is above 1; at the
# default of 1 each store connection is a plain ssh, like ssh://. Either way,
# when `ssh -O check` with the same options finds no master, Nix opens a fresh
# connection and waits for its fixed `-oLocalCommand=echo started` handshake
# (see the preflight's store probe). The copy leg is given -oControlMaster=no
# (use an existing master, never become one) and never ControlPath=none, which
# would defeat the reuse. The direct ssh activation connection reuses the same
# master.
# With --build-host, every ssh connection to EITHER host (build, pull, push,
# activate; including the transports nix copy spawns) is forced to
# -oControlMaster=no -oControlPath=none, placed before any user option so it
# wins (ssh keeps the first value it sees, and command-line -o beats
# ~/.ssh/config, `Match` blocks included). Nothing is multiplexed, so no socket
# can carry a command meant for one host to the other; isolation does not
# depend on parsing or comparing socket paths. The price: every leg in split
# mode authenticates afresh (no shared socket, whether or not Nix starts its
# own private master for a copy), so a hardware key needs a touch per leg. A
# jump host would be a separate ssh client that never sees those forced
# options (and could reuse a shared master), so split-host mode also rejects
# -J/-oProxyJump and forces -oProxyJump=none -oProxyCommand=none, overriding
# any jump or proxy from ~/.ssh/config. Single-host mode keeps -J/-oProxyJump allowed.
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
preflight=auto
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
    --preflight | --skip-preflight)
      [ "$preflight" = auto ] || die "choose at most one of --preflight and --skip-preflight"
      preflight=$1
      shift
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
[ "$dry_run" != true ] || [ "$preflight" != --preflight ] || die "--dry-run and --preflight are mutually exclusive"

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

secrets_dir=""
if [ "$local_secrets" = true ]; then
  if [ -n "$remote_flake" ]; then
    # Resolved on the target, where bootstrap:sync put the checkout.
    overrides+=("nix-secrets=path:../nix-secrets")
  else
    secrets_dir=$(resolve_secrets)
    overrides+=("nix-secrets=path:$secrets_dir")
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

# Options for the copy to the target. Split-host mode already forces no
# multiplexing (and more) at the head of target_opts. Single-host mode must
# reuse the pre-opened master, so it adds only -oControlMaster=no (an existing
# ControlPath socket is still used as a client; this ssh just never becomes a
# master) and never ControlPath=none. Caller options follow and may still set
# -oControlPath explicitly.
target_nix_sshopts() {
  local s
  local forced=()
  [ -n "$build_host" ] || forced=(-oControlMaster=no)
  s=$(sshopts_string ${forced[@]+"${forced[@]}"} ${port:+-p "$port"} ${target_opts[@]+"${target_opts[@]}"})
  printf '%s' "$s"
}

# ssh:// reuses the caller's pre-opened master (one plain ssh per command; the
# path observed to work in #1039). ssh-ng:// is only used where multiplexing is
# forbidden anyway (split-host mode); whether it would reuse a master depends
# on the Nix version and max-connections (see the header).
target_store_scheme() {
  if [ -n "$build_host" ]; then printf 'ssh-ng'; else printf 'ssh'; fi
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
    if [ "$action" = check ]; then
      printf 'plan: copy: skipped (check)\n'
    else
      printf 'plan: nix copy --to %s://%s (NIX_SSHOPTS=%s)\n' "$(target_store_scheme)" "$target" "$(target_nix_sshopts)"
    fi
    printf 'plan: ssh -T %s sudo bash -s -- %s %s %s <nonce>  < activate.sh\n' "$target" "$host" "$closure" "$action"
  fi
  exit 0
fi

# --- 0. transport preflight --------------------------------------------------
# Use a process-group deadline (including ssh and its children), in addition
# to ConnectTimeout, which only covers connection establishment. Never print
# command stderr: it can contain account names, agent paths or config values.
bounded() {
  LC_ALL=C SSH_ASKPASS_REQUIRE=never timeout -k 1s "$@"
}

# The functions below also run on a remote machine (the build-environment
# probe), whose output reaches us merged with arbitrary remote text. There
# (preflight_remote=true) a failure prints only `preflight-error: <code>` and
# the local side renders a fixed message for a code it recognises.
preflight_remote=false

preflight_fail() {
  if [ "$preflight_remote" = true ]; then
    printf 'preflight-error: internal\n'
    exit 1
  fi
  printf 'preflight: %s\n' "$*" >&2
  exit 1
}

preflight_fail_code() { # preflight_fail_code CODE MESSAGE...
  if [ "$preflight_remote" = true ]; then
    printf 'preflight-error: %s\n' "$1"
    exit 1
  fi
  shift
  preflight_fail "$@"
}

require_preflight_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null; then
      case $tool in
        timeout) preflight_fail_code tool-timeout "required tool 'timeout' is missing. Install GNU coreutils." ;;
        *) preflight_fail_code "tool-$tool" "required tool '$tool' is missing. Install it on the machine running this probe." ;;
      esac
    fi
  done
}

# Place these before caller options (OpenSSH uses the first value it sees).
# A probe cannot accept/update host keys, add identities, or set up forwards.
probe_common_opts=(-oBatchMode=yes -oConnectTimeout=8 -oStrictHostKeyChecking=yes
  -oUpdateHostKeys=no -oAddKeysToAgent=no -oClearAllForwardings=yes
  -oForkAfterAuthentication=no)
# Plain ssh probes run no local command at all.
probe_opts=("${probe_common_opts[@]}" -oPermitLocalCommand=no)
# Store probes go through Nix's own ssh, which puts NIX_SSHOPTS FIRST and then
# appends -oPermitLocalCommand=yes -oLocalCommand='echo started'. On a fresh
# (not multiplexed) connection Nix fails unless it reads `started` back, so a
# PermitLocalCommand=no here would win and break the handshake after a
# successful authentication; a warm master hides that, since its multiplexed
# sessions never run LocalCommand. Leave both unset: Nix's command-line values
# then beat any ssh_config PermitLocalCommand/LocalCommand, so the only local
# command is Nix's fixed `echo started` (the option allowlist keeps callers
# from setting either). Everything else matches the plain probes.
store_probe_opts=("${probe_common_opts[@]}")

# Classify a failed ssh/Nix-store probe from its exit status and output.
# Precedence, first match wins (each pair is tested in both orders):
#   1. hostkey      "Host key verification failed"
#   2. signing      "agent refused operation" / "signing failed" /
#                   "PIN required" / "user presence"
#   3. denied       "Permission denied" (explicit authentication denial)
#   4. protocol     "protocol mismatch" (Nix store protocol)
#   5. unreachable  "Could not resolve hostname" / "Connection refused" /
#                   "No route to host" / "Operation timed out" /
#                   "Connection timed out"
#   6. timeout      exit status 124 or 137 (our deadline fired)
#   7. handshake    Nix's "failed to start SSH (master) connection", which it
#                   prints whenever it did not read `started`, including when
#                   ssh exited before authenticating, so 1-6 win over it
#   8. failed       anything else
# The remote build-environment leg inserts two classes (see
# probe_remote_build_environment): a recognised remote code beats 1, and an
# unrecognised `preflight-error:` marker sits between 6 and 7.
ssh_failure_class() { # ssh_failure_class STATUS OUTPUT
  case $2 in *"Host key verification failed"*) echo hostkey && return ;; esac
  case $2 in *"agent refused operation"* | *"signing failed"* | *"PIN required"* | *"user presence"*) echo signing && return ;; esac
  case $2 in *"Permission denied"*) echo denied && return ;; esac
  case $2 in *"protocol mismatch"*) echo protocol && return ;; esac
  case $2 in *"Could not resolve hostname"* | *"Connection refused"* | *"No route to host"* | *"Operation timed out"* | *"Connection timed out"*) echo unreachable && return ;; esac
  case $1 in 124 | 137) echo timeout && return ;; esac
  case $2 in *"failed to start SSH connection"* | *"failed to start SSH master connection"*) echo handshake && return ;; esac
  echo failed
}

ssh_failure_message() { # fixed text per class; no status, host or output
  case $1 in
    hostkey) echo "Host key verification failed. Verify the host key out of band and update the SSH trust entry." ;;
    signing) echo "SSH signing failed (agent refused operation or needs touch/PIN). Unlock the key and verify authentication from an operator terminal." ;;
    denied) echo "SSH authentication denied in BatchMode. Verify the SSH identity and complete any required touch/PIN from an operator terminal." ;;
    protocol) echo "Nix store protocol mismatch. Check the remote Nix store command and unexpected shell startup output." ;;
    unreachable) echo "unreachable over SSH. Check the host, network and SSH port." ;;
    timeout) echo "probe timed out. Check connectivity and any pending SSH touch/PIN prompt." ;;
    handshake) echo "Nix's SSH session did not complete its start handshake. Verify the connection with the same options from an operator terminal." ;;
    failed) echo "probe failed. Verify the SSH connection from an operator terminal." ;;
    *) return 1 ;;
  esac
}

# LEG is locally supplied (our own arguments or our own builder-list parse).
# Remotely this only runs for builder probes, hence the builder-<class> code.
ssh_probe_failure() { # ssh_probe_failure LEG STATUS OUTPUT
  local class
  class=$(ssh_failure_class "$2" "$3")
  preflight_fail_code "builder-$class" "$1: $(ssh_failure_message "$class")"
}

# The fixed local message for a remote build-environment code, or status 1 if
# the code is unknown or names a check that did not run on this path (the
# secrets comparison runs only for a bootstrap with --local-secrets).
remote_preflight_message() { # remote_preflight_message CODE SECRETS_CHECKED
  local install="is missing. Install it on the machine running this probe."
  case $1 in
    tool-timeout) echo "required tool 'timeout' is missing. Install GNU coreutils." ;;
    tool-nix) echo "required tool 'nix' $install" ;;
    tool-cat) echo "required tool 'cat' $install" ;;
    tool-ssh) echo "required tool 'ssh' $install" ;;
    builders-unreadable) echo "cannot read Nix builders on the build machine. Check its Nix configuration." ;;
    builders-file-unreadable) echo "cannot read the Nix builders file. Check its permissions." ;;
    builder-destination-invalid) echo "invalid SSH builder destination. Check the Nix builders configuration." ;;
    builder-hostkey | builder-signing | builder-denied | builder-protocol | builder-unreachable | builder-timeout | builder-handshake | builder-failed)
      echo "a Nix builder configured there: $(ssh_failure_message "${1#builder-}")"
      ;;
    tool-jq | tool-git | secrets-*)
      [ "$2" = true ] || return 1
      case $1 in
        tool-jq) echo "required tool 'jq' $install" ;;
        tool-git) echo "required tool 'git' $install" ;;
        secrets-lock-unreadable) echo "cannot read the locked nix-secrets revision. Check flake.lock." ;;
        secrets-checkout-missing) echo "the local nix-secrets override is missing its Git checkout. Sync the checkout or use the locked input." ;;
        secrets-head-unreadable) echo "cannot read the local nix-secrets HEAD. Check the checkout or use the locked input." ;;
        secrets-worktree-unreadable) echo "cannot inspect the local nix-secrets worktree. Check the checkout or use the locked input." ;;
        secrets-stale-clean) echo "stale local nix-secrets (clean): HEAD differs from the locked revision. Check out the locked revision or omit --local-secrets." ;;
        secrets-stale-dirty) echo "stale local nix-secrets (has uncommitted changes): HEAD differs from the locked revision. Check out the locked revision or omit --local-secrets." ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

probe_agent() {
  local endpoint=$1 cfg agent var status output
  shift
  require_preflight_tools awk
  cfg=$(bounded 4s ssh "${probe_opts[@]}" "$@" -G -T "$endpoint" </dev/null 2>/dev/null) ||
    preflight_fail "cannot read effective SSH settings for $endpoint. Check the SSH configuration for errors or a stalled Match command."
  agent=$(awk '$1 == "identityagent" {sub(/^[^ ]+ +/, ""); print; exit}' <<<"$cfg")
  case $agent in
    none)
      printf 'preflight: IdentityAgent is disabled for %s\n' "$endpoint" >&2
      return
      ;;
    '' | SSH_AUTH_SOCK) agent=${SSH_AUTH_SOCK:-} ;;
    '$'*)
      # ssh -G leaves variable references unexpanded. Resolve one variable
      # without evaluating arbitrary ssh_config content as shell input.
      var=${agent#\$}
      var=${var#\{}
      var=${var%\}}
      [[ $var =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
        preflight_fail "cannot resolve IdentityAgent for $endpoint. Check the configured socket."
      agent=${!var:-}
      ;;
  esac
  agent=${agent/#\%d/$HOME}
  case $agent in
    *%*) preflight_fail "cannot resolve IdentityAgent tokens for $endpoint. Check the configured socket." ;;
    '') preflight_fail "$endpoint: no effective SSH agent socket. Start the SSH agent and load the SSH keys." ;;
  esac
  if [ "$agent" = "${SSH_AUTH_SOCK:-}" ]; then
    printf 'preflight: %s uses the SSH_AUTH_SOCK agent\n' "$endpoint" >&2
  else
    printf 'preflight: %s uses IdentityAgent, which differs from SSH_AUTH_SOCK\n' "$endpoint" >&2
  fi
  output=$(SSH_AUTH_SOCK=$agent bounded 4s ssh-add -l </dev/null 2>&1) || {
    status=$?
    case $status:$output in
      124:* | 137:*) preflight_fail "$endpoint: SSH agent unresponsive. Check for a pending touch or PIN prompt in the operator terminal." ;;
      # A locked OpenSSH agent (ssh-add -x) normally lists no identities too.
      *"The agent has no identities"*) preflight_fail "$endpoint: SSH agent has no identities (a locked agent also lists none). Unlock the effective agent or load the SSH keys into it." ;;
      *"agent refused operation"*) preflight_fail "$endpoint: SSH agent refused operation. Unlock the effective agent and retry." ;;
      *) preflight_fail "$endpoint: cannot query the effective SSH agent. Check that its socket is reachable." ;;
    esac
  }
  # Report public fingerprints and types only, never the key comments.
  awk -v endpoint="$endpoint" '$2 ~ /^SHA256:[a-zA-Z0-9+\/=]+$/ && $NF ~ /^\([A-Z0-9-]+\)$/ {
    printf "preflight: %s agent key %s %s\n", endpoint, $2, $NF
  }' <<<"$output" >&2
}

probe_store() {
  local uri=$1 opts=$2 output
  output=$(NIX_SSHOPTS="$(sshopts_string "${store_probe_opts[@]}" -T) $opts" \
    bounded 12s nix store info --store "$uri" </dev/null 2>&1) ||
    ssh_probe_failure "store transport $uri" "$?" "$output"
}

# A bounded `ssh ... <builder> true` from the caller's context (this user's
# ssh config, agent and known_hosts), not the Nix daemon's, which is what
# really connects for a distributed build. -oControlMaster=no still uses a
# warm master on the effective ControlPath, and that masks host-key and
# authentication failures. A pass shows this caller can reach (and, with no
# warm master, authenticate to) the builder; it does not prove the daemon can.
probe_builders() {
  local builders machine endpoint identity output port
  local -a opts
  require_preflight_tools nix
  builders=$(bounded 4s nix config show builders </dev/null 2>/dev/null) ||
    preflight_fail_code builders-unreadable "cannot read Nix builders on the build machine. Check its Nix configuration."
  # Nix accepts semicolon/newline-delimited machine specs or @/path/to/file.
  case $builders in
    @*)
      machine=${builders#@}
      # Nix treats an absent builders file (including the default) as empty.
      [ -e "$machine" ] || return 0
      require_preflight_tools cat
      builders=$(bounded 4s cat -- "$machine" 2>/dev/null) ||
        preflight_fail_code builders-file-unreadable "cannot read the Nix builders file. Check its permissions."
      ;;
  esac
  while read -r machine _ identity _; do
    case $machine in
      '' | \#* | auto | daemon | local | /*) continue ;;
      ssh://* | ssh-ng://*) endpoint=${machine#*://} ;;
      *://*) continue ;;
      *) endpoint=$machine ;;
    esac
    opts=()
    # Use the SSH identity and port from the machine spec when supplied.
    [ -z "$identity" ] || [ "$identity" = - ] || opts+=(-i "$identity")
    if [[ $endpoint =~ ^(.*\]|[^:]+):([0-9]+)$ ]]; then
      port=${BASH_REMATCH[2]}
      endpoint=${BASH_REMATCH[1]}
      opts+=(-p "$port")
    fi
    endpoint=${endpoint//[\[\]]/}
    [[ $endpoint =~ ^([a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?([a-zA-Z0-9_][a-zA-Z0-9._:%-]*|::[a-zA-Z0-9._:%-]*)$ ]] ||
      preflight_fail_code builder-destination-invalid "invalid SSH builder destination. Check the Nix builders configuration."
    require_preflight_tools ssh
    output=$(bounded 12s ssh "${probe_opts[@]}" -oControlMaster=no "${opts[@]+"${opts[@]}"}" -T "$endpoint" true </dev/null 2>&1 >/dev/null) ||
      ssh_probe_failure "builder $endpoint" "$?" "$output"
  done <<<"${builders//;/$'\n'}"
}

probe_secrets() {
  local lock=$1 dir=$2 locked head dirty state code
  require_preflight_tools jq git
  locked=$(bounded 4s jq -er 'getpath(["nodes", .nodes[.root].inputs["nix-secrets"], "locked", "rev"]) |
    select(type == "string" and test("^[a-f0-9]{40}$"))' "$lock" 2>/dev/null) ||
    preflight_fail_code secrets-lock-unreadable "cannot read the locked nix-secrets revision. Check flake.lock."
  [ -e "$dir/.git" ] ||
    preflight_fail_code secrets-checkout-missing "the local nix-secrets override is missing its Git checkout. Sync the checkout or use the locked input."
  head=$(bounded 4s git -C "$dir" rev-parse --verify HEAD 2>/dev/null) ||
    preflight_fail_code secrets-head-unreadable "cannot read the local nix-secrets HEAD. Check the checkout or use the locked input."
  dirty=$(bounded 4s git --no-optional-locks -C "$dir" status --porcelain --untracked-files=normal 2>/dev/null) ||
    preflight_fail_code secrets-worktree-unreadable "cannot inspect the local nix-secrets worktree. Check the checkout or use the locked input."
  state=clean code=clean
  [ -z "$dirty" ] || state="has uncommitted changes" code=dirty
  if [ "$head" != "$locked" ]; then
    preflight_fail_code "secrets-stale-$code" "stale local nix-secrets ($state): HEAD $head differs from locked $locked. Check out the locked revision or omit --local-secrets."
  fi
  if [ "$preflight_remote" = true ]; then
    printf 'preflight-ok: secrets-%s\n' "$code"
  else
    printf 'preflight: local nix-secrets matches the locked revision (%s)\n' "$state" >&2
  fi
}

probe_remote_build_environment() {
  local endpoint=$1 directory=$2 secrets=$3 output line status message class unrecognized=false
  shift 3
  # Discover and reach distributed builders from the machine running the build.
  # For bootstrap, compare the synced checkout with that machine's flake.lock.
  # Everything the remote side says is untrusted: only exact code lines are
  # read, and only fixed local text (plus our own endpoint) is printed.
  output=$(
    {
      declare -f bounded preflight_fail preflight_fail_code require_preflight_tools \
        ssh_failure_class ssh_failure_message ssh_probe_failure probe_builders probe_secrets
      declare -p probe_opts
      cat <<'REMOTE'
set -euo pipefail
preflight_remote=true
require_preflight_tools timeout nix
if [ "$2" = true ]; then probe_secrets "$1/flake.lock" "$1/../nix-secrets"; fi
probe_builders
REMOTE
    } | bounded 45s ssh "${probe_opts[@]}" "$@" -T "$endpoint" "bash -s -- $directory $secrets" 2>&1
  ) || {
    status=$?
    # 0. a recognised code on any line wins (a successful secrets comparison
    # may already have logged an ok line; it is ignored here).
    while IFS= read -r line; do
      case $line in
        "preflight-error: "*)
          if message=$(remote_preflight_message "${line#preflight-error: }" "$secrets"); then
            preflight_fail "on $endpoint: $message"
          fi
          unrecognized=true
          ;;
      esac
    done <<<"$output"
    # 1-6 of ssh_failure_class, then an unrecognised marker, then 7-8.
    class=$(ssh_failure_class "$status" "$output")
    case $class in
      handshake | failed) ;;
      *) ssh_probe_failure "build environment on $endpoint" "$status" "$output" ;;
    esac
    [ "$unrecognized" = false ] ||
      preflight_fail "on $endpoint: the remote preflight failed with an unrecognized error. Run the same preflight from an operator terminal."
    ssh_probe_failure "build environment on $endpoint" "$status" "$output"
  }
  [ "$secrets" = true ] || return 0
  while IFS= read -r line; do
    case $line in
      "preflight-ok: secrets-clean")
        printf 'preflight: local nix-secrets on %s matches the locked revision (clean)\n' "$endpoint" >&2
        return
        ;;
      "preflight-ok: secrets-dirty")
        printf 'preflight: local nix-secrets on %s matches the locked revision (has uncommitted changes)\n' "$endpoint" >&2
        return
        ;;
    esac
  done <<<"$output"
}

probe_hostname() {
  local leg=$1 deadline=$2 stderr status
  shift 2
  # Send hostname stdout to the caller and collect only stderr for failures.
  stderr=$(bounded "$deadline" "$@" </dev/null 2>&1 >&3) || {
    status=$?
    if [ "$leg" = "local hostname probe" ]; then
      case $status in
        124 | 137) preflight_fail "$leg: probe timed out. Check the local hostname command." ;;
        *) preflight_fail "$leg: could not determine the local hostname (exit $status)." ;;
      esac
    fi
    ssh_probe_failure "$leg" "$status" "$stderr"
  }
} 3>&1

run_preflight() {
  local actual output
  require_preflight_tools timeout
  if [ -n "$dest" ]; then
    local target_argv=(${port:+-p "$port"} ${target_opts[@]+"${target_opts[@]}"})
    if [ -z "$build_host" ]; then
      target_argv=(-oControlMaster=no ${target_argv[@]+"${target_argv[@]}"})
      if ! bounded 4s ssh "${probe_opts[@]}" "${target_argv[@]+"${target_argv[@]}"}" -O check -T "$target" </dev/null >/dev/null 2>&1; then
        if [ -z "$remote_flake" ]; then
          preflight_fail "no usable SSH master for $target. Open it from an operator terminal using the same destination and SSH options."
        fi
        printf 'preflight: warning: no usable SSH master for %s. Continuing with BatchMode probes. To bypass preflight explicitly, use SKIP_PREFLIGHT=true or --skip-preflight.\n' "$target" >&2
      fi
    fi
    probe_agent "$target" "${target_argv[@]+"${target_argv[@]}"}"
    if [ -n "$build_host" ]; then
      probe_agent "$build_host" "${build_opts[@]}"
    fi
    probe_store "$(target_store_scheme)://$target" "$(target_nix_sshopts)"
    if [ -n "$build_host" ]; then
      output=$(bounded 12s ssh "${probe_opts[@]}" "${build_opts[@]}" -T "$build_host" true </dev/null 2>&1 >/dev/null) ||
        ssh_probe_failure "builder $build_host" "$?" "$output"
      probe_store "ssh-ng://$build_host" "$(sshopts_string "${build_opts[@]}")"
      probe_remote_build_environment "$build_host" . false "${build_opts[@]}"
    elif [ -n "$remote_flake" ]; then
      probe_remote_build_environment "$target" "$remote_flake" "$local_secrets" "${target_argv[@]+"${target_argv[@]}"}"
    else
      probe_builders
    fi
    actual=$(probe_hostname "hostname probe for $target" 12s ssh "${probe_opts[@]}" "${target_argv[@]+"${target_argv[@]}"}" -T "$target" hostname)
  else
    probe_builders
    actual=$(probe_hostname "local hostname probe" 4s hostname)
  fi
  # Never print the reply itself: it is remote (or command) output.
  if [ "$actual" != "$host" ]; then
    preflight_fail "hostname probe did not report the expected hostname '$host'. Check the destination and --host."
  fi
  [ -z "$secrets_dir" ] || probe_secrets "$flake/flake.lock" "$secrets_dir"
  printf 'preflight: passed for %s\n' "$host" >&2
}

if [ "$preflight" = --skip-preflight ]; then
  printf 'preflight: skipped (explicit)\n' >&2
else
  run_preflight
  [ "$preflight" != --preflight ] || exit 0
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
# control socket) can reach the other. Without a build host the copy reuses the
# pre-opened ssh master (see the header). The identity-only `check` action
# copies nothing to the target.
if [ -n "$dest" ] && [ -z "$remote_flake" ] && [ "$action" != check ]; then
  printf '[+] Copying closure to %s\n' "$target" >&2
  NIX_SSHOPTS=$(target_nix_sshopts) nix copy --to "$(target_store_scheme)://$target" "$closure"
fi

# --- 3. activate (identity checks + switch in one process on the target) ------
# activate.sh echoes a fresh nonce in two sentinel lines; without both, the
# script did not run to completion (e.g. ssh never fed it to bash) and this
# fails even if every exit status was 0.
nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
transcript=$(mktemp)
trap 'rm -f "$transcript"' EXIT

# activate.sh prints this marker only when it stopped before activating anything
# (the store-copy session did not end in time, #1076): safe to rerun as is.
activation_failed() {
  if grep -qx "ACTIVATE-NIXOS-NOT-ACTIVATED $nonce $host" "$transcript"; then
    die "activation of $host did not start: the store-copy session on the target did not end in time. Nothing was activated; it is safe to retry"
  fi
  die "$1"
}

if [ -z "$dest" ]; then
  printf '[+] Activating %s locally (%s)\n' "$host" "$action" >&2
  if [ "$(id -u)" -eq 0 ]; then
    bash "$activate_script" "$host" "$closure" "$action" "$nonce" | tee "$transcript" ||
      activation_failed "activation of $host failed (not retried)"
  else
    sudo bash "$activate_script" "$host" "$closure" "$action" "$nonce" | tee "$transcript" ||
      activation_failed "activation of $host failed (not retried)"
  fi
else
  printf '[+] Activating %s on %s (%s)\n' "$host" "$target" "$action" >&2
  # `check` copies nothing to the target; only then, and only for a closure this
  # machine already verified locally, may it be absent there.
  verified=""
  [ "$action" != check ] || [ -n "$remote_flake" ] || verified=" caller-verified"
  ssh_target "sudo bash -s -- $host $closure $action $nonce$verified" <"$activate_script" | tee "$transcript" ||
    activation_failed "activation of $host on $target failed (not retried); inspect the target before doing anything else"
fi

grep -qx "ACTIVATE-NIXOS-VERIFIED $nonce $host $action" "$transcript" ||
  die "activation script never confirmed its identity checks on $host; treat the result as unknown and inspect the target"
grep -qx "ACTIVATE-NIXOS-DONE $nonce" "$transcript" ||
  die "activation script on $host did not report completion; inspect the target"
