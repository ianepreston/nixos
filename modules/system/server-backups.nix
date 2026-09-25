# Server backups - Simple Aspect
# Two-phase backup strategy for server hosts:
#   1. services.postgresqlBackup dumps every postgres database to
#      /var/backup/postgresql; services.mysqlBackup dumps every mariadb
#      database to /var/backup/mysql.
#   2. services.restic.backups.server snapshots those dump dirs, plus
#      every app state dir contributed by the module that owns it
#      (`myAppState` for native apps, `myContainerApp.<app>.stateDirs`
#      for containerized ones), to the NFS-mounted Synology share at
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

      # Shared node_exporter textfile-collector drop dir; see
      # ./observability-options.nix.
      textfileDir = config.myObservability.nodeExporterTextfileDirectory;

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
      # doCheck = false: ruff (git-hooks.nix) is the single Python authority;
      # writePython3's flake8 pass conflicts with ruff-format's W503 style.
      # See modules/apps/llm-metrics.nix for the full rationale.
      resticMetrics = pkgs.writers.writePython3 "restic-metrics-server" {
        doCheck = false;
      } (builtins.readFile ./_server-backups/restic-metrics.py);
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

          # Database dumps only. Every app state dir is contributed by the
          # module that owns it: native apps via `myAppState`
          # (modules/system/app-state.nix), containerized apps via
          # `myContainerApp.<app>.stateDirs`
          # (modules/system/oci-containers.nix).
          #
          # `/var/lib/containers` used to be listed here wholesale, which
          # also swept in podman's image store — 75 GB of amos1's 102 GB
          # snapshot, all of it re-pullable from registries (#567).
          paths = [
            "/var/backup/postgresql"
            "/var/backup/mysql"
          ];

          # Caches inside an app's own state dir. Still needed with the
          # narrowed paths above: these live under the per-app dirs that
          # `myContainerApp` contributes, not under the image store.
          #
          # Cross-app glob patterns only. An exclude that carves a
          # single app's state dir belongs in that app's module next to
          # its `myAppState` entry, where the rationale for dropping the
          # data can sit beside the declaration that contributes the
          # path — `services.restic.backups.server.exclude` is a list
          # option, so contributions merge. See the jellyfin module's
          # `metadata` exclude (#569) for the pattern.
          exclude = [
            "/var/lib/containers/*/cache"
            "/var/lib/containers/*/Cache"
            "/var/lib/containers/*/tmp"
          ];

          # `backup` takes an append lock, which coexists with the
          # metrics job's read lock but not with an exclusive one — and
          # it is the *first* of this unit's three ExecStart= lines, so
          # losing that race costs the snapshot itself, not just the
          # prune. `Persistent = true` here and on restic-check-server
          # below is what makes it reachable: a boot that has missed
          # both windows fires both catch-ups in the same transaction,
          # and `restic check`'s exclusive lock is held ~46s. Retry
          # rather than fail, same as `pruneOpts` (#676).
          #
          # `extraBackupArgs` is joined into the `backup` invocation
          # only; the prune and check lines take their own flag.
          extraBackupArgs = [ "--retry-lock 10m" ];

          # …and the flag on `backup` is not enough on its own, because
          # the unit dies before ExecStart even runs. `initialize = true`
          # makes nixpkgs emit an ExecStartPre of
          # `restic cat config > /dev/null || restic init`, and `cat`
          # takes a read lock (restic 0.18.1, cmd/restic/cmd_cat.go:71).
          # Against the check's exclusive lock that probe fails, the
          # `|| init` fallback then fails too ("config file already
          # exists"), and the unit is dead at status=1 with no snapshot
          # — observed directly by forcing the race on hpp-1.
          #
          # nixpkgs offers no way to put a flag on that probe:
          # `resticCmd`'s only injection point is `extraOptions`, which
          # becomes `-o key=value` (restic's extended options), not CLI
          # flags. `backupPrepareCommand` is the lever that works —
          # nixpkgs emits it as the *first* line of the same preStart,
          # so a retrying probe here blocks until the lock clears and
          # the unretried one right after it finds the repo free.
          # RESTIC_REPOSITORY / RESTIC_PASSWORD_FILE come from the
          # unit's own environment. `|| true` because this is only a
          # wait: any real repo problem is the next line's to report,
          # with its own error message.
          backupPrepareCommand = ''
            #!${pkgs.runtimeShell}
            ${pkgs.restic}/bin/restic --retry-lock 10m cat config > /dev/null || true
          '';

          timerConfig = {
            OnCalendar = "*-*-* 03:00:00";
            Persistent = true;
            RandomizedDelaySec = "30m";
          };

          # Flags for `restic forget --prune`, globals included — restic
          # registers `--retry-lock` on the root command, so it is
          # accepted after the subcommand like any policy flag.
          #
          # `--group-by host` is load-bearing, not cosmetic. restic's
          # default grouping is `host,paths`, and `paths` is not static
          # here — every app module contributes its own state dirs, so
          # adding or removing an app mints a brand-new retention group
          # with a fresh 7/4/6 budget. Once a paths-set stops recurring
          # its group is frozen: no new snapshots arrive to age the old
          # ones out, so its newest ~17 are kept forever and pin their
          # blobs against dedup. That kept ~4x the intended snapshots
          # (60 on amos1, 72 on hpp-1, vs the ~17 the policy implies)
          # until #568. One repo per host (see `repository` above) means
          # grouping by host alone collapses to a single policy.
          #
          # `--retry-lock` is what keeps this unit from failing when the
          # metrics oneshot happens to be mid-walk: prune wants an
          # exclusive lock, the metrics job holds a read lock, and
          # restic's default of zero retries turned a few seconds of
          # overlap into exit 11 and a SystemdUnitFailed page — twice in
          # the week after the metrics timer landed (#676). 10m is ~7x
          # the longest hold measured on either side (prune 47s, metrics
          # walk up to 80s), so it absorbs the overlap without masking a
          # genuinely wedged lock for long.
          #
          # Note this cannot be expressed via
          # `services.restic.backups.server.extraOptions`: nixpkgs maps
          # that to restic's `-o <key=value>` extended options, not to
          # CLI flags.
          pruneOpts = [
            "--retry-lock 10m"
            "--group-by host"
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
          #
          # That "successful" is per-unit, not per-snapshot: nixpkgs puts
          # `backup`, `unlock` and `forget --prune` in three ExecStart=
          # lines of this one oneshot, so a prune that fails suppresses
          # both the heartbeat and the metrics refresh even though the
          # snapshot itself landed — see `--retry-lock` in `pruneOpts`
          # above for the concurrency case that used to trigger that.
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

          # Standalone metrics oneshot — fires from the backup unit's
          # ExecStartPost, from its own boot + 6h timer below (#579),
          # and on demand. Reads the latest snapshot, aggregates per-app sizes
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
          #
          # `check` is the third exclusive-lock taker in this module, so
          # it gets the same `--retry-lock` as `forget --prune` (#676).
          # The metrics grid below deliberately avoids this unit's 04:30
          # + 30m jitter window, but its OnBootSec leg does not: a
          # nixos-upgrade reboot lands at ~04:45-05:35 and puts a walk
          # right on top of a Sunday check.
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
              exec ${pkgs.restic}/bin/restic check --with-cache --retry-lock 10m
            '';
          };
        };

        timers = {
          restic-check-server = {
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

          # Boot + 6-hourly refresh, on top of the backup unit's
          # ExecStartPost trigger above.
          #
          # `textfileDir` sits on the rolled-back @root subvolume, so
          # every `.prom` is wiped at boot. Every other producer in the
          # repo already carries an OnBootSec (mylar3, sabnzbd, valheim,
          # llama, podman-images, rollback-root) and so repopulates
          # within minutes; restic was written *only* by the daily
          # ExecStartPost at ~03:00, and the nixos-upgrade reboot lands
          # at ~04:45 — destroying it for the remaining ~22h of the day.
          # ResticSnapshotCountHigh (#568) was therefore evaluating an
          # absent series almost all the time and had never once had
          # data. Closes #579.
          #
          # 6h rather than boot-only: a run that loses the race with the
          # /mnt/backups automount then self-heals long before the next
          # nightly backup, and it lets ResticMetricsStale sit at a
          # meaningful 12h instead of the >24h a daily cadence forces.
          # The job takes ~35-80s and only reads, so four walks a day is
          # negligible load on the NAS — but "read-only" is not
          # "lock-free": `snapshots`, `stats` and `ls` each take a read
          # lock, which conflicts with `forget --prune`'s exclusive one.
          #
          # Hence a fixed OnCalendar grid rather than the
          # `OnUnitActiveSec = "6h"` this started as. Relative-to-last-run
          # meant the ExecStartPost trigger above re-armed the grid every
          # night at the backup's own completion time, so 24h later a
          # tick landed back inside the 03:00-03:30 backup window — a ~9%
          # chance per host-night of overlapping, which collected two
          # failures in the first week (#676). An absolute grid cannot
          # drift into the window. 01:15/07:15/13:15/19:15 keeps the same
          # four-a-day cadence and the same 12h ResticMetricsStale
          # budget, and clears both the nightly backup and the Sunday
          # `restic check` window (04:30 + 30m jitter) by over an hour.
          #
          # `--retry-lock` on both sides (see `pruneOpts` and
          # `resticMetrics` above) is what makes an overlap survivable;
          # this only makes one rare. Both are wanted — the ExecStartPost
          # trigger and a manual `systemctl start` can still land
          # mid-prune whatever the timer says.
          restic-metrics-server = {
            description = "Refresh restic snapshot metrics for node_exporter";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "5m";
              OnCalendar = "*-*-* 01,07,13,19:15:00";
              # Nothing downstream needs sub-minute placement, and
              # loosening this lets systemd batch the wakeup.
              AccuracySec = "1m";
              # No Persistent=: a missed walk is made up by the next tick
              # (or by the nightly ExecStartPost), and a catch-up at boot
              # would only duplicate what OnBootSec already covers.
              Unit = "restic-metrics-server.service";
            };
          };
        };
      };
    };
}
