# Backups and restore

Server hosts run `modules/system/server-backups.nix`, which composes:

- `services.postgresqlBackup` — daily `pg_dumpall` to `/var/backup/postgresql`
  (gzip, runs at 02:00).
- `services.mysqlBackup` — daily mariadb dump to `/var/backup/mysql` (also at
  02:00). Same restic snapshot picks both engines up.
- `services.restic.backups.server` — daily restic snapshot of
  `/var/backup/postgresql`, `/var/backup/mysql`, and app-contributed state paths to
  `/mnt/backups/restic/${hostName}` on the NFS-mounted Synology share (runs at
  03:00 with a 30-minute randomized delay). Retention:
  `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

Native app modules declare `myAppState.<app>` as the authoritative source for
state preservation and backup paths. It renders the preservation entry, the
Restic path (unless `backup = false`), and the profile's preservation guard;
apps do not extend Restic paths directly. See
[the app-state guide](../agents/app-state.md).

Container state under `/var/lib/containers` is preserved as a whole by
`modules/system/preservation-server.nix`. Backup is narrower:
`myContainerApp.<app>.stateDirs` contributes only declared app directories,
excluding Podman's image store. State outside that tree needs its own
`myAppState` declaration.

SQLite-backed apps additionally opt into the `mySqliteQuiesce` helper
(`modules/system/sqlite-quiesce.nix`), which runs `sqlite3 .backup` for each
declared database into `/var/backup/sqlite/<app>/` immediately before each
restic run. The staging root is added to the restic paths automatically, so each
snapshot contains both the (hot, possibly torn) live file in the app's state
directory and a guaranteed-consistent copy under `/var/backup/sqlite/<app>/`.
Apps currently declaring it: audiobookshelf, bambuddy, bazarr, bindery, gatus,
jellyfin, komga, lidarr, minuspod, pinchflat, prowlarr, radarr, shelfmark, sonarr,
wealthfolio. The enabled set depends on the host's module imports.

Only server-local app state is in scope. NAS-resident media under `/mnt/content`
is protected NAS-side via Synology snapshots / Hyper Backup, not by restic.

The restic password lives in `server-shared.yaml` (one value, all servers), so
any server can decrypt any other host's repo for cross-host recovery testing. Each host
still mounts the _other_ environment's backup share read-only at
`/mnt/<otherEnv>-backups` (see `nfsclient.nix`), so e.g. restoring prod state
onto a dev host is a one-liner pointing restic at
`/mnt/prod-backups/restic/<prod-host>` — no extra credentials needed.

The restic repo path is read-write from the host that owns it, so a compromised
server or fat-fingered `rm` could in principle delete its own backups. Mitigate
by enabling **Synology snapshots** on the `server-{dev,prod}-backups` shares —
that's an out-of-band, client-immutable copy.

## Restore runbook (catastrophic rebuild)

Recovery is an explicit operator action — there's intentionally no automatic
restore on container start, since "first boot" and "restore after data loss" are
different decisions.

The `recovery:*` tasks in `taskfiles/recovery.yaml` automate every step below.
Use them for the fast path:

```bash
task bootstrap:reinstall HOST=<host> DEST=<ip>      # reinstall NixOS
task recovery:all HOST=<host> [SOURCE_HOST=<other>] # restore everything
# or, scoped to one app:
task recovery:app APP=<app> HOST=<host>
```

`SOURCE_HOST` defaults to `HOST` (in-place restore); set it to a different host
to seed from that host's restic repo (e.g. prod → dev). The longhand below
documents what each per-app dispatcher actually does so the runbook keeps
working if a task is unavailable or you need to deviate.

Every longhand `restic` invocation below carries `--retry-lock 10m`, matching
the dispatchers. A restore takes a read lock, and the nightly `forget --prune`
holds an exclusive one for ~47s at around 03:2x — without the flag restic
retries zero times and the restore aborts partway through with exit 11 (#676).
If a restore still reports the repo as locked, a previous run died holding one:
`sudo restic -r <repo> --password-file /run/secrets/restic/password unlock`
clears a stale lock, which is what the dispatchers do automatically.

1. **Reinstall the host:**

   ```bash
   task bootstrap:reinstall HOST=<host> DEST=<ip>
   ```

   NixOS comes back up with the same module set; container services will fail
   because their state directories are empty.

2. **Pull state back from restic:**

   ```bash
   sudo restic -r /mnt/backups/restic/<host> \
     --password-file /run/secrets/restic/password --retry-lock 10m \
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
   `ensureDatabases` has already created (`role "bookorbit" already exists`, etc.)
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
   `ALTER USER ... WITH PASSWORD ...` flow used by bookorbit) re-apply on the next
   service start via the per-app `<app>-db-password.service` units, so you don't
   need to set them by hand.

4. **Restart the app containers:**
   ```bash
   sudo systemctl restart 'podman-*.service'
   ```

## Per-app restore

The catastrophic rebuild restores everything. To recover just one app without
touching the rest of the host, scope both the restic include and the postgres
replay. The three apps in this repo each illustrate a different shape — pick the
one that matches what you're restoring. Paperless-ngx, the highest-value
restore, has its own section after them.

The postgres examples below replay the _current_ on-disk dump at
`/var/backup/postgresql/all.sql.gz` (refreshed nightly at 02:00). To restore
from an _older_ snapshot, pull that snapshot's dump to a temp path first:

```bash
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password --retry-lock 10m \
  restore <snapshot-id> --target /tmp/restore \
  --include /var/backup/postgresql
# then point zcat at /tmp/restore/var/backup/postgresql/all.sql.gz
```

`pg_dumpall` writes one combined file with every database and role. The awk
filter below extracts a single database's section by tracking `\connect <name>`
markers. It also stops at `CREATE DATABASE`, because `pg_dumpall` emits the
next database's creation statement before its `\connect` marker; replaying
that statement can fail on an already-provisioned database. This matches the
filter in `taskfiles/recovery.yaml`. Roles are managed by NixOS `ensureUsers`
and don't need to be replayed.

### Containerized app with volume + postgres database (bookorbit)

BookOrbit has both local state (`/var/lib/containers/bookorbit/data`, mounted
as `/data`) and database state (the `bookorbit` Postgres database, including
users, library metadata, and UI-configured OIDC settings). **Restore both from
the same Restic snapshot.** Library media mounted from `/mnt/content` is
protected separately by the NAS.

```bash
# 1. Stop the container so nothing writes during restore.
sudo systemctl stop podman-bookorbit.service

# 2. Restore the volume from restic.
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password --retry-lock 10m \
  restore latest --target / --include /var/lib/containers/bookorbit

# 3. Drop and recreate the database with its required extensions, then
#    replay just the bookorbit section of pg_dumpall. The role already
#    exists (NixOS ensureUsers); its password is unchanged.
sudo -u postgres dropdb --if-exists bookorbit
sudo -u postgres createdb -O bookorbit bookorbit
sudo systemctl restart bookorbit-db-extensions.service
zcat /var/backup/postgresql/all.sql.gz | awk '
  /^\\connect / { db = $2; gsub(/"/, "", db); in_target = (db == "bookorbit"); next }
  /^CREATE DATABASE / { in_target = 0; next }
  in_target { print }
' | sudo -u postgres psql -v ON_ERROR_STOP=1 bookorbit

# 4. Restart. bookorbit-db-password.service is wantedBy podman-bookorbit
#    and re-applies the sops-managed role password before the
#    container comes up, so authentication keeps working.
sudo systemctl start podman-bookorbit.service
```

Same pattern for any future containerized app with a postgres database:
substitute the unit name, volume path, and database name.

### 12-factor app with all state in postgres (miniflux)

Miniflux is a single Go binary running under `DynamicUser=true` with no
persistent on-disk state — feeds, entries, read/unread flags, and OIDC user
mappings all live in the `miniflux` postgres database. Restore is just the
database half of the BookOrbit flow (without its extension setup):

```bash
sudo systemctl stop miniflux.service
sudo -u postgres dropdb --if-exists miniflux
sudo -u postgres createdb -O miniflux miniflux
zcat /var/backup/postgresql/all.sql.gz | awk '
  /^\\connect / { db = $2; gsub(/"/, "", db); in_target = (db == "miniflux"); next }
  /^CREATE DATABASE / { in_target = 0; next }
  in_target { print }
' | sudo -u postgres psql -v ON_ERROR_STOP=1 miniflux
sudo systemctl start miniflux.service
```

Authentik fits the same shape (everything in the `authentik` postgres db, no
host state worth restoring) — same recipe with the names swapped.

### Native service with on-disk state + SQLite (jellyfin, \*arr, komga, …)

Jellyfin keeps everything under `/var/lib/jellyfin` — XML config, plugins,
metadata cache, and the library SQLite database at
`/var/lib/jellyfin/data/jellyfin.db`. There's no postgres to restore. The
wrinkle is that the live SQLite file can be torn mid-write inside a restic
snapshot; `jellyfin-sqlite-backup.service` (from the `mySqliteQuiesce` helper)
runs `sqlite3 .backup` into `/var/backup/sqlite/jellyfin/` immediately before
each restic run, and **those staged copies — not the live ones — are the
authoritative recovery source.**

`/var/lib/jellyfin/metadata` is deliberately excluded from the snapshot (#569):
it was 11 of the 12 GB of jellyfin state and holds nothing but provider-fetched
artwork, which a library scan re-downloads. It is still *preserved* across
reboots under impermanence — the exclude is restic-only, so a reboot does not
rebuild the cache.

The restore below therefore enumerates the state subdirs instead of the parent.
That is load-bearing: `restic restore --delete` removes anything under an
included path that the snapshot lacks, so restoring `/var/lib/jellyfin` as a
whole would wipe the live artwork every time. Adding
`--exclude /var/lib/jellyfin/metadata` alongside the parent `--include` is *not*
an option — restic 0.18 rejects the combination with "exclude and include
patterns are mutually exclusive".

`log/`, `.jellyfin-data` and `Subtitle Edit/` fall outside the enumerated set.
All three are self-healing: logs, a zero-byte marker jellyfin rewrites on start,
and plugin dictionaries the plugin re-fetches.

```bash
# 1. Stop the service so nothing writes during restore.
sudo systemctl stop jellyfin.service

# 2. Restore both the live tree and the staging dir from the same
#    snapshot.
sudo restic -r /mnt/backups/restic/<host> \
  --password-file /run/secrets/restic/password --retry-lock 10m \
  restore latest --target / \
  --include /var/lib/jellyfin/data \
  --include /var/lib/jellyfin/config \
  --include /var/lib/jellyfin/plugins \
  --include /var/lib/jellyfin/root \
  --include /var/backup/sqlite/jellyfin

# 3. Swap the live SQLite file for the consistent staged copy.
#    Use the env from the host's hostSpec (server-dev or server-prod);
#    `id server-prod` / `id server-dev` confirms which one exists.
sudo install -o server-prod -g servers -m 0640 \
  /var/backup/sqlite/jellyfin/jellyfin.db /var/lib/jellyfin/data/jellyfin.db

# 4. Restart. Jellyfin reopens the database and reuses whatever is
#    left in /var/lib/jellyfin/metadata; no library rescan is needed.
#    On a from-scratch rebuild that directory is empty, so the UI comes
#    up without posters or headshots until a scan re-fetches them.
sudo systemctl start jellyfin.service
```

Media files themselves live on the NAS under `/mnt/content` and are out of scope
for restic — Synology snapshots cover them.

The same pattern applies to other apps declared in `mySqliteQuiesce.apps`
(see the current list above): stop every consumer unit, then `restic restore`
both the app's state directory and `/var/backup/sqlite/<app>`
(the state path may be under `/var/lib/private` or `/var/lib/containers`),
then `install` each staged `.db` over the live path declared in the app's
module. Check `mySqliteQuiesce.apps.<app>.databases` in the module for the exact
source paths to overwrite (e.g. sonarr →
`/var/lib/sonarr/.config/ NzbDrone/{sonarr,logs}.db`, bazarr →
`/var/lib/bazarr/db/bazarr.db`). Match the file owner to the service's
user/group (`server-${env}: servers` for the NFS-aligned apps).

### Document archive (paperless-ngx)

Paperless holds the household document archive, the one dataset here that can't
be rebuilt from anywhere else, so it is the restore to get right. It is part of
the quarterly `recovery:test:full` drill. Use the dispatcher:

```bash
task recovery:app APP=paperless-ngx HOST=<host> [SOURCE_HOST=<other>]
```

It restores files and Postgres together on native services. It stops all four
units (`paperless-{scheduler,task-queue,consumer,web}`), restores `/var/lib/paperless-ngx`
(original and archived documents under `media/`, the Tantivy search index, the
model cache) with `--delete`, and replays the `paperless_ngx` database from the
same snapshot. Then it starts the units and waits for `/accounts/login/` on
`127.0.0.1:8010` to return 200. Restore the files and the database together,
because document rows point at files in `media/`. NixOS provides the role, and
sops provides the secret key and OIDC client credentials, so the restore doesn't
touch either.

The vector store (`llm_index/`) is excluded from backup on purpose (#558).
`--delete` removes the old one, so AI suggestions and chat have no index to
retrieve from until the 07:10 index task re-embeds every document. To skip the
wait, rebuild it by hand: `sudo paperless-manage document_llmindex rebuild`.

## Cross-host recovery testing (prod → dev)

Same flow, but pointed at the other env's repo via the cross-mount:

```bash
sudo restic -r /mnt/prod-backups/restic/<prod-host> \
  --password-file /run/secrets/restic/password --retry-lock 10m \
  restore latest --target /tmp/prod-restore
```

`--target /tmp/prod-restore` keeps the prod data sandboxed instead of
overwriting dev's live `/var/lib/containers`. From there you can spot-check
files, replay the postgres dump into a scratch database, etc.
