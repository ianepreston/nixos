# Audiobookshelf - audiobook + podcast manager
# Container; OIDC against authentik. Audiobookshelf doesn't read OIDC
# settings from env vars — those live in its own database — so this
# module only stages the authentik side via myAuthentik.oidcApps with
# clientCredsInAppEnv = false. The audiobookshelf-side toggle and
# matching client-id / client-secret have to be entered once in the
# UI under Settings → Authentication → OpenID Connect; subsequent
# logins flow through SSO.
_: {
  flake.modules.nixos.audiobookshelf =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
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

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/audiobookshelf 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/audiobookshelf/config 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/audiobookshelf/metadata 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.audiobookshelf = {
        # renovate: datasource=docker depName=ghcr.io/advplyr/audiobookshelf
        image = "ghcr.io/advplyr/audiobookshelf:2.34.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/audiobookshelf/config:/config"
          "/var/lib/containers/audiobookshelf/metadata:/metadata"
          "/mnt/content/audiobooks:/audiobooks"
        ];
        # Default listen port is 80; bump it so the unprivileged --user
        # override can bind without CAP_NET_BIND_SERVICE.
        environment = {
          PORT = toString port;
          TZ = config.time.timeZone;
        };
      };

      myCaddy.apps.audiobookshelf = {
        host = audiobookshelfHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
