# Jellyfin - media server
# Native services.jellyfin from nixpkgs (system user `jellyfin`,
# /var/lib/jellyfin for state). Hardware transcoding is tracked as
# a follow-up.
#
# Auth: shared credentials with authentik via LDAP rather than OIDC.
# Most jellyfin clients are TVs / native apps that can't do an SSO
# redirect anyway, so OIDC's only benefit (the web-client redirect)
# wasn't worth depending on the archived 9p4/jellyfin-plugin-sso.
# `jellyfin/jellyfin-plugin-ldapauth` is officially maintained under
# the jellyfin org and binds against the authentik LDAP outpost
# (services.authentik-ldap on loopback :3389). This module requests
# the outpost via `myAuthentik.ldap.enable`; the blueprint creates
# everything including a pre-stamped outpost token so no UI steps are
# needed (see goauthentik/authentik#9711). Only manual one-time bit
# is installing the LDAP plugin DLL inside jellyfin and filling its
# config form — see the Jellyfin section of the README.
#
# Backups: /var/lib/jellyfin contains both XML config and the library
# SQLite databases. Restic snapshots the whole tree, but live SQLite
# files can be torn mid-write — the DB gets an extra consistent copy
# via `sqlite3 .backup` into /var/backup/sqlite/jellyfin/ before each
# restic run (mySqliteQuiesce helper). On restore, prefer the staged
# copy under /var/backup/sqlite/jellyfin/ over the live one under
# /var/lib/jellyfin/data/.
#
# Trickplay cleanup: Jellyfin writes `<video-stem>.trickplay/` next to
# each video. When *arr renames a release the video moves but the old
# trickplay folder is left behind. A weekly oneshot walks the library
# roots and removes any `*.trickplay` directory whose stem doesn't
# match a sibling video file — exact name match against Jellyfin's own
# naming, so valid folders are never touched. Run on demand with
# `systemctl start jellyfin-trickplay-cleanup` or
# `jellyfin-trickplay-cleanup --dry-run /mnt/content/Movies /mnt/content/TV`.
_: {
  flake.modules.nixos.jellyfin =
    {
      pkgs,
      hostSpec,
      ...
    }:
    let
      jellyfinHost = "jellyfin.${hostSpec.serverDomain}";
      jellyfinPort = 8096;
      mediaRoots = [
        "/mnt/content/Movies"
        "/mnt/content/TV"
      ];
      trickplayCleanup =
        pkgs.writers.writePython3Bin "jellyfin-trickplay-cleanup"
          {
            flakeIgnore = [ "E501" ];
          }
          ''
            import argparse
            import shutil
            import sys
            from pathlib import Path

            VIDEO_EXTS = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".webm",
                          ".mpg", ".mpeg", ".wmv", ".flv"}


            def find_orphans(roots):
                for root in roots:
                    root_path = Path(root)
                    if not root_path.is_dir():
                        print(f"warning: skipping missing root {root}", file=sys.stderr)
                        continue
                    for trickplay in root_path.rglob("*.trickplay"):
                        if not trickplay.is_dir():
                            continue
                        stem = trickplay.name[: -len(".trickplay")]
                        parent = trickplay.parent
                        has_video = any(
                            (parent / f"{stem}{ext}").is_file()
                            for ext in VIDEO_EXTS
                        )
                        if not has_video:
                            yield trickplay


            def main():
                ap = argparse.ArgumentParser()
                ap.add_argument("--dry-run", action="store_true",
                                help="print orphans without deleting")
                ap.add_argument("roots", nargs="+")
                args = ap.parse_args()

                orphans = 0
                errors = 0
                for orphan in find_orphans(args.roots):
                    print(f"orphan: {orphan}", flush=True)
                    orphans += 1
                    if args.dry_run:
                        continue
                    try:
                        shutil.rmtree(orphan)
                    except OSError as e:
                        print(f"  rm failed: {e}", file=sys.stderr, flush=True)
                        errors += 1

                mode = "dry-run" if args.dry_run else "delete"
                print(f"done. mode={mode} orphans={orphans} errors={errors}")
                return 1 if errors else 0


            if __name__ == "__main__":
                sys.exit(main())
          '';
    in
    {
      myAuthentik.ldap.enable = true;

      services.jellyfin = {
        enable = true;
        # Run as the shared server-env user so jellyfin can read media
        # off the NFS-mounted Synology share at /mnt/content. UIDs are
        # pinned to match the NAS (server-dev=1029, server-prod=1030,
        # group servers=65536) so NFS doesn't have to translate.
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      # Preservation defaults to root:root, but jellyfin runs as
      # server-${env}:servers and needs to mkdir under its own dir
      # (the bind-mount root). Match the service user/group.
      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/jellyfin";
          user = "server-${hostSpec.serverEnvironment}";
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/jellyfin" ];

      mySqliteQuiesce.apps.jellyfin.databases = [
        "/var/lib/jellyfin/data/jellyfin.db"
      ];

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
        widget = {
          type = "jellyfin";
          url = "http://localhost:${toString jellyfinPort}";
          key = "{{HOMEPAGE_VAR_JELLYFIN_API_KEY}}";
          enableBlocks = true;
          enableNowPlaying = true;
        };
      };

      # Jellyfin API keys live in the ApiKeys table of jellyfin.db; the
      # widget reader looks for a row named "homepage". Create one
      # per-host via Dashboard → API Keys (the SSO user "homepage"
      # convention works for this since the API key name is just a
      # label). Until the row exists the reader emits nothing and the
      # widget shows an error; homepage itself stays up.
      myHomepage.credentials.JELLYFIN_API_KEY = {
        sourceUnit = "jellyfin.service";
        readScript = ''
          sqlite3 -readonly /var/lib/jellyfin/data/jellyfin.db \
            "SELECT AccessToken FROM ApiKeys WHERE Name = 'homepage' LIMIT 1;"
        '';
      };

      environment.systemPackages = [ trickplayCleanup ];

      systemd.services.jellyfin-trickplay-cleanup = {
        description = "Remove orphaned Jellyfin trickplay folders";
        after = [ "remote-fs.target" ];
        unitConfig.RequiresMountsFor = mediaRoots;
        serviceConfig = {
          Type = "oneshot";
          User = "server-${hostSpec.serverEnvironment}";
          Group = "servers";
          ExecStart = "${trickplayCleanup}/bin/jellyfin-trickplay-cleanup ${toString mediaRoots}";
        };
      };

      systemd.timers.jellyfin-trickplay-cleanup = {
        description = "Weekly Jellyfin trickplay orphan cleanup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sun 03:30:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
    };
}
