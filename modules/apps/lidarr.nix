# Lidarr - music management
# Native services.lidarr from nixpkgs (system user `lidarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted taylor-music share land with the UID/GID the NAS expects).
# The perms-sweep below additionally keeps the library world-readable;
# see the lidarr-music-perms unit for the why.
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.lidarr` by modules/apps/authentik.nix.
_:
let
  arrLib = import ./_arr-lib.nix;
in
{
  flake.modules.nixos.lidarr =
    {
      hostSpec,
      pkgs,
      ...
    }:
    let
      inherit (hostSpec) serverUser serverGroup;
      # Lidarr's only root folder, on the NFS share.
      musicDir = "/mnt/content/taylor-music";
    in
    {
      myAuthentik.forwardAuthApps.lidarr = {
        port = 8686;
        displayName = "Lidarr";
        # Unlike the other arrs (Infrastructure — admin tooling Ian
        # alone drives), the music library is Taylor's: she picks what
        # gets grabbed. `Home` is the existing household group (Ian +
        # Taylor, same binding Home Assistant uses), so no new group is
        # needed to give her access.
        authentikGroup = "Home";
        # Skip forward_auth for the REST API, healthcheck, and iCal feeds
        # so non-browser clients (mobile apps, calendar subscribers) can
        # authenticate with the native API key instead of the authentik
        # session cookie they don't have.
        bypassAuthPaths = [
          "/api/*"
          "/ping"
          "/feed/*"
        ];
        homepage = {
          group = "Acquisition";
          icon = "lidarr";
          description = "Music manager";
          widget = {
            type = "lidarr";
            url = "http://localhost:8686";
            key = "{{HOMEPAGE_VAR_LIDARR_API_KEY}}";
          };
        };
      };

      myRuntimeCredentials.readers.LIDARR_API_KEY = {
        sourceUnit = "lidarr.service";
        readScript = ''
          ${arrLib.mkArrApiKeyScript "/var/lib/lidarr/.config/Lidarr/config.xml"}
        '';
      };

      services.lidarr = {
        enable = true;
        user = serverUser;
        group = serverGroup;
        settings = arrLib.externalAuthSettings;
      };

      myAppState.lidarr = {
        stateDir = "/var/lib/lidarr";
        user = serverUser;
      };

      systemd = {
        # World-readable music sweep.
        #
        # Lidarr doesn't just transfer a grab into place — it rewrites
        # every track on import (cover-art embed / tag write), and that
        # rewrite goes through a temp file created at mode 0600, which
        # then replaces the imported file. So each track lands
        # -rw------- owned by server-${env} no matter what the unit's
        # UMask is: the album folders are 0755 (umask 0022, as expected)
        # but every file inside is unreadable to anything but that one
        # user. That's why the NAS `guest` account can list the library
        # over SMB/DSM and then fail to copy anything out of it.
        # Radarr/Sonarr imports on the same host, same user, same
        # download client land 0644 — this is Lidarr-specific.
        #
        # Lidarr's own Media Management > Set Permissions (chmod) is a
        # DB-side UI setting (not reachable from services.lidarr.settings,
        # which only renders config.xml keys), it only touches new
        # imports, and it races the same tag rewrite that caused the
        # problem. So do it host-side instead, exactly like
        # mylar3-comics-perms: run as the file owner (server-${env}; root
        # is squashed on the NAS and can't chmod these) and ensure a+r on
        # files / a+rx on dirs. The `! -perm` predicates skip anything
        # already correct, so steady-state runs only stat the tree.
        services.lidarr-music-perms = {
          description = "ensure music under ${musicDir} stays world-readable";
          after = [ "remote-fs.target" ];
          unitConfig.RequiresMountsFor = [ musicDir ];
          serviceConfig = {
            Type = "oneshot";
            User = serverUser;
            Group = serverGroup;
            Environment = [
              "DIR=${musicDir}"
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

        timers.lidarr-music-perms = {
          description = "Periodic music world-readable sweep";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5m";
            OnUnitActiveSec = "15m";
            AccuracySec = "1m";
          };
        };
      };

      mySqliteQuiesce.apps.lidarr.databases = [
        "/var/lib/lidarr/.config/Lidarr/lidarr.db"
        "/var/lib/lidarr/.config/Lidarr/logs.db"
      ];
    };
}
