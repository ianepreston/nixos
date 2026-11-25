# Coding sandboxes

The `work` Darwin host and the `terra` and `luna` NixOS workstations provide
`sandbox`, a Lima launcher for a disposable Ubuntu VM with an explicit,
project-owned mount and profile specification. It is part of the broader
[coding-sandbox issue](https://github.com/ianepreston/nixos/issues/539).

| Host | VM backend | Guest | Host directory sharing |
| --- | --- | --- | --- |
| Apple Silicon macOS (`work`) | Apple Virtualization.framework (VZ) | `aarch64` Ubuntu, Rosetta for amd64 binaries | virtiofs |
| NixOS workstation (`terra`, `luna`) | QEMU with KVM | Ubuntu on the host's own CPU (`x86_64`) | 9p |

The backend is fixed when the Home Manager configuration is built, so one
`.sandbox.toml` works unchanged on either kind of host. Everything else below
(mounts, network modes, profiles, caches, callbacks, and lifecycle) behaves the
same on both.

## Install and define a project

Apply the host's configuration to put `sandbox` on `PATH`:

```sh
task build_darwin:work   # macOS
task rebuild             # on a NixOS workstation
```

On Linux, `sandbox doctor` also checks that `/dev/kvm` is read-writable by
your user. NixOS's default udev rule makes it world read-writable; without KVM
QEMU would fall back to software emulation, which is too slow to build a guest
profile.

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

The guest is an Ubuntu VM on the host's CPU architecture. It has only the declared mounts, a fixed store-built Home Manager base profile,
and a read-only copy of the active specification at
`/sandbox-spec/.sandbox.toml`. The remainder of the host home directory, host
credentials, and SSH agent are absent. The base profile supplies Nix, Bash,
direnv/nix-direnv, curl, gh, git, and jq, and nothing else: no Databricks CLI,
uv, Node, coding agent, local-model configuration, or model credential. Tools
come from three places, each with a different owner:

| Layer | Owner | Selected by | Use for |
| --- | --- | --- | --- |
| Base profile | this flake | always present | the minimal shell above |
| [Platform bundles](#platform-bundles) | this flake | `[profile].bundles` names | reusable clients and tools: Databricks CLI, uv, Node, agents, Unity Gateway |
| [Project profile](#per-worktree-profile-and-startup) | the project | `[profile].modules`, `[[startup]]` paths | a project-specific Home Manager adjustment |

A project's own dependencies still belong in its `nix develop` devShell, which
the guest realizes natively.

The guest flake's `nixpkgs`, `nixpkgs-unstable`, and Home Manager inputs are
this flake's own locked revisions (with their NAR hashes), so a workstation
revision identifies the guest's bytes. `sandbox plan` prints them as `Guest
pins`. Home Manager itself runs from that pinned input; nothing resolves a
moving release branch at first boot.

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

On macOS these worktrees live under `$TMPDIR`. On Linux they live under
`${XDG_STATE_HOME:-~/.local/state}/coding-sandbox/` instead, because NixOS ages
out `/tmp` entries untouched for 10 days and other distributions mount it as
tmpfs. Either would silently discard uncommitted guest work.

The configuration is deliberately not hidden. It remains visible in a source
mount when that source contains it, and is always mounted read-only at
`/sandbox-spec/.sandbox.toml`. Treat it as reviewable project policy; changing
it requires destroying and recreating the affected VM.

### Platform bundles

A bundle is a named, store-pinned tool set that this flake owns. A project
selects bundles by exact name; it never names a path, URL, or package
attribute:

```toml
[profile]
bundles = ["databricks-cli", "uv", "agent-pi", "unity-gateway"]
```

| Bundle | Provides | Does not provide |
| --- | --- | --- |
| `databricks-cli` | `databricks` | a profile, workspace, or token |
| `uv` | `uv`, `uvx` | a project environment or dependencies |
| `nodejs` | `node`, `npm`, `npx` | npm-installed global tools |
| `agent-pi` | `pi` | a provider, model, or credential |
| `agent-claude-code` | `claude` | a login, API key, or permission bypass |
| `agent-opencode` | `opencode` | a provider, model, or credential |
| `unity-gateway` | `ug`, `ucode` | a workspace, OAuth state, or token |

Bundles contain executables only. `ug` launches whichever agent bundles are
also selected; it finds them on `PATH`. Databricks U2M login stays a human step
inside the guest: declare the CLI's callback range (see
[Browser OAuth callbacks](#browser-oauth-callbacks)) and choose the workspace
explicitly.

Definitions live in `modules/programs/_coding-sandbox/bundles/<name>.nix`;
each returns a description, its commands, and its packages from the guest's
`pkgs` (stable) or `pkgsUnstable` set (`_coding-sandbox/guest-pkgs.nix`, which
also owns the guest's short unfree allowlist). The fast-moving clients use
unstable, as on the workstations. The exception is OpenCode: Hydra doesn't
cache unstable's build, and building it from source runs out of memory in a
default guest, so `agent-opencode` uses stable until the cache serves it. The
work Mac's guest still builds whatever cache.nixos.org lacks, so the pin stays
even though a NixOS host now seeds its guests (below).
Unfree bundles (`databricks-cli`, `agent-claude-code`) and `unity-gateway` are
never in cache.nixos.org.

**On a NixOS workstation (QEMU), the host seeds the selected bundles.** Before
a new VM's first boot, `sandbox start` builds the guest flake's
`sandboxBundles.<name>` outputs on the host. The host's own substituters serve
them: hpp-1 first (CI builds every bundle there as
`legacyPackages.x86_64-linux.coding-sandbox-guest-packages`), then
cache.nixos.org. The host builds locally whatever neither has. It checks that
the catalog's exact store paths are now valid, then exports their closures with
`nix copy --to file://…` into `${XDG_STATE_HOME:-~/.local/state}/coding-sandbox/<instance>.seed`.
The template mounts that directory read-only at `/mnt/sandbox-seed`. Before
the Home Manager switch, the guest's root copies it to a private local
directory and imports it from there with `nix copy --no-check-sigs --from
file://…`. Nix creates subdirectories in a `file://` cache even to read it, so
it can't read the mount in place. The switch then finds the bundle paths valid. Locally built
paths are unsigned. The host is the guest's trust root anyway, since it
supplies the profile flake. The guest gets no network grant to hpp-1 and no
key for it: the seed is a host directory like the profile mount, not guest
egress. The launcher clears the export once `limactl start` returns. It keeps
the empty directory because Lima mounts it on every boot, and removes it with
the VM. If the host can't build or export a bundle, it says so, and the guest
substitutes or builds it as before. If the guest import fails, it records that
in the guest's `/home/agent/.local/state/coding-sandbox/seed.log` and the switch
builds instead.

On the work Mac (VZ) the host can't build Linux paths, so each new VM builds
the uncached bundles itself. They are small builds. `sandbox plan` shows which
path applies on its `Guest packages:` line.

`databricks-cli` is upstream's statically linked release binary rather than
nixpkgs' source build: as an unfree package that build would run in the guest
and fetch its Go modules from `proxy.golang.org`, which the work Mac's network
policy blocks for its guests too.

A bundle that builds in the guest declares the hosts its build fetches from,
and the plan shows them. They stay declared on a NixOS host too, where the
guest builds only when seeding fails. In `restricted` mode the plan refuses
until the project lists each one in `network.public_domains`:
`release-assets.githubusercontent.com` for `databricks-cli` (its download
starts at `github.com`, already a bootstrap domain, which redirects there), and
`downloads.claude.ai` for `agent-claude-code`. The other bundles need nothing
beyond the fixed bootstrap domains. A tool missing from nixpkgs, or one whose
nixpkgs build can't run in a guest, is packaged in its bundle from a fixed tag
or release and its hash. Unity Gateway and the Databricks CLI are packaged like
this and tracked by Renovate; CI regenerates their hashes (the Databricks
CLI's through `regen-hash:` markers, see
[fetch hashes](runbooks/fetch-hashes.md)). Adding a bundle means adding one
file; the catalog is the directory listing.

`sandbox plan` shows each selected bundle with its source digest, commands,
and exact package versions and store paths. After Home Manager activation the
guest checks that every one of those store paths is in the agent's profile,
and fails provisioning if not. Two kinds of change behave differently:

- **Editing a bundle's definition** changes its source digest, so it is a
  policy change. An existing VM refuses to start or run until it is destroyed
  and recreated.
- **A `flake.lock` bump** changes the pins and store paths but not the policy.
  An existing VM keeps the tools it was built with, and `sandbox plan` for it
  shows what it recorded. Destroy and recreate it to pick up the new pins.
  The launcher roots each VM's guest-profile store path (the
  `<instance>.guest-profile` link beside its recorded policy), so garbage
  collection can't remove a path an existing VM still mounts. `destroy` and
  `delete` remove the root.

`modules/programs/_coding-sandbox/fixtures/bundles/.sandbox.toml` is a
credential-free fixture that selects every bundle and mounts nothing.

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
for the VM. If activation or any startup entry fails, `sandbox start` fails
too, and prints the failed entry's log tail (or the end of
`home-manager.log`). Lima alone would still report the VM ready. An unchanged
VM does not rerun setup after stop/start. Any change
to a selected module, startup script, source location, or profile declaration
changes the effective policy: inspect `sandbox plan`, then destroy and recreate
the VM before it can run.

### GitHub session credential

A project may grant each agent session a short-lived GitHub credential for one
repository. The grant is visible, non-secret policy:

```toml
[github]
repository = "ianepreston/nixos"

[github.permissions]
contents = "write"      # clone, fetch, push
pull_requests = "write" # gh pr create / edit
```

Version one accepts only `contents` and `pull_requests`, each `"read"` or
`"write"`. Other permissions (issues, Actions, administration, …) are rejected,
and adding one is separate work.

Immediately before each `sandbox shell` or `sandbox exec`, the host launcher
signs a GitHub App JWT with the App private key, finds the App's installation
for the declared repository, and requests an installation token restricted to
that one repository and the declared permissions. If GitHub returns a token
for anything broader, the launcher refuses to use it. The token is handed only
to the new `agent` process:

- `GH_TOKEN` for `gh` (installed in the base profile).
- An HTTPS Git credential helper for `https://github.com`, supplied through
  `GIT_CONFIG_*` environment variables, so no guest config file names the
  token.

The token crosses into the guest over stdin into a private tmpfs file, which
the session deletes before running anything else. The launcher deletes it
again afterwards in case the session never started. The App key, JWT,
installation ID, and token never appear in `.sandbox.toml`, `plan`,
`validate`, `template`, the recorded policy, guest profile state, a log, or a
process argument on the host or in the guest. While a grant is declared,
`[environment]` may not set `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST`, or any
`GIT_CONFIG*` name.

`sandbox start` provisions the normal credential-free VM; nothing during
provisioning or startup scripts has a token. Because a grant can push code,
its start confirmation is distinct: `START PUBLIC WITH GITHUB`,
`START RESTRICTED WITH GITHUB`, or `OPEN NETWORK WITH GITHUB`. Changing the
grant changes the effective policy, so destroy and recreate the VM.

GitHub expires every installation token after one hour, and the guest cannot
mint or renew one. When GitHub calls start failing, leave and re-enter through
`sandbox shell` or `sandbox exec`; worktree changes survive. `stop` and
`destroy` prevent further tokens. A token that guest code has already copied
elsewhere stays usable until its hour runs out, so treat a grant as giving the
guest that much reach.

Restricted mode already allows `github.com`, `api.github.com`, and
`codeload.github.com`, so a grant adds no network exception.

#### Host credentials and revocation

The GitHub App's ID and private key come from the private `nix-secrets` input
(`sops/coding-sandbox.yaml`, keys `github_app.app_id` and
`github_app.private_key`). Home Manager sops-nix decrypts them on hosts that
have a sops age identity, currently `terra` and `luna`. The `work` Mac has
none yet, so its launcher reports `[github]` as unavailable and `sandbox
shell`/`exec` refuse a policy that declares one. `sandbox doctor` and
`sandbox plan` show whether this host can mint tokens.

Register the App with only the Contents and Pull requests repository
permissions, no webhook, installable only on the owner's account. Install it
only on the repositories sandboxes should be able to request. The App's own
permissions and installation scope cap any grant, whatever `.sandbox.toml`
says.

To revoke access:

1. Remove the `[github]` table (or the repository from the App installation).
   No further tokens can be minted for it.
2. For immediate containment, suspend or uninstall the App installation in
   GitHub's settings. That invalidates every outstanding token.
3. Otherwise, any already-issued token expires within one hour.

Rotating the private key means generating a new key on the App's settings
page, replacing `github_app.private_key` in `nix-secrets`, and deleting the
old key in GitHub.

### Session secrets

A project may grant named secrets that this workstation holds, such as an
API key for an internal service. The grant is visible, non-secret policy:

```toml
[secrets]
grants = ["llm"]

[network]
internal_domains = ["llm.amos.ipreston.net"]
```

The names come from a catalog in `modules/programs/coding-sandbox.nix`
(`sessionSecrets`), which is the only place a secret's source is declared.
A worktree selects names; it can never name a sops key, path, or host
variable. Each catalog entry sets one environment variable:

| Name | Variable | For |
| --- | --- | --- |
| `llm` | `LLAMA_API_KEY` | the llama.cpp endpoints `llm.amos.ipreston.net` and `llm-terra.amos.ipreston.net` |

`sandbox plan` lists each grant with its variable and its domains, and
reports whether the project's network policy reaches each domain (`granted`,
`granted by internal_cidrs`, `open network`, or `NOT GRANTED`). A secret
grants no network reach of its own: without a matching `internal_domains` or
`internal_cidrs` grant, the guest holds a key for a service it cannot
contact. Values never appear in `plan`, the recorded policy, a log, or a
process argument.

Delivery follows the [GitHub session credential](#github-session-credential):
immediately before each `sandbox shell` or `sandbox exec`, the launcher reads
each value from its sops-nix path and passes it over stdin into a private
tmpfs file, which the session reads into its environment and deletes before
running anything else. Nothing during `sandbox start`, provisioning, or
`[[startup]]` has a secret. `[environment]` may not set a granted variable,
and no catalog entry may set the GitHub credential's names. The start
confirmation gains `WITH SECRETS` (or `AND SECRETS` after `WITH GITHUB`), and
changing the grants means destroying and recreating the VM.

The threat model differs from GitHub's. These secrets are long-lived keys for
internal services that are not reachable from the internet, and guest code
can read and copy them. The boundary is what the agent can reach and what the
key itself permits, so give sandboxes their own key wherever the service
supports one. To revoke a secret, rotate the value its catalog entry names in
`nix-secrets` and redeploy the hosts that read it. Each new session reads the
new value; no VM needs recreating.

`llm` is such a key: `llama-cpp/sandbox_api_key` in `sops/llm.yaml`, which
llama-server on amos1 and terra accepts beside the fleet's primary key
(`modules/system/_llama-cpp/nixos.nix`). It lives in `llm.yaml` because the
serving hosts must read it, and `coding-sandbox.yaml` deliberately excludes
servers. Rotating it touches only llama-server; Caddy and the fleet's own
clients keep the primary key.

Secrets come from sops-nix, so the same hosts that can mint GitHub tokens
provision them (`terra` and `luna`). On the `work` Mac every entry reports
`NOT READY`, and `sandbox shell`/`exec` refuse a policy that grants one.
Adding an entry means a new `sessionSecrets` attribute (with its `sopsFile`
and `key`) plus that value in `nix-secrets` **before** the change reaches a
host. Use `sops/coding-sandbox.yaml` unless a server must read the value too,
and then the narrowest file the servers can read: sops-nix
installs a user's secrets all or nothing, so a missing key would also break
that host's other user secrets.

### Seeing what changed

The guest can write to its worktree, so it can edit `.sandbox.toml` to ask
for more: a secret, a network grant, a mount. It cannot get any of it that
way. A VM keeps the policy recorded on the host when it was created
(`~/.local/state/coding-sandbox/<instance>.policy.json`, never mounted in the
guest), and every `shell`/`exec` refuses when the current specification
differs, listing each change:

```text
sandbox: effective policy changed for coding-sandbox-project-0123456789ab:
  + secrets[llm].name: llm
  + secrets[llm].env: LLAMA_API_KEY
  + internal_cidrs: 10.1.2.3/32
  ~ environment.BROWSER: none -> w3m
sandbox: inspect sandbox plan, then destroy and recreate the VM
```

Only a host-side `sandbox destroy` and `sandbox start`, with its typed
confirmation, adopts the change. `destroy` keeps the destroyed VM's policy
beside it, and the next `start` prints the same list above its confirmation,
so an edit nobody remembers making is visible at the moment it would take
effect.

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
does not survive a forced VM termination with an incomplete Nix-store write.

## Network modes

The default `public` mode is the normal safe path:

```sh
sandbox start
sandbox shell
```

Public internet is available without maintaining a registry-by-registry
allowlist. Its security boundary is lateral movement: nftables denies RFC1918
IPv4, CGNAT/Tailscale, IPv4 link-local, IPv6 unique-local, IPv6 site-local, and
IPv6 link-local destinations unless the selected project explicitly grants
them. The policy is IP based, so DNS rebinding or a client connecting directly
by IP cannot bypass it. Site-local `fec0::/10` is listed because QEMU's
user-mode network uses `fec0::/64`, and its `fec0::2` gateway reaches the host
machine's own loopback, exactly as `192.168.5.2` does over IPv4.

The only automatic private-network exception is narrowly infrastructure-only:
DHCP plus DNS on TCP/UDP port 53 to Lima's NAT resolver(s). The guest permits
exactly the IPv4 resolvers DHCP gave its default-route link, and refuses to
provision if one is reached through a router. Under VZ the resolver is the
gateway itself; QEMU's user-mode network answers DNS on a separate address
beside the gateway (192.168.5.3 next to 192.168.5.2). It is not a general
permit for the gateway or its subnet. `sandbox plan` prints this
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
tailnet, host-side, and other internal targets reachable from the host. Use it
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
that with `sandbox exec -- sudo -n nft list ruleset` (it must fail). The host
operator may inspect the VM's rendered rules through Lima's privileged
transport account when diagnosing a policy: `limactl shell INSTANCE sudo nft
list ruleset`, where `INSTANCE` comes from `sandbox plan`. The sandbox has no
host credentials or forwarded SSH agent. The only credentials it can hold are
a declared [GitHub session token](#github-session-credential) and declared
[session secrets](#session-secrets); there is no SSH forwarding or web UI.

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
`http://localhost:8020/...` in the host browser therefore reaches the guest's
`localhost:8020` listener. No listener or host-port reservation exists merely
because the range is declared: Lima creates the host listener when a guest
program starts listening, and removes it when that guest listener closes.

If another host process already owns a declared port when the guest CLI opens
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
`/nix` store from the host or another sandbox: Nix's store database and locks are
not a safe multi-guest cache, exposing it would give untrusted guest code a
host filesystem boundary to attack, and a Darwin host store is not a substitute
for Linux guest outputs. A future shared-cache design should instead use a
dedicated, content-addressed binary-cache service with a narrow interface. The
NixOS bundle seed ([Platform bundles](#platform-bundles)) is a narrow case of
that: a one-shot, read-only binary-cache export of the selected bundles'
closures, imported once by the guest's root.

## Current limits

- Hosts are Apple Silicon macOS (VZ) and Linux with KVM (QEMU). The guest is
  always the host's CPU architecture; there is no cross-architecture guest.
- `.sandbox.toml` covers mount/network policy plus platform bundles, portable
  Home Manager modules, agent-only startup scripts, one-repository GitHub
  session grants, and named session secrets. SSH credentials, a
  `sandbox agent` launcher, and UI settings remain out of scope.
- GitHub grants support only `contents` and `pull_requests`, and only on hosts
  that provision the App credentials (`terra` and `luna`, not yet `work`).
  Session secrets have the same host limit.
- No deploy key, long-lived token, host SSH forwarding, web UI, or general
  service publishing is available. Lima guest port forwarding is denied by default
  except for explicitly declared loopback-only TCP browser callbacks.
- Public mode is the default for ordinary registries and external gateways;
  `restricted` mode requires declaring each additional public hostname.
