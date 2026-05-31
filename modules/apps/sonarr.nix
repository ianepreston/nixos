# Sonarr - TV management
# Native services.sonarr from nixpkgs (system user `sonarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted TV share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.sonarr` by modules/apps/authentik.nix.
_: {
  flake.modules.nixos.sonarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.sonarr = {
        port = 8989;
        displayName = "Sonarr";
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
          icon = "sonarr";
          description = "TV manager";
          widget = {
            type = "sonarr";
            url = "http://localhost:8989";
            key = "{{HOMEPAGE_VAR_SONARR_API_KEY}}";
          };
        };
      };

      myHomepage.credentials.SONARR_API_KEY = {
        sourceUnit = "sonarr.service";
        readScript = ''
          grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/sonarr/.config/NzbDrone/config.xml
        '';
      };

      services.sonarr = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/sonarr";
          user = "server-${hostSpec.serverEnvironment}";
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/sonarr" ];

      mySqliteQuiesce.apps.sonarr.databases = [
        "/var/lib/sonarr/.config/NzbDrone/sonarr.db"
        "/var/lib/sonarr/.config/NzbDrone/logs.db"
      ];
    };
}
