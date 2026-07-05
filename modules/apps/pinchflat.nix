# Pinchflat - yt-dlp channel/playlist subscription manager
# Native services.pinchflat from nixpkgs (Phoenix/Elixir app backed by
# SQLite). User/group overridden to the shared server-${env}:servers
# user so writes against /mnt/content/youtube land with the UID/GID
# the NAS expects — pinchflat drops Jellyfin-friendly NFOs alongside
# the media, and Jellyfin reads them via the same NFS share.
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.pinchflat` by modules/platform/authentik.nix
# (pinchflat ships no native OIDC — only BASIC_AUTH_* env vars — so we
# gate it via forward-auth and skip the built-in basic auth entirely).
#
# SECRET_KEY_BASE is sourced from sops via secretsFile. The nixpkgs
# module enforces an assertion that either `selfhosted = true` (weak
# secret) or `secretsFile` is set; we go with sops. The key must be
# a 64-byte hex string (`openssl rand -hex 64`).
_: {
  flake.modules.nixos.pinchflat =
    {
      config,
      hostSpec,
      ...
    }:
    let
      port = 8945;
    in
    {
      sops.secrets."pinchflat/secret_key_base" = {
        inherit (hostSpec) sopsFile;
        restartUnits = [ "pinchflat.service" ];
      };

      sops.templates."pinchflat.env" = {
        content = ''
          SECRET_KEY_BASE=${config.sops.placeholder."pinchflat/secret_key_base"}
        '';
        restartUnits = [ "pinchflat.service" ];
      };

      myAuthentik.forwardAuthApps.pinchflat = {
        inherit port;
        displayName = "Pinchflat";
        homepage = {
          group = "Acquisition";
          icon = "pinchflat";
          description = "YouTube subscription downloader";
        };
      };

      services.pinchflat = {
        enable = true;
        inherit port;
        # NFS UID alignment: pinchflat writes media + NFOs to the
        # Synology share at /mnt/content/youtube. user/group creation
        # in the module is gated behind cfg.user == "pinchflat", so
        # overriding to the shared server-${env} user cleanly skips
        # the module's user block.
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
        mediaDir = "/mnt/content/youtube";
        secretsFile = config.sops.templates."pinchflat.env".path;
      };

      myAppState.pinchflat = {
        stateDir = "/var/lib/pinchflat";
        user = hostSpec.serverUser;
      };

      mySqliteQuiesce.apps.pinchflat.databases = [
        "/var/lib/pinchflat/db/pinchflat.db"
      ];
    };
}
