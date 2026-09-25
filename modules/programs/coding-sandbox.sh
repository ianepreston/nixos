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
  sandbox cache status [--network public|restricted|open] [PROJECT]
  sandbox cache purge [--network public|restricted|open] [--yes] [PROJECT]
  sandbox plan [--network public|restricted|open] [PROJECT]
  sandbox template [--network public|restricted|open] [PROJECT]
  sandbox validate [--network public|restricted|open] [PROJECT]
  sandbox start [--network public|restricted|open] [--yes] [PROJECT]
  sandbox shell [--network public|restricted|open] [PROJECT]
  sandbox exec [--network public|restricted|open] [PROJECT] -- COMMAND [ARG...]
  sandbox status [--network public|restricted|open] [PROJECT]
  sandbox stop [--network public|restricted|open] [PROJECT]
  sandbox destroy [--network public|restricted|open] [--yes] [PROJECT]
  sandbox delete [--yes] INSTANCE

The default project is the current directory. The launcher searches upward for
its visible .sandbox.toml project specification.

Network modes:
  public      Default. Public internet is available, but an IP-layer policy
              denies LAN, tailnet, host-side, and other protected destinations
              unless .sandbox.toml grants an exact domain or internal CIDR.
  restricted  Hardened mode. Only exact configured public domains and explicit
              internal grants are reachable through a local proxy.
  open        No guest egress firewall or proxy. It removes the lateral
              boundary too; use only for deliberate troubleshooting.

Only paths declared in .sandbox.toml are mounted. Git repository paths are
checked out into launcher-owned temporary worktrees; direct paths are mounted
read-only unless their declaration explicitly requests read-write. The fixed,
store-built guest profile and the project specification are separately mounted
read-only. [profile].modules and [[startup]] sources must be files under one of
those declared mounts; they are activated and run as the unprivileged `agent`
account. The Lima transport account retains passwordless sudo only to bootstrap
the guest and switch to that account. SSH keys, credential agents, and the
rest of HOME are never forwarded or mounted.

The default storage.nix_store = "instance" keeps /nix only for the lifetime of
one VM. storage.nix_store = "persistent" keeps a separate 50 GiB Lima disk
for this project and network mode; inspect it with `sandbox cache status` and
delete it deliberately with `sandbox cache purge` after destroying the VM.
EOF
}

json_string() {
  jq -cn --arg value "$1" '$value'
}

parse_target() {
  network_mode_override=''
  assume_yes=false
  target=
  command=()
  parsing_command=false

  while (($#)); do
    if "$parsing_command"; then
      command+=("$1")
      shift
      continue
    fi

    case "$1" in
      --network)
        (($# >= 2)) || die '--network needs public, restricted, or open'
        network_mode_override="$2"
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
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$target" ]] || die "only one project can be selected (got $1)"
        target="$1"
        shift
        ;;
    esac
  done

  case "$network_mode_override" in
    '' | public | restricted | open) ;;
    *) die "unknown network mode '$network_mode_override' (choose public, restricted, or open)" ;;
  esac

  target="${target:-$PWD}"
  project=$(cd "$target" && pwd -P) || die "cannot access project $target"
  load_policy
  project=$(jq -r '.config_root' <<<"$policy_json")
  if [[ $(jq -r '.config_path == null' <<<"$policy_json") == true ]]; then
    # Compatibility for projects without a spec: retain the original safe
    # secondary-worktree behaviour until they add an explicit mount table.
    worktree=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) ||
      die "$project has no .sandbox.toml; select a Git worktree or add a project specification"
    primary_worktree=$(git -C "$worktree" worktree list --porcelain | awk '$1 == "worktree" { print $2; exit }')
    [[ "$worktree" != "$primary_worktree" ]] || die \
      "$worktree is the primary checkout; add .sandbox.toml with [[mounts]] to use it directly"
    policy_json=$(jq --arg source "$worktree" \
      '.mounts = [{ source: $source, source_path: $source, mount_point: "/workspace", access: "rw", access_source: "legacy", kind: "path", branch: null }]' \
      <<<"$policy_json")
  fi
  # A visible policy may deliberately declare no host mounts.  In that case
  # the agent starts in its private guest home; the read-only policy copy is
  # still available at /sandbox-spec/.sandbox.toml.  Legacy projects without
  # a spec retain the compatibility worktree synthesized above.
  guest_workdir=/home/agent
  if jq -e '.mounts | any(.mount_point == "/workspace")' <<<"$policy_json" >/dev/null; then
    guest_workdir=/workspace
  fi
  # Lima performs --workdir before sudo switches from its transport account to
  # agent.  agent's private home is deliberately 0700, so use lima's home for
  # that handoff and change directory only after the privilege drop.
  transport_workdir="$guest_workdir"
  if [[ "$guest_workdir" == /home/agent ]]; then
    transport_workdir=/home/lima
  fi
  instance_id=$(printf '%s' "$project:$network_mode" | sha256sum | cut -c1-12)
  # Lima's per-instance Unix sockets live beneath its state directory. Keep
  # the readable part short enough for macOS's 104-byte socket-path limit;
  # the hash still makes the full instance identity collision-resistant.
  project_label=$(basename "$project" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-*//; s/-*$//' | cut -c1-16)
  project_label="${project_label:-project}"
  instance="coding-sandbox-$project_label-$instance_id"
  nix_store_mode=$(jq -r '.storage.nix_store' <<<"$policy_json")
  # Lima labels ext4 volumes "lima-$name" and ext4 labels are at most 16
  # bytes. Keep the opaque disk name to 11 bytes while retaining 40 bits of
  # the per-project/per-network instance identity.
  nix_store_disk="s${instance_id:0:10}"
  policy_record="$HOME/.local/state/coding-sandbox/$instance.policy.json"
  temporary_root="${TMPDIR:-/tmp}"
  temporary_root="${temporary_root%/}"
  mount_root="$temporary_root/coding-sandbox-worktrees/$instance"
  spec_mount_root="$temporary_root/coding-sandbox-specs/$instance"
}

load_policy() {
  local -a args=("$project")
  if [[ -n "$network_mode_override" ]]; then
    args+=(--network "$network_mode_override")
  fi
  policy_json=$(python3 "$SANDBOX_POLICY_HELPER" "${args[@]}") ||
    die 'sandbox policy helper failed; see the error above'
  network_mode=$(jq -r '.mode' <<<"$policy_json")
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
Ready. Next safe gate: `sandbox plan /path/to/project`.
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

Use `sandbox destroy [PROJECT]` while the project still exists, or
`sandbox delete INSTANCE` to remove a listed orphan. Both ask for confirmation.
EOF
}

show_plan() {
  cat <<EOF
Coding sandbox plan

  Instance:     $instance
  VM:           Ubuntu aarch64 under Apple Virtualization (VZ)
  Project:      $project
  Spec:         $(jq -r '.config_path // "none (legacy secondary-worktree mode)"' <<<"$policy_json")
  Base profile: fixed store-built profile (read-only)
  Guest commands: unprivileged agent account (no sudo)
  Guest working directory: $guest_workdir
  SSH agent:    not forwarded
  Network:      $network_mode ($(jq -r '.mode_source' <<<"$policy_json"))
EOF

  show_callbacks

  case "$nix_store_mode" in
    instance)
      printf '%s\n' '  Nix store:    instance-local (warm across stop/start; deleted with the VM)'
      ;;
    persistent)
      printf '%s\n' "  Nix store:    persistent Lima disk $nix_store_disk (50 GiB sparse)"
      printf '%s\n' '                survives VM deletion; no cache is shared with another sandbox'
      ;;
  esac

  printf '\n  Declared mounts:\n'
  jq -r --arg mount_root "$mount_root" '
    .mounts | to_entries[] |
    if .value.kind == "git" then
      "    \(.value.source_path) (Git branch \(.value.branch)) -> \($mount_root)/mount-\(.key) -> \(.value.mount_point) [\(.value.access)]"
    else
      "    \(.value.source_path) (direct path) -> \(.value.mount_point) [\(.value.access)]"
    end
  ' <<<"$policy_json"
  if [[ -n $(jq -r '.config_path // empty' <<<"$policy_json") ]]; then
    printf '%s\n' '    project specification -> /sandbox-spec/.sandbox.toml [ro]'
  fi

  printf '\n  Selected profile: sha256:%s\n' "$(jq -r '.profile.digest | sub("sha256:"; "")' <<<"$policy_json")"
  if [[ $(jq '.profile.modules | length' <<<"$policy_json") -eq 0 ]]; then
    printf '%s\n' '    modules: none'
  else
    jq -r '.profile.modules[] | "    module: \(.guest_path) <- \(.source) [\(.mount_access), \(.digest)]"' \
      <<<"$policy_json"
  fi

  if [[ $(jq '.environment | length' <<<"$policy_json") -eq 0 ]]; then
    printf '%s\n' '  Guest environment: none declared'
  else
    printf '%s\n' '  Guest environment (literal values, agent only):'
    jq -r '.environment | to_entries[] | "    \(.key)=\(.value | @json)"' <<<"$policy_json"
  fi
  if [[ $(jq '.startup | length' <<<"$policy_json") -eq 0 ]]; then
    printf '%s\n' '    startup: none'
  else
    jq -r '.startup[] | "    startup: \(.name): \(.guest_path) <- \(.source) args=\(.args | @json) [\(.mount_access), \(.digest)]"' \
      <<<"$policy_json"
  fi

  case "$network_mode" in
    public)
      printf '%s\n' '  Public internet: allowed directly'
      printf '%s\n' '  Lateral boundary: IP-layer deny with only the grants below'
      ;;
    restricted)
      printf '%s\n' '  Public internet: exact-domain allowlist through a local proxy only'
      printf '%s\n' '  Lateral boundary: IP-layer deny with only the grants below'
      ;;
    open)
      printf '%s\n' '  Egress:       WIDE OPEN — no guest firewall or proxy is installed'
      printf '%s\n' '  Lateral boundary: DISABLED; configured grants do not constrain this mode'
      ;;
  esac

  if [[ "$network_mode" != open ]]; then
    cat <<'EOF'

  Protected destinations denied unless explicitly granted:
    IPv4: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
          100.64.0.0/10 (CGNAT/Tailscale), 169.254.0.0/16
    IPv6: fc00::/7 (unique local), fe80::/10 (link-local)

  Internal grants:
EOF
    if [[ $(jq '.internal_domains | length' <<<"$policy_json") -eq 0 ]]; then
      printf '%s\n' '    domains: none'
    else
      jq -r '.internal_domains[] | "    domain: \(.name) -> \(.addresses | join(", "))"' <<<"$policy_json"
    fi
    if [[ $(jq '.internal_cidrs | length' <<<"$policy_json") -eq 0 ]]; then
      printf '%s\n' '    CIDRs: none'
    else
      jq -r '.internal_cidrs[] | "    CIDR: \(.)"' <<<"$policy_json"
    fi
    cat <<'EOF'

  Lima infrastructure: DHCP only; DNS only to the discovered NAT resolver on
  TCP/UDP port 53. No general gateway or private-subnet exception exists.
EOF
  fi

  if [[ "$network_mode" == restricted ]]; then
    printf '\n  Restricted public domains:\n'
    jq -r '.strict_domains[] | "    \(.name) -> \(.addresses | join(", "))"' <<<"$policy_json"
  fi

  cat <<'EOF'

No host credentials, SSH agent, or directories outside the declared mounts are
available in the VM. Git mount worktrees are retained under the temporary
directory after VM deletion so uncommitted guest work is never discarded.
EOF
}

show_callbacks() {
  if [[ $(jq '.callbacks.port_ranges | length' <<<"$policy_json") -eq 0 ]]; then
    printf '%s\n' '  Browser callbacks: none (all guest ports remain denied on the host)'
    return
  fi

  cat <<'EOF'
  Browser callbacks: dynamic TCP forwarding on host loopback only
EOF
  jq -r '.callbacks.port_ranges[] | "    127.0.0.1:[\(.[0]), \(.[1])] -> guest localhost:[\(.[0]), \(.[1])]"' \
    <<<"$policy_json"
  cat <<'EOF'
    Lima creates a host listener only while the guest listens on a declared
    port. Declarations do not reserve host ports when this VM starts. If a
    host port is already in use when a guest listener appears, Lima cannot
    forward that listener; stop the conflicting process or choose another
    declared OAuth callback port. No fallback port is selected here.

EOF
}

prepare_git_worktree() {
  local index="$1" source="$2" branch="$3" destination actual_root actual_branch
  destination="$mount_root/mount-$index"

  if [[ -e "$destination" ]]; then
    actual_root=$(git -C "$destination" rev-parse --show-toplevel 2>/dev/null) ||
      die "temporary mount $destination exists but is not a Git worktree; remove it manually"
    [[ "$actual_root" == "$destination" ]] || die \
      "temporary mount $destination is not a worktree root; remove it manually"
    actual_branch=$(git -C "$destination" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [[ "$actual_branch" == "$branch" ]] || die \
      "temporary mount $destination has branch ${actual_branch:-detached}, expected $branch"
  else
    mkdir -p "$mount_root"
    if git -C "$source" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$source" worktree add "$destination" "$branch" >&2
    else
      git -C "$source" worktree add -b "$branch" "$destination" HEAD >&2
    fi
  fi
  printf '%s\n' "$destination"
}

prepare_declared_mounts() {
  local count index source kind branch location mount_point access
  mount_locations=()
  mount_points=()
  mount_accesses=()
  count=$(jq '.mounts | length' <<<"$policy_json")
  for ((index = 0; index < count; index++)); do
    source=$(jq -r ".mounts[$index].source" <<<"$policy_json")
    kind=$(jq -r ".mounts[$index].kind" <<<"$policy_json")
    mount_point=$(jq -r ".mounts[$index].mount_point" <<<"$policy_json")
    access=$(jq -r ".mounts[$index].access" <<<"$policy_json")
    if [[ "$kind" == git ]]; then
      branch=$(jq -r ".mounts[$index].branch" <<<"$policy_json")
      location=$(prepare_git_worktree "$index" "$source" "$branch")
    else
      location="$source"
    fi
    mount_locations+=("$location")
    mount_points+=("$mount_point")
    mount_accesses+=("$access")
  done
}

prepare_spec_mount() {
  local config_path temporary
  config_path=$(jq -r '.config_path // empty' <<<"$policy_json")
  [[ -n "$config_path" ]] || return
  mkdir -p "$spec_mount_root"
  temporary=$(mktemp "$spec_mount_root/.sandbox.toml.XXXXXX")
  cp "$config_path" "$temporary"
  chmod 444 "$temporary"
  mv "$temporary" "$spec_mount_root/.sandbox.toml"
}

append_declared_mounts() {
  local index writable
  prepare_declared_mounts
  prepare_spec_mount
  for ((index = 0; index < ${#mount_locations[@]}; index++)); do
    [[ "${mount_accesses[$index]}" == rw ]] && writable=true || writable=false
    printf '%s\n' "- location: $(json_string "${mount_locations[$index]}")"
    printf '%s\n' "  mountPoint: ${mount_points[$index]}" "  writable: $writable"
  done
  if [[ -n $(jq -r '.config_path // empty' <<<"$policy_json") ]]; then
    printf '%s\n' '  # Visible project specification, independently read-only.'
    printf '%s\n' "- location: $(json_string "$spec_mount_root")"
    printf '%s\n' '  mountPoint: /sandbox-spec' '  writable: false'
  fi
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

# Lima evaluates port-forwarding rules in order. Explicit callback rules are
# deliberately dynamic: Lima creates their host listener only after the guest
# opens the matching port, and removes it again when that listener closes.
portForwards:
YAML
    jq -r '.callbacks.port_ranges[] | "- guestPortRange: [\(.[0]), \(.[1])]\n  hostIP: \"127.0.0.1\"\n  hostPortRange: [\(.[0]), \(.[1])]\n  proto: tcp"' \
      <<<"$policy_json"
    cat <<'YAML'
# Lima appends an all-ports loopback forwarding rule unless a preceding rule
# matches. This deny rule covers every guest listener, including one bound to
# 127.0.0.1, so the VM never publishes a service on the host by default.
- guestIP: "0.0.0.0"
  guestIPMustBeZero: false
  guestPortRange: [1, 65535]
  proto: any
  ignore: true

YAML
    if [[ "$nix_store_mode" == persistent ]]; then
      printf '%s\n' 'additionalDisks:'
      printf '%s\n' "- name: $(json_string "$nix_store_disk")" '  # Format only when the new disk has no Lima label.'
      printf '%s\n' '  format: true' '  fsType: ext4'
    fi
    printf '%s\n' 'mounts:'
    append_declared_mounts
    printf '%s\n' '  # Fixed, store-built guest profile; read-only and not a host secret.'
    printf '%s\n' "- location: $(json_string "$SANDBOX_GUEST_PROFILE")"
    printf '%s\n' '  mountPoint: /mnt/sandbox-profile' '  writable: false'
  } >>"$template"
}

append_persistent_nix_store_provision() {
  [[ "$nix_store_mode" == persistent ]] || return 0
  cat >>"$template" <<YAML

    # Lima owns this separate ext4 volume. Keep only Nix's content-addressed
    # store, database, and profile roots there; the guest OS, agent home, and
    # all project state remain on the disposable VM disk.
    persistent_nix_root=/mnt/lima-$nix_store_disk
    test -d "\$persistent_nix_root"
    systemctl stop nix-daemon.service nix-daemon.socket 2>/dev/null || true
    if test -e "\$persistent_nix_root/.coding-sandbox-nix-cache-v1"; then
      test -d "\$persistent_nix_root/store"
      test -d "\$persistent_nix_root/db"
      test -d "\$persistent_nix_root/profiles"
      test -d "\$persistent_nix_root/gcroots"
    else
      install -d -m 0755 \\
        "\$persistent_nix_root/store" \\
        "\$persistent_nix_root/db" \\
        "\$persistent_nix_root/profiles" \\
        "\$persistent_nix_root/gcroots"
      cp -a /nix/store/. "\$persistent_nix_root/store/"
      cp -a /nix/var/nix/db/. "\$persistent_nix_root/db/"
      cp -a /nix/var/nix/profiles/. "\$persistent_nix_root/profiles/"
      cp -a /nix/var/nix/gcroots/. "\$persistent_nix_root/gcroots/"
      touch "\$persistent_nix_root/.coding-sandbox-nix-cache-v1"
    fi
    mountpoint -q /nix/store || mount --bind "\$persistent_nix_root/store" /nix/store
    mountpoint -q /nix/var/nix/db || mount --bind "\$persistent_nix_root/db" /nix/var/nix/db
    mountpoint -q /nix/var/nix/profiles || mount --bind "\$persistent_nix_root/profiles" /nix/var/nix/profiles
    mountpoint -q /nix/var/nix/gcroots || mount --bind "\$persistent_nix_root/gcroots" /nix/var/nix/gcroots
    systemctl start nix-daemon.service
YAML
}

policy_nft_set() {
  local field="$1"
  jq -r --arg field "$field" '
    .[$field] | if length == 0 then "" else "elements = { " + join(", ") + " }" end
  ' <<<"$policy_json"
}

append_profile_provision() {
  local use_proxy="$1" profile_state environment_exports
  profile_state=$(jq -c '{ profile, startup, environment }' <<<"$policy_json")
  environment_exports=$(jq -r '.environment | to_entries[] | "export \(.key)=\(.value | @sh)"' <<<"$policy_json")
  {
    cat <<'YAML'
- mode: system
  script: |
    #!/bin/bash
    set -euxo pipefail
    agent_home=/home/agent
    marker="$agent_home/.local/state/coding-sandbox/profile-ready"
    if test -e "$marker"; then
      exit 0
    fi
    # These are guest-only developer tools. Install them through their
    # upstream bootstrap scripts rather than putting a host package closure in
    # the VM boundary. Restricted mode intentionally does not fetch arbitrary
    # installer domains after its exact-domain egress policy becomes active.
    if [[ ! -r /etc/coding-sandbox/policy.json || $(jq -r .mode /etc/coding-sandbox/policy.json) != restricted ]]; then
      if ! command -v databricks >/dev/null; then
        curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
      fi
      if ! command -v uv >/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
      fi
      databricks -v
      uv --version
    fi
    state_dir="$agent_home/.local/state/coding-sandbox"
    install -d -m 0700 -o agent -g agent \
      "$agent_home/.local/share/coding-sandbox/profile" \
      "$state_dir" \
      "$agent_home/.local/state/nix/profiles" \
      "$agent_home/.config/coding-sandbox"
    cat >"$agent_home/.config/coding-sandbox/environment.sh" <<'ENVIRONMENT'
YAML
    printf '%s\n' "$environment_exports" | sed 's/^/    /'
    cat <<'YAML'
    # uv installs tool entrypoints here. Keep them available in every agent
    # shell and startup command without requiring `uv tool update-shell`.
    export PATH="$HOME/.local/bin:$PATH"
    ENVIRONMENT
    cat >"$agent_home/.bash_profile" <<'BASH_PROFILE'
    if [[ -r "$HOME/.bashrc" ]]; then
      source "$HOME/.bashrc"
    fi
    source "$HOME/.config/coding-sandbox/environment.sh"
    BASH_PROFILE
    cp -a /mnt/sandbox-profile/. "$agent_home/.local/share/coding-sandbox/profile/"
    # The source is a read-only Nix-store mount. Nix writes the initial lock
    # file beside the guest's private copy, never into that source.
    chown -R agent:agent "$agent_home/.local" "$agent_home/.config" "$agent_home/.bash_profile"
    chmod 0600 "$agent_home/.config/coding-sandbox/environment.sh" "$agent_home/.bash_profile"
    chmod -R u+w "$agent_home/.local/share/coding-sandbox/profile"
YAML
    cat <<YAML
    cat >"\$state_dir/profile.json" <<'PROFILE_STATE'
    $profile_state
    PROFILE_STATE
    cat >"\$agent_home/.local/share/coding-sandbox/profile/sandbox-profile.nix" <<'PROFILE_MODULE'
    { ... }: {
      imports = [
YAML
    jq -r '.profile.modules[] | "        (builtins.toPath \(.guest_path | @json))"' <<<"$policy_json"
    cat <<'YAML'
      ];
    }
    PROFILE_MODULE
    chown agent:agent "$state_dir/profile.json" \
      "$agent_home/.local/share/coding-sandbox/profile/sandbox-profile.nix"

    verify_source() {
      local guest_path="$1" expected_digest="$2" actual_digest
      actual_digest="sha256:$(sha256sum "$guest_path" | awk '{ print $1 }')"
      test "$actual_digest" = "$expected_digest"
    }

    module_count=$(jq '.profile.modules | length' "$state_dir/profile.json")
    for ((module_index = 0; module_index < module_count; module_index++)); do
      verify_source \
        "$(jq -r ".profile.modules[$module_index].guest_path" "$state_dir/profile.json")" \
        "$(jq -r ".profile.modules[$module_index].digest" "$state_dir/profile.json")"
    done
YAML
    if [[ "$use_proxy" == true ]]; then
      cat <<'YAML'
    proxy_environment=(
      http_proxy=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128
      HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 ALL_PROXY=http://127.0.0.1:3128
    )
YAML
    else
      cat <<'YAML'
    proxy_environment=()
YAML
    fi
    cat <<'YAML'
    runuser -u agent -- env HOME="$agent_home" "${proxy_environment[@]}" bash -lc '
      source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      nix run github:nix-community/home-manager/release-26.05 -- switch --impure --flake "$HOME/.local/share/coding-sandbox/profile#agent"
    ' >"$state_dir/home-manager.log" 2>&1
    chown agent:agent "$state_dir/home-manager.log"

    startup_count=$(jq '.startup | length' "$state_dir/profile.json")
    agent_profile_path="$agent_home/.nix-profile/bin:$PATH"
    for ((startup_index = 0; startup_index < startup_count; startup_index++)); do
      startup_name=$(jq -r ".startup[$startup_index].name" "$state_dir/profile.json")
      startup_path=$(jq -r ".startup[$startup_index].guest_path" "$state_dir/profile.json")
      startup_digest=$(jq -r ".startup[$startup_index].digest" "$state_dir/profile.json")
      startup_log="$state_dir/startup-$startup_name.log"
      verify_source "$startup_path" "$startup_digest"
      mapfile -d '' -t startup_args < <(jq -j ".startup[$startup_index].args[] | ., \"\\u0000\"" "$state_dir/profile.json")
      if ! runuser -u agent -- env HOME="$agent_home" PATH="$agent_profile_path" "${proxy_environment[@]}" \
        bash -c 'source "$HOME/.config/coding-sandbox/environment.sh"; exec bash "$@"' \
        sandbox-startup "$startup_path" "${startup_args[@]}" >"$startup_log" 2>&1; then
        chown agent:agent "$startup_log"
        printf '%s\n' "$startup_name" >"$state_dir/failed-startup"
        chown agent:agent "$state_dir/failed-startup"
        exit 1
      fi
      chown agent:agent "$startup_log"
    done
    touch "$marker"
    chown agent:agent "$marker"
YAML
  } >>"$template"
}

append_protected_provision() {
  local mode="$1" packages strict_domains strict_hosts granted_v4 granted_v6 strict_v4 strict_v6 use_proxy=false
  granted_v4=$(policy_nft_set grants_v4)
  granted_v6=$(policy_nft_set grants_v6)
  strict_v4=$(policy_nft_set strict_v4)
  strict_v6=$(policy_nft_set strict_v6)
  packages='ca-certificates curl git jq nftables unzip'
  if [[ "$mode" == restricted ]]; then
    packages+=' squid'
    strict_domains=$(jq -r '.strict_domains | map(.name) | join(" ")' <<<"$policy_json")
    # Squid must use the exact addresses reviewed into strict_v4/strict_v6,
    # rather than independently selecting another address from a CDN-backed
    # name.  Otherwise nftables correctly drops that unreviewed connection.
    strict_hosts=$(jq -r '.strict_domains[] | .name as $name | .addresses[] | "\(.) \($name)"' <<<"$policy_json" | sed 's/^/    /')
    use_proxy=true
  else
    strict_domains=''
    strict_hosts=''
  fi

  cat >>"$template" <<YAML
provision:
- mode: system
  script: |
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y $packages

    # Lima is the privileged transport/bootstrap account. Untrusted commands
    # run only as agent, which has no sudo or administrative group membership.
    if ! id -u agent >/dev/null 2>&1; then
      useradd --create-home --user-group --shell /bin/bash agent
    fi
    gpasswd -d agent sudo 2>/dev/null || true
    ! id -nG agent | tr ' ' '\n' | grep -Fxq sudo
    install -d -m 0700 -o lima -g lima /home/lima
    install -d -m 0700 -o agent -g agent /home/agent

    # Bootstrap is trusted launcher code; no worktree command has run and no
    # host credential is mounted. The firewall below is active before the
    # guest profile or any sandbox command is realized.
    if ! test -x /nix/var/nix/profiles/default/bin/nix; then
      curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix \\
        | sh -s -- install --no-confirm
    fi

YAML
  append_persistent_nix_store_provision
  cat >>"$template" <<YAML

    # Lima NAT normally supplies this IPv4 default gateway as both router and
    # resolver. Refuse an unfamiliar topology rather than allowing a private
    # subnet or gateway generally.
    gateway="\$(ip -4 route show default | awk '/default/ { print \$3; exit }')"
    test -n "\$gateway"
    install -d /etc/coding-sandbox
    cat >/etc/coding-sandbox/policy.json <<'POLICY'
    $policy_json
    POLICY
YAML

  if [[ "$mode" == restricted ]]; then
    cat >>"$template" <<YAML
    # Squid checks exact requested names; nftables below additionally confines
    # its connections to this inspectable, plan-time address set.  Squid's
    # hosts_file prevents a separate CDN DNS answer from escaping that set.
    cat >/etc/squid/coding-sandbox.hosts <<HOSTS
    $strict_hosts
    HOSTS
    cat >/etc/squid/squid.conf <<SQUID
    dns_nameservers \$gateway
    hosts_file /etc/squid/coding-sandbox.hosts
    http_port 127.0.0.1:3128
    acl allowed_domains dstdomain $strict_domains
    http_access allow allowed_domains
    http_access deny all
    cache deny all
    forwarded_for delete
    via off
    SQUID
    squid -k parse
    systemctl restart squid

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
YAML
  fi

  cat >>"$template" <<YAML
    cat >/etc/nftables.conf <<NFT
    flush ruleset
    table inet coding_sandbox {
      set protected_v4 {
        type ipv4_addr
        flags interval
        elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 }
      }
      set protected_v6 {
        type ipv6_addr
        flags interval
        elements = { fc00::/7, fe80::/10 }
      }
      set granted_v4 {
        type ipv4_addr
        flags interval
        $granted_v4
      }
      set granted_v6 {
        type ipv6_addr
        flags interval
        $granted_v6
      }
      set strict_v4 {
        type ipv4_addr
        flags interval
        $strict_v4
      }
      set strict_v6 {
        type ipv6_addr
        flags interval
        $strict_v6
      }
      chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo" accept
        # Replies to a connection initiated by Lima (notably its SSH
        # transport) must remain possible after a VM restart.  This precedes
        # the protected-destination drop because the peer is on Lima's
        # private NAT subnet; it never authorizes a new guest connection.
        ct state established,related accept
        # Lima infrastructure only: DHCP and DNS to the one discovered NAT
        # gateway. It is not a general private-gateway exception.
        ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept
        ip daddr \$gateway udp dport 53 accept
        ip daddr \$gateway tcp dport 53 accept
        # Permit only IPv6 neighbour discovery / DHCPv6 control messages, then
        # deny all IPv6 multicast and link-local application traffic below.
        ip6 daddr ff02::/16 icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
        ip6 daddr ff02::1:2 udp sport 546 udp dport 547 accept
        ip daddr @granted_v4 accept
        ip6 daddr @granted_v6 accept
        ip daddr @protected_v4 drop
        ip6 daddr @protected_v6 drop
        ip daddr 224.0.0.0/4 drop
        ip daddr 255.255.255.255 drop
        ip6 daddr ff00::/8 drop
YAML
  if [[ "$mode" == restricted ]]; then
    cat >>"$template" <<'YAML'
        meta skuid "proxy" ip daddr @strict_v4 accept
        meta skuid "proxy" ip6 daddr @strict_v6 accept
        ct state established,related accept
YAML
  else
    cat >>"$template" <<'YAML'
        accept
YAML
  fi
  cat >>"$template" <<'YAML'
      }
    }
    NFT
    systemctl enable --now nftables
YAML
  append_profile_provision "$use_proxy"
}

append_public_provision() {
  append_protected_provision public
}

append_restricted_provision() {
  append_protected_provision restricted
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
    apt-get install -y ca-certificates curl git jq unzip
    if ! id -u agent >/dev/null 2>&1; then
      useradd --create-home --user-group --shell /bin/bash agent
    fi
    gpasswd -d agent sudo 2>/dev/null || true
    ! id -nG agent | tr ' ' '\n' | grep -Fxq sudo
    install -d -m 0700 -o lima -g lima /home/lima
    install -d -m 0700 -o agent -g agent /home/agent
    if ! test -x /nix/var/nix/profiles/default/bin/nix; then
      curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix \
        | sh -s -- install --no-confirm
    fi
YAML
  append_persistent_nix_store_provision
  append_profile_provision false
}

make_template() {
  template=$(mktemp "${TMPDIR:-/tmp}/coding-sandbox.XXXXXX.yaml")
  append_common_template
  case "$network_mode" in
    public) append_public_provision ;;
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
  show_callbacks
  note 'template is valid. Next gate: inspect with sandbox plan, then sandbox start.'
}

confirm_start() {
  local response='' confirmation
  case "$network_mode" in
    public)
      confirmation='START PUBLIC'
      cat <<'EOF'

Network mode: public
Public internet is allowed. LAN, tailnet, host-side, and other protected
destinations are blocked at the IP layer except for the grants listed above.
EOF
      ;;
    restricted)
      confirmation='START RESTRICTED'
      cat <<'EOF'

Network mode: restricted
Only the listed exact public domains and internal grants are reachable.
All other public and protected destinations are blocked.
EOF
      ;;
    open)
      confirmation='OPEN NETWORK'
      cat <<'EOF'

WARNING: Network mode: open
This VM may reach public internet, LAN, tailnet, host-side services, and other
internal targets reachable from the Mac. No lateral network boundary applies.
EOF
      ;;
  esac

  cat <<'EOF'

The selected Home Manager modules activate as the unprivileged agent account.
After activation, every selected startup script executes as that same account.
EOF

  "$assume_yes" && return
  printf 'Type %s to create this VM: ' "$confirmation"
  read -r response
  [[ "$response" == "$confirmation" ]] || die 'not started'
}

policy_matches_instance() {
  local recorded current_contract recorded_contract
  [[ -r "$policy_record" ]] || die \
    "existing $instance has no recorded policy; destroy it before using this network-policy version"
  recorded=$(jq -ce '.policy' "$policy_record") ||
    die "cannot read recorded policy for $instance; destroy it before continuing"
  # The strict bootstrap names are pinned into the VM at creation.  Public
  # CDN answers may legitimately rotate afterwards, so compare the policy
  # contract without those derived addresses and retain the recorded policy
  # for all actions and plan output against this existing VM.  Internal grants
  # remain in the compared contract and still require recreation on change.
  current_contract=$(jq -cS 'del(.strict_domains, .strict_v4, .strict_v6)' <<<"$policy_json")
  recorded_contract=$(jq -cS 'del(.strict_domains, .strict_v4, .strict_v6)' <<<"$recorded")
  [[ "$recorded_contract" == "$current_contract" ]] || die \
    "effective policy changed for $instance; inspect sandbox plan, then destroy and recreate the VM"
  policy_json="$recorded"
}

record_policy() {
  local record_dir temporary
  record_dir=$(dirname "$policy_record")
  mkdir -p "$record_dir"
  temporary=$(mktemp "$record_dir/.policy.XXXXXX")
  jq -cn --arg instance "$instance" --argjson policy "$policy_json" \
    '{ instance: $instance, policy: $policy }' >"$temporary"
  mv "$temporary" "$policy_record"
}

persistent_disk_exists() {
  limactl disk list 2>/dev/null | awk -v disk="$nix_store_disk" '$1 == disk { found = 1 } END { exit !found }'
}

ensure_persistent_disk() {
  [[ "$nix_store_mode" == persistent ]] || return 0
  if persistent_disk_exists; then
    return
  fi
  note "creating persistent 50 GiB Nix cache disk $nix_store_disk"
  limactl disk create --size 50GiB --format qcow2 --yes "$nix_store_disk"
}

cache_status() {
  check_host
  case "$nix_store_mode" in
    instance)
      if persistent_disk_exists; then
        printf '%s\n' "Nix cache: persistent disk $nix_store_disk retained from an earlier persistent setting."
        cat <<'EOF'

The current storage.nix_store setting is instance, but this project still has
an older persistent cache disk. It can be purged after the VM is destroyed.
EOF
      else
        cat <<'EOF'
Nix cache: instance-local

It remains warm while this VM is stopped, then is deleted with the VM. There
is no separately persistent Lima disk for this project.
EOF
      fi
      ;;
    persistent)
      if persistent_disk_exists; then
        limactl disk list | awk -v disk="$nix_store_disk" '$1 == disk { print "Nix cache: persistent " $0; found = 1 } END { exit !found }'
        printf '%s\n' "It is isolated to $instance and survives sandbox destroy."
      else
        printf '%s\n' "Nix cache: persistent mode selected; disk $nix_store_disk has not been created yet."
      fi
      ;;
  esac
}

cache_purge() {
  check_host
  if limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    die "destroy $instance before purging its persistent cache disk"
  fi
  if ! persistent_disk_exists; then
    if [[ "$nix_store_mode" == instance ]]; then
      die 'storage.nix_store is instance and no retained persistent cache disk exists'
    fi
    note "persistent cache disk $nix_store_disk does not exist"
    return
  fi
  if ! "$assume_yes"; then
    local response
    printf 'Type purge cache %s to delete this persistent Nix cache: ' "$nix_store_disk"
    read -r response
    [[ "$response" == "purge cache $nix_store_disk" ]] || die 'cache not purged'
  fi
  limactl disk delete "$nix_store_disk"
  note "deleted persistent Nix cache disk $nix_store_disk"
}

cache_command() {
  local action="${1:-}"
  case "$action" in
    status | purge)
      shift
      ;;
    *)
      die 'sandbox cache needs status or purge'
      ;;
  esac
  parse_target "$@"
  ((${#command[@]} == 0)) || die "sandbox cache $action does not accept a guest command"
  case "$action" in
    status) cache_status ;;
    purge) cache_purge ;;
  esac
}

start() {
  check_host
  if limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    policy_matches_instance
  fi
  show_plan
  confirm_start

  if limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    limactl start "$instance"
    note "ready. Run: sandbox shell --network $network_mode $project"
    return
  fi
  ensure_persistent_disk
  make_template
  trap 'rm -f "$template"' EXIT

  note "creating or starting $instance; first boot downloads Ubuntu, Nix, and the selected guest profile"
  limactl start --tty=false --name="$instance" "$template"
  record_policy
  note "ready. Run: sandbox shell --network $network_mode $project"
}

instance_action() {
  local action="$1"
  shift
  check_host
  if ! limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    die "$instance does not exist; run sandbox start first"
  fi
  policy_matches_instance
  case "$action" in
    shell)
      if [[ "$network_mode" == restricted ]]; then
        # /etc/profile.d supplies the loopback proxy for the normal interactive
        # path.  Use a login shell explicitly: Lima's raw SSH shell need not
        # source the system profile. Lima is only the transport account; the
        # interactive agent process has no administrative privilege.
        limactl shell --workdir "$transport_workdir" "$instance" sudo -H -u agent -- \
          bash -c "cd \"\$1\"; exec bash --login" sandbox-agent-shell "$guest_workdir"
      else
        limactl shell --workdir "$transport_workdir" "$instance" sudo -H -u agent -- \
          bash -c "cd \"\$1\"; exec bash --login" sandbox-agent-shell "$guest_workdir"
      fi
      ;;
    exec)
      ((${#command[@]})) || die 'sandbox exec needs a command after --'
      if [[ "$network_mode" == restricted ]]; then
        # Unlike an interactive login shell, an arbitrary command never reads
        # /etc/profile.d.  Inject only the guest-local proxy endpoints, never
        # a host proxy or credential, so `sandbox exec -- curl …` has the
        # documented allowlisted path while direct connections stay default-drop.
        # The command below is evaluated by the guest shell, not this launcher.
        # shellcheck disable=SC2016
        limactl shell --workdir "$transport_workdir" "$instance" sudo -H -u agent -- env \
          HTTP_PROXY=http://127.0.0.1:3128 \
          HTTPS_PROXY=http://127.0.0.1:3128 \
          ALL_PROXY=http://127.0.0.1:3128 \
          NO_PROXY=127.0.0.1,localhost \
          http_proxy=http://127.0.0.1:3128 \
          https_proxy=http://127.0.0.1:3128 \
          bash -c 'source "$HOME/.config/coding-sandbox/environment.sh"; cd "$1"; shift; exec "$@"' sandbox-agent-exec "$guest_workdir" "${command[@]}"
      else
        # The command below is evaluated by the guest shell, not this launcher.
        # shellcheck disable=SC2016
        limactl shell --workdir "$transport_workdir" "$instance" sudo -H -u agent -- \
          bash -c 'source "$HOME/.config/coding-sandbox/environment.sh"; cd "$1"; shift; exec "$@"' sandbox-agent-exec "$guest_workdir" "${command[@]}"
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
  local instance_nix_store_mode="$nix_store_mode" recorded_policy
  check_host
  if ! limactl list --format '{{.Name}}' | grep -Fxq "$instance"; then
    die "$instance does not exist"
  fi
  # Destruction must use the lifecycle captured when this VM was created.  A
  # user may have changed .sandbox.toml from persistent to instance while
  # deciding to tear it down; that must not orphan a cache disk which the
  # current policy can no longer address.
  if [[ -r "$policy_record" ]]; then
    recorded_policy=$(jq -cer '.policy' "$policy_record") ||
      die "cannot read recorded policy for $instance; use sandbox delete to remove this legacy VM"
    instance_nix_store_mode=$(jq -r '.storage.nix_store // "instance"' <<<"$recorded_policy")
  fi
  show_plan
  if ! "$assume_yes"; then
    printf '\nType destroy to delete this VM and all guest state: '
    read -r response
    [[ "$response" == destroy ]] || die 'not destroyed'
  fi
  if [[ "$instance_nix_store_mode" == persistent ]] && [[ $(limactl list --format '{{.Status}}' "$instance") == Running ]]; then
    # `limactl delete --force` terminates VZ immediately. Flush and stop a VM
    # with a persistent ext4 cache disk first so its Nix database and store do
    # not survive a torn write.
    note "flushing persistent Nix cache disk $nix_store_disk"
    limactl shell "$instance" sudo sync
    limactl stop "$instance"
    # The guest is already down and the disk is detached. `--force` only
    # removes Lima's stopped-instance state here, avoiding its redundant
    # second disk-unlock attempt.
    limactl delete --force "$instance"
  else
    limactl delete --force "$instance"
  fi
  rm -f "$policy_record"
  if [[ "$instance_nix_store_mode" == persistent ]]; then
    note "deleted VM. Persistent Nix cache disk $nix_store_disk was retained."
  else
    note 'deleted. Declared host paths and generated Git worktrees were retained.'
  fi
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
      -h | --help)
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
  note 'deleted. No declared host path was changed.'
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
    cache)
      cache_command "$@"
      ;;
    delete)
      delete_instance "$@"
      ;;
    plan | template | validate | start | shell | exec | status | stop | destroy)
      parse_target "$@"
      case "$subcommand" in
        plan)
          # For an existing VM, report the address set it actually enforces,
          # rather than a fresh CDN lookup that would only apply after
          # recreation.  A plan remains usable without Lima for a new project.
          if command -v limactl >/dev/null &&
            limactl list --format '{{.Name}}' 2>/dev/null | grep -Fxq "$instance"; then
            policy_matches_instance
          fi
          show_plan
          ;;
        template) show_template ;;
        validate) validate_template ;;
        start) start ;;
        shell | exec | status | stop) instance_action "$subcommand" ;;
        destroy) destroy ;;
      esac
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      die "unknown command: $subcommand"
      ;;
  esac
}

main "$@"
