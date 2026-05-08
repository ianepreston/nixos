# Bazarr - subtitles for sonarr/radarr libraries
# Container only; auth/caddy/homepage wired by platform/authentik.nix. Reads from
# both /mnt/content/TV and /mnt/content/Movies so it can write subtitle
# files alongside the video files sonarr and radarr manage. Image
# baked-in user is `nobody:nogroup`; we override via `user` so writes
# back to the NFS share land with the UID/GID the NAS expects.
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
      myAuthentik.forwardAuthApps.bazarr = {
        inherit port;
        displayName = "Bazarr";
        homepage = {
          group = "Acquisition";
          icon = "bazarr";
          description = "Subtitle manager";
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/bazarr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.bazarr = {
        # renovate: datasource=docker depName=ghcr.io/home-operations/bazarr
        image = "ghcr.io/home-operations/bazarr:1.5.6";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/bazarr:/config"
          "/mnt/content/TV:/tv"
          "/mnt/content/Movies:/movies"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };
    };
}
