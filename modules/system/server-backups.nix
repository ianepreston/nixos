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
#
# Healthchecks.io liveness — closes #138. Prometheus rules catch units
# that *failed*, but a timer that never fired (masked dep, disabled
# unit, etc.) leaves no `state="failed"` sample to alert on. Each
# backup unit therefore ExecStartPost-curls a per-job healthchecks.io
# heartbeat URL on success. If the daily ping misses its window
# healthchecks.io pages via the existing Discord integration —
# mirroring the Alertmanager Watchdog pattern.
#
# ExecStartPost is only invoked when ExecStart exits 0 on a Type=oneshot
# unit, so a failing backup deliberately does *not* ping. The dead-man's
# switch is the missing ping, not an explicit /fail call.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.server-backups =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      # Heartbeat helper. curl flags: fail on HTTP errors, silent w/
      # body suppressed, hard 10s cap, retry transient network/5xx
      # blips. systemd expands $HEALTHCHECK_URL from the unit's
      # EnvironmentFile=; no shell involved, so the env var sits at
      # argv[N] verbatim — exactly one argument, no word-splitting.
      # Healthchecks.io accepts a bare GET as a successful ping.
      heartbeatCmd = "${pkgs.curl}/bin/curl -fsS -m 10 --retry 5 -o /dev/null $HEALTHCHECK_URL";
    in
    {
      imports = [ inputs.self.modules.nixos.mySqliteQuiesce ];

      # Operator-facing CLI for ad-hoc snapshot/restore work
      # (e.g. cross-host recovery from /mnt/<env>-backups/restic/<host>).
      environment.systemPackages = [ pkgs.restic ];

      sops.secrets = {
        "restic/password" = { };
        # Three per-job heartbeat URLs. Per-host sops file because the
        # restic repo is also per-host, and each backup unit needs its
        # own healthchecks.io check (otherwise one job silently masks
        # another's miss).
        "healthchecks/restic_backup_url" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = [ "restic-backups-server.service" ];
        };
        "healthchecks/postgresql_backup_url" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = [ "postgresqlBackup.service" ];
        };
        "healthchecks/mysql_backup_url" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = [ "mysql-backup.service" ];
        };
      };

      # One env-file template per unit so each unit only sees its own
      # URL (defence-in-depth — a buggy ExecStartPost can't accidentally
      # ping the wrong check).
      sops.templates = {
        "restic-heartbeat.env" = {
          content = ''
            HEALTHCHECK_URL=${config.sops.placeholder."healthchecks/restic_backup_url"}
          '';
          restartUnits = [ "restic-backups-server.service" ];
        };
        "postgresql-backup-heartbeat.env" = {
          content = ''
            HEALTHCHECK_URL=${config.sops.placeholder."healthchecks/postgresql_backup_url"}
          '';
          restartUnits = [ "postgresqlBackup.service" ];
        };
        "mysql-backup-heartbeat.env" = {
          content = ''
            HEALTHCHECK_URL=${config.sops.placeholder."healthchecks/mysql_backup_url"}
          '';
          restartUnits = [ "mysql-backup.service" ];
        };
      };

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

      systemd.services = {
        # Restic timer fires after the database dumps so each daily
        # snapshot contains the morning's dumps from both engines.
        # ExecStartPost runs only on successful ExecStart, giving us
        # the "last successful snapshot" liveness the issue asks for.
        restic-backups-server = {
          after = [
            "mnt-backups.mount"
            "postgresqlBackup.service"
            "mysql-backup.service"
          ];
          requires = [ "mnt-backups.mount" ];
          serviceConfig = {
            EnvironmentFile = [ config.sops.templates."restic-heartbeat.env".path ];
            ExecStartPost = [ heartbeatCmd ];
          };
        };

        postgresqlBackup.serviceConfig = {
          EnvironmentFile = [ config.sops.templates."postgresql-backup-heartbeat.env".path ];
          ExecStartPost = [ heartbeatCmd ];
        };

        mysql-backup.serviceConfig = {
          EnvironmentFile = [ config.sops.templates."mysql-backup-heartbeat.env".path ];
          ExecStartPost = [ heartbeatCmd ];
        };
      };
    };
}
