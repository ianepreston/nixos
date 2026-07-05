# Mylar3 - comics manager
# Container only; auth/caddy/homepage wired by apps/authentik.nix. Mounts
# /mnt/content/Comics so it can manage the user's comic library and
# /mnt/content/Downloads so post-processed grabs land in the right
# place.
_: {
  flake.modules.nixos.mylar3 =
    {
      hostSpec,
      pkgs,
      ...
    }:
    let
      inherit (hostSpec) serverUser;
      port = 8090;
      # Comics library on the NFS share. The perms-sweep below keeps it
      # world-readable; see the mylar3-comics-perms unit for the why.
      comicsDir = "/mnt/content/Comics";
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

      myContainerApp.mylar3 = {
        inherit port;
        linuxServer = true;
      };

      systemd = {
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
        # `Status='Snatched'` is the authoritative "awaiting
        # download/import" state (the `snatched` table accumulates stale
        # rows and isn't reliable on its own); we join to `snatched` only
        # for the per-issue snatch timestamp (DateAdded, stored in local
        # time — both sides of the subtraction are interpreted as UTC by
        # strftime so the tz offset cancels and the age is true).
        #
        # Annuals live in a SEPARATE `annuals` table, not `issues` — a
        # stuck annual (e.g. a mis-matched grab that filed the wrong
        # issue number) never appears in `issues` and so would silently
        # escape a `issues`-only count. Both gauges therefore union the
        # two tables (annuals filtered by `NOT Deleted` — soft-deleted
        # rows aren't real stucks). Recovering an annuals-table stuck is
        # different from the runbook above: `/failed_handling` aborts on
        # annuals ("issuenzb not found … sandwich was not defined"), and
        # for a mis-matched grab it would wrongly blacklist the good
        # release it actually fetched — reset it with
        #   curl -sG http://localhost:8090/markissues --data-urlencode action=Retry --data-urlencode 'issueids[]=<IssueID>'
        # (annuals-aware; sets Wanted + re-searches, no blacklist).
        #
        # Two gauges land in the textfile collector; the >6h threshold
        # lives in the MylarSnatchedStuck rule in victoriametrics.nix.
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
                "SELECT (SELECT COUNT(*) FROM issues WHERE Status='Snatched') + (SELECT COUNT(*) FROM annuals WHERE Status='Snatched' AND NOT Deleted);" 2>/dev/null || echo "")
              oldest=$(sqlite3 -readonly -cmd '.timeout 5000' -batch "$DB" \
                "SELECT COALESCE(MAX(strftime('%s','now','localtime') - strftime('%s', latest)), 0) FROM (SELECT MAX(s.DateAdded) AS latest FROM issues i JOIN snatched s ON s.IssueID=i.IssueID WHERE i.Status='Snatched' GROUP BY i.IssueID UNION ALL SELECT MAX(s.DateAdded) AS latest FROM annuals a JOIN snatched s ON s.IssueID=a.IssueID WHERE a.Status='Snatched' AND NOT a.Deleted GROUP BY a.IssueID);" 2>/dev/null || echo "")
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
              echo "# HELP mylar3_snatched_issues Issues (incl. annuals) currently in Mylar's Snatched state (awaiting download/import)."
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

        # World-readable comics sweep.
        #
        # Mylar metatags every grab (enable_meta): comictagger rewrites
        # the .cbz into a fresh file via Python's tempfile.mkstemp, which
        # hardcodes mode 0600 and ignores umask. So every imported comic
        # lands -rw------- owned by server-${env}, readable only by that
        # user — anything browsing the NFS share as another account (SMB,
        # other tooling) is locked out. Mylar's own enable_perm chmod is
        # capped at chmod_file=0660 (no other-read), fires unreliably over
        # NFS from inside the container, and only touches new grabs.
        #
        # Instead: a host-side sweep running as the file owner
        # (server-${env}; root is squashed on the NAS and can't chmod
        # these) that ensures a+r on files / a+rx on dirs. The `! -perm`
        # predicates skip anything already correct, so steady-state runs
        # only stat the tree and chmod the handful of new imports.
        services.mylar3-comics-perms = {
          description = "ensure comics under ${comicsDir} stay world-readable";
          serviceConfig = {
            Type = "oneshot";
            User = serverUser;
            Group = "servers";
            Environment = [
              "DIR=${comicsDir}"
              "PATH=${
                pkgs.lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.findutils
                ]
              }"
            ];
          };
          script = ''
            set -eu
            [ -d "$DIR" ] || exit 0
            find "$DIR" -type d ! -perm -0555 -exec chmod a+rx {} + || true
            find "$DIR" -type f ! -perm -0444 -exec chmod a+r {} + || true
          '';
        };

        timers.mylar3-comics-perms = {
          description = "Periodic comics world-readable sweep";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5m";
            OnUnitActiveSec = "15m";
            AccuracySec = "1m";
          };
        };
      };

      virtualisation.oci-containers.containers.mylar3 = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/mylar3
        image = "lscr.io/linuxserver/mylar3:0.10.0";
        volumes = [
          "/var/lib/containers/mylar3:/config"
          "/mnt/content/Comics:/comics"
          "/mnt/content/Downloads:/downloads"
        ];
      };
    };
}
