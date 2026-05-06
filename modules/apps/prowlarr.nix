# Prowlarr - indexer aggregator for the *arr stack
# Container only; auth/caddy/homepage wiring is generated from
# `myArrAuth.apps.prowlarr` by modules/apps/arr-auth.nix.
#
# Runs as the shared server-${env}:servers user so any future config
# pointed at the NFS share lines up with NAS-side UID checks. Other
# *arr containers reach prowlarr via the default podman bridge using
# the container name (DNS is enabled in modules/system/oci-containers.nix).
_: {
  flake.modules.nixos.prowlarr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 9696;
    in
    {
      myArrAuth.apps.prowlarr = {
        inherit port;
        displayName = "Prowlarr";
        homepageDescription = "Indexer manager";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/prowlarr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.prowlarr = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/prowlarr
        image = "lscr.io/linuxserver/prowlarr:2.3.5";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [ "/var/lib/containers/prowlarr:/config" ];
        environment = {
          PUID = toString serverUid;
          PGID = toString serverGid;
          TZ = config.time.timeZone;
        };
      };
    };
}
