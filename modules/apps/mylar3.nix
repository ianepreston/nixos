# Mylar3 - comics manager
# Container only; auth/caddy/homepage wired by apps/authentik.nix. Mounts
# /mnt/content/Comics so it can manage the user's comic library and
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
      myAuthentik.forwardAuthApps.mylar = {
        inherit port;
        displayName = "Mylar";
        homepage = {
          group = "Acquisition";
          icon = "mylar";
          description = "Comics manager";
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/mylar3 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.mylar3 = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/mylar3
        image = "lscr.io/linuxserver/mylar3:0.9.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/mylar3:/config"
          "/mnt/content/Comics:/comics"
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
