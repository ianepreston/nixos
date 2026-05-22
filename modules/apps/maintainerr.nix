# Maintainerr - rule-driven media library cleanup against
# Plex/Jellyfin + Seerr/Radarr/Sonarr/Tautulli
# (https://github.com/jorenn92/Maintainerr). Container only;
# upstream has no built-in auth (open feature request as of v3.10.x),
# so the app is gated by authentik forward-auth via Caddy. State (the
# sqlite DB and overlay assets) lives at /var/lib/containers/maintainerr.
_: {
  flake.modules.nixos.maintainerr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 6246;
    in
    {
      myAuthentik.forwardAuthApps.maintainerr = {
        inherit port;
        displayName = "Maintainerr";
        homepage = {
          group = "Acquisition";
          icon = "maintainerr";
          description = "Media library cleanup";
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/maintainerr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.maintainerr = {
        # renovate: datasource=docker depName=ghcr.io/maintainerr/maintainerr
        image = "ghcr.io/maintainerr/maintainerr:3.12.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/maintainerr:/opt/data"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
