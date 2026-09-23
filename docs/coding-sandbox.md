# macOS coding sandboxes

The `work` Darwin host provides `sandbox`, a Lima launcher for a disposable
Ubuntu VM with an explicit, project-owned mount specification. This is the first
macOS-only slice of the broader [coding-sandbox issue](https://github.com/ianepreston/nixos/issues/539).
NixOS support and per-project profiles are intentionally not implemented yet.

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
has only the declared mounts, a fixed store-built Home Manager profile, and a
read-only copy of the active specification at `/sandbox-spec/.sandbox.toml`.
The remainder of the host home directory, host credentials, and SSH agent are
absent. The minimal profile supplies Nix, Bash, direnv/nix-direnv, curl, git,
and jq; it deliberately does not install Pi, OpenCode, Claude Code,
local-model configuration, or model credentials. Use a project `nix develop`
for declared project tools, or install a demo's agent inside the guest and
configure it to use that demo's AI gateway.

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

For a stricter policy inspection, run `sandbox exec -- sudo nft list ruleset`
inside the guest and compare the address sets with `sandbox plan`. The sandbox
has no host credentials or forwarded SSH agent, and this iteration does not add
GitHub credentials, SSH forwarding, or a web UI.

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
Destroying the VM removes that cache. Do not mount a shared writable `/nix`
store from macOS or another sandbox: Nix's store database and locks are not a
safe multi-guest cache, exposing it would give untrusted guest code a host
filesystem boundary to attack, and a Darwin host store is not a substitute for
Linux guest outputs. A future shared-cache design should instead use a
dedicated, content-addressed binary-cache service with a narrow interface.

## Current limits

- The implementation is Apple-Silicon macOS only.
- `.sandbox.toml` currently covers mount and network policy only. Packages,
  agent/profile selection, credentials, and UI settings remain out of scope.
- No GitHub token/deploy key, host SSH forwarding, or web UI/port forwarding is
  available. Lima guest port forwarding is denied by default.
- Public mode is the default for ordinary registries and external gateways;
  `restricted` mode requires declaring each additional public hostname.
