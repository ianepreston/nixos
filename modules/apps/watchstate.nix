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
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
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

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/watchstate 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.watchstate = {
        # renovate: datasource=docker depName=arabcoders/watchstate
        image = "arabcoders/watchstate:v1.8.7";
        ports = [ "127.0.0.1:${toString port}:8080" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/watchstate:/config"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
