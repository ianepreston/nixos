# SQLite quiesce helper for restic backups.
# `mySqliteQuiesce.apps.<name>.databases = [...]` stages an online
# `sqlite3 .backup` copy of each listed database into
# /var/backup/sqlite/<name>/ before each restic-backups-server run,
# so the nightly snapshot includes a guaranteed-consistent copy
# alongside the (potentially mid-write) live files. WAL makes the
# hot copy *usually* fine, but `.backup` is the only thing sqlite
# itself promises is point-in-time consistent. On restore, prefer the
# staged copy under /var/backup/sqlite/<name>/ over the live one.
#
# Lives next to server-backups.nix rather than inline so app modules
# can still contribute to `mySqliteQuiesce.apps` from a self-contained
# option surface — the helper is consumed by exactly one consumer
# (server-backups) but the contribution pattern is the same as
# myCaddy.apps / myHomepage.tiles / etc.
#
# The oneshot runs as root with `before = [restic-backups-server.service]`
# and `wantedBy = [restic-backups-server.service]` (not requires) so a
# failed quiesce doesn't abort the nightly restic run — the hot copy
# still goes into the snapshot. Missing literal source files are
# silently skipped: apps drop/rename auxiliary databases (e.g.
# jellyfin's old `library.db`) across upgrades and we don't want every
# such change to break backups. Glob entries are the exception — they
# exist because the path isn't known at eval time, so a miss means the
# app moved its database and the unit fails rather than hide it.
_: {
  flake.modules.nixos.mySqliteQuiesce =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (config.mySqliteQuiesce) apps;
      stagingRoot = "/var/backup/sqlite";
      isGlob = db: builtins.match ".*[*?[].*" db != null;
    in
    {
      options.mySqliteQuiesce.apps = lib.mkOption {
        default = { };
        description = ''
          Apps with SQLite databases that should be quiesced before
          restic-backups-server fires. Each entry lists absolute paths
          to .db files; the helper creates one oneshot per app that
          runs `sqlite3 .backup` for each into
          /var/backup/sqlite/<name>/<basename> and orders it before
          the nightly restic snapshot.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.databases = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = ''
                Absolute paths to SQLite files. The basename ends up
                in /var/backup/sqlite/<name>/<basename>; basename
                collisions across the list are the caller's problem.
                An entry may be a glob for a path the app picks at
                runtime (wealthfolio's per-profile directory); it must
                match exactly one file, and the quiesce unit fails
                otherwise. Recovery resolves the same glob on restore.
              '';
            };
          }
        );
      };

      config = lib.mkIf (apps != { }) {
        # 0700 root:root — staged dumps may contain user data and
        # restic runs as root.
        systemd.tmpfiles.rules = [
          "d ${stagingRoot} 0700 root root -"
        ]
        ++ lib.mapAttrsToList (name: _: "d ${stagingRoot}/${name} 0700 root root -") apps;

        services.restic.backups.server.paths = [ stagingRoot ];

        systemd.services = lib.mapAttrs' (
          name: app:
          lib.nameValuePair "${name}-sqlite-backup" {
            description = "Snapshot ${name} SQLite databases for restic";
            before = [ "restic-backups-server.service" ];
            wantedBy = [ "restic-backups-server.service" ];
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Group = "root";
            };
            script = ''
              set -euo pipefail
              shopt -s nullglob
              dstdir=${lib.escapeShellArg "${stagingRoot}/${name}"}
              ${lib.concatMapStringsSep "\n" (
                db:
                if isGlob db then
                  ''
                    srcs=( ${db} )
                    if [ "''${#srcs[@]}" -ne 1 ]; then
                      echo ${lib.escapeShellArg db}" matched ''${#srcs[@]} files, expected 1" >&2
                      exit 1
                    fi
                    ${pkgs.sqlite}/bin/sqlite3 "''${srcs[0]}" ".backup $dstdir/$(basename "''${srcs[0]}")"
                  ''
                else
                  ''
                    src=${lib.escapeShellArg db}
                    if [ -f "$src" ]; then
                      ${pkgs.sqlite}/bin/sqlite3 "$src" ".backup $dstdir/$(basename "$src")"
                    fi
                  ''
              ) app.databases}
            '';
          }
        ) apps;
      };
    };
}
