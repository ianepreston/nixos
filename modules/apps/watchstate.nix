# Watchstate - sync media-server play state across Jellyfin/Plex/Emby
# (https://github.com/arabcoders/watchstate). Container only;
# auth/caddy/homepage wired by apps/authentik.nix. The host-native Jellyfin
# is reachable from inside the podman bridge at
# host.containers.internal:8096 — that URL is registered through the
# webui on first boot, not via this module. State lives at
# /var/lib/containers/watchstate so the standard /var/lib/containers
# restic snapshot covers it.
_: {
  flake.modules.nixos.watchstate =
    _:
    let
      port = 8088;
    in
    {
      myAuthentik.forwardAuthApps.watchstate = {
        inherit port;
        displayName = "Watchstate";
        iconUrl = "https://raw.githubusercontent.com/arabcoders/watchstate/master/frontend/public/images/logo_nobg.png";
        homepage = {
          group = "Acquisition";
          icon = "https://raw.githubusercontent.com/arabcoders/watchstate/master/frontend/public/images/logo_nobg.png";
          description = "Sync media play state";
        };
      };

      myContainerApp.watchstate = {
        inherit port;
        containerPort = 8080;
      };

      virtualisation.oci-containers.containers.watchstate = {
        # renovate: datasource=docker depName=arabcoders/watchstate
        image = "arabcoders/watchstate:v1.9.1";
        volumes = [
          "/var/lib/containers/watchstate:/config"
        ];
      };
    };
}
