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
# `mySqliteQuiesce` (modules/system/sqlite-quiesce.nix) is imported
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

      # Textfile collector directory — defined in victoriametrics.nix's
      # node_exporter config. Kept in sync by hand; both modules live
      # in the same observability profile so they're loaded together.
      textfileDir = "/var/lib/node-exporter-textfile-collector";

      # Per-app aggregation for the latest snapshot. Streams `restic ls
      # --json` once, classifies each file by top-level path prefix, and
      # writes a textfile_collector `.prom` to publish per-app sizes plus
      # repo-wide stats. Path → (app, component) mapping mirrors the
      # backup paths declared across modules/apps/*.nix:
      #   /var/lib/containers/<app>/...       → container_state
      #   /var/lib/private/<app>/...          → state (DynamicUser apps)
      #   /var/lib/<app>/...                  → state
      #   /var/backup/postgresql/<db>.sql.gz  → postgres_dump
      #   /var/backup/mysql/<db>.gz           → mysql_dump
      #   /var/backup/sqlite/<app>/...        → sqlite_staging
      # Anything that doesn't match is dropped (e.g. mount roots,
      # top-level dirs). Atomic write via tempfile + rename so a
      # crashed run never leaves a partial `.prom` for node_exporter.
      resticMetrics =
        pkgs.writers.writePython3 "restic-metrics-server"
          {
            flakeIgnore = [
              "E501"
              "W391"
            ];
          }
          ''
            import datetime
            import json
            import os
            import re
            import subprocess
            import sys
            import tempfile

            REPO = os.environ["RESTIC_REPOSITORY"]
            PWF = os.environ["RESTIC_PASSWORD_FILE"]
            OUT = os.environ["TEXTFILE_OUT"]
            HOST = os.environ["RESTIC_HOST"]


            def restic(*args):
                cmd = ["restic", "-r", REPO, "-p", PWF, "--json", *args]
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    sys.stderr.write(r.stderr)
                    sys.exit(r.returncode)
                return r.stdout


            # `--latest 1 --host <h>` does NOT return a single snapshot:
            # restic groups by (host, paths-set) and returns the latest
            # for each group. Repos that have evolved their `paths`
            # list over time (e.g. new app modules adding to
            # services.restic.backups.server.paths) end up with many
            # groups and many "latest" results. Listing all snapshots
            # for the host and picking the chronologically newest is
            # the only robust way to find the actually-latest backup.
            snapshots = json.loads(restic("snapshots", "--host", HOST))
            if not snapshots:
                sys.stderr.write(f"no snapshots for host {HOST}\n")
                sys.exit(1)
            latest = max(snapshots, key=lambda s: s["time"])
            snap_id = latest["short_id"]
            snap_ts = datetime.datetime.fromisoformat(
                latest["time"].replace("Z", "+00:00")
            ).timestamp()

            # Single repo-wide stats call. raw-data mode returns
            # total_size + total_blob_count + snapshots_count. We
            # deliberately avoid `--mode restore-size` (and per-snapshot
            # stats calls) — each walks every blob/snapshot and adds
            # minutes on an NFS-backed repo. Snapshot size / file count
            # are derived from the `restic ls` stream below for free.
            repo = json.loads(restic("stats", "--mode", "raw-data"))


            def classify(path):
                parts = path.split("/")
                # parts[0] is "" because path starts with "/"; first real
                # segment is parts[1].
                if path.startswith("/var/lib/containers/") and len(parts) >= 5:
                    return (parts[4], "container_state")
                if path.startswith("/var/lib/private/") and len(parts) >= 5:
                    return (parts[4], "state")
                if path.startswith("/var/lib/") and len(parts) >= 4:
                    return (parts[3], "state")
                if path.startswith("/var/backup/postgresql/") and len(parts) >= 5:
                    m = re.match(r"^([^/]+?)(\.prev)?\.sql\.gz$", parts[4])
                    if m:
                        return (m.group(1), "postgres_dump")
                if path.startswith("/var/backup/mysql/") and len(parts) >= 5:
                    m = re.match(r"^([^/]+?)(\.prev)?\.gz$", parts[4])
                    if m:
                        return (m.group(1), "mysql_dump")
                if path.startswith("/var/backup/sqlite/") and len(parts) >= 5:
                    return (parts[4], "sqlite_staging")
                return None


            sizes = {}
            snap_total_size = 0
            snap_file_count = 0
            # --recursive is required: without it, restic 0.18+ only
            # walks the first 1-2 directory levels under each backup
            # root and silently emits a fraction of the snapshot's file
            # nodes. The snapshot summary's total_files_processed is
            # the truth check — they must match (modulo dirs/symlinks).
            proc = subprocess.Popen(
                ["restic", "-r", REPO, "-p", PWF, "ls", "--long", "--recursive", "--json", snap_id],
                stdout=subprocess.PIPE,
                text=True,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # First message is the snapshot header (message_type=snapshot).
                # File entries come as struct_type/message_type=node with
                # type=file.
                if obj.get("type") != "file":
                    continue
                size = int(obj.get("size", 0))
                snap_total_size += size
                snap_file_count += 1
                cls = classify(obj.get("path", ""))
                if cls is None:
                    continue
                sizes[cls] = sizes.get(cls, 0) + size
            proc.wait()
            if proc.returncode != 0:
                sys.stderr.write(f"restic ls exited {proc.returncode}\n")
                sys.exit(proc.returncode)

            out_dir = os.path.dirname(OUT)
            fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".restic.prom.")
            try:
                with os.fdopen(fd, "w") as f:
                    f.write("# HELP restic_repo_size_bytes Deduplicated size of restic repo (raw-data).\n")
                    f.write("# TYPE restic_repo_size_bytes gauge\n")
                    f.write(f"restic_repo_size_bytes {repo.get('total_size', 0)}\n")

                    f.write("# HELP restic_repo_blob_count Blob count in the restic repo.\n")
                    f.write("# TYPE restic_repo_blob_count gauge\n")
                    f.write(f"restic_repo_blob_count {repo.get('total_blob_count', 0)}\n")

                    f.write("# HELP restic_repo_snapshot_count Snapshot count in the restic repo.\n")
                    f.write("# TYPE restic_repo_snapshot_count gauge\n")
                    f.write(f"restic_repo_snapshot_count {repo.get('snapshots_count', 0)}\n")

                    f.write("# HELP restic_snapshot_size_bytes Raw size of the latest snapshot (sum of file sizes from `restic ls`).\n")
                    f.write("# TYPE restic_snapshot_size_bytes gauge\n")
                    f.write(f"restic_snapshot_size_bytes {snap_total_size}\n")

                    f.write("# HELP restic_snapshot_file_count File count in the latest snapshot.\n")
                    f.write("# TYPE restic_snapshot_file_count gauge\n")
                    f.write(f"restic_snapshot_file_count {snap_file_count}\n")

                    f.write("# HELP restic_snapshot_timestamp_seconds Unix timestamp of the latest snapshot for this host.\n")
                    f.write("# TYPE restic_snapshot_timestamp_seconds gauge\n")
                    f.write(f"restic_snapshot_timestamp_seconds {snap_ts}\n")

                    f.write("# HELP restic_app_size_bytes Restic-tracked size per app/component in the latest snapshot.\n")
                    f.write("# TYPE restic_app_size_bytes gauge\n")
                    for (app, component), size in sorted(sizes.items()):
                        f.write(
                            f'restic_app_size_bytes{{app="{app}",component="{component}"}} {size}\n'
                        )
                os.chmod(tmp, 0o644)
                os.replace(tmp, OUT)
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
          '';
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
          inherit (hostSpec) sopsFile;
          restartUnits = [ "restic-backups-server.service" ];
        };
        "healthchecks/postgresql_backup_url" = {
          inherit (hostSpec) sopsFile;
          restartUnits = [ "postgresqlBackup.service" ];
        };
        "healthchecks/mysql_backup_url" = {
          inherit (hostSpec) sopsFile;
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

      systemd = {
        services = {
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
              # Heartbeat first (cheap, liveness signal), then kick off
              # the metrics oneshot async so the backup unit doesn't
              # block on the per-app `restic ls` walk. The oneshot
              # itself is also runnable manually via
              # `systemctl start restic-metrics-server.service`.
              ExecStartPost = [
                heartbeatCmd
                "${pkgs.systemd}/bin/systemctl --no-block start restic-metrics-server.service"
              ];
            };
          };

          # Standalone metrics oneshot — fires automatically as an
          # ExecStartPost of the backup unit, but also runnable on
          # demand. Reads the latest snapshot, aggregates per-app sizes
          # via `restic ls`, writes a textfile_collector `.prom` for
          # node_exporter to pick up. Best-effort: if it fails the
          # backup is still considered successful (it's a separate
          # unit, no `Requires=` from the backup side).
          restic-metrics-server = {
            description = "publish restic snapshot metrics to node_exporter textfile collector";
            after = [ "mnt-backups.mount" ];
            requires = [ "mnt-backups.mount" ];
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "RESTIC_REPOSITORY=/mnt/backups/restic/${hostSpec.hostName}"
                "RESTIC_PASSWORD_FILE=${config.sops.secrets."restic/password".path}"
                "TEXTFILE_OUT=${textfileDir}/restic.prom"
                "RESTIC_HOST=${hostSpec.hostName}"
                "PATH=${pkgs.restic}/bin"
              ];
              ExecStart = "${resticMetrics}";
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

          # Weekly `restic check` against the repo to catch silent
          # corruption (bit-rot, partial truncation) that the nightly
          # backup itself won't detect. `--with-cache` reuses restic's
          # local pack cache so we don't re-download every pack from the
          # NAS each week. A failed check leaves the unit in `failed`
          # state, which is picked up by the `SystemdUnitFailed`
          # Prometheus rule in observability.nix and routed to
          # Alertmanager → Discord like any other unit failure.
          restic-check-server = {
            description = "restic check for server repo";
            after = [ "mnt-backups.mount" ];
            requires = [ "mnt-backups.mount" ];
            serviceConfig = {
              Type = "oneshot";
              # Match the backup job's privilege model: root, so the
              # unix-mount ACLs on /mnt/backups behave identically.
              User = "root";
              # Quiet down the journal noise from a healthy check;
              # restic prints per-pack progress otherwise.
              Environment = [
                "RESTIC_PROGRESS_FPS=0"
              ];
            };
            script = ''
              set -euo pipefail
              export RESTIC_REPOSITORY=/mnt/backups/restic/${hostSpec.hostName}
              export RESTIC_PASSWORD_FILE=${config.sops.secrets."restic/password".path}
              exec ${pkgs.restic}/bin/restic check --with-cache
            '';
          };
        };

        timers.restic-check-server = {
          description = "Weekly restic check for server repo";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            # Sunday 04:30 — well clear of the 03:00 nightly backup
            # window plus its 30m randomized delay, and after pruning
            # has typically settled.
            OnCalendar = "Sun *-*-* 04:30:00";
            Persistent = true;
            RandomizedDelaySec = "30m";
          };
        };
      };
    };
}
