# Radarr - Movie management
# Container only; auth/caddy/homepage wired by arr-auth.nix. Image
# baked-in user is `nobody:nogroup`; we override via `user` so the
# process runs as the shared server-${env}:servers user that the NAS
# expects on the NFS-mounted Movies share.
_: {
  flake.modules.nixos.radarr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 7878;
    in
    {
      myArrAuth.apps.radarr = {
        inherit port;
        displayName = "Radarr";
        homepageDescription = "Movie manager";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/radarr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.radarr = {
        # renovate: datasource=docker depName=ghcr.io/home-operations/radarr
        image = "ghcr.io/home-operations/radarr:6.2.0.10390";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/radarr:/config"
          "/mnt/content/Movies:/movies"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
