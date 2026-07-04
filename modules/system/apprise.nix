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
        # Bind target for /etc/timezone — supervisord-startup writes ${TZ}
        # to /etc/timezone on every boot, which fails when the container runs
        # as a non-root user (the image's /etc/timezone is root-owned). TZ env
        # is the real source of truth; this just keeps the write quiet.
        "f /var/lib/containers/apprise/timezone 0644 ${toString serverUid} ${toString serverGid} - ${config.time.timeZone}"
      ];

      virtualisation.oci-containers.containers.apprise = {
        # renovate: datasource=docker depName=caronc/apprise
        image = "caronc/apprise:v1.5.1";
        ports = [ "127.0.0.1:${toString port}:8000" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/apprise/config:/config"
          "/var/lib/containers/apprise/timezone:/etc/timezone"
        ];
        environment = {
          TZ = config.time.timeZone;
          # Read plaintext /config/<key>.yml files directly. Default is
          # "hash", which only sees configs saved via the API into
          # /config/store/ under hashed filenames, and silently returns
          # 204 No Content for /notify/<key> when <key>.yml exists only
          # as a static file (the shape consumer modules render).
          APPRISE_STATEFUL_MODE = "simple";
        };
      };
    };
}
