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
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/bazarr";
          user = "server-${hostSpec.serverEnvironment}";
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/bazarr" ];

      mySqliteQuiesce.apps.bazarr.databases = [
        "/var/lib/bazarr/db/bazarr.db"
      ];
    };
}
