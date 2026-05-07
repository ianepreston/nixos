# Shelfmark - book search + request hub (calibrain/shelfmark)
# Container only; auth/caddy/homepage wired by arr-auth.nix. Mounts
# /mnt/content/books for downloaded books and /mnt/content/Downloads
# at the same path the *arr / sabnzbd containers see — shelfmark
# requires the torrent/usenet client volume to match exactly so it
# can hand off completed paths.
_: {
  flake.modules.nixos.shelfmark =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8084;
    in
    {
      myArrAuth.apps.shelfmark = {
        inherit port;
        displayName = "Shelfmark";
        homepageDescription = "Book search + requests";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/shelfmark 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/shelfmark/config 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.shelfmark = {
        # renovate: datasource=docker depName=ghcr.io/calibrain/shelfmark
        image = "ghcr.io/calibrain/shelfmark:v1.2.3";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/shelfmark/config:/config"
          "/mnt/content/books:/books"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          PUID = toString serverUid;
          PGID = toString serverGid;
          TZ = config.time.timeZone;
          FLASK_PORT = toString port;
        };
      };
    };
}
