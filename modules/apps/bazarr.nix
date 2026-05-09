# Bazarr - subtitles for sonarr/radarr libraries
# Native services.bazarr from nixpkgs (system user `bazarr` overridden
# to the shared server-${env}:servers user so NFS reads/writes against
# /mnt/content land with the UID/GID the NAS expects). auth/caddy/
# homepage wiring is generated from `myAuthentik.forwardAuthApps.bazarr`
# by modules/platform/authentik.nix.
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

      services.restic.backups.server.paths = [ "/var/lib/bazarr" ];
    };
}
