# Server backups - Simple Aspect
# Two-phase backup strategy for server hosts:
#   1. services.postgresqlBackup dumps every database to /var/backup/postgresql.
#   2. services.restic.backups.server snapshots /var/backup/postgresql and
#      /var/lib/containers (all containerized app state) to the NFS-mounted
#      Synology share at /mnt/backups/restic/<hostname>.
#
# Restore is a manual operator action; see README "Server App Pattern".
#
# The restic password lives in shared.yaml (not per-host) so any server
# can decrypt any other server's repo for cross-host recovery testing.
_: {
  flake.modules.nixos.server-backups =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    {
      # Operator-facing CLI for ad-hoc snapshot/restore work
      # (e.g. cross-host recovery from /mnt/<env>-backups/restic/<host>).
      environment.systemPackages = [ pkgs.restic ];

      sops.secrets."restic/password" = { };

      services.postgresqlBackup = {
        enable = true;
        location = "/var/backup/postgresql";
        compression = "gzip";
        startAt = "*-*-* 02:00:00";
      };

      services.restic.backups.server = {
        repository = "/mnt/backups/restic/${hostSpec.hostName}";
        passwordFile = config.sops.secrets."restic/password".path;
        initialize = true;

        paths = [
          "/var/backup/postgresql"
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

      # Restic timer fires after postgresqlBackup so each daily snapshot
      # contains the dumps from the same morning.
      systemd.services.restic-backups-server = {
        after = [
          "mnt-backups.mount"
          "postgresqlBackup.service"
        ];
        requires = [ "mnt-backups.mount" ];
      };
    };
}
