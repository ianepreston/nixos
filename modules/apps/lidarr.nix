# Lidarr - music management
# Native services.lidarr from nixpkgs (system user `lidarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted taylor-music share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.lidarr` by modules/apps/authentik.nix.
_:
let
  arrLib = import ./_arr-lib.nix;
in
{
  flake.modules.nixos.lidarr =
    { hostSpec, ... }:
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

      myHomepage.credentials.LIDARR_API_KEY = {
        sourceUnit = "lidarr.service";
        readScript = ''
          ${arrLib.mkArrApiKeyScript "/var/lib/lidarr/.config/Lidarr/config.xml"}
        '';
      };

      services.lidarr = {
        enable = true;
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
        settings = arrLib.externalAuthSettings;
      };

      myAppState.lidarr = {
        stateDir = "/var/lib/lidarr";
        user = hostSpec.serverUser;
      };

      mySqliteQuiesce.apps.lidarr.databases = [
        "/var/lib/lidarr/.config/Lidarr/lidarr.db"
        "/var/lib/lidarr/.config/Lidarr/logs.db"
      ];
    };
}
