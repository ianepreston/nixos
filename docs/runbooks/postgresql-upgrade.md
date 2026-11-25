# PostgreSQL major-version upgrades

`services.postgresql.package` is pinned to a specific major (`postgresql_18` at
time of writing) in `modules/system/postgresql.nix` so that rebuilds never
silently dump-and-restore the cluster. Major upgrades are a manual operation.
The canonical reference is the
[NixOS manual section](https://nixos.org/manual/nixos/stable/#module-services-postgres-upgrading).

**Historical recipe: the 17 → 18 upgrade below records the then-deployed
services and paths.** It is not a current consumer inventory; derive that
inventory from the target configuration before a future major upgrade.

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
