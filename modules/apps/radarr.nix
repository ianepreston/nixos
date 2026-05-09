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

      services.restic.backups.server.paths = [ "/var/lib/radarr" ];
    };
}
