# Mylar3 - comics manager
# Container only; auth/caddy/homepage wired by platform/authentik.nix. Mounts
# /mnt/content/comics so it can manage the user's comic library and
# /mnt/content/Downloads so post-processed grabs land in the right
# place.
_: {
  flake.modules.nixos.mylar3 =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8090;
    in
    {
      myAuthentik.forwardAuthApps.mylar3 = {
        inherit port;
        displayName = "Mylar3";
        homepage = {
          group = "Acquisition";
          icon = "mylar3";
          description = "Comics manager";
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/mylar3 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.mylar3 = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/mylar3
        image = "lscr.io/linuxserver/mylar3:5.9.5";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/mylar3:/config"
          "/mnt/content/comics:/comics"
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
