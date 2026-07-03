# Audiobookshelf - audiobook + podcast manager
# Native services.audiobookshelf from nixpkgs (Node service; user
# overridden to server-${env}:servers so reads against /mnt/content/
# audiobooks line up with the NFS UID the NAS expects). OIDC against
# authentik is configured in the audiobookshelf UI under Settings →
# Authentication → OpenID Connect (clientCredsInAppEnv = false on
# myAuthentik.oidcApps); this module only stages the authentik side.
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
        displayName = "Audiobookshelf";
      };

      services.audiobookshelf = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
        inherit port;
      };

      myAppState.audiobookshelf = {
        stateDir = "/var/lib/audiobookshelf";
        user = "server-${hostSpec.serverEnvironment}";
      };

      mySqliteQuiesce.apps.audiobookshelf.databases = [
        "/var/lib/audiobookshelf/config/absdatabase.sqlite"
      ];

      myCaddy.apps.audiobookshelf = {
        host = audiobookshelfHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
