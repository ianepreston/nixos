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
- [Home Assistant](#home-assistant)
- [Local LLM Inference](#local-llm-inference)
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
- Local LLM inference (llama.cpp on CUDA) served from the workstation GPU and
  fronted with TLS + SSO by the prod server
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
│   ├── _host-spec.nix     # Schema definition for host specs
│   ├── luna.nix
│   ├── terra.nix
│   ├── work.nix
│   ├── penguin.nix
│   ├── toshibachromebook.nix
│   └── iso.nix
├── modules/               # All configuration modules, auto-imported by import-tree
│   ├── flake/             # Flake infrastructure (host-specs, module namespaces, dev shell, git hooks)
│   ├── profiles/          # Composable profiles (base, darwin-base, server, server-apps, workstation)
│   │   └── _ssh-keys/    # Human login pubkeys — authorized fleet-wide (see its README)
│   ├── system/            # System-level modules (sops, ssh, caddy, postgresql, mariadb, oci-containers, server-backups, observability, tailscale, …). Cross-cutting option surfaces (myCaddy.apps, myPostgresApp, myHomepage.tiles, mySqliteQuiesce.apps) are declared inline next to the service that consumes them.
│   │   └── _hm-core/     # Core home-manager config (git, zsh, starship, neovim, direnv, packages, platform-specific)
│   ├── apps/              # Server-app modules (jellyfin, mealie, miniflux, authentik, homepage, …) plus per-app blueprint dirs
│   ├── hardware/          # Hardware-specific modules (intel-quicksync, nvidia, yubikey, keyboards, rgb, xreal-headset)
│   ├── desktop/           # Desktop environment modules (gnome, audio, gaming, flatpak, themes, moonshine, quickemu)
│   │   └── _gnome/       # GNOME-specific sub-modules (dconf, cursor, stylix)
│   ├── programs/          # Application modules (browser, ghostty, comms, media, obsidian, etc.)
│   └── hosts/             # Per-host configurations and hardware/disk definitions
├── scripts/               # Utility scripts (dconf capture)
└── assets/                # Static assets (wallpapers)
```

## Hosts

| Host                  | Platform       | Config Type            | Description                                                               |
| --------------------- | -------------- | ---------------------- | ------------------------------------------------------------------------- |
| **luna**              | x86_64-linux   | `nixosConfigurations`  | MSI GS43VR laptop — workstation + GNOME + gaming + NVIDIA GTX 1060        |
| **terra**             | x86_64-linux   | `nixosConfigurations`  | AMD desktop — workstation + GNOME + gaming + RTX 5080 + llama.cpp serving |
| **hpp-1**             | x86_64-linux   | `nixosConfigurations`  | Dev server — `server` + `server-apps` + Intel QuickSync transcoding       |
| **amos1**             | x86_64-linux   | `nixosConfigurations`  | Prod server — `server` + `server-apps` + NVIDIA transcoding               |
| **work**              | aarch64-darwin | `darwinConfigurations` | macOS work machine — Homebrew, Hammerspoon, work-specific git config      |
| **penguin**           | x86_64-linux   | `homeConfigurations`   | Standalone home-manager (WSL / non-NixOS Linux)                           |
| **toshibachromebook** | x86_64-linux   | `nixosConfigurations`  | Minimal ChromeBook config                                                 |
| **xps13**             | x86_64-linux   | `nixosConfigurations`  | Dell XPS 13 laptop — headless workstation + GNOME (built-in display dead) |
| **tests-server**      | x86_64-linux   | `nixosConfigurations`  | Server-shaped VM target — drives `task recovery:test:full` restore drill  |
| **tests-desktop**     | x86_64-linux   | `nixosConfigurations`  | Desktop-shaped VM target — workstation profile iteration                  |
| **iso**               | x86_64-linux   | `nixosConfigurations`  | Custom NixOS installer/recovery ISO                                       |

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
`modules/apps/<appname>.nix` and are composed into the `server-apps` profile
(which is itself layered on top of `server` — the core infra profile that owns
caddy, postgres, authentik, observability, backups, etc.). Each app module is
self-contained: it declares the OCI container or native service, contributes a
Caddy route, any database/user it needs, its sops secrets, an authentik
blueprint (if SSO-protected), and a homepage tile — all in one place.
`modules/apps/mealie.nix` is the canonical example for a containerized,
postgres-backed, OIDC-integrated app.

App modules contribute to a small set of aggregator options declared inline next
to the services that consume them (in `modules/system/` or, for `myAuthentik.*`,
`modules/apps/authentik.nix`):

- `myCaddy.apps.<name>` — hands a route block to the wildcard
  `*.${serverDomain}` virtualHost (one wildcard cert covers every app, dodging
  Let's Encrypt rate limits).
- `myPostgresApp.<name>` — provisions the database/role plus a sops-managed
  password rotation oneshot, so containerized apps connecting over TCP get a
  passworded role without per-app boilerplate.
- `myAuthentik.oidcApps.<name>` — for apps that speak OIDC: declares the sops
  secret pair, contributes a blueprint dir, stacks the necessary worker-side env
  vars onto authentik, and optionally renders a per-app env file consumed by the
  upstream image.
- `myAuthentik.forwardAuthApps.<name>` — for apps that don't speak OIDC:
  generates the proxy provider/application/policy binding blueprint and a Caddy
  `forward_auth` route in one go (the embedded outpost's `providers` list is
  owned by a single merged blueprint per host so apps don't clobber each other).
- `myHomepage.tiles.<name>` — adds a tile to the homepage dashboard.

### Conventions

- **Registration:** `flake.modules.nixos.<appname>`, then add the name to the
  `imports` list in `modules/profiles/server-apps.nix`.
- **Container runtime:** `virtualisation.oci-containers` with the podman backend
  (rootful — see `modules/system/oci-containers.nix`). Containers drop
  privileges via `user = "${serverUid}:${serverGid}"` so files on NFS-mounted
  volumes line up with the Synology UID/GID (1029/1030 + 65536).
- **NFS UID alignment (containers AND native services):** anything that reads or
  writes the NFS-mounted Synology share (under `/mnt/content`, `/mnt/backups`,
  etc.) must run as `server-${env}:servers` (1029/1030 + 65536). The NAS
  enforces UID-based access — a service running as its own per-package system
  user (e.g. the upstream jellyfin module's default `jellyfin:jellyfin`) will
  silently see an empty directory listing on the NFS mount. For native modules
  that expose `user`/`group` options (jellyfin, etc.), pin them to
  `server-${hostSpec.serverEnvironment}` and `servers`. Existing
  `/var/lib/<app>` state created with the wrong owner needs a one-time
  `sudo chown -R server-<env>:servers` on first deploy — `tmpfiles` rules with
  type `d` won't re-chown an existing directory.
- **Networking:** bind container ports to `127.0.0.1` only — Caddy fronts
  everything externally. Containers reach host services (e.g. postgres) via
  `host.containers.internal`, which resolves to the podman bridge gateway; the
  bridge is in `networking.firewall.trustedInterfaces`.
- **Reverse proxy:** add a `myCaddy.apps.<name>` entry inside the same module —
  `host` defaults to `<name>.${hostSpec.serverDomain}` and `routeConfig` is the
  body of the `handle` block (typically a `reverse_proxy localhost:<port>`
  directive). The wildcard vhost in `modules/system/caddy.nix` folds these into
  one matcher per app, so one wildcard cert (DNS-01 via Cloudflare) covers them
  all.
- **Image versions:** pin the tag in the module and put a renovate annotation
  above it so updates are automated:
  ```nix
  # renovate: datasource=docker depName=ghcr.io/mealie-recipes/mealie
  image = "ghcr.io/mealie-recipes/mealie:v3.16.0";
  ```
- **Volumes:** state lives under `/var/lib/containers/<appname>` (single prefix
  lets the backup module cover every app automatically). Create the directory
  via `systemd.tmpfiles.rules` owned by the server UID/GID and bind-mount it
  into the container.
- **Postgres:** declare
  `myPostgresApp.<name>.consumerService = "podman-<app>.service"` (or whatever
  unit consumes the role). The helper in `modules/system/postgresql.nix` handles
  the database/role via `ensureDatabases`/`ensureUsers`, the sops secret, and
  the rotate-on-secret-change oneshot wired `before` the consumer unit. The app
  is responsible for plumbing `${config.sops.placeholder."<app>/db_password"}`
  into its own env file (e.g. as `POSTGRES_PASSWORD`) and pointing the upstream
  service at `host.containers.internal:5432` with the matching role
  - db name.
- **UI-stored config can silently beat the module.** Several apps keep a
  settings row in their own database and prefer it over the environment —
  paperless-ngx's AI configuration page is `app_config.X or settings.X` for
  every field, and Home Assistant's `.storage` behaves the same way. Where an
  app has both surfaces, configure it from the module and leave the UI page
  empty; a value saved there wins over the declarative one and does not show up
  in a diff.
- **Secrets:** declare per-app entries under `sops.secrets."<app>/..."` with
  `sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml"`. For env vars the
  container needs, render a `sops.templates."<app>.env"` and pass it via
  `environmentFiles`; set `restartUnits = [ "podman-<app>.service" ]` so the
  container picks up rotated secrets.

### Operating containers

The systemd services that run containers (e.g. `podman-mealie.service`) are
root-owned, so use `sudo podman ps`, `sudo podman logs <name>`, etc. for
inspection. Rootless podman as your user works for ad-hoc containers you start
yourself, but it can't see the system-managed ones.

### Backups and restore

Server hosts run `modules/system/server-backups.nix`, which composes:

- `services.postgresqlBackup` — daily `pg_dumpall` to `/var/backup/postgresql`
  (gzip, runs at 02:00).
- `services.mysqlBackup` — daily mariadb dump to `/var/backup/mysql` (also at
  02:00). Same restic snapshot picks both engines up.
- `services.restic.backups.server` — daily restic snapshot of
  `/var/backup/postgresql`, `/var/backup/mysql`, and `/var/lib/containers` to
  `/mnt/backups/restic/${hostName}` on the NFS-mounted Synology share (runs at
  03:00 with a 30-minute randomized delay). Retention:
  `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

Apps that keep state outside `/var/lib/containers` (e.g. the native \*arr stack,
jellyfin, kavita, komga, audiobookshelf, readeck) extend
`services.restic.backups.server.paths` themselves with their own
`/var/lib/<app>` tree; the listOf merges via concat so the base paths stay
intact.

SQLite-backed native apps additionally opt into the `mySqliteQuiesce` helper
(`modules/system/sqlite-quiesce.nix`), which runs `sqlite3 .backup` for each
declared database into `/var/backup/sqlite/<app>/` immediately before each
restic run. The staging root is added to the restic paths automatically, so each
snapshot contains both the (hot, possibly torn) live file under
`/var/lib/<app>/...` and a guaranteed-consistent copy under
`/var/backup/sqlite/<app>/`. Apps currently using it: jellyfin, sonarr, radarr,
lidarr, prowlarr, bazarr, kavita, komga, readeck, audiobookshelf.

Only server-local app state is in scope. NAS-resident media under `/mnt/content`
is protected NAS-side via Synology snapshots / Hyper Backup, not by restic.

The restic password lives in `shared.yaml` (one value, all servers), so any host
can decrypt any other host's repo for cross-host recovery testing. Each host
still mounts the _other_ environment's backup share read-only at
`/mnt/<otherEnv>-backups` (see `nfsclient.nix`), so e.g. restoring prod state
onto a dev host is a one-liner pointing restic at
`/mnt/prod-backups/restic/<prod-host>` — no extra credentials needed.

The restic repo path is read-write from the host that owns it, so a compromised
server or fat-fingered `rm` could in principle delete its own backups. Mitigate
by enabling **Synology snapshots** on the `server-{dev,prod}-backups` shares —
that's an out-of-band, client-immutable copy.

#### Restore runbook (catastrophic rebuild)

Recovery is an explicit operator action — there's intentionally no automatic
restore on container start, since "first boot" and "restore after data loss" are
different decisions.

The `recovery:*` tasks in `taskfiles/recovery.yaml` automate every step below.
Use them for the fast path:

```bash
task bootstrap:reinstall HOST=<host> DEST=<ip>      # reinstall NixOS
task recovery:all HOST=<host> [SOURCE_HOST=<other>] # restore everything
# or, scoped to one app:
task recovery:mealie HOST=<host>
```

`SOURCE_HOST` defaults to `HOST` (in-place restore); set it to a different host
to seed from that host's restic repo (e.g. prod → dev). The longhand below
documents what each per-app dispatcher actually does so the runbook keeps
working if a task is unavailable or you need to deviate.

1. **Reinstall the host:**

   ```bash
   task bootstrap:reinstall HOST=<host> DEST=<ip>
   ```

   NixOS comes back up with the same module set; container services will fail
   because their state directories are empty.

2. **Pull state back from restic:**

   ```bash
   sudo restic -r /mnt/backups/restic/<host> \
     --password-file /run/secrets/restic/password \
     restore latest --target /
   ```

   This repopulates `/var/lib/containers/*` and `/var/backup/postgresql`.

3. **Restore PostgreSQL.** With the default `services.postgresqlBackup` config,
   the dump is a single `pg_dumpall` output at
   `/var/backup/postgresql/all.sql.gz` (roles + every database). Replay it into
   the running cluster:

   ```bash
   sudo -u postgres bash -c 'zcat /var/backup/postgresql/all.sql.gz | psql -v ON_ERROR_STOP=0 postgres'
   ```

   Expect benign errors for roles/databases that NixOS's `ensureUsers` /
   `ensureDatabases` has already created (`role "mealie" already exists`, etc.)
   — they don't stop the data-loading `\connect` blocks that follow.
   `ON_ERROR_STOP=0` keeps psql going past those.

   If you'd rather start clean (and you're sure no other apps' data is in the
   cluster), stop postgres, wipe its data dir, and let NixOS reinit before
   replaying:

   ```bash
   sudo systemctl stop postgresql
   sudo rm -rf /var/lib/postgresql/<major>/*
   sudo systemctl start postgresql        # creates empty cluster + roles
   sudo -u postgres bash -c 'zcat /var/backup/postgresql/all.sql.gz | psql postgres'
   ```

   App-specific role passwords (the sops-managed
   `ALTER USER ... WITH PASSWORD ...` flow used by mealie) re-apply on the next
   service start via the per-app `<app>-db-password.service` units, so you don't
   need to set them by hand.

4. **Restart the app containers:**
   ```bash
   sudo systemctl restart 'podman-*.service'
   ```

#### Per-app restore

The catastrophic rebuild restores everything. To recover just one app without
touching the rest of the host, scope both the restic include and the postgres
replay. The three apps in this repo each illustrate a different shape — pick the
one that matches what you're restoring.

The postgres examples below replay the _current_ on-disk dump at
`/var/backup/postgresql/all.sql.gz` (refreshed nightly at 02:00). To restore
from an _older_ snapshot, pull that snapshot's dump to a temp path first:

```bash
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password \
  restore <snapshot-id> --target /tmp/restore \
  --include /var/backup/postgresql
# then point zcat at /tmp/restore/var/backup/postgresql/all.sql.gz
```

`pg_dumpall` writes one combined file with every database and role. The awk
filter below extracts a single database's section by tracking `\connect <name>`
markers. Roles are managed by NixOS `ensureUsers` and don't need to be replayed.

##### Containerized app with volume + postgres database (mealie)

Mealie has both on-disk state (`/var/lib/containers/mealie` — uploaded recipe
images, user assets) and database state (the `mealie` postgres db — recipes,
users, OIDC mappings). The two reference each other, so **restore both from the
same restic snapshot** — mixing eras leaves broken image references in recipe
rows.

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

Same pattern for any future containerized app with a postgres database:
substitute the unit name, volume path, and database name.

##### 12-factor app with all state in postgres (miniflux)

Miniflux is a single Go binary running under `DynamicUser=true` with no
persistent on-disk state — feeds, entries, read/unread flags, and OIDC user
mappings all live in the `miniflux` postgres database. Restore is just the
database half of the mealie flow:

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

Authentik fits the same shape (everything in the `authentik` postgres db, no
host state worth restoring) — same recipe with the names swapped.

##### Native service with on-disk state + SQLite (jellyfin, \*arr, kavita, …)

Jellyfin keeps everything under `/var/lib/jellyfin` — XML config, plugins,
metadata cache, and the library SQLite database at
`/var/lib/jellyfin/data/jellyfin.db`. There's no postgres to restore. The
wrinkle is that the live SQLite file can be torn mid-write inside a restic
snapshot; `jellyfin-sqlite-backup.service` (from the `mySqliteQuiesce` helper)
runs `sqlite3 .backup` into `/var/backup/sqlite/jellyfin/` immediately before
each restic run, and **those staged copies — not the live ones — are the
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

Media files themselves live on the NAS under `/mnt/content` and are out of scope
for restic — Synology snapshots cover them.

The same pattern applies to every app that opts into `mySqliteQuiesce` (sonarr,
radarr, lidarr, prowlarr, bazarr, kavita, komga, readeck, audiobookshelf): stop
the unit, `restic restore` both `/var/lib/<app>` (or `/var/lib/private/<app>`
for DynamicUser apps like prowlarr and readeck) and `/var/backup/sqlite/<app>`,
then `install` each staged `.db` over the live path declared in the app's
module. Check `mySqliteQuiesce.apps.<app>.databases` in the module for the exact
source paths to overwrite (e.g. sonarr →
`/var/lib/sonarr/.config/ NzbDrone/{sonarr,logs}.db`, bazarr →
`/var/lib/bazarr/db/bazarr.db`). Match the file owner to the service's
user/group (`server-${env}: servers` for the NFS-aligned apps).

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

`services.postgresql.package` is pinned to a specific major (`postgresql_18` at
time of writing) in `modules/system/postgresql.nix` so that rebuilds never
silently dump-and-restore the cluster. Major upgrades are a manual operation.
The canonical reference is the
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
  tandoor-recipes.service \
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
`modules/system/postgresql.nix` and `task deploy:<host>`. The old datadir under
`/var/lib/postgresql/<old>` is untouched by copy-mode `pg_upgrade`, so postgres
just resumes there.

## Jellyfin

`modules/apps/jellyfin.nix` deploys jellyfin as a native systemd unit (no
container) pinned to the `server-${env}:servers` UID/GID so it can read media
off the NFS-mounted Synology share. Restic snapshots `/var/lib/jellyfin` plus
the `mySqliteQuiesce` staging dir at `/var/backup/sqlite/jellyfin/`, which holds
a `sqlite3 .backup` dump of `jellyfin.db` written by a pre-hook before each
restic run.

### LDAP authentication via authentik

Jellyfin doesn't share a credentials store with the rest of the authentik OIDC
apps. The OIDC plugin
([`9p4/jellyfin-plugin-sso`](https://github.com/9p4/jellyfin-plugin-sso)) was
archived 2026-05-12 with no successor, and TV / native clients can't do OIDC
redirects anyway — so we use
[`jellyfin/jellyfin-plugin-ldapauth`](https://github.com/jellyfin/jellyfin-plugin-ldapauth)
(officially maintained under the jellyfin org) against authentik's LDAP outpost.
Users type the same password they use everywhere else; no MFA at jellyfin login
(LDAP binds bypass authentik's MFA flow — acceptable for a media server).

**Declarative side** (already in this repo): `modules/apps/jellyfin.nix` sets
`myAuthentik.ldap.enable = true`, which:

- Renders `modules/apps/authentik-blueprints-ldap/ldap.yaml`: LDAP provider +
  application + policy binding gating to the Users group, `ldapservice`
  service-account user (bind user for jellyfin) with the `search_full_directory`
  object permission on the LDAP provider, and the outpost record itself.
- Wires `services.authentik-ldap` (from authentik-nix) listening on
  `127.0.0.1:3389`. The outpost's API token is auto-generated by authentik when
  the outpost record is saved — there's no clean way to pre-set it via blueprint
  in current authentik (the `token_identifier` field on the outpost model is a
  computed property, not a writable column; the workaround from
  [goauthentik/authentik#9711](https://github.com/goauthentik/authentik/issues/9711#issuecomment-2845076876)
  doesn't take effect). Instead, a one-shot
  `authentik-ldap-token-fetcher.service` polls the admin API at boot (auth'd
  with the existing `authentik/bootstrap_token`), fetches the auto-generated
  token via `/api/v3/core/tokens/<id>/view_key/`, and writes it into
  `/run/authentik-ldap-token/env` which the outpost consumes as its
  `environmentFile`.
- Declares one sops secret: `authentik/ldap_service_password` (the bind password
  jellyfin uses). The outpost-side API token never hits sops — it's fetched at
  runtime from authentik itself.

**One-time setup** (per host that enables `myAuthentik.ldap`):

1. Generate the bind password:

   ```bash
   task secrets:secret APP=authentik KEY=ldap_service_password LEN=32
   task secrets:publish MSG="add ldapservice bind password for hpp-1"
   ```

2. `task deploy:hpp-1`. The worker applies the blueprint (creates provider +
   application + outpost record + service account + search permission).
   authentik mints the outpost's API token; the token-fetcher oneshot grabs it
   and writes the outpost's env file; `services.authentik-ldap` reads that file
   and connects back. No UI steps required. Verify:

   ```bash
   ssh hpp-1 'systemctl is-active authentik-ldap-token-fetcher authentik-ldap'
   # both should print "active"

   ssh hpp-1 'nix shell nixpkgs#openldap -c ldapsearch -x -H ldap://127.0.0.1:3389 \
     -D "cn=ldapservice,ou=users,dc=ldap,dc=goauthentik,dc=io" \
     -w "$(sudo cat /run/secrets/authentik/ldap_service_password)" \
     -b "dc=ldap,dc=goauthentik,dc=io" "(cn=ian)"'
   # should return ian's entry with memberOf lines
   ```

3. Install the jellyfin plugin (manual — the plugin DLL itself can't be wired
   declaratively, but lives under `/var/lib/jellyfin/` which restic snapshots;
   only a from-scratch rebuild needs this re-run):
   - Jellyfin UI → **Dashboard → Plugins → Repositories**. The official Jellyfin
     repo is already present; no extra repo needed.
   - **Catalog → LDAP Authentication → Install**.
   - Restart jellyfin: `ssh hpp-1 'sudo systemctl restart jellyfin'`.

4. Configure the plugin: **Dashboard → Plugins → LDAP-Auth**.

   | Field                     | Value                                                                                                                                                                                                                                                                    |
   | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
   | LDAP Server               | `127.0.0.1`                                                                                                                                                                                                                                                              |
   | LDAP Port                 | `3389`                                                                                                                                                                                                                                                                   |
   | Secure LDAP / StartTLS    | both off (loopback)                                                                                                                                                                                                                                                      |
   | LDAP Bind User            | `cn=ldapservice,ou=users,dc=ldap,dc=goauthentik,dc=io`                                                                                                                                                                                                                   |
   | LDAP Bind Password        | value of `authentik/ldap_service_password` from sops                                                                                                                                                                                                                     |
   | LDAP Base DN for searches | `dc=ldap,dc=goauthentik,dc=io`                                                                                                                                                                                                                                           |
   | LDAP User Filter          | `(&(objectClass=user)(memberOf=cn=Users,ou=groups,dc=ldap,dc=goauthentik,dc=io))`                                                                                                                                                                                        |
   | LDAP Admin Base DN        | `dc=ldap,dc=goauthentik,dc=io`                                                                                                                                                                                                                                           |
   | LDAP Admin Filter         | `(memberOf=cn=Infrastructure,ou=groups,dc=ldap,dc=goauthentik,dc=io)` (reuses the existing authentik group used to gate forward-auth admin tools; anyone in `Infrastructure` becomes a jellyfin admin. Leave blank if you'd rather manage admin status inside jellyfin.) |
   | LDAP Search Attributes    | `uid,cn,mail,displayName`                                                                                                                                                                                                                                                |
   | LDAP Username Attribute   | `cn` (authentik puts the human-readable username here; `uid` is a hashed opaque identifier and produces UUID-shaped jellyfin accounts)                                                                                                                                   |
   | LDAP Password Attribute   | `userPassword`                                                                                                                                                                                                                                                           |
   | Enable User Creation      | on (auto-provisions jellyfin accounts on first LDAP login)                                                                                                                                                                                                               |
   | Library Access            | pick the libraries new LDAP users get; can also be tuned per-user after first login                                                                                                                                                                                      |

   Use the **Test Server Settings** / **Test LDAP Search Filter** buttons before
   saving. The search filter test should return your own authentik account.

5. (Optional) Create an `jellyfin-admins` group in authentik UI and add members;
   LDAP-Auth will treat them as administrators inside jellyfin. Existing
   jellyfin users created before the plugin was installed stay local — convert
   them via **Dashboard → Users → `<user>` → Set the LDAP user UID** so
   subsequent logins go through LDAP.

The plugin DLL and its config live under `/var/lib/jellyfin/`, which restic
snapshots — a restore restores the plugin too. Only a fresh install
(catastrophic rebuild on a new disk) needs steps 5–7 re-run.

### Hardware-accelerated transcoding

The host needs `modules/hardware/intel-quicksync.nix` (Intel iGPU) included in
its host module — see `modules/hosts/hpp-1.nix`. `server-${env}` already has
`video` and `render` supplementary groups from
`modules/system/server-users.nix`, so once the QSV module is loaded
`/dev/dri/renderD128` is reachable by jellyfin.

The remaining setup is **manual in the jellyfin web UI** (the resulting config
lives in `/var/lib/jellyfin/config/encoding.xml` and is captured by restic, so
this is a one-time-per-host step):

1. Dashboard → Playback → Transcoding.
2. **Hardware acceleration:** Intel QuickSync (QSV).
3. **VA-API device:** `/dev/dri/renderD128`.
4. Enable hardware decoding for the codecs you care about (H.264, HEVC, VP9 are
   safe on HD 630 and newer).
5. Enable hardware encoding.
6. Enable Tone mapping (works because `intel-compute-runtime` ships the OpenCL
   runtime via `intel-quicksync.nix`).

To verify the host stack before configuring the UI:

```bash
ssh <host> 'nix-shell -p libva-utils --run "vainfo --display drm --device /dev/dri/renderD128"'
```

Should report `Driver version: Intel iHD driver` and a list of `VAProfile*`
entries. To confirm the GPU is actually doing work during a transcode, watch
`intel_gpu_top` while jellyfin transcodes a stream:

```bash
ssh <host> 'nix-shell -p intel-gpu-tools --run "sudo intel_gpu_top"'
```

The Render/3D and Video engines should show activity.

## Authentik (SSO)

`modules/apps/authentik.nix` deploys Authentik as native systemd units via the
[`nix-community/authentik-nix`](https://github.com/nix-community/authentik-nix)
flake input — _not_ containers. The module's `services.authentik` runs three
units (`authentik`, `authentik-worker`, `authentik-migrate`) under
`DynamicUser=true`, talks to the shared postgres over the unix socket via peer
auth (so no role password is needed), and uses the unnamed NixOS
`services.redis.servers.""` instance on `localhost:6379`. Caddy fronts it at
`authentik.${hostSpec.serverDomain}`.

### Declarative configuration via blueprints

Groups, users, applications, OAuth/proxy providers, and group bindings are all
managed as Authentik **blueprints** (YAML, applied idempotently by the worker on
a periodic Celery task and on startup). No terraform, no UI clicks. Two starter
blueprints live under `modules/apps/authentik-blueprints/`:

- `groups.yaml` — homelab groups (Home, Infrastructure, Users).
- `users.yaml` — the `ian` admin user (in `authentik Admins`, Home,
  Infrastructure, Users) plus a few "Pattern A" onboarding users that have no
  `password` attr yet and authenticate after running through the recovery flow.
  `ian`'s password reads from `!Env IAN_PASSWORD`, which is rendered into the
  systemd `EnvironmentFile` from sops.
- `hardening.yaml` / `recovery.yaml` — bundled hardening and recovery flow
  tweaks.

The module merges its blueprints with the upstream-bundled set into a single
`blueprints_dir` via `pkgs.runCommandLocal` + `cp -rL`. **Do not use
`pkgs.symlinkJoin`** here: authentik's `retrieve_file` calls
`Path(...).resolve()` and rejects anything that resolves outside
`blueprints_dir`, so symlink-joined entries (which dereference back to their
original store paths) all fail with "Invalid blueprint path". Real files via
`cp -L` are required.

### Adding an OIDC app to Authentik

Apps that speak OIDC natively register via the `myAuthentik.oidcApps` aggregator
from `modules/apps/authentik.nix`. The aggregator generates the sops secret
pair, contributes the per-app blueprint dir, and stacks one merged worker-side
env file onto authentik so blueprint `!Env` placeholders resolve. Apps that read
OIDC creds from env vars (mealie, miniflux, paperless-ngx, tandoor, komga,
actualbudget) get their own per-app env file too; apps that store creds in their
own DB/UI (audiobookshelf, kavita, seerr) opt out via
`clientCredsInAppEnv = false`.

Blueprint secrets must reference `!Env <APP>_OIDC_CLIENT_ID` /
`<APP>_OIDC_CLIENT_SECRET` (uppercased app name with hyphens → underscores) so
they never land in `/nix/store`.

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
      grant_types: [authorization_code, refresh_token] # see note below — required on 2026.x
      authentication_flow:
        !Find [authentik_flows.flow, [slug, default-authentication-flow]]
      authorization_flow:
        !Find [
          authentik_flows.flow,
          [slug, default-provider-authorization-implicit-consent],
        ]
      invalidation_flow:
        !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
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

**Always set `grant_types` explicitly.** authentik 2026.x added
`OAuth2Provider.grant_types` (defaults to an empty list) and the authorize view
now rejects any flow whose grant isn't listed (`Invalid grant_type for provider`
→ the app sees a malformed-request error and bounces back to its login page).
Providers created under an older authentik were back-filled by the migration, so
the omission is invisible until a provider is created **fresh** on 2026.x — a
new app, a new host, or a `recovery:all` / `bootstrap:reinstall` rebuild (which
recreates every provider at once and would otherwise break all SSO
simultaneously). `[authorization_code, refresh_token]` is authentik's own UI
default and the right value for every app here, including `public`/PKCE clients
(grimmory). This bit komga on amos1 — see the blueprint comments for the full
trace.

Reference:
[model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
[YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).

### Forward-auth via Caddy

For apps that don't speak OIDC themselves (AlertManager, Prometheus,
Longhorn-style admin UIs), gate them via Authentik's embedded outpost + Caddy's
`forward_auth`. Register the app via `myAuthentik.forwardAuthApps.<name>` — the
aggregator emits the proxy provider + application + policy binding into a single
merged blueprint per host (so two forward-auth apps don't clobber the embedded
outpost's global `providers` list) **and** wires a Caddy route that imports the
reusable `(authentik_forward_auth)` snippet:

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

The snippet (defined in `modules/apps/authentik.nix`) handles both the
`forward_auth` directive (auth check on every request) and the
`handle /outpost.goauthentik.io/*` block (callback routes).

### YAML lint exclusion

Authentik's custom YAML tags (`!Env`, `!Find`, `!KeyOf`) aren't accepted by
pyyaml's safe loader, so `modules/apps/authentik-blueprints/` is excluded from
the `check-yaml` pre-commit hook in `modules/flake/git-hooks.nix`. Add new
blueprint paths under that prefix or extend the excludes list.

## Home Assistant

Home Assistant runs as the **native** `services.home-assistant`
(`modules/apps/homeassistant.nix`), not a container. That reverses the usual
"big, churny apps stay containerized" instinct, so the reasoning is worth
recording.

### Why native, and the real tradeoff

The original objection was that HA's python dependencies wouldn't fit the
nixpkgs cadence. That turned out to be wrong — Nix isolates HA's closure
cleanly. The genuine tradeoff is different:

- **Version currency.** HA ships ~monthly and its integrations track fast-moving
  cloud APIs; the stable channel freezes HA at a yearly snapshot. So the HA
  package (and its custom components) are pinned to `nixpkgs-unstable` via a
  per-package overlay (the `rgb.nix` pattern), while the rest of the system
  stays on stable. HA updates are therefore `nixos-rebuild`s, not Renovate
  image-tag bumps.
- **Integration declaration.** The container image bundles every integration's
  python deps, so "discover device → click Add" always worked. Native ships deps
  only for **declared** components. This is the one real recurring cost, and it
  lands on _experimentation_, not steady state — which suits a stable device set
  and buys a git-tracked, reproducible, reviewable integration inventory in
  exchange.

What native gives back: declarative OIDC (no HACS), the recorder on the shared
native postgres over a peer-auth socket, the DHCP/discovery integrations working
without container capability hacks, and custom integrations captured in git
instead of installed imperatively through HACS into a stateful volume.

### Adding a device — the recurring workflow

Auto-discovery still finds devices, but if the integration's python dep isn't
shipped the UI config flow fails
**`Config flow could not be loaded: Invalid handler specified`**. Two cases:

1. **Core integration** (in nixpkgs) — add its domain to
   `services.home-assistant.extraComponents` and deploy. Confirm the name is
   real first:

   ```sh
   nix eval --json "github:NixOS/nixpkgs/nixos-unstable#home-assistant.availableComponents" \
     --apply 'cs: builtins.elem "<domain>" cs'
   ```

2. **HACS-only integration** (no core module) — package it as a
   `customComponents` entry with `buildHomeAssistantComponent` (the `auth_oidc`
   / `bambu_lab` / `hoymiles_wifi` / `ha_blueair` pattern in the module). Any
   python lib nixpkgs lacks gets its own `buildPythonPackage`, pinned to the
   version the component's `manifest.json` `requirements` demands — the
   `manifestRequirementsCheckHook` fails the build otherwise.

Custom-component versions are Renovate-tracked via the `github-releases` `tag`
custom manager in `renovate.json`, kept **manual** (grouped as "home-assistant
custom components"): Renovate bumps the `tag`, then the `fetchFromGitHub` hash
is regenerated from the failing build, and if the new manifest pins a different
lib version the paired `buildPythonPackage` is bumped in the same PR. The libs
themselves are deliberately _not_ Renovate-tracked — they must move in lockstep
with the component.

### Config: declarative vs. stateful

`configuration.yaml` is Nix-managed and immutable (`default_config`,
`http.trusted_proxies`, `recorder.db_url`, `auth_oidc`). OIDC creds reach it
through HA's `!secret` tag from a sops-rendered `secrets.yaml` symlinked into
the config dir. UI-authored automations/scripts/scenes are file-based `!include`
targets, seeded empty by the service `preStart` (race-free, never clobbered) so
UI edits persist.

Everything with an **"Add" button** in the UI — paired devices, integrations —
is stateful and lives in `/var/lib/hass/.storage`, keyed by internal UUIDs. That
state does **not** merge between instances: do device pairing directly on the
target host rather than trying to sync a dev instance into prod. The only
cleanly portable Tier-2 artifacts are the `automations.yaml` / `scripts.yaml` /
`scenes.yaml` files (plain YAML; each automation needs a unique `id` and
entity_ids that exist on the target).

## Local LLM Inference

`llama-server` (llama.cpp's OpenAI-compatible HTTP API) runs on the host with
the GPU, wired up by `modules/system/llama-cpp.nix` — a thin wrapper over
nixpkgs' `services.llama-cpp` that adds a CUDA build, a sops-fed API key, and a
source-scoped firewall hole. A host enables inference with one attr set:

```nix
# modules/hosts/terra.nix
myLlamaCpp = {
  enable = true;
  cudaCapabilities = [ "12.0" ];      # RTX 5080 / Blackwell / sm_120
  models = {
    "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M" = {
      aliases = [ "vision" ];
      ctxSize = 98304;
      cacheTypeK = "q8_0";            # KV cache quantization; f16 is the default
      cacheTypeV = "q8_0";
    };
    "ggml-org/gpt-oss-20b-GGUF:MXFP4" = {
      aliases = [ "text" ];
      ctxSize = 131072;
      cacheTypeK = "q8_0";
      cacheTypeV = "q8_0";
    };
    "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q4_K_XL" = {
      aliases = [ "code" ];
      ctxSize = 131072;
      cacheTypeK = "q8_0";
      cacheTypeV = "q8_0";
      nCpuMoeLayers = 40;             # MoE experts to host RAM; weights exceed the card
    };
  };
  listenAddress = "0.0.0.0";
  allowedClients = [ "192.168.10.11" ]; # amos1 only
  sleepIdleSeconds = 600;
};
```

Two instances run today, and they are not redundant copies of each other:

| | terra | amos1 |
| --- | --- | --- |
| GPU | RTX 5080, 16 GB | RTX 3070, 8 GB, shared with Jellyfin |
| `vision` | Qwen3-VL-8B Q4_K_M @ 98304 | Qwen3-VL-4B Q4_K_M @ 32768 |
| `text` | gpt-oss-20b MXFP4 @ 131072 | Qwen3-8B Q4_K_M @ 16384 |
| `code` | Qwen3-Coder-30B-A3B UD-Q4_K_XL @ 131072 | — |
| `text-qwen` | Qwen3-14B Q4_K_M @ 40960 | — |
| resident VRAM | 13576 / 13352 / 10846 / 12226 MiB | 6080 / 6190 MiB |
| idle window | 600 s | 300 s |
| availability | only when the desktop is on | always |
| URL | `llm-terra.<serverDomain>` | `llm.<serverDomain>` |

So `llm.*` is the one to point a client at by default, and `llm-terra.*` is
the larger model of either kind when that machine happens to be up.

### Router mode: one model at a time

Each host serves a *set* of models rather than one. `llama-server` runs as a
**router**: the process that owns the port holds no model itself and spawns a
child `llama-server` per model on a loopback ephemeral port, picking the child
by the `"model"` field in the request body (or `?model=` on GET endpoints).

That exists because neither host has a single model that does everything.
Vision is the prerequisite for Tandoor photo import and paperless document AI,
and on both cards the best vision model that fits is materially weaker at text
than the generalist it displaced — terra's is 8B-class against a 14B, amos1's
4B-class against an 8B. Routing gets both back.

terra carries two more for a different reason. #518 set out to pick one model
for agentic coding and could not: gpt-oss-20b beats Qwen3-Coder-30B on every
*measured* axis (8.4x prefill, 5.1x generation, 9.5 GB less host RAM at the
same 128k context), but throughput is not code quality, and a coding specialist
against a general reasoner is a question only real sessions answer. Both are
routable by name — `text` and `code` — so the comparison is a model field
rather than a rebuild. `text-qwen` keeps the dense 14B that `text` displaced
available on the same terms.

`--models-max` is pinned to **1**. This is swap-on-demand, not concurrent
serving: terra's four are ~56 GB of models against a 16.3 GB card, amos1's pair
is 12.4 GB against 8.0 GB, and nothing fits two at once. Asking for a model that
isn't resident evicts the one that is. That costs 3–4 s on terra's NVMe with the
page cache cold, and 2–5 s on amos1 — cheap enough that the swap is not worth
designing around.

Three consequences worth knowing:

- **The `model` field is now mandatory and exact.** Single-model mode ignored
  it; the router answers `400 model name is missing from the request` without
  one and `400 model 'x' not found` for a name it doesn't have. A client that
  used to send a placeholder stops working.
- **`aliases` is the stable name to point clients at.** Both hosts register
  `text` and `vision` alongside the full `<repo>:<quant>` names, and terra adds
  `code` and `text-qwen`, so swapping the GGUF underneath a role is a change to
  `modules/hosts/<host>.nix` and not to every client. The role set is per-host:
  a client asking amos1 for `code` gets `400 model not found`, which is the
  correct answer rather than a silent downgrade.
- **The cache is a model *source*, not just storage.** The router enumerates
  `LLAMA_CACHE` as well as its preset, so a leftover GGUF from an earlier config
  is still routable — with llama.cpp defaults, since nothing sizes it. Pruning
  is therefore how the served set is kept equal to the declared one, not only
  how disk is reclaimed.

Multimodal capability is per-model and does not leak: `-hf` resolves and
downloads each repo's `mmproj` projector on its own, and in a mixed set the
text-only model reports `input_modalities: ["text"]` and rejects an image with
`image input is not supported`, while the vision model reports
`["text","image"]` and answers.

Nothing loads at service start. The first request that names a model pays its
load, which for a model not yet on disk is a multi-GB download inside that
request — `task llm:models:fetch HOST=<host>` does that warm-up deliberately,
with a timeout that expects it.

### The CUDA build is local and unavoidable

`pkgs.llama-cpp` in this flake is a CPU build — nothing sets
`config.cudaSupport`. The module imports a second nixpkgs instance with CUDA on,
which no binary cache serves (CUDA is unfree), so the first rebuild on a host
compiles llama.cpp from scratch. Budget for it.

`cudaCapabilities` is what keeps that survivable. Left at the nixpkgs default it
builds kernels for nine architectures (7.5 → 12.1); pinned to the one the host
actually has, the compile drops to roughly a ninth of that (~10 min on terra's
16-core Ryzen). Getting the value *wrong* doesn't fail the build — it fails at
runtime with no usable kernels. RTX 5080 is `12.0`, RTX 3070 is `8.6`.

### Model files are not Nix's problem

GGUFs are gigabytes and don't belong in the store. Each `models.<name>` key is
passed straight through as `-hf <repo>:<quant>` and llama-server downloads the
weights itself, into `LLAMA_CACHE`. The module points that at the *state*
directory rather than upstream's `/var/cache/llama-cpp`, so nothing that treats
`/var/cache` as disposable can trigger a multi-GB re-download.

That download happens on first *use*, not first start, and takes as long as it
takes (~9 GB for a 14B at Q4_K_M) with working egress to huggingface.co. Do it
on purpose rather than inside somebody's request:

```sh
task llm:models:fetch HOST=terra   # one throwaway request per configured model
```

`systemctl status llama-cpp` shows nothing useful while this happens; watch the
blob instead:

```sh
sudo du -sh /var/lib/private/llama-cpp
```

Nothing outside nix's view gets garbage-collected, so old weights pile up as
`models` changes — and in router mode they stay *routable* while they do. Two
tasks handle that:

```sh
task llm:models                    # what's cached, what's routable, what's resident
task llm:models:prune              # dry run: what would go
task llm:models:prune APPLY=true   # actually delete
```

The keep-set is the declared `myLlamaCpp.models`, not what happens to be
loaded: at most one of several configured models is resident, so "keep the live
one" would delete whichever was idle. The running router is still consulted, to
prove it is on *this* generation of the config — the prune aborts unless it
answers `/v1/models` and every configured name is in the answer, so a
half-applied switch can't turn into a deletion. As a second check, any model
that *is* loaded has its `model_path` fetched and the prune aborts if that path
is in the doomed set.

What it removes: whole repos nothing configured maps to, revisions of a kept
repo other than the one `refs/main` names, superseded quants inside the current
revision, and blobs no surviving symlink points at. What it keeps: every shard
of a split model, any `mmproj*`/`mtp-*` sidecar, non-`.gguf` files, any filename
whose quant tag doesn't parse, and any `.downloadInProgress` touched in the last
hour.

### Sizing against VRAM

Every model is sized against the *whole* card, not a share of it, because only
one is resident at a time. Weights plus KV cache plus compute buffers have to
fit. KV cache is the part that surprises: at f16 Qwen3-14B is ~160 KB/token and
Qwen3-8B is ~144 KB/token, so context — not the model — is what runs a card out
of memory.

`cacheTypeK` / `cacheTypeV` are the lever. Quantizing the KV cache to `q8_0`
halves its per-token cost, and both hosts measurably buy context with it rather
than with VRAM (`f16` stays the module default, so a model opts in). Measured on
each host's `text` model:

| host | before | after | resident VRAM | generation |
| --- | --- | --- | --- | --- |
| terra (16 GB) | 16k, f16 | **40960, q8_0** | 12878 → 13768 MiB | 89.9 → 86.1 tok/s |
| amos1 (8 GB) | 8k, f16 | **16384, q8_0** | 6105 → 6199 MiB | 77.8 → 74.1 tok/s |

Both pay about 4% of generation throughput. Prompt processing pays a similar
few percent. It is not free on quality either — `q8_0` KV is a far smaller hit
than quantizing weights another step, but it is a hit, so it is worth a
subjective check on a real task before reaching for anything below `q8_0`.

The two hosts hit *different* ceilings on those models, which is why their
numbers differ (the vision models' budgets are worked through in the comments in
`modules/hosts/terra.nix` and `modules/hosts/amos1.nix`):

- **terra's `text-qwen` runs out of model, not card.** 40960 is Qwen3-14B's
  `n_ctx_train`; past it quality degrades without RoPE scaling. f16 KV at 40960
  does not fit at all (it would be ~6.4 GB of cache on top of ~9 GB of
  weights); q8_0 fits with a couple of GB spare — the deployed service reports
  40960 context at 86.8 tok/s holding 12226 MiB, with the card at 12937 of
  16303 MiB. `--no-kv-offload` would allow more still, but costs ~30%
  generation and ~40% prefill, so it is not worth reaching for here.
- **amos1 runs out of Jellyfin headroom.** The 3070's 8 GB is also NVENC
  scratch space. At 16384/q8_0 the model sits at 6199 MiB, leaving 1993 MiB —
  and with the model resident *and* generating, a 1080p `h264_nvenc` transcode
  peaks the card at 6586 MiB and a 4K `hevc_nvenc` one at 7730 MiB. Both
  succeed. 24576 does not clear that bar: 6811 MiB resident leaves 1381 MiB,
  under the ~1.5 GB a 4K transcode wants. Raising `ctxSize` there spends
  Jellyfin's margin, not spare capacity — which is also why the idle window is
  300 s rather than terra's 600 s.

### Two ways past "it doesn't fit"

The arithmetic above sizes a *dense* model with global attention. terra's two
128k models both break it, in opposite directions, and each needs a different
lever.

**Sliding-window attention makes long context nearly free — gpt-oss-20b.**
Alternating layers cap their cache at a 128-token window rather than growing it
with the prompt. Naive bytes-per-token arithmetic predicts ~3.1 GB of KV at
131072; measured, KV *and* compute buffers together come to ~1254 MiB on top of
12.1 GB of weights — 13352 MiB resident in all, for 1.5 GB of host RAM. That is the whole reason a 20B model holds 3.2x the context
of the 14B it displaced while also being faster than it (10817 vs 3282 tok/s
prefill, 189.5 vs 62.8 generation on a fixed 16,701-token prompt) — MXFP4
weights and ~3.6B active parameters of 20B do the rest. f16 KV at that context
still OOMs, so `q8_0` is a prerequisite here and not a tuning choice.

**`nCpuMoeLayers` puts a model bigger than the card on the card — Qwen3-Coder-30B.**
17.7 GB of weights against 16.3 GB of VRAM is not a context problem, and `-ngl`
is the wrong tool: dropping whole layers to the CPU drags their KV cache off the
card with them. `-ncmoe N` splits it the other way — attention and the entire KV
cache stay on the GPU while the first N layers' *expert* FFN weights live in host
RAM. An MoE activates a small fraction of its parameters per token, so the PCIe
traffic is far smaller than the resident size implies.

Fewer offloaded layers is monotonically faster, so the setting is bounded below
by VRAM and picked as the largest that leaves headroom:

| terra, Coder30B @ 131072 | VRAM | host RAM | prefill | generation |
| --- | --- | --- | --- | --- |
| `nCpuMoeLayers = 30` | 15655 MiB | 11.0 GB | 1282.8 tok/s | 37.0 tok/s |
| **`nCpuMoeLayers = 40`** | **12391 MiB** | **14.3 GB** | **1033.5 tok/s** | **30.0 tok/s** |

30 is faster and was rejected: ~650 MiB of headroom on a card also running a
GNOME session is not a margin. Deployed, 40 measures better than the bench
above — 10846 MiB resident under the router rather than 12391.

The host-RAM column needs reading carefully. Of that 14.3 GB of RSS, 13.6 GB is
`RssFile`: the offloaded experts are an mmap of the GGUF, so the kernel accounts
them as reclaimable page cache and `free` still reports ~26 GB available on a
30 GB machine. Only ~0.5 GB is anonymous. So it is much kinder to a desktop than
"14 GB gone" implies — but not free, because reclaiming those pages means
re-reading experts from NVMe per token, and the throughput above assumes they
stay resident. `sleepIdleSeconds` hands back VRAM, not this.

262144, the model's native limit, does not fit at any offload level: compute
buffers fail to allocate before the KV cache is even the constraint.

`sleepIdleSeconds` exists because terra is a gaming machine first — after the
idle window llama-server sleeps and hands the VRAM back. Measured on terra:
12.2 GB down to 1.7 GB at the 600 s mark, and ~3 s to wake on the next request
(the GGUF is still in page cache, so nothing is re-read from disk). `/health`
keeps answering while asleep and doesn't reset the timer.

Router mode does not change this — the flag is passed to the router and
inherited by every child, so it is uniform across a host's models by
construction. It is a separate mechanism from `--models-max` eviction and both
apply: a sleeping model still counts as loaded, so asking for a different model
unloads the sleeper outright rather than waiting for it to wake.

### The model cache under impermanence

Servers run impermanence, so llama-server's downloaded GGUFs would be wiped on
every reboot without a preservation entry — several GB of re-download per boot.
`modules/apps/llm.nix` preserves `/var/lib/private/llama-cpp`, but deliberately
**not** via `myAppState`: that derives a restic path from the same declaration,
and a GGUF has no business in a nightly snapshot. It is re-downloadable bytes,
not state anyone authored. Same reasoning as sabnzbd's incomplete dir —
preserve-only, listed conditionally in `residualPreservedDirs` so the structural
guard still asserts it stays preserved on hosts that run the daemon.

That also means there is no `recovery:` dispatcher for it: nothing of it is in
restic to restore. After a catastrophic rebuild the model re-downloads on first
start.

A preservation bindmount hands the unit a `root:root 0700` directory on a fresh
boot, which looks wrong for a DynamicUser service. It isn't — systemd chowns an
existing `StateDirectory` to the on-disk sentinel (`nobody:nogroup 0755`) before
`ExecStart`, and the unit writes through the idmapped mount normally.

### Fronting a workstation from a server

terra imports the `workstation` profile: no caddy, no authentik, no tailscale.
Rather than replicate that stack onto a desktop, the servers proxy to it —
`modules/apps/llm-terra.nix` is a route-only module (no service, no state, hence
no `recovery:` dispatcher) that registers a `myAuthentik.forwardAuthApps` entry
pointing at `terra.ipreston.net`. Both hpp-1 and amos1 import it, so the same
backend answers on `llm-terra.dnix.ipreston.net` and
`llm-terra.amos.ipreston.net`; TLS terminates on each server's existing wildcard
cert.

Two things that follow from that shape:

- **`upstreamHost`.** `myAuthentik.forwardAuthApps` gained an `upstreamHost`
  option (default `localhost`) for exactly this. Only point it at a backend that
  has its own auth on whatever paths you bypass — the hop is plaintext HTTP over
  the LAN.
- **The address has to be pinned.** `terra.ipreston.net` is registered by the
  router from terra's DHCP lease, so terra needs a DHCP reservation (one is in
  place) or the route drifts. terra is also a desktop that gets powered off; the
  route 502s while it's down, which is expected rather than a fault.

### Why the `/v1/*` bypass is conditional

OpenAI-compatible clients send a bearer token and can't follow an authentik
login redirect, so the API paths bypass forward-auth and are gated by
llama-server's own `--api-key` instead — the same "app has its own key auth on
this sub-path" pattern as radarr's `/api/*`.

Path alone turned out to be the wrong condition. llama-server enforces its key
on nearly everything it serves — `/props` and `/slots` as well as
`/v1/chat/completions`, with only `/`, `/index.html` and the bundles public — so
the web UI would load and then prompt the human for a shared API key they had
just earned by logging into authentik. Gating on SSO and then demanding the
shared secret anyway defeats the SSO.

So `myAuthentik.forwardAuthApps.<app>.upstreamBearerEnvVar` names an env var in
caddy's `EnvironmentFile`, and when it's set the route changes shape: the
bypass additionally requires an `Authorization` header (catching API clients,
not browsers), and the authentik-gated branch injects the token upstream
itself. A browser logs into authentik and just works; an API client presents
its own token, which passes through untouched.

That also closed a leak this route previously accepted. llama-server treats
`/v1/models` and `/v1/health` as *public* — served with no key even when
`--api-key` is set — so a plain path bypass left the model list readable
without credentials. With the header condition, an unauthenticated request to
`/v1/*` lands on authentik instead of reaching llama-server at all.

Router mode made that closure worth more, because `/v1/models` now enumerates
every model the router knows *and* each one's full child argv and rendered
preset — store path, context size, cache types. The API key is not among them:
llama.cpp strips `LLAMA_API_KEY` from the preset before rendering a child's
argv, and the child picks it up from the inherited environment instead. So it is
a fingerprinting leak rather than a credential one, and the header condition is
what keeps it off the public hostname.

The key comes from sops via `LLAMA_API_KEY` in an `EnvironmentFile`, never
`--api-key` on the command line: `/proc/*/cmdline` and `/nix/store` are both
world-readable. It lives in `shared.yaml` rather than a per-host file because
terra and both servers need it — wider than the three hosts that do, which is
the thing to fix when the sops files get split more finely.

### Driving it from a coding agent

The workstation side of the same endpoints. `modules/programs/vibes.nix` (the
home-manager aspect that carries Claude Code) also installs
[pi](https://github.com/earendil-works/pi) and
[opencode](https://github.com/sst/opencode), and writes each one's config so
both can drive the fleet's own GPUs instead of a paid API:

| agent | config file | credential form |
| --- | --- | --- |
| pi | `~/.pi/agent/models.json` | `!cat <path>` |
| opencode | `~/.config/opencode/opencode.json` | `{file:<path>}` |

Both get the same six entries — `text` and `vision` on `amos1`, plus `code` and
`text-qwen` alongside those two on `terra` — rendered from one `llamaHosts`
attrset in that module rather than written twice. It mirrors each host's
`myLlamaCpp.models` and has to be edited in lockstep with it. The two agents disagree about nearly every field name
(`contextWindow` vs `limit.context`, `input` vs `modalities.input`) but not
about the facts.

Both come from `nixpkgs-unstable`, whose lag is small where stable's isn't
(pi 0.84.4 vs 0.75.4, opencode 1.18.25 vs 1.15.10). pi is *not* taken from
upstream's community flake ([lukasl-dev/pi.nix](https://github.com/lukasl-dev/pi.nix)):
the two track the same rev, but nixpkgs' build is served by `cache.nixos.org`
while pi.nix would add three transitive inputs and a cachix substituter for one
feature we don't need (its bubblewrap jail).

Five things make this work, none of which needed a server-side change:

- **The model ids are the routers' `aliases`, not GGUF names.** `text`,
  `code`, `text-qwen` and `vision` survive swapping the weights underneath; the
  `<repo>:<quant>` names would not. That is what makes #518's open question —
  which model actually writes better patches — a picker entry rather than a
  rebuild.
- **Tool calling is already on.** llama.cpp rejects a `tools` param without
  `--jinja` — but `--jinja` defaults to *enabled* in b9190, so `myLlamaCpp`
  inherits it and a full agent loop (bash tool → answer) works from both agents
  against both hosts as deployed.
- **No OpenAI-compat shims.** llama-server accepts the `developer` role and
  takes `reasoning_effort` — ignoring it for Qwen3 rather than 400ing, and
  honouring it for gpt-oss — so pi's `compat` escape hatches stay unset and
  opencode's stock `@ai-sdk/openai-compatible` needs nothing beyond a URL and a
  key.
- **opencode's ai-sdk provider is bundled, not fetched.** Naming an `npm`
  package in a provider block normally implies a runtime install; this one ships
  inside the binary, so the config works on a host that has never reached the
  npm registry.
- **The key is read at request time, not baked in.** Both configs land in
  `/nix/store` and are world-readable, so each references a home-manager sops
  secret by path — the same `shared.yaml` key llama-server enforces. Rotation
  needs no rebuild.

Thinking is always on, and the lever differs per model. The Qwen3 models are
hybrid-thinking and `reasoning_effort` doesn't gate them, so pi's
`--thinking off` can't suppress the `<think>` pass;
`chat_template_kwargs.enable_thinking = false` does, via a model's
`samplingParams` (pi) or `options` (opencode). gpt-oss reasons through the
harmony format instead, where `reasoning_effort` *is* a real knob
(low/medium/high, default medium). Both are left unset — reasoning earns its
tokens for agentic work — and are worth reaching for only if a small-context
model is burning its window on preamble.

Both providers point at caddy, including on terra itself, so terra's own
requests loop out to amos1 and back rather than hitting its loopback port. That
buys one identical file on every host in exchange for a hop on a wired segment.
`terra` 502s whenever that desktop is off; pick an `amos1` model instead.

Two things stay unmanaged on purpose. pi's `settings.json` is written by pi
itself (`/model` Ctrl+S, `pi install`), so it is left alone — `models.json` is
the read-only half and the only one symlinked. opencode has no such split:
providers share `opencode.json` with everything else, so managing providers
means managing the file, and the cost is that `opencode plugin --global` can't
rewrite it (declare plugins in the module instead). Project-local
`opencode.json` still layers on top, and `opencode providers` writes credentials
to a separate `auth.json`.

penguin is the exception to all of it. It is a standalone home-manager config
with no sops, so it gets both agents with no local-inference providers rather
than entries pointing at a key file that will never exist.

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
- `sops.useSystemdActivation = true` runs decryption as a real systemd unit
  (`sops-install-secrets.service`) instead of a nixos-activation script, so
  consumer units can order against it explicitly

### Recovering from a sops decryption failure

If `sops-install-secrets.service` fails on boot (most commonly: the host's age
key isn't present yet, the secret was re-encrypted against a different key, or a
YAML file is malformed), any service that reads the missing secret via a script
will hit a no-op guard or auth-fail. The current safety net for postgres roles
is the `unitConfig.ConditionPathExists` on `<app>-db-password.service` (see
`modules/system/postgresql.nix`): the unit refuses to run if the secret file is
missing, so it can't silently `ALTER USER … WITH PASSWORD ''` and lock the app
out of its DB.

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
`journalctl -u sops-install-secrets` has the underlying decryption error. The
`*-db-password` units are oneshots, so re-running them is always safe — they
just ALTER USER with whatever password is currently in the decrypted file.

## Task Automation

Common operations are automated via `Taskfile.yaml`. The bootstrap, recovery,
and secrets-management workflows live in `taskfiles/*.yaml` and are pulled in
via Task's `includes:`, so `task --list` shows the full prefixed surface
(`bootstrap:*`, `recovery:*`, `secrets:*`).

| Command                                          | Description                                                                      |
| ------------------------------------------------ | -------------------------------------------------------------------------------- |
| `task rebuild`                                   | Rebuild current NixOS host                                                       |
| `task rebuild:<host>`                            | Rebuild a specific NixOS host                                                    |
| `task deploy:<host>`                             | Build locally and push the closure to a live remote host (`switch` over SSH)     |
| `task build_darwin:<host>`                       | Rebuild a nix-darwin host                                                        |
| `task build_home:<target>`                       | Rebuild standalone home-manager                                                  |
| `task build`                                     | Build a host without switching (default: luna)                                   |
| `task build-all`                                 | Build all NixOS host configurations                                              |
| `task update`                                    | Update flake inputs                                                              |
| `task update_dconf`                              | Capture host dconf config into the repo via `scripts/dconf.sh`                   |
| `task lint`                                      | Run statix and deadnix                                                           |
| `task fmt`                                       | Format all Nix files with nixfmt                                                 |
| `task fmt-check`                                 | Check formatting without modifying files                                         |
| `task check`                                     | Full pre-push check (fmt-check + lint + flake check)                             |
| `task iso`                                       | Build the installer/recovery ISO                                                 |
| `task garbage_collect`                           | Remove store objects older than 7 days                                           |
| `task bootstrap:new HOST=x DEST=ip`              | New host pipeline: install, hwconfig, secrets setup, sync + rebuild              |
| `task bootstrap:reinstall HOST=x DEST=ip`        | Reinstall existing host: install + sync + rebuild (no secrets pause)             |
| `task bootstrap:install HOST=x DEST=ip`          | Run nixos-anywhere to install NixOS; prints age key at end                       |
| `task bootstrap:hwconfig HOST=x DEST=ip`         | Extract hardware-configuration.nix from target                                   |
| `task bootstrap:hostkey HOST=x DEST=ip`          | Re-derive age key from live host SSH key (fallback if install output was missed) |
| `task bootstrap:secrets HOST=x DEST=ip`          | Add host age key to nix-secrets, create host secrets, commit                     |
| `task bootstrap:sync HOST=x DEST=ip`             | Rsync nixos and nix-secrets to target                                            |
| `task bootstrap:rebuild HOST=x DEST=ip`          | Run nixos-rebuild switch on target                                               |
| `task recovery:<app> HOST=x [SOURCE_HOST=other]` | Restore a single app from restic; see `task --list` for the full app menu        |
| `task recovery:all HOST=x`                       | Catastrophic restore: every per-app dispatcher in sequence                       |
| `task recovery:test:full SOURCE_HOST=x`          | Quarterly drill — install tests-server VM, restore three shapes, teardown        |
| `task secrets:oidc APP=x [HOST=y]`               | Generate OIDC `client_id` + `client_secret` for an app on a host                 |
| `task secrets:dbpw APP=x [HOST=y]`               | Generate a postgres `db_password` for an app on a host                           |
| `task secrets:secret APP=x KEY=k`                | Generic high-entropy hex secret at `<app>.<key>`                                 |
| `task secrets:edit:<host>`                       | Open a host's sops yaml in `$EDITOR`                                             |
| `task secrets:view:<host>`                       | Decrypt and print a host's sops yaml                                             |
| `task llm:models [HOST=x]`                       | List cached GGUFs on a llama-server host, flagging the live one                  |
| `task llm:models:prune [HOST=x] [APPLY=true]`    | Remove superseded GGUFs; dry run unless `APPLY=true`                             |
| `task secrets:rekey`                             | Re-encrypt every `sops/*.yaml` against current `.sops.yaml`                      |

## Bootstrapping a New Host

### Prerequisites

- Target machine booted into a NixOS ISO (use `task iso` for a custom one)
- This repo and `nix-secrets` cloned on the source machine (e.g.
  `~/src/{nixos,nix-secrets}`)
- A key on the source machine that can decrypt secrets
  (`~/.config/sops/age/keys.txt`)

### Connecting the target to wifi (minimal ISO)

If the target has no ethernet, get it on wifi before running any bootstrap tasks
— they all SSH into `DEST`. The minimal ISO ships `nmtui`. On the target's TTY:

```bash
sudo nmtui
```

Pick "Activate a connection", select your SSID, enter the passphrase.

### 1. Create host config files

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

Two VM-compatible flake hosts exist for local testing:

- `tests-server` — server-shaped (imports `server` + `server-apps`, same as
  hpp-1). Used by `task recovery:test:full` for the quarterly restore drill.
- `tests-desktop` — desktop-shaped (imports the workstation profile). Useful for
  iterating on desktop modules without a real machine.

The `task vm:*` namespace drives a single quickemu VM at a time under
`~/vms/nixos-vm/`, with a persistent SSH host key (and matching age identity)
preserved across teardowns. Authorize the VM key onto the secrets it needs once
via `task vm:sops-authorize TARGET=<host>` (uncommitted edit in
`../nix-secrets`; commit + push via `task secrets:publish` to make sticky, or
`git restore` to revoke).

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
