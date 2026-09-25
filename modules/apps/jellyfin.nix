# Jellyfin - media server
# Native services.jellyfin from nixpkgs (system user `jellyfin`,
# /var/lib/jellyfin for state). Hardware transcoding (NVENC/NVDEC on
# the host's NVIDIA GPU) is enabled, but configured via the Jellyfin
# UI — it lives in runtime state, not this module: encode/decode in
# /var/lib/jellyfin/config/encoding.xml (HardwareAccelerationType=nvenc),
# trickplay in config/system.xml (<TrickplayOptions> EnableHwAcceleration).
# Note: not all CPU load is transcoding — the chromaprint media-segment
# (intro-detection) scan is audio-only and stays on CPU regardless.
#
# Auth: shared credentials with authentik via LDAP rather than OIDC.
# Most jellyfin clients are TVs / native apps that can't do an SSO
# redirect anyway, so OIDC's only benefit (the web-client redirect)
# wasn't worth depending on the archived 9p4/jellyfin-plugin-sso.
# `jellyfin/jellyfin-plugin-ldapauth` is officially maintained under
# the jellyfin org and binds against the authentik LDAP outpost
# (services.authentik-ldap on loopback :3389). LDAP binds run a
# dedicated, MFA-free authentik flow (`ldap-authentication-flow`, see
# authentik-blueprints-ldap/ldap.yaml): the outpost can't satisfy a
# WebAuthn/passkey challenge, so a user with any MFA device would
# otherwise fail every bind with "no compatible authenticator class
# found". LDAP is therefore password-only; browser SSO keeps full MFA.
# This module requests the outpost via `myAuthentik.ldap.enable`; the
# blueprint creates
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
      lib,
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
      # doCheck = false: ruff (git-hooks.nix) is the single Python authority.
      # The program lives in a colocated tracked source file (extracted from an
      # inline Nix string, following the #697 pattern) so the ruff gate lints
      # and formats it; writePython3's flake8 pass is dropped to avoid the
      # ruff-format/flake8 W503 conflict. See modules/apps/llm-metrics.nix.
      trickplayCleanup = pkgs.writers.writePython3Bin "jellyfin-trickplay-cleanup" {
        doCheck = false;
      } (builtins.readFile ./_jellyfin/trickplay-cleanup.py);
    in
    {
      myObservability.monitoredSystemdUnits = [ "jellyfin" ];

      myRecovery.apps.jellyfin = {
        kind = "sqlite";
        order = 80;
        units = [ "jellyfin.service" ];
        # `paths` enumerates jellyfin's state subdirs rather than the whole of
        # /var/lib/jellyfin, because metadata/ is excluded from the backup
        # (#569 — ~11 GB of provider artwork a library scan re-downloads).
        # This is load-bearing, not cosmetic: `_restore-sqlite` restores with
        # `--delete`, which removes anything under an included path that the
        # snapshot lacks, so including the parent would wipe the live artwork
        # on every partial restore.
        #
        # The tidier-looking fix — keep the parent include and add
        # `--exclude /var/lib/jellyfin/metadata` — does not work: restic 0.18
        # rejects it with "exclude and include patterns are mutually
        # exclusive". Enumerating is the only option that keeps --delete.
        #
        # Deliberately NOT restored, all non-critical and self-healing: log/
        # (logs), .jellyfin-data (zero-byte marker jellyfin rewrites on
        # start), and `Subtitle Edit/` (plugin dictionaries the plugin
        # re-fetches — its space would not survive the space-split PATHS loop
        # in the template anyway).
        #
        # On a from-scratch rebuild metadata/ is simply absent: jellyfin comes
        # up with no posters or headshots and repopulates them from the
        # providers on the first library scan. The health check below passes
        # either way — it only asserts the server is serving.
        paths = [
          "/var/lib/jellyfin/data"
          "/var/lib/jellyfin/config"
          "/var/lib/jellyfin/plugins"
          "/var/lib/jellyfin/root"
        ];
        health = {
          url = "http://127.0.0.1:8096/health";
          retries = 60;
        };
      };

      myAuthentik.ldap.enable = true;

      services.jellyfin = {
        enable = true;
        # Run as the shared server-env user so jellyfin can read media
        # off the NFS-mounted Synology share at /mnt/content. UIDs are
        # pinned to match the NAS (server-dev=1029, server-prod=1030,
        # group servers=65536) so NFS doesn't have to translate.
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
      };

      # Preservation defaults to root:root, but jellyfin runs as
      # server-${env}:servers and needs to mkdir under its own dir
      # (the bind-mount root). Match the service user/group.
      myAppState.jellyfin = {
        stateDir = "/var/lib/jellyfin";
        user = hostSpec.serverUser;
      };

      # Keep provider-downloaded artwork out of restic — closes #569.
      # /var/lib/jellyfin/metadata was 11 of the 12 GB of jellyfin state
      # on amos1 (People 5.3 G of actor headshots, library 4.9 G, Studio
      # 40 M) and is 100% jpg/png: not a single NFO file lives there.
      # Movies, TV and Collections all run with SaveLocalMetadata=true,
      # so their NFO *and* any manually-overridden artwork are written
      # next to the media on /mnt/content rather than here; only the
      # YouTube library caches images into metadata/library, and
      # pinchflat leaves the source thumbnails beside the media anyway.
      # The irreplaceable state — the library DB, users, watch state,
      # playlists and collections (all under data/), plus config/,
      # plugins/ and root/ — is under 2 GB and stays in scope.
      #
      # Restore-time cost: a rebuilt instance comes up with no posters
      # or headshots and looks broken until a library scan re-fetches
      # them from the providers. That is the deliberate trade.
      #
      # Declared here rather than in server-backups.nix so the exclude
      # sits next to the myAppState entry that contributes the path.
      services.restic.backups.server.exclude = [ "/var/lib/jellyfin/metadata" ];

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
          enableMediaControl = false;
          fields = [
            "movies"
            "series"
            "episodes"
          ];
        };
      };

      # Jellyfin API keys live in the ApiKeys table of jellyfin.db; the
      # widget reader looks for a row named "homepage". Create one
      # per-host via Dashboard → API Keys (the SSO user "homepage"
      # convention works for this since the API key name is just a
      # label). Until the row exists the reader emits nothing and the
      # widget shows an error; homepage itself stays up.
      myRuntimeCredentials.readers.JELLYFIN_API_KEY = {
        sourceUnit = "jellyfin.service";
        readScript = ''
          sqlite3 -readonly /var/lib/jellyfin/data/jellyfin.db \
            "SELECT AccessToken FROM ApiKeys WHERE Name = 'homepage' LIMIT 1;"
        '';
      };

      environment.systemPackages = [ trickplayCleanup ];

      systemd = {
        # The upstream module hardens jellyfin with UMask=0077, so every
        # trickplay tile / metadata image it writes next to the media on
        # the NFS share lands 0600 — unreadable to the NAS `guest` user
        # (and anything not in the `servers` group) browsing over SMB/DSM.
        # Relax to 0022 so generated files are other-readable (0644),
        # matching the rest of the library. See README / NFS notes.
        services.jellyfin.serviceConfig.UMask = lib.mkForce "0022";

        services.jellyfin-trickplay-cleanup = {
          description = "Remove orphaned Jellyfin trickplay folders";
          after = [ "remote-fs.target" ];
          unitConfig.RequiresMountsFor = mediaRoots;
          serviceConfig = {
            Type = "oneshot";
            User = hostSpec.serverUser;
            Group = "servers";
            ExecStart = "${trickplayCleanup}/bin/jellyfin-trickplay-cleanup ${toString mediaRoots}";
          };
        };

        timers.jellyfin-trickplay-cleanup = {
          description = "Weekly Jellyfin trickplay orphan cleanup";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "Sun 03:30:00";
            Persistent = true;
            RandomizedDelaySec = "30m";
          };
        };
      };
    };
}
