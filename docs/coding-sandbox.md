# macOS coding sandboxes

The `work` Darwin host provides `sandbox`, a Lima launcher for a disposable
Ubuntu VM around one coding or demonstration worktree. This is the first
macOS-only slice of the broader [coding-sandbox issue](https://github.com/ianepreston/nixos/issues/539).
NixOS support and per-project profiles are intentionally not implemented yet.

## Install and choose a worktree

Apply the `work` configuration to put `sandbox` on `PATH`:

```sh
task build_darwin:work
```

`sandbox` is a normal Home Manager package, rather than a per-repository
install. It accepts any Git repository's **secondary** worktree; it refuses a
primary checkout so the only mutable host mount is the work item itself.

```sh
cd /path/to/project
git worktree add -b fix/example /tmp/project-example HEAD

cd /tmp/project-example
sandbox doctor
sandbox plan
sandbox validate
sandbox start
# Type: start
```

`doctor`, `plan`, and `validate` are deliberate gates: use them to inspect the
host prerequisites, filesystem boundary, network policy, and exact rendered
Lima template before creating the VM. `sandbox template` prints that YAML when
more detail is useful.

The guest is an `aarch64` Ubuntu VM under Apple Virtualization.framework. It
has `/workspace` (the selected worktree) read-write and a fixed, store-built
Home Manager profile read-only. The remainder of the host home directory,
host credentials, and SSH agent are absent. The minimal profile supplies Nix,
Bash, direnv/nix-direnv, curl, git, and jq; it deliberately does not install
Pi, OpenCode, Claude Code, local-model configuration, or model credentials.
Use a project `nix develop` for declared project tools, or install a demo's
agent inside the guest and configure it to use that demo's AI gateway.

## Network modes

The default `restricted` mode is the safe path:

```sh
sandbox start
sandbox shell
```

Guest egress is default-drop in nftables. A local Squid proxy permits HTTPS to
the configured LLM endpoints, Nix caches, Determinate Nix, and GitHub. The
launcher supplies that guest-local proxy automatically to restricted shells
and `sandbox exec` commands. A direct connection, including a client that
ignores proxy variables, remains blocked.

```sh
sandbox exec -- curl -I https://cache.nixos.org/
sandbox exec -- bash -lc \
  'if curl --noproxy "*" --connect-timeout 5 -I https://example.com; then exit 1; else echo blocked; fi'
```

Use open networking only where the explicit risk is appropriate, such as an
external AI gateway or troubleshooting a dependency that the fixed allowlist
does not cover:

```sh
sandbox plan --network open
sandbox validate --network open
sandbox start --network open
# Type: OPEN NETWORK

sandbox exec --network open -- curl --noproxy '*' -I https://example.com
```

Open mode installs neither Squid nor nftables. It is a separate VM instance,
not a policy change to the restricted VM, and its confirmation deliberately
spells out the wider exposure.

## Multiple VMs and cleanup

An instance is keyed by the absolute worktree path and its network mode. You
can run many sandboxes at once: the same worktree has separate restricted and
open instances, and every other worktree has its own VM. Instance names include
a readable worktree label plus a short collision-resistant suffix.

```sh
sandbox list
sandbox status                         # current worktree, restricted mode
sandbox status --network open          # current worktree, open mode
sandbox stop                           # retain this VM and its guest Nix cache
sandbox destroy                        # remove this worktree's restricted VM
sandbox destroy --network open         # remove this worktree's open VM
```

If the original worktree is gone, list the VMs and explicitly delete the
orphan by its printed instance name:

```sh
sandbox list
sandbox delete coding-sandbox-project-example-0123456789ab
# Type: delete coding-sandbox-project-example-0123456789ab
```

`destroy` and `delete` delete only the VM disk/state after confirmation; they
never delete or alter a host worktree. `--yes` is available for scripted,
deliberate cleanup.

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
- There is no `.sandbox.toml` yet for per-worktree mounts, allowlist domains,
  packages, agent/profile selection, credentials, or UI settings.
- No GitHub token/deploy key, host SSH forwarding, or web UI/port forwarding is
  available. Lima guest port forwarding is denied by default.
- The restricted allowlist cannot yet be extended per project. Projects needing
  npm, PyPI, a custom registry, or another endpoint should use the explicit
  open mode for now.
