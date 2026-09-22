# shellcheck shell=bash
# This file is embedded in the store-managed `sandbox` wrapper by
# coding-sandbox.nix. Keep it POSIX-ish Bash: it runs on macOS before the VM
# exists, not in the Linux guest.
set -euo pipefail

die() {
  printf 'sandbox: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'sandbox: %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  sandbox doctor
  sandbox list
  sandbox plan [--network restricted|open] [WORKTREE]
  sandbox template [--network restricted|open] [WORKTREE]
  sandbox validate [--network restricted|open] [WORKTREE]
  sandbox start [--network restricted|open] [--yes] [WORKTREE]
  sandbox shell [--network restricted|open] [WORKTREE]
  sandbox exec [--network restricted|open] [WORKTREE] -- COMMAND [ARG...]
  sandbox status [--network restricted|open] [WORKTREE]
  sandbox stop [--network restricted|open] [WORKTREE]
  sandbox destroy [--network restricted|open] [--yes] [WORKTREE]
  sandbox delete [--yes] INSTANCE

The default worktree is the current directory's Git worktree.

Network modes:
  restricted  Default. Guest egress is default-drop; only HTTPS through an
              allowlisted proxy is possible. The initial allowlist is the two
              local model endpoints, Nix caches, Determinate Nix, and GitHub
              (needed to materialize the fixed guest Home Manager profile).
  open        No guest egress firewall or proxy. Use only for troubleshooting
              or a task that cannot work through the restricted proxy.

The selected worktree is the only mutable host path, mounted read-write at
/workspace. The fixed, store-built guest profile is separately mounted
read-only; SSH keys, credential agents, and the rest of HOME are never
forwarded or mounted.
EOF
}

json_string() {
  jq -cn --arg value "$1" '$value'
}

parse_target() {
  network_mode=restricted
  assume_yes=false
  target=
  command=( )
  parsing_command=false

  while (($#)); do
    if "$parsing_command"; then
      command+=("$1")
      shift
      continue
    fi

    case "$1" in
      --network)
        (($# >= 2)) || die '--network needs restricted or open'
        network_mode="$2"
        shift 2
        ;;
      --yes)
        assume_yes=true
        shift
        ;;
      --)
        parsing_command=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$target" ]] || die "only one worktree can be selected (got $1)"
        target="$1"
        shift
        ;;
    esac
  done

  case "$network_mode" in
    restricted|open) ;;
    *) die "unknown network mode '$network_mode' (choose restricted or open)" ;;
  esac

  target="${target:-$PWD}"
  worktree=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) \
    || die "$target is not inside a Git worktree"

  primary_worktree=$(git -C "$worktree" worktree list --porcelain | awk '$1 == "worktree" { print $2; exit }')
  [[ "$worktree" != "$primary_worktree" ]] || die \
    "$worktree is the primary checkout; create/select a per-work-item worktree first"

  instance_id=$(printf '%s' "$worktree:$network_mode" | sha256sum | cut -c1-12)
  # Lima's per-instance Unix sockets live beneath its state directory. Keep
  # the readable part short enough for macOS's 104-byte socket-path limit;
  # the hash still makes the full instance identity collision-resistant.
  worktree_label=$(basename "$worktree" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-*//; s/-*$//' | cut -c1-16)
  worktree_label="${worktree_label:-worktree}"
  instance="coding-sandbox-$worktree_label-$instance_id"
}

check_host() {
  [[ "$(uname -s)" == Darwin ]] || die 'this first implementation supports macOS only'
  [[ "$(uname -m)" == arm64 ]] || die 'this first implementation requires Apple Silicon'
  command -v limactl >/dev/null || die 'Lima is not installed; apply the Darwin configuration, then run sandbox doctor again'
}

doctor() {
  local failures=0

  printf 'Coding sandbox doctor\n\n'
  if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]; then
    printf '  PASS  Apple Silicon macOS: %s %s\n' "$(sw_vers -productVersion)" "$(uname -m)"
  else
    printf '  FAIL  Requires Apple Silicon macOS (found %s %s)\n' "$(uname -s)" "$(uname -m)"
    failures=1
  fi

  if command -v limactl >/dev/null; then
    printf '  PASS  Lima: %s\n' "$(limactl --version)"
  else
    printf '  FAIL  Lima is not on PATH. Apply the Darwin configuration that installs it.\n'
    failures=1
  fi

  if [[ -r /dev/null && -w "$HOME" ]]; then
    printf '  PASS  Home directory is usable for Lima state.\n'
  else
    printf '  FAIL  Home directory is not usable for Lima state.\n'
    failures=1
  fi

  printf '\n'
  if ((failures)); then
    cat <<'EOF'
Not ready. Fix the failed checks, then run `sandbox doctor` again.
EOF
    return 1
  fi

  cat <<'EOF'
Ready. Next safe gate: `sandbox plan /path/to/worktree`.
EOF
}

list_instances() {
  check_host
  local instances
  instances=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk '$1 ~ /^coding-sandbox-/')

  if [[ -z "$instances" ]]; then
    note 'no sandbox VMs exist'
    return
  fi

  printf 'Sandbox instances\n\n'
  printf '%-56s %s\n' INSTANCE STATUS
  printf '%s\n' "$instances"
  cat <<'EOF'

Use `sandbox destroy [WORKTREE]` while the worktree still exists, or
`sandbox delete INSTANCE` to remove a listed orphan. Both ask for confirmation.
EOF
}

show_plan() {
  cat <<EOF
Coding sandbox plan

  Instance:     $instance
  VM:           Ubuntu aarch64 under Apple Virtualization (VZ)
  Worktree:     $worktree
  Guest mount:  /workspace (read-write)
  Profile mount: fixed store-built profile (read-only)
  Other paths:  none
  SSH agent:    not forwarded
  Network:      $network_mode
EOF

  if [[ "$network_mode" == restricted ]]; then
    printf '%s\n' '  Egress:       default-drop; allowlisted HTTPS proxy only'
    printf '%s\n' '  Allowlist:    local model endpoints, Nix caches, Determinate Nix, GitHub'
  else
    printf '%s\n' '  Egress:       WIDE OPEN — no guest firewall or proxy is installed'
  fi

  cat <<'EOF'

No host credentials, SSH agent, or directories outside this worktree are
available in the VM.
EOF
}

append_common_template() {
  {
    cat <<'YAML'
minimumLimaVersion: 2.0.0
base:
- template:_images/ubuntu-lts

vmType: vz
arch: aarch64
mountType: virtiofs
propagateProxyEnv: false
containerd:
  system: false
  user: false
ssh:
  forwardAgent: false
  loadDotSSHPubKeys: false
vmOpts:
  vz:
    rosetta:
      enabled: true
      binfmt: true
user:
  # Do not derive an account name or home from macOS: the operator's account
  # name may be invalid on Linux, and the fixed Home Manager profile owns this
  # precise guest home.
  name: lima
  home: /home/lima
  shell: /bin/bash

# Lima appends an all-ports loopback forwarding rule unless a preceding rule
# matches. This deny rule covers every guest listener, including one bound to
# 127.0.0.1, so the VM never publishes a service on the host by default.
portForwards:
- guestIP: "0.0.0.0"
  guestIPMustBeZero: false
  guestPortRange: [1, 65535]
  proto: any
  ignore: true

mounts:
YAML
    printf '%s\n' '  # The selected worktree is the only mutable host path.'
    printf '%s\n' "- location: $(json_string "$worktree")"
    printf '%s\n' '  mountPoint: /workspace' '  writable: true'
    printf '%s\n' '  # Fixed, store-built guest profile; read-only and not a host secret.'
    printf '%s\n' "- location: $(json_string "$SANDBOX_GUEST_PROFILE")"
    printf '%s\n' '  mountPoint: /mnt/sandbox-profile' '  writable: false'
  } >>"$template"
}

append_restricted_provision() {
  # shellcheck disable=SC2129 # A quoted here-document makes the guest script literal.
  cat >>"$template" <<'YAML'
provision:
- mode: system
  script: |
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git jq nftables squid

    # Nix and Home Manager are realized in the guest, never cross-built on
    # the Mac. This is intentionally before the firewall is installed: the
    # bootstrap has no access to /workspace code and no forwarded credentials.
    if ! test -x /nix/var/nix/profiles/default/bin/nix; then
      curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix \
        | sh -s -- install --no-confirm
    fi

    # Squid must resolve names itself. Let it use Lima's NAT resolver, derived
    # from the guest's DHCP default route, so the resolver process itself need
    # not get an egress exception. Direct guest DNS remains default-drop.
    dns_resolver="$(ip route show default | awk '/default/ { print $3; exit }')"
    test -n "$dns_resolver"

    # Own squid.conf rather than an include in Ubuntu's stock policy: an
    # earlier stock `http_access allow localhost` would otherwise let every
    # guest process use this loopback proxy before our allowlist is reached.
    cat >/etc/squid/squid.conf <<SQUID
    dns_nameservers $dns_resolver
    http_port 127.0.0.1:3128
    acl allowed_domains dstdomain llm.amos.ipreston.net llm-terra.amos.ipreston.net cache.nixos.org nix-community.cachix.org install.determinate.systems github.com api.github.com codeload.github.com
    http_access allow allowed_domains
    http_access deny all
    cache deny all
    forwarded_for delete
    via off
    SQUID
    systemctl restart squid

    # The user shell below carries lower-case proxy variables, but substituter
    # fetches run in Determinate's systemd-managed nix-daemon. Give that unit
    # the same loopback-only proxy explicitly; Nix has no http-proxy nix.conf
    # setting. Squid is already live, while the firewall is not yet enabled.
    install -d /etc/systemd/system/nix-daemon.service.d
    cat >/etc/systemd/system/nix-daemon.service.d/coding-sandbox-proxy.conf <<'PROXY'
    [Service]
    Environment="http_proxy=http://127.0.0.1:3128"
    Environment="https_proxy=http://127.0.0.1:3128"
    Environment="HTTP_PROXY=http://127.0.0.1:3128"
    Environment="HTTPS_PROXY=http://127.0.0.1:3128"
    Environment="ALL_PROXY=http://127.0.0.1:3128"
    PROXY
    systemctl daemon-reload
    systemctl restart nix-daemon.service

    cat >/etc/profile.d/coding-sandbox-proxy.sh <<'PROXY'
    export HTTP_PROXY=http://127.0.0.1:3128
    export HTTPS_PROXY=http://127.0.0.1:3128
    export ALL_PROXY=http://127.0.0.1:3128
    export NO_PROXY=127.0.0.1,localhost
    PROXY
    cat >/etc/nftables.conf <<'NFT'
    flush ruleset
    table inet coding_sandbox {
      chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo" accept
        ct state established,related accept
        meta skuid "proxy" accept
      }
    }
    NFT
    systemctl enable --now nftables
- mode: user
  script: |
    #!/bin/bash
    set -euxo pipefail
    marker="$HOME/.local/state/coding-sandbox/profile-ready"
    if test -e "$marker"; then
      exit 0
    fi
    mkdir -p "$HOME/.local/share/coding-sandbox/profile" "$(dirname "$marker")"
    cp -a /mnt/sandbox-profile/. "$HOME/.local/share/coding-sandbox/profile/"
    # The source is a read-only Nix-store mount. Nix writes the initial lock
    # file beside the guest's private copy, never into that source.
    chmod -R u+w "$HOME/.local/share/coding-sandbox/profile"
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    export http_proxy=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128
    export HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 ALL_PROXY=http://127.0.0.1:3128
    nix run github:nix-community/home-manager/release-26.05 -- switch --flake "$HOME/.local/share/coding-sandbox/profile#lima"
    touch "$marker"
YAML
}

append_open_provision() {
  cat >>"$template" <<'YAML'
provision:
- mode: system
  script: |
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git jq
    if ! test -x /nix/var/nix/profiles/default/bin/nix; then
      curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix \
        | sh -s -- install --no-confirm
    fi
- mode: user
  script: |
    #!/bin/bash
    set -euxo pipefail
    marker="$HOME/.local/state/coding-sandbox/profile-ready"
    if test -e "$marker"; then
      exit 0
    fi
    mkdir -p "$HOME/.local/share/coding-sandbox/profile" "$(dirname "$marker")"
    cp -a /mnt/sandbox-profile/. "$HOME/.local/share/coding-sandbox/profile/"
    # The source is a read-only Nix-store mount. Nix writes the initial lock
    # file beside the guest's private copy, never into that source.
    chmod -R u+w "$HOME/.local/share/coding-sandbox/profile"
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    nix run github:nix-community/home-manager/release-26.05 -- switch --flake "$HOME/.local/share/coding-sandbox/profile#lima"
    touch "$marker"
YAML
}

make_template() {
  template=$(mktemp "${TMPDIR:-/tmp}/coding-sandbox.XXXXXX.yaml")
  append_common_template
  case "$network_mode" in
    restricted) append_restricted_provision ;;
    open) append_open_provision ;;
  esac
}

show_template() {
  make_template
  trap 'rm -f "$template"' EXIT
  cat "$template"
}

validate_template() {
  check_host
  make_template
  trap 'rm -f "$template"' EXIT
  limactl validate "$template"
  note 'template is valid. Next gate: inspect with sandbox plan, then sandbox start.'
}

confirm_start() {
  if "$assume_yes"; then
    return
  fi

  if [[ "$network_mode" == open ]]; then
    printf '\nType OPEN NETWORK to create this unrestricted VM: '
    read -r response
    [[ "$response" == 'OPEN NETWORK' ]] || die 'not started'
  else
    printf '\nType start to create this VM: '
    read -r response
    [[ "$response" == start ]] || die 'not started'
  fi
}

start() {
  check_host
  show_plan
  confirm_start
  make_template
  trap 'rm -f "$template"' EXIT

  note "creating or starting $instance; first boot downloads Ubuntu, Nix, and the fixed guest profile"
  limactl start --tty=false --name="$instance" "$template"
  note "ready. Run: sandbox shell --network $network_mode $worktree"
}

instance_action() {
  local action="$1"
  shift
  check_host
  if ! limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    die "$instance does not exist; run sandbox start first"
  fi
  case "$action" in
    shell)
      if [[ "$network_mode" == restricted ]]; then
        # /etc/profile.d supplies the loopback proxy for the normal interactive
        # path.  Use a login shell explicitly: Lima's raw SSH shell need not
        # source the system profile.
        limactl shell --workdir /workspace "$instance" bash --login
      else
        limactl shell --workdir /workspace "$instance"
      fi
      ;;
    exec)
      ((${#command[@]})) || die 'sandbox exec needs a command after --'
      if [[ "$network_mode" == restricted ]]; then
        # Unlike an interactive login shell, an arbitrary command never reads
        # /etc/profile.d.  Inject only the guest-local proxy endpoints, never
        # a host proxy or credential, so `sandbox exec -- curl …` has the
        # documented allowlisted path while direct connections stay default-drop.
        limactl shell --workdir /workspace "$instance" env \
          HTTP_PROXY=http://127.0.0.1:3128 \
          HTTPS_PROXY=http://127.0.0.1:3128 \
          ALL_PROXY=http://127.0.0.1:3128 \
          NO_PROXY=127.0.0.1,localhost \
          http_proxy=http://127.0.0.1:3128 \
          https_proxy=http://127.0.0.1:3128 \
          "${command[@]}"
      else
        limactl shell --workdir /workspace "$instance" "${command[@]}"
      fi
      ;;
    status)
      limactl list "$instance"
      ;;
    stop)
      limactl stop "$instance"
      note "stopped. State remains until sandbox destroy."
      ;;
  esac
}

destroy() {
  check_host
  if ! limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    die "$instance does not exist"
  fi
  show_plan
  if ! "$assume_yes"; then
    printf '\nType destroy to delete this VM and all guest state: '
    read -r response
    [[ "$response" == destroy ]] || die 'not destroyed'
  fi
  limactl delete --force "$instance"
  note 'deleted. The host worktree was not changed.'
}

delete_instance() {
  local instance_to_delete='' response=''
  assume_yes=false

  while (($#)); do
    case "$1" in
      --yes)
        assume_yes=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$instance_to_delete" ]] || die 'sandbox delete accepts one instance name'
        instance_to_delete="$1"
        shift
        ;;
    esac
  done

  [[ -n "$instance_to_delete" ]] || die 'sandbox delete needs an instance name from sandbox list'
  [[ "$instance_to_delete" == coding-sandbox-* ]] || die 'sandbox delete only accepts sandbox instances'
  check_host
  if ! limactl list --format '{{.Name}}' | grep -Fxq "$instance_to_delete"; then
    die "$instance_to_delete does not exist"
  fi

  if ! "$assume_yes"; then
    printf 'Type delete %s to delete this VM and all guest state: ' "$instance_to_delete"
    read -r response
    [[ "$response" == "delete $instance_to_delete" ]] || die 'not deleted'
  fi
  limactl delete --force "$instance_to_delete"
  note 'deleted. No host worktree was changed.'
}

main() {
  (($#)) || {
    usage
    exit 2
  }
  subcommand="$1"
  shift

  case "$subcommand" in
    doctor)
      (($# == 0)) || die 'sandbox doctor accepts no arguments'
      doctor
      ;;
    list)
      (($# == 0)) || die 'sandbox list accepts no arguments'
      list_instances
      ;;
    delete)
      delete_instance "$@"
      ;;
    plan|template|validate|start|shell|exec|status|stop|destroy)
      parse_target "$@"
      case "$subcommand" in
        plan) show_plan ;;
        template) show_template ;;
        validate) validate_template ;;
        start) start ;;
        shell|exec|status|stop) instance_action "$subcommand" ;;
        destroy) destroy ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $subcommand"
      ;;
  esac
}

main "$@"
