# MeTube - single-page yt-dlp frontend for ad-hoc downloads
# Container only — not packaged in nixpkgs (the closest names there
# are unrelated apps: `metee`, `smtube`, `yewtube`). auth/caddy/
# homepage wired by platform/authentik.nix. MeTube ships no built-in
# auth, so forward-auth is mandatory in front of it.
#
# Downloads land in /mnt/content/youtube/metube so they're visible to
# Jellyfin via the same NFS share pinchflat writes to (kept under a
# sibling dir so the two tools don't fight over output templates).
# Container runs as server-${env}:servers so NFS sees the expected
# UID/GID. CHOWN_DIRS is disabled because the container would
# otherwise try to chown the NFS mount on startup (the NAS rejects
# server-side chowns from clients).
_: {
  flake.modules.nixos.metube =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      # 8081 is cAdvisor (modules/system/prometheus.nix); 8082 is
      # homepage (modules/system/homepage.nix). 8085 is the next free
      # loopback port.
      port = 8085;
    in
    {
      myAuthentik.forwardAuthApps.metube = {
        inherit port;
        displayName = "MeTube";
        iconUrl = "https://raw.githubusercontent.com/alexta69/metube/master/favicon/android-chrome-192x192.png";
        homepage = {
          group = "Acquisition";
          icon = "https://raw.githubusercontent.com/alexta69/metube/master/favicon/android-chrome-192x192.png";
          description = "Ad-hoc yt-dlp downloader";
        };
      };

      # State dir for MeTube's queue.json / completed.json etc. Kept
      # off the NFS share so persistence survives independent of the
      # media output dir.
      systemd.tmpfiles.rules = [
        "d /var/lib/containers/metube 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.metube = {
        # renovate: datasource=docker depName=ghcr.io/alexta69/metube
        image = "ghcr.io/alexta69/metube:2026.04.28";
        # MeTube inside the container always listens on 8081; map our
        # chosen host port onto that.
        ports = [ "127.0.0.1:${toString port}:8081" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/metube:/downloads/.metube"
          "/mnt/content/youtube/metube:/downloads"
        ];
        environment = {
          TZ = config.time.timeZone;
          DOWNLOAD_DIR = "/downloads";
          STATE_DIR = "/downloads/.metube";
          TEMP_DIR = "/downloads";
          # NFS rejects client-side chown; skip the startup ownership
          # fixup since the bind-mount root is already owned correctly
          # by the systemd-tmpfiles rule above and the NAS export.
          CHOWN_DIRS = "false";
          UID = toString serverUid;
          GID = toString serverGid;
        };
      };
    };
}
