# Mylar3 - comics manager
# Container only; auth/caddy/homepage wired by apps/authentik.nix. Mounts
# /mnt/content/Comics so it can manage the user's comic library and
# /mnt/content/Downloads so post-processed grabs land in the right
# place.
_: {
  flake.modules.nixos.mylar3 =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8090;
      # LinuxServer image nests its app data under /config/mylar, so the
      # SQLite DB lands here on the host (the /config mount is
      # /var/lib/containers/mylar3). Rollback-journal mode + local btrfs,
      # so a root `sqlite3 -readonly` reads it cleanly alongside the
      # running container.
      dbPath = "/var/lib/containers/mylar3/mylar/mylar.db";
      # Textfile collector — set in modules/system/victoriametrics.nix.
      # Kept in sync by hand; both modules live on the same hosts. Same
      # arrangement as sabnzbd.nix's incomplete-dir metrics.
      textfileDir = "/var/lib/node-exporter-textfile-collector";
    in
    {
      myAuthentik.forwardAuthApps.mylar = {
        inherit port;
        displayName = "Mylar";
        homepage = {
          group = "Acquisition";
          icon = "mylar";
          description = "Comics manager";
        };
      };

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/mylar3 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        # Stuck-Snatched detector (#299 follow-up). Mylar's SAB
        # completed-download-handling tracks each grab by the nzo_id SAB
        # returns at send time and has no recovery when that id vanishes
        # (SAB retry/re-add, or a failed slot purged by
        # sab_remove_failed) — the historycheck loops "Cannot find nzb …
        # was it removed?" forever and the issue sits in Snatched without
        # ever importing. The files are usually complete on disk; only
        # Mylar's bookkeeping is wedged. Recover with a folder-based
        # manual post-process:
        #   curl 'http://localhost:8090/post_process?nzb_name=Manual+Run&nzb_folder=/downloads/complete/comics/<folder>'
        # then `podman restart mylar3` to flush the in-memory CDH list.
        #
        # `issues.Status='Snatched'` is the authoritative "awaiting
        # download/import" state (the `snatched` table accumulates stale
        # rows and isn't reliable on its own); we join to `snatched` only
        # for the per-issue snatch timestamp (DateAdded, stored in local
        # time — both sides of the subtraction are interpreted as UTC by
        # strftime so the tz offset cancels and the age is true). Two
        # gauges land in the textfile collector; the >6h threshold lives
        # in the MylarSnatchedStuck rule in victoriametrics.nix.
        services.mylar3-snatched-metrics = {
          description = "publish mylar3 stuck-Snatched metrics to node_exporter textfile collector";
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Environment = [
              "DB=${dbPath}"
              "OUT=${textfileDir}/mylar3.prom"
              "PATH=${
                pkgs.lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.sqlite
                ]
              }"
            ];
          };
          script = ''
            set -eu
            count=""
            oldest=""
            if [ -r "$DB" ]; then
              # `.timeout` (dot-command via -cmd) sets the busy timeout
              # without emitting a result row — a `PRAGMA busy_timeout=…`
              # inside the SQL would print its value and pollute the
              # scalar output. Read-only against a rollback-journal db,
              # so the timeout only matters for the brief window Mylar
              # holds an EXCLUSIVE write lock.
              count=$(sqlite3 -readonly -cmd '.timeout 5000' -batch "$DB" \
                "SELECT COUNT(*) FROM issues WHERE Status='Snatched';" 2>/dev/null || echo "")
              oldest=$(sqlite3 -readonly -cmd '.timeout 5000' -batch "$DB" \
                "SELECT COALESCE(MAX(strftime('%s','now','localtime') - strftime('%s', latest)), 0) FROM (SELECT MAX(s.DateAdded) AS latest FROM issues i JOIN snatched s ON s.IssueID=i.IssueID WHERE i.Status='Snatched' GROUP BY i.IssueID);" 2>/dev/null || echo "")
            fi
            # On a read failure (db locked / query error) leave the
            # previous .prom in place rather than publishing a misleading
            # zero, and still exit 0 so the unit doesn't trip
            # SystemdUnitFailed for a transient lock.
            case "$count" in ""|*[!0-9]*)
              echo "mylar3-snatched-metrics: query failed, leaving previous metrics" >&2
              exit 0 ;;
            esac
            case "$oldest" in ""|*[!0-9]*) oldest=0 ;; esac
            tmp=$(mktemp -p "$(dirname "$OUT")" .mylar3.prom.XXXXXX)
            {
              echo "# HELP mylar3_snatched_issues Issues currently in Mylar's Snatched state (awaiting download/import)."
              echo "# TYPE mylar3_snatched_issues gauge"
              echo "mylar3_snatched_issues $count"
              echo "# HELP mylar3_snatched_oldest_seconds Age in seconds of the longest-outstanding Snatched issue, measured from its most recent snatch."
              echo "# TYPE mylar3_snatched_oldest_seconds gauge"
              echo "mylar3_snatched_oldest_seconds $oldest"
            } > "$tmp"
            chmod 0644 "$tmp"
            mv "$tmp" "$OUT"
          '';
        };

        timers.mylar3-snatched-metrics = {
          description = "Periodic mylar3 stuck-Snatched metrics refresh";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "3m";
            OnUnitActiveSec = "5m";
            AccuracySec = "30s";
          };
        };
      };

      virtualisation.oci-containers.containers.mylar3 = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/mylar3
        image = "lscr.io/linuxserver/mylar3:0.9.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/mylar3:/config"
          "/mnt/content/Comics:/comics"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          PUID = toString serverUid;
          PGID = toString serverGid;
          TZ = config.time.timeZone;
        };
      };
    };
}
