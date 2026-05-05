# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Hosts](#hosts)
- [Module System](#module-system)
- [Server App Pattern](#server-app-pattern)
- [Jellyfin](#jellyfin)
- [Authentik (SSO)](#authentik-sso)
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
- **NFS UID alignment (containers AND native services):** anything that
  reads or writes the NFS-mounted Synology share (under `/mnt/content`,
  `/mnt/backups`, etc.) must run as `server-${env}:servers`
  (1029/1030 + 65536). The NAS enforces UID-based access — a service
  running as its own per-package system user (e.g. the upstream
  jellyfin module's default `jellyfin:jellyfin`) will silently see an
  empty directory listing on the NFS mount. For native modules that
  expose `user`/`group` options (jellyfin, etc.), pin them to
  `server-${hostSpec.serverEnvironment}` and `servers`. Existing
  `/var/lib/<app>` state created with the wrong owner needs a one-time
  `sudo chown -R server-<env>:servers` on first deploy — `tmpfiles`
  rules with type `d` won't re-chown an existing directory.
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

The restic password lives in `shared.yaml` (one value, all servers), so
any host can decrypt any other host's repo for cross-host recovery
testing. Each host still mounts the *other* environment's backup share
read-only at `/mnt/<otherEnv>-backups` (see `nfsclient.nix`), so e.g.
restoring prod state onto a dev host is a one-liner pointing restic at
`/mnt/prod-backups/restic/<prod-host>` — no extra credentials needed.

The restic repo path is read-write from the host that owns it, so a
compromised server or fat-fingered `rm` could in principle delete its
own backups. Mitigate by enabling **Synology snapshots** on the
`server-{dev,prod}-backups` shares — that's an out-of-band,
client-immutable copy.

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

#### Cross-host recovery testing (prod → dev)

Same flow, but pointed at the other env's repo via the cross-mount:

```bash
sudo restic -r /mnt/prod-backups/restic/<prod-host> \
  --password-file /run/secrets/restic/password \
  restore latest --target /tmp/prod-restore
```

`--target /tmp/prod-restore` keeps the prod data sandboxed instead of
overwriting dev's live `/var/lib/containers`. From there you can spot-check
files, replay the postgres dump into a scratch database, etc.

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

## Jellyfin

`modules/apps/jellyfin.nix` deploys jellyfin as a native systemd unit
(no container) pinned to the `server-${env}:servers` UID/GID so it
can read media off the NFS-mounted Synology share. Restic snapshots
`/var/lib/jellyfin` and an extra staging dir at `/var/backup/jellyfin`
that holds `sqlite3 .backup` dumps of `library.db` / `jellyfin.db`,
written by a pre-hook before each restic run.

### Hardware-accelerated transcoding

The host needs `modules/hardware/intel-quicksync.nix` (Intel iGPU)
included in its host module — see `modules/hosts/hpp-1.nix`.
`server-${env}` already has `video` and `render` supplementary groups
from `modules/system/server-users.nix`, so once the QSV module is
loaded `/dev/dri/renderD128` is reachable by jellyfin.

The remaining setup is **manual in the jellyfin web UI** (the
resulting config lives in `/var/lib/jellyfin/config/encoding.xml` and
is captured by restic, so this is a one-time-per-host step):

1. Dashboard → Playback → Transcoding.
2. **Hardware acceleration:** Intel QuickSync (QSV).
3. **VA-API device:** `/dev/dri/renderD128`.
4. Enable hardware decoding for the codecs you care about (H.264,
   HEVC, VP9 are safe on HD 630 and newer).
5. Enable hardware encoding.
6. Enable Tone mapping (works because `intel-compute-runtime` ships
   the OpenCL runtime via `intel-quicksync.nix`).

To verify the host stack before configuring the UI:

```bash
ssh <host> 'nix-shell -p libva-utils --run "vainfo --display drm --device /dev/dri/renderD128"'
```

Should report `Driver version: Intel iHD driver` and a list of
`VAProfile*` entries. To confirm the GPU is actually doing work
during a transcode, watch `intel_gpu_top` while jellyfin transcodes
a stream:

```bash
ssh <host> 'nix-shell -p intel-gpu-tools --run "sudo intel_gpu_top"'
```

The Render/3D and Video engines should show activity.

## Authentik (SSO)

`modules/apps/authentik.nix` deploys Authentik as native systemd units via
the [`nix-community/authentik-nix`](https://github.com/nix-community/authentik-nix)
flake input — *not* containers. The module's `services.authentik` runs three
units (`authentik`, `authentik-worker`, `authentik-migrate`) under
`DynamicUser=true`, talks to the shared postgres over the unix socket via
peer auth (so no role password is needed), and uses the unnamed NixOS
`services.redis.servers.""` instance on `localhost:6379`. Caddy fronts it
at `authentik.${hostSpec.serverDomain}`.

### Declarative configuration via blueprints

Groups, users, applications, OAuth/proxy providers, and group bindings are
all managed as Authentik **blueprints** (YAML, applied idempotently by the
worker on a periodic Celery task and on startup). No terraform, no UI
clicks. Two starter blueprints live under `modules/apps/authentik-blueprints/`:

- `groups.yaml` — homelab groups (Downloads, Grafana Admins, Home,
  Infrastructure, Media, Monitoring, Users).
- `users.yaml` — the `ian` admin user, in all groups + built-in
  `authentik Admins`. The password reads from `!Env IAN_PASSWORD`, which
  is rendered into the systemd `EnvironmentFile` from sops.

The module merges its blueprints with the upstream-bundled set into a
single `blueprints_dir` via `pkgs.runCommandLocal` + `cp -rL`. **Do not
use `pkgs.symlinkJoin`** here: authentik's `retrieve_file` calls
`Path(...).resolve()` and rejects anything that resolves outside
`blueprints_dir`, so symlink-joined entries (which dereference back to
their original store paths) all fail with "Invalid blueprint path".
Real files via `cp -L` are required.

### Adding an app to Authentik

Each app module that wants SSO drops its own blueprint(s) and any new
secrets via `myAuthentik.extraBlueprints` and an `lib.mkAfter` chunk on
`sops.templates."authentik.env"`. Blueprint secrets (`client_secret`,
token `key`, user `password`) **must** be passed via `!Env VAR_NAME` so
they never land in `/nix/store`; add the matching env line to the
authentik env template.

Sketch (Grafana OIDC):

```nix
# modules/apps/grafana.nix
{ inputs, ... }: {
  flake.modules.nixos.grafana = { config, lib, ... }: {
    sops.secrets."grafana/oidc_client_secret" = {
      sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
      restartUnits = [ "authentik.service" "authentik-worker.service" ];
    };
    sops.templates."authentik.env".content = lib.mkAfter ''
      GRAFANA_OIDC_CLIENT_ID=${config.sops.placeholder."grafana/oidc_client_id"}
      GRAFANA_OIDC_CLIENT_SECRET=${config.sops.placeholder."grafana/oidc_client_secret"}
    '';
    myAuthentik.extraBlueprints = [ ./grafana-blueprints ];
    # ... grafana-the-app config
  };
}
```

```yaml
# modules/apps/grafana-blueprints/grafana.yaml
version: 1
metadata: { name: grafana }
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: prov-grafana
    identifiers: { name: grafana }
    attrs:
      client_type: confidential
      client_id: !Env GRAFANA_OIDC_CLIENT_ID
      client_secret: !Env GRAFANA_OIDC_CLIENT_SECRET
      authentication_flow: !Find [authentik_flows.flow, [slug, default-authentication-flow]]
      authorization_flow:  !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow:   !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-openid"]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-email"]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-profile"]]
      redirect_uris:
        - { matching_mode: strict, url: "https://grafana.dnix.ipreston.net/login/generic_oauth" }
  - model: authentik_core.application
    id: app-grafana
    identifiers: { slug: grafana }
    attrs:
      name: Grafana
      provider: !KeyOf prov-grafana
      meta_launch_url: https://grafana.dnix.ipreston.net
  - model: authentik_policies.policybinding
    identifiers: { target: !KeyOf app-grafana, order: 0 }
    attrs:
      group: !Find [authentik_core.group, [name, Grafana Admins]]
      enabled: true
```

Reference: [model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
[YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).

### Forward-auth via Caddy

For apps that don't speak OIDC themselves (AlertManager, Prometheus,
Longhorn-style admin UIs), gate them via Authentik's embedded outpost +
Caddy's `forward_auth`. The authentik module exports a reusable Caddy
snippet `(authentik_forward_auth)` that protected virtualHosts can
import:

```nix
services.caddy.virtualHosts."alertmanager.${hostSpec.serverDomain}".extraConfig = ''
  reverse_proxy localhost:9093
  import authentik_forward_auth
'';
```

The matching proxy provider + application + binding go in that app's
blueprint. The snippet handles both the `forward_auth` directive (auth
check on every request) and the `handle_path /outpost.goauthentik.io/*`
block (callback routes).

### YAML lint exclusion

Authentik's custom YAML tags (`!Env`, `!Find`, `!KeyOf`) aren't accepted
by pyyaml's safe loader, so `modules/apps/authentik-blueprints/` is
excluded from the `check-yaml` pre-commit hook in
`modules/flake/git-hooks.nix`. Add new blueprint paths under that prefix
or extend the excludes list.

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
