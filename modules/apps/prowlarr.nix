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

      services.restic.backups.server.paths = [ "/var/lib/prowlarr" ];
    };
}
