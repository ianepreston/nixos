# Komga - comic + manga server
# Container with native OIDC against authentik. Komga is a Spring Boot
# app, so its OIDC client config is set via Spring's relaxed-binding
# env vars (SPRING_SECURITY_OAUTH2_CLIENT_*). The provider name segment
# (`authentik`) shows up in the redirect URI: Spring routes the OAuth2
# callback through `/login/oauth2/code/<registrationId>`.
#
# Komga doesn't have a sign-up toggle for OAuth — first OIDC login
# creates an account, but only if the email address matches an
# already-existing Komga user, OR if `unauthorizedRedirect` is wired
# up. To onboard new users, log in once as the Komga admin and
# pre-create their accounts (email-only is fine), or flip the
# auto-create flag in the Komga admin UI.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.komga =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      komgaHost = "komga.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      port = 25600;
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "komga/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-komga.service" ];
        };
        "komga/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-komga.service" ];
        };
      };

      sops.templates = {
        "komga.env" = {
          content = ''
            SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_ID=${
              config.sops.placeholder."komga/oidc_client_id"
            }
            SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_SECRET=${
              config.sops.placeholder."komga/oidc_client_secret"
            }
          '';
          restartUnits = [ "podman-komga.service" ];
        };
        "komga-authentik.env" = {
          content = ''
            KOMGA_OIDC_CLIENT_ID=${config.sops.placeholder."komga/oidc_client_id"}
            KOMGA_OIDC_CLIENT_SECRET=${config.sops.placeholder."komga/oidc_client_secret"}
          '';
          restartUnits = restartAuthentik;
        };
      };

      myAuthentik.extraBlueprints = [ ./komga-blueprints ];

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/komga 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services = {
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."komga-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."komga-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."komga-authentik.env".path
          ];
        };
      };

      virtualisation.oci-containers.containers.komga = {
        # renovate: datasource=docker depName=gotson/komga
        image = "gotson/komga:1.24.4";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/komga:/config"
          "/mnt/content/comics:/data/comics"
          "/mnt/content/books:/data/books"
        ];
        environment = {
          TZ = config.time.timeZone;
          SERVER_PORT = toString port;
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_NAME = "Authentik";
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_SCOPE = "openid,profile,email";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_ISSUER_URI = "https://${authentikHost}/application/o/komga/";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_USER_NAME_ATTRIBUTE = "preferred_username";
        };
        environmentFiles = [ config.sops.templates."komga.env".path ];
      };

      myCaddy.apps.komga = {
        host = komgaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };

      myHomepage.tiles.Komga = {
        group = "Consumption";
        href = "https://${komgaHost}";
        icon = "komga";
        description = "Comics + manga";
      };
    };
}
