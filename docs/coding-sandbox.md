# macOS coding sandboxes

The `work` Darwin host provides `sandbox`, a Lima launcher for a disposable
Ubuntu VM with an explicit, project-owned mount and profile specification. This
is the first macOS-only slice of the broader [coding-sandbox issue](https://github.com/ianepreston/nixos/issues/539).
NixOS support remains intentionally unimplemented.

## Install and define a project

Apply the `work` configuration to put `sandbox` on `PATH`:

```sh
task build_darwin:work
```

`sandbox` is a normal Home Manager package, rather than a per-repository
install. The visible `.sandbox.toml` at a project's root declares every host
path exposed to the guest. The launcher searches upward from the selected
directory to find it.

```sh
cd /path/to/project
cat >.sandbox.toml <<'EOF'
version = 1

[[mounts]]
# The launcher creates this branch's temporary Git worktree itself.
path = "."
branch = "sandbox/example"
mount_point = "/workspace"

[[mounts]]
# A non-Git directory is mounted directly and defaults to read-only.
path = "../reference-data"
mount_point = "/reference-data"

[network]
mode = "public"
EOF

sandbox doctor
sandbox plan
sandbox validate
sandbox start
# Type: START PUBLIC
```

`doctor`, `plan`, and `validate` are deliberate gates: use them to inspect the
host prerequisites, mount boundary, network policy, and exact rendered
Lima template before creating the VM. `sandbox template` prints that YAML when
more detail is useful.

The guest is an `aarch64` Ubuntu VM under Apple Virtualization.framework. It
has only the declared mounts, a fixed store-built Home Manager base profile,
and a read-only copy of the active specification at
`/sandbox-spec/.sandbox.toml`. The remainder of the host home directory, host
credentials, and SSH agent are absent. The base profile supplies Nix, Bash,
direnv/nix-direnv, curl, git, and jq. Public and open VMs also run the upstream
Databricks CLI and uv install scripts at first boot, placing both in
`/usr/local/bin` for the unprivileged agent; destroy and recreate a VM to pick
up a newer upstream release. Restricted VMs do not fetch those unrestricted
installer domains after their exact-domain egress policy is active. The base
profile deliberately does not install Pi, OpenCode, Claude Code, local-model
configuration, or model credentials. A project may compose extra portable HM
modules and unprivileged startup scripts as described below, or use a project
`nix develop` for its declared tools.

A project may intentionally expose no host paths at all. Omit `[[mounts]]`
from the visible specification; the agent then starts in its private
`/home/agent` directory, with only the read-only specification mounted:

```toml
version = 1

[network]
mode = "public"
```

This is useful for an agent whose entire working state should remain in the
disposable guest. `sandbox plan` prints `/home/agent` as its working directory.
Projects with no `.sandbox.toml` continue to use the legacy secondary-Git-
worktree `/workspace` behaviour.

### Guest privilege boundary

The launcher uses Lima's `lima` account only as a privileged transport and
bootstrap account. System provisioning installs the firewall, proxy, Nix, and
the fixed profile before any project command runs. `sandbox shell` and
`sandbox exec` then switch to an `agent` account with no sudo or administrative
group membership. This prevents agent code from replacing the guest firewall,
changing routes, or changing proxy configuration.

The agent can still use `nix develop`, `nix profile`, project-local language
environments, and writable declared mounts. It cannot install system packages
with `apt`; add a trusted bootstrap package or use a user/project-level tool
instead. This is a guest privilege boundary, not a defence against a guest
kernel or Nix-daemon vulnerability.

### Mount declarations

Each `[[mounts]]` entry has a source `path` and an absolute guest
`mount_point`. A source path may be absolute or relative to the directory
containing `.sandbox.toml`; it must name an existing directory. Guest mount
points are normalized absolute paths, cannot be `/`, and cannot overlap.

When `path` names a Git repository root, `branch` is required. The launcher
creates (or reuses) a linked worktree under its own temporary directory and
mounts that worktree — never the configured checkout itself. An existing local
branch is used; a missing branch is created from the configured repository's
current `HEAD`. Git mounts default to `access = "rw"`:

```toml
[[mounts]]
path = "/Users/me/src/api"
branch = "sandbox/api-change"
mount_point = "/workspace"
# access = "rw" # the Git default
```

For a non-Git directory, the configured path itself is mounted and defaults to
`access = "ro"`. Set `access = "rw"` only when the guest must modify it:

```toml
[[mounts]]
path = "../fixtures"
mount_point = "/fixtures"
# access = "ro" # the non-Git default
```

`sandbox plan` prints the source, Git branch (where applicable), actual guest
mount point, and effective access for review. Generated Git worktrees remain
after `sandbox destroy`: this deliberately protects uncommitted guest work.
Once clean or committed, remove one using the path printed by `sandbox plan`:

```sh
git -C /path/to/repository worktree remove /private/tmp/coding-sandbox-worktrees/...
```

The configuration is deliberately not hidden. It remains visible in a source
mount when that source contains it, and is always mounted read-only at
`/sandbox-spec/.sandbox.toml`. Treat it as reviewable project policy; changing
it requires destroying and recreating the affected VM.

### Per-worktree profile and startup

`[profile].modules` accepts ordinary, portable Home Manager module files.
`[[startup]]` entries are ordered Bash scripts, each with a stable name and
optional string arguments. Every selected file must resolve beneath an existing
declared mount; a module that merely registers itself through flake-parts, or
expects the workstation flake's `inputs`, is not a portable module. This keeps
the guest from evaluating the host configuration or gaining its credentials.

```toml
[[mounts]]
path = "."
branch = "sandbox/unity-gateway"
mount_point = "/workspace"

[profile]
modules = ["sandbox/wcb-home.nix"]

[[startup]]
name = "unity-gateway"
path = "sandbox/install-unity-gateway.sh"
args = []
```

The plan prints each guest path, host source, mount access, individual source
digest, and combined profile digest. At first creation, the launcher generates
a private guest flake which combines the fixed base profile with precisely
those module paths, verifies every selected digest, and runs `home-manager
switch` as `agent`. It then verifies and invokes startup scripts in their
declared order as `agent`, using `bash <path> [args...]`. No selected code gets
sudo, the Lima transport identity, forwarded SSH state, or a broader mount.

Home Manager needs impure evaluation solely to import the reviewed absolute
guest mount paths; it never evaluates the workstation flake. A profile module
can add user packages such as `uv`, but its Linux closure is built inside the
guest—there is no Darwin or NixOS rebuild. In `restricted` mode, declare every
additional public hostname required by a module or startup script.

### Guest environment

Projects can declare literal environment variables for the unprivileged guest
account. They appear in `sandbox plan`, become part of the policy digest, and
are available to interactive shells, `sandbox exec`, and startup scripts:

```toml
[environment]
# Use an approved internal package mirror rather than bypassing host DNS policy.
UV_INDEX_URL = "https://pypi-proxy.cloud.databricks.com/simple"
BROWSER = "none"
```

This is not a host-environment bridge: values are literal strings, not
references such as `$HOST_TOKEN`, and must not contain secrets. The launcher
sets them only after it has dropped to the `agent` account; they never affect
Lima or privileged guest provisioning. Changing the table requires destroying
and recreating the VM. In `restricted` mode, separately list an index hostname
in `network.public_domains` (or `network.internal_domains` when it is a
protected endpoint). The launcher also includes `~/.local/bin` in the agent's
PATH, so `uv tool install` entrypoints work immediately without running
`uv tool update-shell`.

Activation output is recorded in
`~/.local/state/coding-sandbox/home-manager.log`; each startup entry gets
`startup-<name>.log` there, and `profile.json` records the sources/digests used
for the VM. An unchanged VM does not rerun setup after stop/start. Any change
to a selected module, startup script, source location, or profile declaration
changes the effective policy: inspect `sandbox plan`, then destroy and recreate
the VM before it can run.

### Nix cache lifecycle

The default keeps `/nix` on the VM's primary disk. It is warm across
`sandbox stop` / `sandbox start`, but `sandbox destroy` removes it along with
all other guest state. This is the ordinary disposable-sandbox path.

For a worktree whose profile takes substantial time to realize, opt in to a
dedicated persistent cache disk:

```toml
[storage]
# Default is "instance". "persistent" keeps Nix's store and database after
# sandbox destroy; the agent home, guest OS, and project state remain volatile.
nix_store = "persistent"
```

The launcher creates one sparse 50 GiB Lima disk for the project and network
mode. It is never shared with another sandbox, so public and restricted
instances can run at the same time and untrusted worktrees cannot share a
writable Nix store. The plan names the disk before creation.

The first VM initializes the disk from its newly installed Nix store. Later
VMs still install their own daemon and build users on the disposable OS disk,
then bind the persistent store, database, profile roots, and GC roots into
place. Consequently no guest configuration, credentials, or agent state is
carried across recreation—only Nix cache data and profile references.

Inspect or deliberately remove the disk with:

```sh
sandbox cache status
sandbox destroy
sandbox cache purge
# Type: purge cache s<instance-id-prefix>
```

`cache purge` refuses while the instance exists, even when stopped. It is the
only command that deletes a persistent cache disk; `destroy` deliberately
leaves it intact for the next VM. When that VM is running, `destroy` first
flushes and shuts it down normally before deleting it, so an ext4 cache disk
does not survive a forced VZ termination with an incomplete Nix-store write.

## Network modes

The default `public` mode is the normal safe path:

```sh
sandbox start
sandbox shell
```

Public internet is available without maintaining a registry-by-registry
allowlist. Its security boundary is lateral movement: nftables denies RFC1918
IPv4, CGNAT/Tailscale, IPv4 link-local, IPv6 unique-local, and IPv6 link-local
destinations unless the selected project explicitly grants them. The policy is
IP based, so DNS rebinding or a client connecting directly by IP cannot bypass
it.

The only automatic private-network exception is narrowly infrastructure-only:
DHCP plus DNS on TCP/UDP port 53 to Lima's discovered NAT resolver. It is not a
general permit for the gateway or its subnet. `sandbox plan` prints this
boundary and every resolved grant before a VM is created.

### Per-project network grants

Put network policy in the same visible `.sandbox.toml` as the mount declarations:

```toml
version = 1

[network]
# public is the default; restricted and open are described below.
mode = "public"

# Exact FQDNs only: no wildcards and no suffix matching.
internal_domains = ["dev.example.internal"]

# Each CIDR must be wholly inside a protected range.
internal_cidrs = ["100.64.12.34/32", "fd00:1234::42/128"]
```

An internal domain must resolve to protected addresses at launch. The launcher
prints the resulting literal addresses and renders them into nftables; changed
DNS or changed policy requires destroying and recreating the VM. This makes the
grant inspectable and fail-closed. A public application's name merely sharing a
suffix with an internal domain is not blocked or granted by that suffix: only
the exact names above matter.

No grants means no internal reachability. The file is project-controlled data,
so inspect the effective plan and start warning before confirming a VM:

```sh
sandbox plan
sandbox validate
sandbox start
# Type: START PUBLIC
```

### Hardened public allowlisting

`restricted` is an optional stricter mode for work that can operate through a
small public-domain allowlist. It keeps the lateral IP boundary and adds a
guest-local Squid proxy; direct public egress stays denied.

```toml
[network]
mode = "restricted"
public_domains = ["registry.npmjs.org"]
internal_domains = ["dev.example.internal"]
```

The fixed bootstrap domains for Nix, Determinate Nix, and GitHub remain
available. `public_domains` contains exact public FQDNs and is valid only in
this mode. Internal endpoints are never implicit baseline grants.

At VM creation, the launcher resolves each allowed name, prints the literal
addresses in the plan, and pins Squid to those exact answers. nftables permits
the proxy to connect only to that same finite set. This prevents a separate
CDN/DNS answer from silently widening the allowlist; destroy and recreate the
VM when an allowed service changes addresses.

```sh
sandbox start --network restricted
# Type: START RESTRICTED
sandbox exec --network restricted -- curl -I https://cache.nixos.org/
sandbox exec --network restricted -- bash -lc \
  'if curl --noproxy "*" --connect-timeout 5 -I https://example.com; then exit 1; else echo blocked; fi'
```

`open` is separate and deliberately not a convenience escape hatch. It removes
both the public allowlist and the lateral boundary, so it can reach LAN,
tailnet, host-side, and other internal targets reachable from the Mac. Use it
only for explicit troubleshooting:

```sh
sandbox plan --network open
sandbox validate --network open
sandbox start --network open
# Type: OPEN NETWORK

sandbox exec --network open -- curl --noproxy '*' -I https://example.com
```

Open mode installs neither Squid nor nftables. It is a separate VM instance,
not a policy change to a public or restricted VM, and its confirmation
deliberately spells out the wider exposure.

### Network acceptance checks

After starting a sandbox, prove the policy rather than trusting the template:

```sh
# Public egress works in the default mode.
sandbox exec -- curl --connect-timeout 10 -I https://example.com/

# An ungranted protected address is blocked, even without DNS.
sandbox exec -- bash -lc \
  'if curl --noproxy "*" --connect-timeout 5 -I http://100.64.0.1; then exit 1; else echo blocked; fi'

# For a project with an explicit grant, substitute the granted hostname.
sandbox exec -- curl --connect-timeout 10 -I http://dev.example.internal/
```

The agent account cannot inspect or replace firewall rules with `sudo`; prove
that with `sandbox exec -- sudo -n nft list ruleset` (it must fail). The Mac
operator may inspect the VM's rendered rules through Lima's privileged
transport account when diagnosing a policy: `limactl shell INSTANCE sudo nft
list ruleset`, where `INSTANCE` comes from `sandbox plan`. The sandbox has no
host credentials or forwarded SSH agent, and this iteration does not add
GitHub credentials, SSH forwarding, or a web UI.

### Browser OAuth callbacks

An OAuth CLI running in the guest can receive a browser callback through a
small, project-declared TCP allowlist. This is host-loopback ingress, separate
from the guest's `[network]` egress policy. For example, the Databricks CLI
starts at port 8020 and can fall back through 8040:

```toml
[callbacks]
port_ranges = [[8020, 8040]]
```

After adding, removing, or changing callback ranges, inspect the changed
policy and destroy/recreate the sandbox; an existing VM keeps the policy it was
created with:

```sh
sandbox plan
sandbox destroy
sandbox start
```

For each declared range, Lima dynamically forwards guest TCP listeners to the
same port range on `127.0.0.1` only. A redirect to
`http://localhost:8020/...` in the Mac browser therefore reaches the guest's
`localhost:8020` listener. No listener or host-port reservation exists merely
because the range is declared: Lima creates the host listener when a guest
program starts listening, and removes it when that guest listener closes.

If another Mac process already owns a declared port when the guest CLI opens
its listener, Lima cannot forward that callback. Stop the conflicting process
or use another port already declared by the CLI's callback range; the launcher
does not silently remap a redirect port. `sandbox plan` and `sandbox validate`
show the effective ranges and this dynamic conflict model before a VM is
created.

This is intentionally not general service publishing: only declared TCP
ranges map 1:1, UDP is unavailable, and undeclared guest listeners remain
denied by the all-port Lima rule. The host binding is never `0.0.0.0`, so the
callback is not reachable from the LAN, tailnet, or another host.

## Multiple VMs and cleanup

An instance is keyed by the project specification path and its network mode.
You can run many sandboxes at once: the same project has separate restricted
and open instances, and every other project has its own VM. Instance names
include a readable project label plus a short collision-resistant suffix.

```sh
sandbox list
sandbox status                         # current project, public mode
sandbox status --network open          # current project, open mode
sandbox stop                           # retain this VM and its guest Nix cache
sandbox destroy                        # remove this project's public VM
sandbox destroy --network open         # remove this project's open VM
sandbox cache status                    # inspect an opted-in persistent cache disk
```

If the original worktree is gone, list the VMs and explicitly delete the
orphan by its printed instance name:

```sh
sandbox list
sandbox delete coding-sandbox-project-example-0123456789ab
# Type: delete coding-sandbox-project-example-0123456789ab
```

`destroy` and `delete` delete only the VM disk/state after confirmation; they
never delete or alter a declared host path or generated Git worktree. `--yes`
is available for scripted, deliberate cleanup.

Stopping a VM preserves its complete guest disk, including `/nix`, by default.
That gives each work item a warm, isolated Nix cache on the next start.
Destroying an `instance` cache removes it; destroying a `persistent` cache
leaves its dedicated Lima disk for the next VM. Do not mount a shared writable
`/nix` store from macOS or another sandbox: Nix's store database and locks are
not a safe multi-guest cache, exposing it would give untrusted guest code a
host filesystem boundary to attack, and a Darwin host store is not a substitute
for Linux guest outputs. A future shared-cache design should instead use a
dedicated, content-addressed binary-cache service with a narrow interface.

## Current limits

- The implementation is Apple-Silicon macOS only.
- `.sandbox.toml` covers mount/network policy plus portable Home Manager
  modules and agent-only startup scripts. Credentials, agent selection, and UI
  settings remain out of scope.
- No GitHub token/deploy key, host SSH forwarding, web UI, or general service
  publishing is available. Lima guest port forwarding is denied by default
  except for explicitly declared loopback-only TCP browser callbacks.
- Public mode is the default for ordinary registries and external gateways;
  `restricted` mode requires declaring each additional public hostname.
