# Prowlarr - indexer aggregator for the *arr stack
# Native services.prowlarr from nixpkgs (DynamicUser systemd unit,
# state under /var/lib/prowlarr). auth/caddy/homepage wiring is
# generated from `myAuthentik.forwardAuthApps.prowlarr` by
# modules/platform/authentik.nix.
_: {
  flake.modules.nixos.prowlarr =
    _:
    let
      port = 9696;
    in
    {
      myAuthentik.forwardAuthApps.prowlarr = {
        inherit port;
        displayName = "Prowlarr";
        homepage = {
          group = "Acquisition";
          icon = "prowlarr";
          description = "Indexer manager";
        };
      };

      services.prowlarr = {
        enable = true;
        settings.server.port = port;
      };

      # DynamicUser: real state lives at /var/lib/private/prowlarr;
      # /var/lib/prowlarr is the symlink systemd recreates each boot.
      # Restic doesn't follow symlinks, so backing up /var/lib/prowlarr
      # captures only the link, not the data.
      services.restic.backups.server.paths = [ "/var/lib/private/prowlarr" ];
    };
}
