# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Hosts](#hosts)
- [Module System](#module-system)
- [Server App Pattern](#server-app-pattern)
- [Secrets Management](#secrets-management)
- [Task Automation](#task-automation)
- [Bootstrapping a New Host](#bootstrapping-a-new-host)
- [Guidance and Resources](#guidance-and-resources)

---

## Feature Highlights

- Flake-based multi-host, multi-platform configurations for NixOS, Darwin, and
  standalone Home-Manager
  - Modular architecture using
    [flake-parts](https://github.com/hercules-ci/flake-parts) and
    [import-tree](https://github.com/vic/import-tree) for automatic module
    discovery
  - Host specifications defined declaratively in `hostSpecs/` with a formal
    schema
  - Multi-context modules that can register NixOS, Darwin, and Home-Manager
    configs from a single file
- Secrets management via sops-nix and a private `nix-secrets` repo included as a
  flake input
- Declarative, btrfs-on-LUKS disk partitioning via disko
- Automated remote-bootstrapping of NixOS via
  [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and Taskfile
  tasks
- Custom NixOS recovery/installer ISO
- Theming via stylix
- Task automation via [go-task](https://taskfile.dev/) (`Taskfile.yaml`)

## Requirements

- NixOS 25.11+ / nix-darwin 25.11+ / Home-Manager release-25.11
- For secrets: access to the private `nix-secrets` repo via SSH
- Patience

This is a tweaked version of the repo originally provided by
[EmergentMind](https://github.com/EmergentMind/nix-config/). Check out his repos
and resources if you want to build your own.

## Structure Quick Reference

```
.
├── flake.nix              # Entrypoint — uses flake-parts + import-tree to auto-discover modules
├── Taskfile.yaml          # Task runner for build, rebuild, lint, format, etc.
├── hostSpecs/             # Declarative host specifications (hostname, platform, features)
│   ├── host-spec.nix      # Schema definition for host specs
│   ├── luna.nix
│   ├── terra.nix
│   ├── work.nix
│   ├── penguin.nix
│   ├── toshibachromebook.nix
│   └── iso.nix
├── modules/               # All configuration modules, auto-imported by import-tree
│   ├── flake/             # Flake infrastructure (host-specs, module namespaces, dev shell, git hooks)
│   ├── profiles/          # Composable profiles (base, darwin-base, server, workstation)
│   │   ├── _hm-core/     # Core home-manager config (git, zsh, starship, neovim, direnv)
│   │   └── _ssh-keys/    # Public SSH keys
│   ├── system/            # System-level modules (sops, ssh, docker, homebrew, smbclient)
│   ├── apps/              # Server-app modules (containerized services + reverse proxy + secrets)
│   ├── hardware/          # Hardware-specific modules (nvidia, yubikey, keyboards, rgb)
│   ├── desktop/           # Desktop environment modules (gnome, audio, gaming, flatpak, themes)
│   │   └── _gnome/       # GNOME-specific sub-modules (dconf, cursor, stylix)
│   ├── programs/          # Application modules (browser, ghostty, comms, media, obsidian, etc.)
│   └── hosts/             # Per-host configurations and hardware/disk definitions
├── scripts/               # Utility scripts (dconf, sops check)
└── assets/                # Static assets (wallpapers)
```

## Hosts

| Host                  | Platform       | Config Type            | Description                                                              |
| --------------------- | -------------- | ---------------------- | ------------------------------------------------------------------------ |
| **luna**              | x86_64-linux   | `nixosConfigurations`  | MSI GS43VR laptop — workstation + GNOME + gaming + NVIDIA GTX 1060       |
| **terra**             | x86_64-linux   | `nixosConfigurations`  | AMD desktop — workstation + GNOME + gaming + NVIDIA RTX 5080 + streaming |
| **work**              | aarch64-darwin | `darwinConfigurations` | macOS work machine — Homebrew, Hammerspoon, work-specific git config     |
| **penguin**           | x86_64-linux   | `homeConfigurations`   | Standalone home-manager (WSL / non-NixOS Linux)                          |
| **toshibachromebook** | x86_64-linux   | `nixosConfigurations`  | Minimal ChromeBook config                                                |
| **testvm**            | x86_64-linux   | `nixosConfigurations`  | Minimal VM for bootstrap testing (quickemu)                              |
| **iso**               | x86_64-linux   | `nixosConfigurations`  | Custom NixOS installer/recovery ISO                                      |

## Module System

Modules use a dendritic registration pattern powered by flake-parts. Each module
registers itself under one or more namespaces:

```nix
# Example: a module registering both NixOS and home-manager configs
flake.modules.nixos.gnome = { ... };
flake.modules.homeManager.gnome = { ... };
```

Available namespaces: `flake.modules.nixos`, `flake.modules.darwin`,
`flake.modules.homeManager`, `flake.modules.generic`.

Hosts compose their configuration by importing modules:

```nix
# In modules/hosts/terra.nix
modules = with inputs.self.modules.nixos; [
  workstation gnome docker gaming nvidia-rtx5080 ...
];
```

Home-manager modules are wired in via `home-manager.sharedModules` at the
profile level, so they automatically apply to all users on a host.

## Server App Pattern

Server-side applications (web apps hosted behind Caddy) live in
`modules/apps/<appname>.nix` and are composed into the `server` profile. Each
app module is self-contained: it declares the OCI container, its reverse-proxy
virtualHost, any database/user it needs, and its sops secrets in one place.
`modules/apps/mealie.nix` is the canonical example.

### Conventions

- **Registration:** `flake.modules.nixos.<appname>`, then add the name to the
  `imports` list in `modules/profiles/server.nix`.
- **Container runtime:** `virtualisation.oci-containers` with the podman
  backend (rootful — see `modules/system/oci-containers.nix`). Containers
  drop privileges via `user = "${serverUid}:${serverGid}"` so files on
  NFS-mounted volumes line up with the Synology UID/GID (1029/1030 + 65536).
- **Networking:** bind container ports to `127.0.0.1` only — Caddy fronts
  everything externally. Containers reach host services (e.g. postgres) via
  `host.containers.internal`, which resolves to the podman bridge gateway;
  the bridge is in `networking.firewall.trustedInterfaces`.
- **Reverse proxy:** add a `services.caddy.virtualHosts.<appHost>.extraConfig`
  entry inside the same module. Hostnames are derived from
  `hostSpec.serverDomain`, e.g. `"mealie.${hostSpec.serverDomain}"`.
- **Image versions:** pin the tag in the module and put a renovate annotation
  above it so updates are automated:
  ```nix
  # renovate: datasource=docker depName=ghcr.io/mealie-recipes/mealie
  image = "ghcr.io/mealie-recipes/mealie:v3.16.0";
  ```
- **Volumes:** state lives under `/var/lib/containers/<appname>` (single
  prefix lets the backup module cover every app automatically). Create the
  directory via `systemd.tmpfiles.rules` owned by the server UID/GID and
  bind-mount it into the container.
- **Postgres:** add the database/user via `services.postgresql.ensureDatabases`
  / `ensureUsers`. Set the role's password from a sops secret in a small
  oneshot service that runs `after = [ "postgresql-setup.service" ]` and
  `before = [ "podman-<app>.service" ]` — don't use
  `postgresql-setup.postStart`, since the secret may not be decrypted yet
  when that runs.
- **Secrets:** declare per-app entries under `sops.secrets."<app>/..."` with
  `sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml"`. For env vars the
  container needs, render a `sops.templates."<app>.env"` and pass it via
  `environmentFiles`; set `restartUnits = [ "podman-<app>.service" ]` so the
  container picks up rotated secrets.

### Operating containers

The systemd services that run containers (e.g. `podman-mealie.service`) are
root-owned, so use `sudo podman ps`, `sudo podman logs <name>`, etc. for
inspection. Rootless podman as your user works for ad-hoc containers you
start yourself, but it can't see the system-managed ones.

### Backups and restore

Server hosts run `modules/system/server-backups.nix`, which composes:

- `services.postgresqlBackup` — daily `pg_dumpall` to
  `/var/backup/postgresql` (gzip, runs at 02:00).
- `services.restic.backups.server` — daily restic snapshot of
  `/var/backup/postgresql` and `/var/lib/containers` to
  `/mnt/backups/restic/${hostName}` on the NFS-mounted Synology share
  (runs at 03:00 with a randomized delay). Retention:
  `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

Only server-local app state is in scope. NAS-resident media under
`/mnt/content` is protected NAS-side via Synology snapshots / Hyper Backup,
not by restic.

The restic repo path is read-write from the host, so a compromised server
or fat-fingered `rm` could in principle delete its own backups. Mitigate
by enabling **Synology snapshots** on the `server-{dev,prod}-backups`
shares — that's an out-of-band, client-immutable copy.

#### Restore runbook (catastrophic rebuild)

Recovery is an explicit operator action — there's intentionally no
automatic restore on container start, since "first boot" and "restore
after data loss" are different decisions.

1. **Reinstall the host:**
   ```bash
   task bootstrap:reinstall HOST=<host> DEST=<ip>
   ```
   NixOS comes back up with the same module set; container services will
   fail because their state directories are empty.

2. **Pull state back from restic:**
   ```bash
   sudo restic -r /mnt/backups/restic/<host> \
     --password-file /run/secrets/restic/password \
     restore latest --target /
   ```
   This repopulates `/var/lib/containers/*` and `/var/backup/postgresql`.

3. **Restore PostgreSQL.** With the default `services.postgresqlBackup`
   config, the dump is a single `pg_dumpall` output at
   `/var/backup/postgresql/all.sql.gz` (roles + every database). Replay
   it into the running cluster:

   ```bash
   sudo -u postgres bash -c 'zcat /var/backup/postgresql/all.sql.gz | psql -v ON_ERROR_STOP=0 postgres'
   ```

   Expect benign errors for roles/databases that NixOS's `ensureUsers` /
   `ensureDatabases` has already created (`role "mealie" already exists`,
   etc.) — they don't stop the data-loading `\connect` blocks that follow.
   `ON_ERROR_STOP=0` keeps psql going past those.

   If you'd rather start clean (and you're sure no other apps' data is in
   the cluster), stop postgres, wipe its data dir, and let NixOS reinit
   before replaying:

   ```bash
   sudo systemctl stop postgresql
   sudo rm -rf /var/lib/postgresql/<major>/*
   sudo systemctl start postgresql        # creates empty cluster + roles
   sudo -u postgres bash -c 'zcat /var/backup/postgresql/all.sql.gz | psql postgres'
   ```

   App-specific role passwords (the sops-managed `ALTER USER ... WITH
   PASSWORD ...` flow used by mealie) re-apply on the next service start
   via the per-app `<app>-db-password.service` units, so you don't need
   to set them by hand.

4. **Restart the app containers:**
   ```bash
   sudo systemctl restart 'podman-*.service'
   ```

For per-app restores (e.g. just mealie), point `restic restore` at
`--include /var/lib/containers/mealie` and skip the postgres step unless
the database is also wrecked.

### PostgreSQL major-version upgrades

`services.postgresql.package` is pinned to a specific major
(`postgresql_17` at time of writing) in `modules/system/postgresql.nix` so
that rebuilds never silently dump-and-restore the cluster. Major upgrades
are a manual operation, following the canonical NixOS recipe:

- [NixOS manual — Upgrading PostgreSQL](https://nixos.org/manual/nixos/stable/#module-services-postgres-upgrading)

The short version: stop `postgresql.service`, run the
`upgrade-pg-cluster` script (made available by temporarily setting both the
old and new packages in a shell), bump `package = pkgs.postgresql_<new>` in
this repo, rebuild, and verify before deleting the old data directory.

## Secrets Management

Secrets are stored in a private `nix-secrets` repository pulled in as a flake
input and managed with [sops-nix](https://github.com/Mic92/sops-nix).

- Secrets are YAML files in the `nix-secrets` repo (`sops/shared.yaml`,
  `sops/<hostname>.yaml`)
- Age encryption keys are bootstrapped from host SSH keys
  (`/etc/ssh/ssh_host_ed25519_key`)
- Home-manager secrets use `~/.config/sops/age/keys.txt`
- Configured in `modules/system/sops.nix` with both NixOS and home-manager
  integration

## Task Automation

Common operations are automated via `Taskfile.yaml`:

| Command                                   | Description                                                                      |
| ----------------------------------------- | -------------------------------------------------------------------------------- |
| `task rebuild`                            | Rebuild current NixOS host                                                       |
| `task rebuild:<host>`                     | Rebuild a specific NixOS host                                                    |
| `task build_darwin:<host>`                | Rebuild a nix-darwin host                                                        |
| `task build_home:<target>`                | Rebuild standalone home-manager                                                  |
| `task build`                              | Build a host without switching (default: luna)                                   |
| `task build-all`                          | Build all NixOS host configurations                                              |
| `task update`                             | Update flake inputs                                                              |
| `task lint`                               | Run statix and deadnix                                                           |
| `task fmt`                                | Format all Nix files with nixfmt                                                 |
| `task check`                              | Full pre-push check (format + lint + flake check)                                |
| `task iso`                                | Build the installer/recovery ISO                                                 |
| `task garbage_collect`                    | Remove store objects older than 7 days                                           |
| `task bootstrap:new HOST=x DEST=ip`       | New host pipeline: install, hwconfig, secrets setup, sync + rebuild              |
| `task bootstrap:reinstall HOST=x DEST=ip` | Reinstall existing host: install + sync + rebuild (no secrets pause)             |
| `task bootstrap:install HOST=x DEST=ip`   | Run nixos-anywhere to install NixOS; prints age key at end                       |
| `task bootstrap:hwconfig HOST=x DEST=ip`  | Extract hardware-configuration.nix from target                                   |
| `task bootstrap:hostkey HOST=x DEST=ip`   | Re-derive age key from live host SSH key (fallback if install output was missed) |
| `task bootstrap:secrets HOST=x DEST=ip`   | Add host age key to nix-secrets, create host secrets, commit                     |
| `task bootstrap:sync HOST=x DEST=ip`      | Rsync nixos and nix-secrets to target                                            |
| `task bootstrap:rebuild HOST=x DEST=ip`   | Run nixos-rebuild switch on target                                               |

## Bootstrapping a New Host

### Prerequisites

- Target machine booted into a NixOS ISO (use `task iso` for a custom one)
- This repo and `nix-secrets` cloned on the source machine (e.g.
  `~/src/{nixos,nix-secrets}`)
- A key on the source machine that can decrypt secrets
  (`~/.config/sops/age/keys.txt`)

### 1. Create host config files

Before bootstrapping, the target host needs configuration in this repo:

- `hostSpecs/newhostname.nix` — host specification (copy from an existing host)
- `modules/hosts/_newhostname-disks.nix` — disko disk layout
- `modules/hosts/newhostname.nix` — host module (which modules to compose)

Also add the new host to `hostSpecs/default.nix` imports list, then `git add`
all new files — the flake uses `git+file://` and won't see untracked files.

The hardware config is automatically fetched from the target during
`bootstrap:install` if the file doesn't exist yet. It gets refreshed from
the installed OS by `bootstrap:hwconfig` after reboot.

### 2. Run the bootstrap

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
task bootstrap:rebuild  HOST=newhostname DEST=192.168.1.50  # remote nixos-rebuild switch
```

### 3. Secrets setup

`bootstrap:new` handles secrets automatically via `bootstrap:secrets`, which:

1. Derives the host's age key from its SSH host key
2. Adds the key to `nix-secrets/.sops.yaml` (host anchor + creation rules)
3. Creates `nix-secrets/sops/newhostname.yaml` with a generated SSH key
4. Re-encrypts shared secrets for the new host
5. Commits nix-secrets (locally — not pushed)

To run this step manually (e.g. after a partial re-run):

```bash
task bootstrap:secrets HOST=newhostname DEST=192.168.1.50
```

The rebuild uses `--override-input nix-secrets path:../nix-secrets`, so the
local commit is sufficient during bootstrap. After the host is up, push
nix-secrets and run `nix flake update nix-secrets` in this repo so normal
rebuilds work without the override.

### Reinstalling an existing host

For hosts that already have keys and secrets configured, use
`bootstrap:reinstall` — it skips the secrets setup pause:

```bash
task bootstrap:reinstall HOST=existinghost DEST=192.168.1.50
```

### VM testing

A `testvm` host config is included for bootstrap testing. Build the ISO if
needed (`task iso`), then:

```bash
# Create a quickemu config (adjust paths as needed)
mkdir -p ~/vms/testvm
cat > ~/vms/testvm.conf <<'EOF'
guest_os="linux"
disk_img="/home/ipreston/vms/testvm/testvm.qcow2"
iso="/home/ipreston/src/nixos/latest.iso"
disk_size="20G"
ram="4G"
cpu_cores="2"
EOF

# Boot the VM headlessly with a fixed SSH port
quickemu --vm ~/vms/testvm.conf --display none --ssh-port 22222
```

Then run the full bootstrap pipeline using `127.0.0.1` (not `localhost` — QEMU
only forwards IPv4):

```bash
task bootstrap:new HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
```

Or run individual steps for debugging:

```bash
task bootstrap:install  HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
# Wait for reboot, then:
task bootstrap:hwconfig HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
task bootstrap:hostkey  HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
# Follow the secrets steps above, then:
task bootstrap:sync     HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
task bootstrap:rebuild  HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
```

To start fresh, delete the VM disk and OVMF vars:

```bash
rm -f ~/vms/testvm/testvm.qcow2 ~/vms/testvm/OVMF_VARS.fd
```

## Guidance and Resources

- [NixOS.org Manuals](https://nixos.org/learn/)
- [Official Nix Documentation](https://nix.dev)
  - [Best practices](https://nix.dev/guides/best-practices)
- [Noogle](https://noogle.dev/) - Nix API reference documentation.
- [Official NixOS Wiki](https://wiki.nixos.org/)
- [NixOS Package Search](https://search.nixos.org/packages)
- [NixOS Options Search](https://search.nixos.org/options?)
- [Home Manager Option Search](https://home-manager-options.extranix.com/)
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/) - an excellent
  introductory book by Ryan Yin
