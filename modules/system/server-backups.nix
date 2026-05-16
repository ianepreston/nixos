# Server backups - Simple Aspect
# Two-phase backup strategy for server hosts:
#   1. services.postgresqlBackup dumps every postgres database to
#      /var/backup/postgresql; services.mysqlBackup dumps every mariadb
#      database to /var/backup/mysql.
#   2. services.restic.backups.server snapshots /var/backup/postgresql,
#      /var/backup/mysql, and /var/lib/containers (all containerized app
#      state) to the NFS-mounted Synology share at
#      /mnt/backups/restic/<hostname>.
#
# Restore is a manual operator action; see README "Server App Pattern".
#
# The restic password lives in shared.yaml (not per-host) so any server
# can decrypt any other server's repo for cross-host recovery testing.
#
# `mySqliteQuiesce` (modules/platform/sqlite-quiesce.nix) is imported
# here so SQLite-backed app modules can opt into a pre-restic
# `.backup` oneshot wherever this profile is in effect.
{ inputs, ... }:
{
  flake.modules.nixos.server-backups =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    {
      imports = [ inputs.self.modules.nixos.mySqliteQuiesce ];

      # Operator-facing CLI for ad-hoc snapshot/restore work
      # (e.g. cross-host recovery from /mnt/<env>-backups/restic/<host>).
      environment.systemPackages = [ pkgs.restic ];

      sops.secrets."restic/password" = { };

      services = {
        postgresqlBackup = {
          enable = true;
          location = "/var/backup/postgresql";
          compression = "gzip";
          startAt = "*-*-* 02:00:00";
        };

        mysqlBackup = {
          enable = true;
          location = "/var/backup/mysql";
          # Same daily cadence as postgres; restic ordering below picks up
          # both dumps in the same morning's snapshot.
          calendar = "*-*-* 02:00:00";
        };

        restic.backups.server = {
          repository = "/mnt/backups/restic/${hostSpec.hostName}";
          passwordFile = config.sops.secrets."restic/password".path;
          initialize = true;

          paths = [
            "/var/backup/postgresql"
            "/var/backup/mysql"
            "/var/lib/containers"
          ];

          exclude = [
            "/var/lib/containers/*/cache"
            "/var/lib/containers/*/Cache"
            "/var/lib/containers/*/tmp"
          ];

          timerConfig = {
            OnCalendar = "*-*-* 03:00:00";
            Persistent = true;
            RandomizedDelaySec = "30m";
          };

          pruneOpts = [
            "--keep-daily 7"
            "--keep-weekly 4"
            "--keep-monthly 6"
          ];
        };
      };

      # Restic timer fires after the database dumps so each daily snapshot
      # contains the morning's dumps from both engines.
      systemd.services.restic-backups-server = {
        after = [
          "mnt-backups.mount"
          "postgresqlBackup.service"
          "mysql-backup.service"
        ];
        requires = [ "mnt-backups.mount" ];
      };
    };
}
