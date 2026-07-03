# Radarr - movie management
# Native services.radarr from nixpkgs (system user `radarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted Movies share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.radarr` by modules/apps/authentik.nix.
_: {
  flake.modules.nixos.radarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.radarr = {
        port = 7878;
        displayName = "Radarr";
        # Skip forward_auth for the REST API, healthcheck, and iCal feeds
        # so non-browser clients (iOS app, calendar subscribers) can
        # authenticate with the native API key instead of the authentik
        # session cookie they don't have.
        bypassAuthPaths = [
          "/api/*"
          "/ping"
          "/feed/*"
        ];
        homepage = {
          group = "Acquisition";
          icon = "radarr";
          description = "Movie manager";
          widget = {
            type = "radarr";
            url = "http://localhost:7878";
            key = "{{HOMEPAGE_VAR_RADARR_API_KEY}}";
          };
        };
      };

      myHomepage.credentials.RADARR_API_KEY = {
        sourceUnit = "radarr.service";
        readScript = ''
          grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/radarr/.config/Radarr/config.xml
        '';
      };

      services.radarr = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      myAppState.radarr = {
        stateDir = "/var/lib/radarr";
        user = "server-${hostSpec.serverEnvironment}";
      };

      mySqliteQuiesce.apps.radarr.databases = [
        "/var/lib/radarr/.config/Radarr/radarr.db"
        "/var/lib/radarr/.config/Radarr/logs.db"
      ];
    };
}
