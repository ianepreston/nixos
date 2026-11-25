# Sonarr - TV management
# Native services.sonarr from nixpkgs (system user `sonarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted TV share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.sonarr` by modules/apps/authentik.nix.
_:
let
  arrLib = import ./_arr-lib.nix;
in
{
  flake.modules.nixos.sonarr =
    { config, hostSpec, ... }:
    let
      # The port sonarr actually listens on, so the route, widget and
      # published endpoint follow any override of the listener.
      inherit (config.services.sonarr.settings.server) port;
    in
    {
      myObservability.monitoredSystemdUnits = [ "sonarr" ];

      myRecovery.apps.sonarr = {
        kind = "sqlite";
        order = 270;
        units = [ "sonarr.service" ];
        paths = [ "/var/lib/sonarr" ];
      };

      myAuthentik.forwardAuthApps.sonarr = {
        inherit port;
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
            url = "http://localhost:${toString port}";
            key = "{{HOMEPAGE_VAR_SONARR_API_KEY}}";
          };
        };
      };

      # Sonarr binds every interface by default, so containers on the
      # podman bridge can reach it too.
      myServiceEndpoints.sonarr = {
        url = "http://127.0.0.1:${toString port}";
        containerUrl = "http://host.containers.internal:${toString port}";
        unit = "sonarr.service";
      };

      myRuntimeCredentials.readers.SONARR_API_KEY = {
        sourceUnit = "sonarr.service";
        readScript = ''
          ${arrLib.mkArrApiKeyScript "/var/lib/sonarr/.config/NzbDrone/config.xml"}
        '';
      };

      services.sonarr = {
        enable = true;
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
        settings = arrLib.externalAuthSettings // {
          # nixpkgs' default, pinned here as the one declaration.
          server.port = 8989;
        };
      };

      myAppState.sonarr = {
        stateDir = "/var/lib/sonarr";
        user = hostSpec.serverUser;
      };

      mySqliteQuiesce.apps.sonarr.databases = [
        "/var/lib/sonarr/.config/NzbDrone/sonarr.db"
        "/var/lib/sonarr/.config/NzbDrone/logs.db"
      ];
    };
}
