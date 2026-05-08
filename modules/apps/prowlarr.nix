# Prowlarr - indexer aggregator for the *arr stack
# Native services.prowlarr from nixpkgs (DynamicUser systemd unit,
# state under /var/lib/prowlarr). auth/caddy/homepage wiring is
# generated from `myAuthentik.forwardAuthApps.prowlarr` by
# modules/platform/authentik.nix.
#
# Cross-app URL after migration: other *arr containers (sonarr/radarr/
# bazarr/sabnzbd) that referenced this service via the podman DNS name
# `prowlarr` need their connection settings updated to
# `host.containers.internal:9696` until they themselves migrate to
# native (then plain `localhost:9696`). The host firewall already
# trusts the podman bridge, so containers can reach the native port.
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

      # One-shot migration from the previous container layout
      # (/var/lib/containers/prowlarr -> /var/lib/prowlarr). DynamicUser
      # services rechown the StateDirectory tree on first start, so the
      # move is enough; no chown needed here.
      systemd.services.prowlarr-migrate-state = {
        description = "Migrate prowlarr state from container layout";
        before = [ "prowlarr.service" ];
        wantedBy = [ "prowlarr.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/prowlarr";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e /var/lib/prowlarr ] || [ -z "$(ls -A /var/lib/prowlarr 2>/dev/null)" ]; then
            rm -rf /var/lib/prowlarr
            mv /var/lib/containers/prowlarr /var/lib/prowlarr
          fi
        '';
      };
    };
}
