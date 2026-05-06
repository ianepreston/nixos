# Radarr - Movie management
# Container only; auth/caddy/homepage wired by arr-auth.nix.
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
        # renovate: datasource=docker depName=lscr.io/linuxserver/radarr
        image = "lscr.io/linuxserver/radarr:6.1.1";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/radarr:/config"
          "/mnt/content/Movies:/movies"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          PUID = toString serverUid;
          PGID = toString serverGid;
          TZ = config.time.timeZone;
        };
      };
    };
}
