# Bootstrapping a New Host

## Prerequisites

- Target machine booted into a NixOS ISO (use `task iso` for a custom one)
- This repo and `nix-secrets` cloned on the source machine (e.g.
  `~/src/{nixos,nix-secrets}`)
- An operator identity on the source machine: terra or luna with one of the
  two operator YubiKeys plugged in (`~/.config/sops/age/keys.txt` holds the
  stubs)

## Connecting the target to wifi (minimal ISO)

If the target has no ethernet, get it on wifi before running any bootstrap tasks
— they all SSH into `DEST`. The minimal ISO ships `nmtui`. On the target's TTY:

```bash
sudo nmtui
```

Pick "Activate a connection", select your SSID, enter the passphrase.

## 1. Create host config files

Before bootstrapping, the target host needs configuration in this repo:

- `hostSpecs/newhostname.nix` — host specification (copy from an existing host)
- `modules/hosts/_newhostname-disks.nix` — disko disk layout
- `modules/hosts/newhostname.nix` — host module (which modules to compose)

`git add` all new files — the flake uses `git+file://` and won't see untracked
files. (Host files under `hostSpecs/` are auto-discovered — no need to edit
`hostSpecs/default.nix`.)

The hardware config is automatically fetched from the target during
`bootstrap:install` if the file doesn't exist yet. It gets refreshed from the
installed OS by `bootstrap:hwconfig` after reboot.

## 2. Run the bootstrap

```bash
# Full pipeline for a new host — pauses twice: once for reboot, once for secrets setup:
task bootstrap:new HOST=newhostname DEST=192.168.1.50

# With LUKS encryption:
task bootstrap:new HOST=newhostname DEST=192.168.1.50 LUKS_PASS=temp-passphrase
```

The pipeline pauses once for the target to reboot after install, then
automatically configures secrets in nix-secrets via `bootstrap:secrets`.

Individual steps can be run independently for partial re-runs after failures:

```bash
task bootstrap:install  HOST=newhostname DEST=192.168.1.50  # nixos-anywhere + prints age key
task bootstrap:hwconfig HOST=newhostname DEST=192.168.1.50  # extract hardware config
task bootstrap:hostkey  HOST=newhostname DEST=192.168.1.50  # re-derive age key from live host
task bootstrap:secrets  HOST=newhostname DEST=192.168.1.50  # configure nix-secrets for host
task bootstrap:sync     HOST=newhostname DEST=192.168.1.50  # rsync configs to target
task bootstrap:rebuild  HOST=newhostname DEST=192.168.1.50  # build + identity-checked switch on target
```

## 3. Secrets setup

`bootstrap:new` handles secrets automatically via `bootstrap:secrets`, which:

1. Derives the host's age key from its SSH host key
2. Adds the key to `nix-secrets/.sops.yaml` (host anchor + creation rules)
3. Creates `nix-secrets/sops/newhostname.yaml` with a generated SSH key
4. Grants the host every cross-host sops file its config reads, and rekeys them
5. Commits nix-secrets (locally — not pushed)
6. Prints the host's machine pubkey — **add it to GitHub as a deploy key** for
   the private `nix-secrets` input, or `nixos-upgrade` can't fetch it

That machine key is deliberately not committed to
`modules/profiles/_ssh-keys/`: everything in that directory is an authorized
key on every host, so storing a machine identity there would let a compromised
server SSH into your workstations. It stays recoverable from sops — the task
prints both recovery commands. See `modules/profiles/_ssh-keys/README.md`.

To run this step manually (e.g. after a partial re-run):

```bash
task bootstrap:secrets HOST=newhostname DEST=192.168.1.50
```

The rebuild uses `--override-input nix-secrets path:../nix-secrets`, so the
local commit is sufficient during bootstrap. After the host is up, run
`task secrets:publish` to push that commit and pin it in this repo, so normal
rebuilds work without the override (see `docs/agents/secrets.md`).

## Reinstalling an existing host

For hosts that already have keys and secrets configured, use
`bootstrap:reinstall` — it skips the secrets setup pause:

```bash
task bootstrap:reinstall HOST=existinghost DEST=192.168.1.50
```

## VM testing

Two VM-compatible flake hosts exist for local testing:

- `tests-server` — server-shaped (imports `server` + `server-apps`, same as
  hpp-1). Used by `task recovery:test:full` for the quarterly restore drill.
- `tests-desktop` — desktop-shaped (imports the workstation profile). Useful for
  iterating on desktop modules without a real machine.

The `task vm:*` namespace drives a single quickemu VM at a time under
`~/vms/nixos-vm/`, with a persistent SSH host key (and matching age identity)
preserved across teardowns. Authorize the VM key onto the secrets it needs once
via `task vm:sops-authorize TARGET=<host>` (uncommitted edit in
`../nix-secrets`, built by `vm:install` with `LOCAL_SECRETS=true`; to make it
sticky, switch `../nix-secrets` to a branch and run
`task secrets:publish MSG="authorize VM"`, or `git restore` to revoke).

```bash
# Bring up the VM (builds latest.iso if absent; FORCE_ISO=true to rebuild)
task vm:up

# One-time per real-host secret set: authorize the VM age key
task vm:sops-authorize TARGET=hpp-1

# Install — pre-builds with ../nix-secrets by default (LOCAL_SECRETS=true)
task vm:install HOST=tests-server

# ... iterate, poke ...

# Tear down (kills quickemu, deletes qcow2, preserves SSH host key)
task vm:down

# Or do all of the above as a single fresh-sandbox run:
task vm:reset HOST=tests-server
```

To use flake-locked nix-secrets instead of the local sibling checkout:

```bash
task vm:install HOST=tests-server LOCAL_SECRETS=false
```
