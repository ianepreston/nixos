# Audiobookshelf - audiobook + podcast manager
# Native services.audiobookshelf from nixpkgs (Node service; user
# overridden to server-${env}:servers so reads against /mnt/content/
# audiobooks line up with the NFS UID the NAS expects). OIDC against
# authentik is configured in the audiobookshelf UI under Settings →
# Authentication → OpenID Connect (clientCredsInAppEnv = false on
# myAuthentik.oidcApps); this module only stages the authentik side.
#
# `audiobooks` library path: the container exposed the share at
# /audiobooks via a bind-mount; the native service runs in the host
# namespace, so update the library path in the audiobookshelf UI to
# /mnt/content/audiobooks after migration.
_: {
  flake.modules.nixos.audiobookshelf =
    { hostSpec, ... }:
    let
      audiobookshelfHost = "audiobookshelf.${hostSpec.serverDomain}";
      port = 13378;
    in
    {
      myAuthentik.oidcApps.audiobookshelf = {
        blueprintsDir = ./audiobookshelf-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Consumption";
          icon = "audiobookshelf";
          description = "Audiobooks";
        };
        homepageDisplayName = "Audiobookshelf";
        homepageHref = "https://${audiobookshelfHost}";
      };

      services.audiobookshelf = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
        inherit port;
      };

      services.restic.backups.server.paths = [ "/var/lib/audiobookshelf" ];

      # Audiobookshelf stores its sqlite db and metadata cache as
      # `config/` and `metadata/` subdirs inside the working directory,
      # so the container's two volumes map cleanly into one new tree.
      systemd.services.audiobookshelf-migrate-state = {
        description = "Migrate audiobookshelf state from container layout";
        before = [ "audiobookshelf.service" ];
        wantedBy = [ "audiobookshelf.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/audiobookshelf";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p /var/lib/audiobookshelf
          for sub in config metadata; do
            if [ -d /var/lib/containers/audiobookshelf/$sub ] && \
               { [ ! -e /var/lib/audiobookshelf/$sub ] || \
                 [ -z "$(ls -A /var/lib/audiobookshelf/$sub 2>/dev/null)" ]; }; then
              rm -rf /var/lib/audiobookshelf/$sub
              mv /var/lib/containers/audiobookshelf/$sub /var/lib/audiobookshelf/$sub
            fi
          done
        '';
      };

      myCaddy.apps.audiobookshelf = {
        host = audiobookshelfHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
