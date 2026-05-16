# Jellyfin - media server
# Native services.jellyfin from nixpkgs (system user `jellyfin`,
# /var/lib/jellyfin for state). Hardware transcoding and OIDC are
# tracked as follow-ups; v1 is just the bare service + caddy + backups.
#
# Backups: /var/lib/jellyfin contains both XML config and the library
# SQLite databases. Restic snapshots the whole tree, but live SQLite
# files can be torn mid-write — `library.db` and `jellyfin.db` get an
# extra consistent copy via `sqlite3 .backup` into /var/backup/jellyfin
# before each restic run, captured by the same snapshot. On restore,
# prefer the staged copy from /var/backup/jellyfin/ over the live one
# under /var/lib/jellyfin/data/.
_: {
  flake.modules.nixos.jellyfin =
    {
      hostSpec,
      pkgs,
      ...
    }:
    let
      jellyfinHost = "jellyfin.${hostSpec.serverDomain}";
      jellyfinPort = 8096;
      sqliteBackupDir = "/var/backup/jellyfin";
    in
    {
      services.jellyfin = {
        enable = true;
        # Run as the shared server-env user so jellyfin can read media
        # off the NFS-mounted Synology share at /mnt/content. UIDs are
        # pinned to match the NAS (server-dev=1029, server-prod=1030,
        # group servers=65536) so NFS doesn't have to translate.
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      # Append jellyfin's persistent state + the sqlite staging dir to
      # the restic snapshot. listOf merges via concat so the existing
      # /var/backup/postgresql + /var/lib/containers paths from
      # modules/system/server-backups.nix stay intact.
      preservation.preserveAt."/persist".directories = [ "/var/lib/jellyfin" ];

      services.restic.backups.server.paths = [
        "/var/lib/jellyfin"
        sqliteBackupDir
      ];

      systemd = {
        # Ensure the staging dir exists with sane permissions before the
        # pre-hook tries to write into it. 0700 root:root — restic runs
        # as root and the dumps may contain user data.
        tmpfiles.rules = [
          "d ${sqliteBackupDir} 0700 root root -"
        ];

        services = {
          # SQLite online .backup of jellyfin's databases into the
          # staging dir. Runs before restic-backups-server so the
          # snapshot includes a guaranteed-consistent copy alongside
          # the live files. wantedBy (not requires) so a failure here
          # doesn't abort the nightly restic run.
          jellyfin-sqlite-backup = {
            description = "Snapshot Jellyfin SQLite databases for restic";
            before = [ "restic-backups-server.service" ];
            wantedBy = [ "restic-backups-server.service" ];
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Group = "root";
            };
            script = ''
              set -euo pipefail
              for db in library.db jellyfin.db; do
                src="/var/lib/jellyfin/data/$db"
                [ -f "$src" ] || continue
                ${pkgs.sqlite}/bin/sqlite3 "$src" ".backup ${sqliteBackupDir}/$db"
              done
            '';
          };
        };
      };

      myCaddy.apps.jellyfin = {
        host = jellyfinHost;
        routeConfig = ''
          reverse_proxy localhost:${toString jellyfinPort}
        '';
      };

      myHomepage.tiles.Jellyfin = {
        group = "Consumption";
        href = "https://${jellyfinHost}";
        icon = "jellyfin";
        description = "Media server";
      };
    };
}
