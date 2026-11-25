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

      # The staged name is passed to sqlite's `.backup` unquoted, and its
      # dot-command parser splits on whitespace and treats quotes and
      # backslashes specially, so only these characters reach the file
      # name intact. stage-checked.sh uses the same set.
      safeName = base: builtins.match "[A-Za-z0-9._+@%,:=~-]+" base != null;
      # A staged copy is named after its source's basename. A literal's is
      # known at evaluation; so is a glob's whose last component is a plain
      # safe name. Any other glob tail (a pattern, a shell escape such as
      # `plain\.db`, quoting) is only known once the shell resolves it.
      staticName = db: !isGlob db || safeName (baseNameOf db);
      # Static names claimed by more than one entry of an app.
      staticCollisions =
        app:
        lib.filterAttrs (_: dbs: lib.length dbs > 1) (
          lib.groupBy baseNameOf (lib.filter staticName app.databases)
        );
      # Only a runtime-named entry beside another entry can collide after
      # evaluation; those units resolve every entry before writing.
      needsRuntimeCheck = app: lib.length app.databases > 1 && !lib.all staticName app.databases;

      # Resolve a glob entry into `srcs`, which must hold exactly one match.
      # No trailing newline: callers interpolate it as a line of their own.
      resolveGlob =
        db:
        lib.removeSuffix "\n" ''
          srcs=( ${db} )
          if [ "''${#srcs[@]}" -ne 1 ]; then
            echo ${lib.escapeShellArg db}" matched ''${#srcs[@]} files, expected 1" >&2
            exit 1
          fi
        '';
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
                in /var/backup/sqlite/<name>/<basename>, so basenames
                must be distinct within an app: no two entries may share
                a staged file. A collision between names known at
                evaluation fails evaluation. Staged names may only use
                letters, digits and `._+@%,:=~-`, because sqlite's
                `.backup` takes them unquoted; a literal path with any
                other basename fails evaluation.
                An entry may be a glob for a path the app picks at
                runtime (wealthfolio's per-profile directory); it must
                match exactly one file, and the quiesce unit fails
                otherwise. Recovery resolves the same glob on restore.
                When a glob's last component is anything but a plain
                safe name (a pattern, a shell escape such as
                `plain\.db`), its staged name is checked once resolved:
                the unit fails before writing any staged copy if two
                entries would share one or a resolved name has any
                other character. A hidden file only matches a pattern
                that spells out its leading dot (`.*.db`).
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
            ''
            + (
              if needsRuntimeCheck app then
                ''
                  ${builtins.readFile ./_sqlite-quiesce/stage-checked.sh}
                  entries=()
                  ${lib.concatMapStringsSep "\n" (
                    db:
                    if isGlob db then
                      ''
                        ${resolveGlob db}
                        entries+=( resolved "''${srcs[0]}" )
                      ''
                    else
                      "entries+=( literal ${lib.escapeShellArg db} )"
                  ) app.databases}
                  stage_checked ${pkgs.sqlite}/bin/sqlite3 "$dstdir" "''${entries[@]}"
                ''
              else
                lib.concatMapStringsSep "\n" (
                  db:
                  if isGlob db then
                    ''
                      ${resolveGlob db}
                      ${pkgs.sqlite}/bin/sqlite3 "''${srcs[0]}" ".backup $dstdir/$(basename "''${srcs[0]}")"
                    ''
                  else
                    ''
                      src=${lib.escapeShellArg db}
                      if [ -f "$src" ]; then
                        ${pkgs.sqlite}/bin/sqlite3 "$src" ".backup $dstdir/$(basename "$src")"
                      fi
                    ''
                ) app.databases
                + "\n"
            );
          }
        ) apps;

        assertions = lib.concatLists (
          lib.mapAttrsToList (
            name: app:
            map (db: {
              assertion = false;
              message = "mySqliteQuiesce.apps.${lib.strings.escapeNixIdentifier name}.databases: `${db}` stages as `${baseNameOf db}`, which sqlite's .backup cannot take unquoted; staged names may only use letters, digits and `._+@%,:=~-`.";
            }) (lib.filter (db: !isGlob db && !safeName (baseNameOf db)) app.databases)
            ++ lib.mapAttrsToList (base: dbs: {
              assertion = false;
              message = "mySqliteQuiesce.apps.${lib.strings.escapeNixIdentifier name}.databases: ${
                lib.concatMapStringsSep ", " (db: "`${db}`") dbs
              } all stage to ${stagingRoot}/${name}/${base}; each database needs a distinct basename.";
            }) (staticCollisions app)
          ) apps
        );
      };
    };
}
