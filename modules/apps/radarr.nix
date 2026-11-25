# Radarr - movie management
# Native services.radarr from nixpkgs (system user `radarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted Movies share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.radarr` by modules/apps/authentik.nix.
_:
let
  arrLib = import ./_arr-lib.nix;
in
{
  flake.modules.nixos.radarr =
    { hostSpec, ... }:
    let
      port = 7878;
    in
    {
      myObservability.monitoredSystemdUnits = [ "radarr" ];

      myRecovery.apps.radarr = {
        kind = "sqlite";
        order = 220;
        units = [ "radarr.service" ];
        paths = [ "/var/lib/radarr" ];
      };

      myAuthentik.forwardAuthApps.radarr = {
        inherit port;
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
            url = "http://localhost:${toString port}";
            key = "{{HOMEPAGE_VAR_RADARR_API_KEY}}";
          };
        };
      };

      # Radarr binds every interface by default, so containers on the
      # podman bridge can reach it too.
      myServiceEndpoints.radarr = {
        url = "http://127.0.0.1:${toString port}";
        containerUrl = "http://host.containers.internal:${toString port}";
        unit = "radarr.service";
      };

      myRuntimeCredentials.readers.RADARR_API_KEY = {
        sourceUnit = "radarr.service";
        readScript = ''
          ${arrLib.mkArrApiKeyScript "/var/lib/radarr/.config/Radarr/config.xml"}
        '';
      };

      services.radarr = {
        enable = true;
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
        settings = arrLib.externalAuthSettings;
      };

      myAppState.radarr = {
        stateDir = "/var/lib/radarr";
        user = hostSpec.serverUser;
      };

      mySqliteQuiesce.apps.radarr.databases = [
        "/var/lib/radarr/.config/Radarr/radarr.db"
        "/var/lib/radarr/.config/Radarr/logs.db"
      ];
    };
}
