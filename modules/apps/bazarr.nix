# Bazarr - subtitles for sonarr/radarr libraries
# Container only; auth/caddy/homepage wired by arr-auth.nix. Reads from
# both /mnt/content/TV and /mnt/content/Movies so it can write subtitle
# files alongside the video files sonarr and radarr manage.
_: {
  flake.modules.nixos.bazarr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 6767;
    in
    {
      myArrAuth.apps.bazarr = {
        inherit port;
        displayName = "Bazarr";
        homepageDescription = "Subtitle manager";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/bazarr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.bazarr = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/bazarr
        image = "lscr.io/linuxserver/bazarr:1.5.6";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/bazarr:/config"
          "/mnt/content/TV:/tv"
          "/mnt/content/Movies:/movies"
        ];
        environment = {
          PUID = toString serverUid;
          PGID = toString serverGid;
          TZ = config.time.timeZone;
        };
      };
    };
}
