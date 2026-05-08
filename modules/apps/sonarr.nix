# Sonarr - TV management
# Container only; auth/caddy/homepage wiring lives in arr-auth.nix.
# Bind-mounts /mnt/content/TV (NFS share) so library scans land in the
# right place. Image baked-in user is `nobody:nogroup`; we override via
# `user` so the process runs as server-${env}:servers (the UID/GID the
# NAS expects on the share).
_: {
  flake.modules.nixos.sonarr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8989;
    in
    {
      myArrAuth.apps.sonarr = {
        inherit port;
        displayName = "Sonarr";
        homepageDescription = "TV manager";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/sonarr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.sonarr = {
        # renovate: datasource=docker depName=ghcr.io/home-operations/sonarr
        image = "ghcr.io/home-operations/sonarr:4.0.17.2967";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/sonarr:/config"
          "/mnt/content/TV:/tv"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
