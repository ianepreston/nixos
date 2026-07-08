# ytdlp-web-player - stream-oriented yt-dlp web player
# (https://github.com/Matszwe02/ytdlp_web_player). Paste a URL, the app
# fetches it with yt-dlp and streams it back; downloads are ephemeral
# (auto-purged after MAX_VIDEO_AGE of inactivity). Container only — no
# nixpkgs module. Has no built-in auth, so it's gated by the authentik
# embedded outpost via Caddy (myAuthentik.forwardAuthApps), exactly like
# kapowarr.
#
# Runs as root (manageUser = false) rather than server-${env}:servers.
# The upstream image is a bare `python:3.13-alpine` with no PUID/PGID
# mechanism, and its daily yt-dlp self-update runs
# `pip install --upgrade yt-dlp` into the root-owned system site-packages
# — which fails silently under a dropped uid, leaving yt-dlp to rot while
# YouTube's extractors move on. Root keeps the self-update working. The
# app touches no NFS share (downloads are a local ephemeral cache), so
# the usual NFS UID-alignment reason to force the server user doesn't
# apply here.
_: {
  flake.modules.nixos.ytdlp-web-player =
    { hostSpec, ... }:
    let
      # Host loopback port; the container listens on 5000 internally.
      port = 5010;
      containerPort = 5000;
    in
    {
      myAuthentik.forwardAuthApps.ytdlp-web-player = {
        inherit port;
        host = "ytdlp.${hostSpec.serverDomain}";
        displayName = "YT-DLP Player";
        authentikGroup = "Users";
        iconUrl = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/yt-dlp.png";
        homepage = {
          group = "Consumption";
          icon = "yt-dlp";
          description = "Stream videos via yt-dlp";
        };
      };

      # Stateless: the only thing this app writes is the download cache
      # (transient videos it auto-purges after MAX_VIDEO_AGE) and the
      # self-updated yt-dlp binary (re-fetched on every start). Neither is
      # worth persisting, so there's no state dir and no bind mount — the
      # cache lives in the container's own writable layer and is never
      # pulled into the restic snapshot. stateDirs = [ ] suppresses the
      # default /var/lib/containers/<app> tmpfiles rule.
      myContainerApp.ytdlp-web-player = {
        inherit port containerPort;
        manageUser = false;
        stateDirs = [ ];
      };

      virtualisation.oci-containers.containers.ytdlp-web-player = {
        # renovate: datasource=docker depName=matszwe02/ytdlp_web_player
        image = "matszwe02/ytdlp_web_player:v1.0.1";
        # PORT matches containerPort; DOWNLOAD_PATH defaults to ./download
        # inside the container, which is fine as an ephemeral cache.
        environment.PORT = toString containerPort;
      };
    };
}
