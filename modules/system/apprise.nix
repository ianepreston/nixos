# Apprise - notification gateway (apprise-api)
# Container-only; not packaged in nixpkgs. Loopback-bound on 8002 so
# off-host clients can't reach it. Co-located containers reach apprise
# via the podman bridge DNS (http://apprise:8000); host services hit
# http://localhost:8002.
#
# Stateful config: each consumer module writes its own
# /var/lib/containers/apprise/config/<key>.yml — typically rendered
# from a sops env file via a tiny oneshot in the consumer — and posts
# notifications to /notify/<key>. apprise-api re-reads the file per
# request, so config changes need no restart on either side.
_: {
  flake.modules.nixos.apprise =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8002;
    in
    {
      systemd.tmpfiles.rules = [
        "d /var/lib/containers/apprise 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/apprise/config 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.apprise = {
        # renovate: datasource=docker depName=caronc/apprise
        image = "caronc/apprise:v1.4.1";
        ports = [ "127.0.0.1:${toString port}:8000" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/apprise/config:/config"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
