# Prowlarr - indexer aggregator for the *arr stack
# Container only; auth/caddy/homepage wiring is generated from
# `myArrAuth.apps.prowlarr` by modules/apps/arr-auth.nix.
#
# Runs as the shared server-${env}:servers user so any future config
# pointed at the NFS share lines up with NAS-side UID checks. Image
# baked-in user is `nobody:nogroup`; we override via `user`. Other
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
        # renovate: datasource=docker depName=ghcr.io/home-operations/prowlarr
        image = "ghcr.io/home-operations/prowlarr:2.3.7.5365";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [ "/var/lib/containers/prowlarr:/config" ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
