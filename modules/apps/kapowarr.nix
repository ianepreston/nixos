# Kapowarr - comics manager (alternative to mylar3)
# Container only; auth/caddy/homepage wired by arr-auth.nix. Upstream
# image isn't a linuxserver build, so we set the runtime user via
# `--user` directly rather than via PUID/PGID env vars.
_: {
  flake.modules.nixos.kapowarr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 5656;
    in
    {
      myArrAuth.apps.kapowarr = {
        inherit port;
        displayName = "Kapowarr";
        homepageDescription = "Comics manager";
        # No upstream icon in dashboard-icons yet; fall back to generic.
        homepageIcon = "https://raw.githubusercontent.com/Casvt/Kapowarr/master/frontend/static/img/favicon.svg";
        iconUrl = "https://raw.githubusercontent.com/Casvt/Kapowarr/master/frontend/static/img/favicon.svg";
      };

      # `/app/logs` inside the image is owned by kapowarr's bundled
      # default user; with `--user` overridden to server-${env}:servers
      # the bundled user can't write there, so mount the logs dir off
      # of the host state tree to keep them writable (and conveniently
      # included in the /var/lib/containers restic snapshot).
      systemd.tmpfiles.rules = [
        "d /var/lib/containers/kapowarr 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/kapowarr/db 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/kapowarr/logs 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.kapowarr = {
        # renovate: datasource=docker depName=mrcas/kapowarr
        image = "mrcas/kapowarr:v1.3.1";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/kapowarr/db:/app/db"
          "/var/lib/containers/kapowarr/logs:/app/logs"
          "/mnt/content/comics:/content"
          "/mnt/content/Downloads:/app/temp_downloads"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
