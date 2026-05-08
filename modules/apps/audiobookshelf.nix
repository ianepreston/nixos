# Audiobookshelf - audiobook + podcast manager
# Container; OIDC against authentik. Audiobookshelf doesn't read OIDC
# settings from env vars — those live in its own database — so this
# module only stages the authentik side (provider/application/policy
# binding via the blueprint, plus the env-file for the worker so
# `!Env` substitutions resolve). The audiobookshelf-side toggle and
# matching client-id / client-secret have to be entered once in the
# UI under Settings → Authentication → OpenID Connect; subsequent
# logins flow through SSO.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
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
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "audiobookshelf/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
        "audiobookshelf/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
      };

      sops.templates."audiobookshelf-authentik.env" = {
        content = ''
          AUDIOBOOKSHELF_OIDC_CLIENT_ID=${config.sops.placeholder."audiobookshelf/oidc_client_id"}
          AUDIOBOOKSHELF_OIDC_CLIENT_SECRET=${config.sops.placeholder."audiobookshelf/oidc_client_secret"}
        '';
        restartUnits = restartAuthentik;
      };

      myAuthentik.extraBlueprints = [ ./audiobookshelf-blueprints ];

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/audiobookshelf 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/audiobookshelf/config 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/audiobookshelf/metadata 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services = {
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."audiobookshelf-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."audiobookshelf-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."audiobookshelf-authentik.env".path
          ];
        };
      };

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

      myHomepage.tiles.Audiobookshelf = {
        group = "Consumption";
        href = "https://${audiobookshelfHost}";
        icon = "audiobookshelf";
        description = "Audiobooks";
      };
    };
}
