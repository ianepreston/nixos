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
│   ├── profiles/          # Composable profiles (base, darwin-base, server, server-apps, workstation)
│   │   └── _ssh-keys/    # Public SSH keys
│   ├── system/            # System-level modules (sops, ssh, caddy, postgresql, mariadb, oci-containers, server-backups, observability, tailscale, …). Cross-cutting option surfaces (myCaddy.apps, myPostgresApp, myHomepage.tiles, mySqliteQuiesce.apps) are declared inline next to the service that consumes them.
│   │   └── _hm-core/     # Core home-manager config (git, zsh, starship, neovim, direnv, packages, platform-specific)
│   ├── apps/              # Server-app modules (jellyfin, mealie, miniflux, authentik, homepage, …) plus per-app blueprint dirs
│   ├── hardware/          # Hardware-specific modules (intel-quicksync, nvidia, yubikey, keyboards, rgb, xreal-headset)
│   ├── desktop/           # Desktop environment modules (gnome, audio, gaming, flatpak, themes, sunshine, quickemu)
│   │   └── _gnome/       # GNOME-specific sub-modules (dconf, cursor, stylix)
│   ├── programs/          # Application modules (browser, ghostty, comms, media, obsidian, etc.)
│   └── hosts/             # Per-host configurations and hardware/disk definitions
├── scripts/               # Utility scripts (dconf capture, sops check, system-install)
└── assets/                # Static assets (wallpapers)
```

## Hosts

| Host                  | Platform       | Config Type            | Description                                                              |
| --------------------- | -------------- | ---------------------- | ------------------------------------------------------------------------ |
| **luna**              | x86_64-linux   | `nixosConfigurations`  | MSI GS43VR laptop — workstation + GNOME + gaming + NVIDIA GTX 1060       |
| **terra**             | x86_64-linux   | `nixosConfigurations`  | AMD desktop — workstation + GNOME + gaming + NVIDIA RTX 5080 + streaming |
| **hpp-1**             | x86_64-linux   | `nixosConfigurations`  | Dev server — `server` + `server-apps` + Intel QuickSync transcoding      |
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
`modules/apps/<appname>.nix` and are composed into the `server-apps`
profile (which is itself layered on top of `server` — the core
infra profile that owns caddy, postgres, authentik, observability,
backups, etc.). Each app module is self-contained: it declares the
OCI container or native service, contributes a Caddy route, any
database/user it needs, its sops secrets, an authentik blueprint
(if SSO-protected), and a homepage tile — all in one place.
`modules/apps/mealie.nix` is the canonical example for a
containerized, postgres-backed, OIDC-integrated app.

App modules contribute to a small set of aggregator options declared
inline next to the services that consume them (in `modules/system/` or,
for `myAuthentik.*`, `modules/apps/authentik.nix`):

- `myCaddy.apps.<name>` — hands a route block to the wildcard
  `*.${serverDomain}` virtualHost (one wildcard cert covers every
  app, dodging Let's Encrypt rate limits).
- `myPostgresApp.<name>` — provisions the database/role plus a
  sops-managed password rotation oneshot, so containerized apps
  connecting over TCP get a passworded role without per-app
  boilerplate.
- `myAuthentik.oidcApps.<name>` — for apps that speak OIDC: declares
  the sops secret pair, contributes a blueprint dir, stacks the
  necessary worker-side env vars onto authentik, and optionally
  renders a per-app env file consumed by the upstream image.
- `myAuthentik.forwardAuthApps.<name>` — for apps that don't speak
  OIDC: generates the proxy provider/application/policy binding
  blueprint and a Caddy `forward_auth` route in one go (the embedded
  outpost's `providers` list is owned by a single merged blueprint
  per host so apps don't clobber each other).
- `myHomepage.tiles.<name>` — adds a tile to the homepage dashboard.

### Conventions

- **Registration:** `flake.modules.nixos.<appname>`, then add the name to the
  `imports` list in `modules/profiles/server-apps.nix`.
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
- **Reverse proxy:** add a `myCaddy.apps.<name>` entry inside the same
  module — `host` defaults to `<name>.${hostSpec.serverDomain}` and
  `routeConfig` is the body of the `handle` block (typically a
  `reverse_proxy localhost:<port>` directive). The wildcard vhost in
  `modules/system/caddy.nix` folds these into one matcher per app, so
  one wildcard cert (DNS-01 via Cloudflare) covers them all.
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
- **Postgres:** declare `myPostgresApp.<name>.consumerService =
  "podman-<app>.service"` (or whatever unit consumes the role). The
  helper in `modules/system/postgresql.nix` handles the
  database/role via `ensureDatabases`/`ensureUsers`, the sops secret,
  and the rotate-on-secret-change oneshot wired `before` the consumer
  unit. The app is responsible for plumbing
  `${config.sops.placeholder."<app>/db_password"}` into its own env
  file (e.g. as `POSTGRES_PASSWORD`) and pointing the upstream
  service at `host.containers.internal:5432` with the matching role
  + db name.
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
- `services.mysqlBackup` — daily mariadb dump to `/var/backup/mysql`
  (also at 02:00). Same restic snapshot picks both engines up.
- `services.restic.backups.server` — daily restic snapshot of
  `/var/backup/postgresql`, `/var/backup/mysql`, and
  `/var/lib/containers` to `/mnt/backups/restic/${hostName}` on the
  NFS-mounted Synology share (runs at 03:00 with a 30-minute
  randomized delay). Retention:
  `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

Apps that keep state outside `/var/lib/containers` (e.g. the native
*arr stack, jellyfin, kavita, komga, audiobookshelf, readeck) extend
`services.restic.backups.server.paths` themselves with their own
`/var/lib/<app>` tree; the listOf merges via concat so the base paths
stay intact.

SQLite-backed native apps additionally opt into the `mySqliteQuiesce`
helper (`modules/system/sqlite-quiesce.nix`), which runs `sqlite3
.backup` for each declared database into `/var/backup/sqlite/<app>/`
immediately before each restic run. The staging root is added to the
restic paths automatically, so each snapshot contains both the (hot,
possibly torn) live file under `/var/lib/<app>/...` and a
guaranteed-consistent copy under `/var/backup/sqlite/<app>/`. Apps
currently using it: jellyfin, sonarr, radarr, prowlarr, bazarr,
kavita, komga, readeck, audiobookshelf.

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

#### Per-app restore

The catastrophic rebuild restores everything. To recover just one app
without touching the rest of the host, scope both the restic include
and the postgres replay. The three apps in this repo each illustrate a
different shape — pick the one that matches what you're restoring.

The postgres examples below replay the *current* on-disk dump at
`/var/backup/postgresql/all.sql.gz` (refreshed nightly at 02:00). To
restore from an *older* snapshot, pull that snapshot's dump to a temp
path first:

```bash
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password \
  restore <snapshot-id> --target /tmp/restore \
  --include /var/backup/postgresql
# then point zcat at /tmp/restore/var/backup/postgresql/all.sql.gz
```

`pg_dumpall` writes one combined file with every database and role.
The awk filter below extracts a single database's section by tracking
`\connect <name>` markers. Roles are managed by NixOS `ensureUsers`
and don't need to be replayed.

##### Containerized app with volume + postgres database (mealie)

Mealie has both on-disk state (`/var/lib/containers/mealie` — uploaded
recipe images, user assets) and database state (the `mealie` postgres
db — recipes, users, OIDC mappings). The two reference each other, so
**restore both from the same restic snapshot** — mixing eras leaves
broken image references in recipe rows.

```bash
# 1. Stop the container so nothing writes during restore.
sudo systemctl stop podman-mealie.service

# 2. Restore the volume from restic.
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password \
  restore latest --target / --include /var/lib/containers/mealie

# 3. Drop and recreate the database, then replay just the mealie
#    section of the pg_dumpall output. The mealie role already exists
#    (NixOS ensureUsers); its password is unchanged.
sudo -u postgres dropdb --if-exists mealie
sudo -u postgres createdb -O mealie mealie
zcat /var/backup/postgresql/all.sql.gz | awk '
  /^\\connect / { db = $2; gsub(/"/, "", db); in_target = (db == "mealie"); next }
  in_target { print }
' | sudo -u postgres psql -v ON_ERROR_STOP=1 mealie

# 4. Restart. mealie-db-password.service is wantedBy podman-mealie
#    and re-applies the sops-managed role password before the
#    container comes up, so authentication keeps working.
sudo systemctl start podman-mealie.service
```

Same pattern for any future containerized app with a postgres
database: substitute the unit name, volume path, and database name.

##### 12-factor app with all state in postgres (miniflux)

Miniflux is a single Go binary running under `DynamicUser=true` with
no persistent on-disk state — feeds, entries, read/unread flags, and
OIDC user mappings all live in the `miniflux` postgres database.
Restore is just the database half of the mealie flow:

```bash
sudo systemctl stop miniflux.service
sudo -u postgres dropdb --if-exists miniflux
sudo -u postgres createdb -O miniflux miniflux
zcat /var/backup/postgresql/all.sql.gz | awk '
  /^\\connect / { db = $2; gsub(/"/, "", db); in_target = (db == "miniflux"); next }
  in_target { print }
' | sudo -u postgres psql -v ON_ERROR_STOP=1 miniflux
sudo systemctl start miniflux.service
```

Authentik fits the same shape (everything in the `authentik` postgres
db, no host state worth restoring) — same recipe with the names
swapped.

##### Native service with on-disk state + SQLite (jellyfin, *arr, kavita, …)

Jellyfin keeps everything under `/var/lib/jellyfin` — XML config,
plugins, metadata cache, and the library SQLite database at
`/var/lib/jellyfin/data/jellyfin.db`. There's no postgres to restore.
The wrinkle is that the live SQLite file can be torn mid-write inside
a restic snapshot; `jellyfin-sqlite-backup.service` (from the
`mySqliteQuiesce` helper) runs `sqlite3 .backup` into
`/var/backup/sqlite/jellyfin/` immediately before each restic run,
and **those staged copies — not the live ones — are the
authoritative recovery source.**

```bash
# 1. Stop the service so nothing writes during restore.
sudo systemctl stop jellyfin.service

# 2. Restore both the live tree and the staging dir from the same
#    snapshot.
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password \
  restore latest --target / \
  --include /var/lib/jellyfin \
  --include /var/backup/sqlite/jellyfin

# 3. Swap the live SQLite file for the consistent staged copy.
#    Use the env from the host's hostSpec (server-dev or server-prod);
#    `id server-prod` / `id server-dev` confirms which one exists.
sudo install -o server-prod -g servers -m 0640 \
  /var/backup/sqlite/jellyfin/jellyfin.db /var/lib/jellyfin/data/jellyfin.db

# 4. Restart. Jellyfin will reopen the database and reuse the
#    cached metadata; no library rescan is needed.
sudo systemctl start jellyfin.service
```

Media files themselves live on the NAS under `/mnt/content` and are
out of scope for restic — Synology snapshots cover them.

The same pattern applies to every app that opts into `mySqliteQuiesce`
(sonarr, radarr, prowlarr, bazarr, kavita, komga, readeck,
audiobookshelf): stop the unit, `restic restore` both `/var/lib/<app>`
(or `/var/lib/private/<app>` for DynamicUser apps like prowlarr and
readeck) and `/var/backup/sqlite/<app>`, then `install` each staged
`.db` over the live path declared in the app's module. Check
`mySqliteQuiesce.apps.<app>.databases` in the module for the exact
source paths to overwrite (e.g. sonarr → `/var/lib/sonarr/.config/
NzbDrone/{sonarr,logs}.db`, bazarr → `/var/lib/bazarr/db/bazarr.db`).
Match the file owner to the service's user/group (`server-${env}:
servers` for the NFS-aligned apps).

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
(`postgresql_18` at time of writing) in `modules/system/postgresql.nix`
so that rebuilds never silently dump-and-restore the cluster. Major
upgrades are a manual operation. The canonical reference is the
[NixOS manual section](https://nixos.org/manual/nixos/stable/#module-services-postgres-upgrading);
the concrete recipe that worked here for 17 → 18 was:

```bash
# 0. Fresh dump + restic snapshot as a known-good rollback point.
ssh <host> sudo systemctl start postgresqlBackup.service
ssh <host> sudo systemctl start restic-backups-server.service

# 1. Stage the new postgres closure on the target so the deploy at the
#    end is just a switch, not a copy.
NEW=$(nix build --no-link --print-out-paths nixpkgs#postgresql_18)
OLD=$(nix build --no-link --print-out-paths nixpkgs#postgresql_17)
nix copy --to ssh-ng://<host> "$NEW"

# 2. Stop every postgres consumer + the cluster itself.
ssh <host> sudo systemctl stop \
  authentik.service authentik-worker.service \
  mealie.service miniflux.service \
  paperless-{web,scheduler,task-queue,consumer}.service \
  podman-tandoor.service \
  postgresql.service

# 3. initdb the new cluster with **matching encoding, locale, and
#    checksum flag** as the old one — pg_upgrade refuses if any of the
#    three differs. Check the old cluster first if unsure:
#      sudo -u postgres psql -tAc "SHOW server_encoding; SHOW data_checksums"
#      sudo -u postgres psql -tAc "SELECT datname, datcollate FROM pg_database"
#    The 17 cluster here was UTF8 / en_CA.UTF-8 / checksums off, so:
ssh <host> "sudo install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18 && \
  sudo -u postgres $NEW/bin/initdb \
    --encoding=UTF8 --locale=en_CA.UTF-8 --no-data-checksums \
    -D /var/lib/postgresql/18"

# 4. Run pg_upgrade in copy mode (slower than --link, but keeps the
#    old datadir untouched as a rollback). Run from /tmp so pg_upgrade's
#    log files don't clutter postgres' home.
ssh <host> "sudo -u postgres bash -c 'cd /tmp && $NEW/bin/pg_upgrade \
  --old-bindir=$OLD/bin --new-bindir=$NEW/bin \
  --old-datadir=/var/lib/postgresql/17 --new-datadir=/var/lib/postgresql/18'"

# 5. Bump package = pkgs.postgresql_<new> in modules/system/postgresql.nix,
#    then deploy. The NixOS module will skip initdb (sees PG_VERSION=18),
#    apply pg_hba.conf, and start postgres on the upgraded datadir;
#    ensureDatabases/ensureUsers + *-db-password.service no-op against
#    the already-present roles. Consumers come back up automatically.
task deploy:<host>

# 6. Refresh planner stats (pg_upgrade doesn't carry them over).
ssh <host> "sudo -u postgres $NEW/bin/vacuumdb --all --analyze-in-stages --missing-stats-only"

# 7. Smoke-test the apps. Then, after a few days, delete the old datadir:
ssh <host> sudo rm -rf /var/lib/postgresql/17
```

Rollback (any step before 5): revert the package pin in
`modules/system/postgresql.nix` and `task deploy:<host>`. The old
datadir under `/var/lib/postgresql/<old>` is untouched by copy-mode
`pg_upgrade`, so postgres just resumes there.

## Jellyfin

`modules/apps/jellyfin.nix` deploys jellyfin as a native systemd unit
(no container) pinned to the `server-${env}:servers` UID/GID so it
can read media off the NFS-mounted Synology share. Restic snapshots
`/var/lib/jellyfin` plus the `mySqliteQuiesce` staging dir at
`/var/backup/sqlite/jellyfin/`, which holds a `sqlite3 .backup` dump
of `jellyfin.db` written by a pre-hook before each restic run.

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

- `groups.yaml` — homelab groups (Home, Infrastructure, Users).
- `users.yaml` — the `ian` admin user (in `authentik Admins`, Home,
  Infrastructure, Users) plus a few "Pattern A" onboarding users that
  have no `password` attr yet and authenticate after running through
  the recovery flow. `ian`'s password reads from `!Env IAN_PASSWORD`,
  which is rendered into the systemd `EnvironmentFile` from sops.
- `hardening.yaml` / `recovery.yaml` — bundled hardening and recovery
  flow tweaks.

The module merges its blueprints with the upstream-bundled set into a
single `blueprints_dir` via `pkgs.runCommandLocal` + `cp -rL`. **Do not
use `pkgs.symlinkJoin`** here: authentik's `retrieve_file` calls
`Path(...).resolve()` and rejects anything that resolves outside
`blueprints_dir`, so symlink-joined entries (which dereference back to
their original store paths) all fail with "Invalid blueprint path".
Real files via `cp -L` are required.

### Adding an OIDC app to Authentik

Apps that speak OIDC natively register via the `myAuthentik.oidcApps`
aggregator from `modules/apps/authentik.nix`. The aggregator
generates the sops secret pair, contributes the per-app blueprint
dir, and stacks one merged worker-side env file onto authentik so
blueprint `!Env` placeholders resolve. Apps that read OIDC creds
from env vars (mealie, miniflux, paperless-ngx, tandoor, komga,
actualbudget) get their own per-app env file too; apps that store
creds in their own DB/UI (audiobookshelf, kavita, seerr) opt out via
`clientCredsInAppEnv = false`.

Blueprint secrets must reference `!Env <APP>_OIDC_CLIENT_ID` /
`<APP>_OIDC_CLIENT_SECRET` (uppercased app name with hyphens →
underscores) so they never land in `/nix/store`.

Sketch (Mealie — see `modules/apps/mealie.nix` for the real thing):

```nix
# modules/apps/mealie.nix
_: {
  flake.modules.nixos.mealie = { config, hostSpec, ... }: {
    myPostgresApp.mealie.consumerService = "podman-mealie.service";

    myAuthentik.oidcApps.mealie = {
      blueprintsDir = ./mealie-blueprints;
      appRestartUnit = "podman-mealie.service";
      extraEnvLines = ''
        POSTGRES_PASSWORD=${config.sops.placeholder."mealie/db_password"}
      '';
      homepage = {
        group = "Consumption";
        icon = "mealie";
        description = "Recipe manager";
      };
    };

    myCaddy.apps.mealie = {
      # host defaults to "mealie.${hostSpec.serverDomain}"
      routeConfig = "reverse_proxy localhost:9925";
    };

    # ... oci-container declaration that consumes
    # config.sops.templates."mealie.env".path
  };
}
```

```yaml
# modules/apps/mealie-blueprints/mealie.yaml
version: 1
metadata: { name: mealie }
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: prov-mealie
    identifiers: { name: mealie }
    attrs:
      client_type: confidential
      client_id: !Env MEALIE_OIDC_CLIENT_ID
      client_secret: !Env MEALIE_OIDC_CLIENT_SECRET
      authentication_flow: !Find [authentik_flows.flow, [slug, default-authentication-flow]]
      authorization_flow:  !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow:   !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      # ... property_mappings, redirect_uris, etc.
  - model: authentik_core.application
    id: app-mealie
    identifiers: { slug: mealie }
    attrs: { name: Mealie, provider: !KeyOf prov-mealie }
  - model: authentik_policies.policybinding
    identifiers: { target: !KeyOf app-mealie, order: 0 }
    attrs:
      group: !Find [authentik_core.group, [name, Users]]
      enabled: true
```

Reference: [model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
[YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).

### Forward-auth via Caddy

For apps that don't speak OIDC themselves (AlertManager, Prometheus,
Longhorn-style admin UIs), gate them via Authentik's embedded outpost +
Caddy's `forward_auth`. Register the app via
`myAuthentik.forwardAuthApps.<name>` — the aggregator emits the
proxy provider + application + policy binding into a single merged
blueprint per host (so two forward-auth apps don't clobber the
embedded outpost's global `providers` list) **and** wires a Caddy
route that imports the reusable `(authentik_forward_auth)` snippet:

```nix
myAuthentik.forwardAuthApps.alertmanager = {
  port = 9093;
  displayName = "Alertmanager";
  authentikGroup = "Infrastructure";   # default
  homepage = {                          # optional
    group = "Infrastructure";
    icon = "alertmanager";
    description = "Alert routing";
  };
};
```

The snippet (defined in `modules/apps/authentik.nix`) handles both
the `forward_auth` directive (auth check on every request) and the
`handle /outpost.goauthentik.io/*` block (callback routes).

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
- `sops.useSystemdActivation = true` runs decryption as a real systemd
  unit (`sops-install-secrets.service`) instead of a nixos-activation
  script, so consumer units can order against it explicitly

### Recovering from a sops decryption failure

If `sops-install-secrets.service` fails on boot (most commonly: the
host's age key isn't present yet, the secret was re-encrypted against
a different key, or a YAML file is malformed), any service that reads
the missing secret via a script will hit a no-op guard or auth-fail.
The current safety net for postgres roles is the
`unitConfig.ConditionPathExists` on `<app>-db-password.service` (see
`modules/system/postgresql.nix`): the unit refuses to run if the
secret file is missing, so it can't silently `ALTER USER … WITH
PASSWORD ''` and lock the app out of its DB.

To recover after the underlying sops issue is fixed:

```bash
# 1. Re-run decryption.
sudo systemctl start sops-install-secrets.service
# 2. Re-apply any role passwords that no-op'd while the secret was missing.
sudo systemctl start <app>-db-password.service
# 3. Restart the consumer service to pick up the (now correct) password.
sudo systemctl restart <app>.service   # or podman-<app>.service
```

`systemctl status sops-install-secrets` shows which secret failed;
`journalctl -u sops-install-secrets` has the underlying decryption
error. The `*-db-password` units are oneshots, so re-running them is
always safe — they just ALTER USER with whatever password is currently
in the decrypted file.

## Task Automation

Common operations are automated via `Taskfile.yaml`:

| Command                                   | Description                                                                      |
| ----------------------------------------- | -------------------------------------------------------------------------------- |
| `task rebuild`                            | Rebuild current NixOS host                                                       |
| `task rebuild:<host>`                     | Rebuild a specific NixOS host                                                    |
| `task deploy:<host>`                      | Build locally and push the closure to a live remote host (`switch` over SSH)     |
| `task build_darwin:<host>`                | Rebuild a nix-darwin host                                                        |
| `task build_home:<target>`                | Rebuild standalone home-manager                                                  |
| `task build`                              | Build a host without switching (default: luna)                                   |
| `task build-all`                          | Build all NixOS host configurations                                              |
| `task update`                             | Update flake inputs                                                              |
| `task update_dconf`                       | Capture host dconf config into the repo via `scripts/dconf.sh`                   |
| `task lint`                               | Run statix and deadnix                                                           |
| `task fmt`                                | Format all Nix files with nixfmt                                                 |
| `task fmt-check`                          | Check formatting without modifying files                                         |
| `task check`                              | Full pre-push check (fmt-check + lint + flake check)                             |
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

### Connecting the target to wifi (minimal ISO)

If the target has no ethernet, get it on wifi before running any bootstrap
tasks — they all SSH into `DEST`. The minimal ISO ships `nmtui`. On the
target's TTY:

```bash
sudo nmtui
```

Pick "Activate a connection", select your SSID, enter the passphrase.

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
