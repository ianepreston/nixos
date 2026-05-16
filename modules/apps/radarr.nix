# Radarr - movie management
# Native services.radarr from nixpkgs (system user `radarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted Movies share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.radarr` by modules/platform/authentik.nix.
_: {
  flake.modules.nixos.radarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.radarr = {
        port = 7878;
        displayName = "Radarr";
        homepage = {
          group = "Acquisition";
          icon = "radarr";
          description = "Movie manager";
        };
      };

      services.radarr = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/radarr";
          user = "server-${hostSpec.serverEnvironment}";
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/radarr" ];

      mySqliteQuiesce.apps.radarr.databases = [
        "/var/lib/radarr/.config/Radarr/radarr.db"
        "/var/lib/radarr/.config/Radarr/logs.db"
      ];
    };
}
