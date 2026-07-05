# Bazarr - subtitles for sonarr/radarr libraries
# Native services.bazarr from nixpkgs (system user `bazarr` overridden
# to the shared server-${env}:servers user so NFS reads/writes against
# /mnt/content land with the UID/GID the NAS expects). auth/caddy/
# homepage wiring is generated from `myAuthentik.forwardAuthApps.bazarr`
# by modules/apps/authentik.nix.
_: {
  flake.modules.nixos.bazarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.bazarr = {
        port = 6767;
        displayName = "Bazarr";
        homepage = {
          group = "Acquisition";
          icon = "bazarr";
          description = "Subtitle manager";
        };
      };

      services.bazarr = {
        enable = true;
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
      };

      myAppState.bazarr = {
        stateDir = "/var/lib/bazarr";
        user = hostSpec.serverUser;
      };

      mySqliteQuiesce.apps.bazarr.databases = [
        "/var/lib/bazarr/db/bazarr.db"
      ];
    };
}
