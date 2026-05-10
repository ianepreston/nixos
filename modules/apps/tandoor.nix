# Tandoor - recipe manager
# Container; OIDC against authentik gated to the Users group. Tandoor
# speaks OIDC via django-allauth: SOCIAL_PROVIDERS selects the
# openid_connect backend, SOCIALACCOUNT_PROVIDERS is a single-line JSON
# blob with the client credentials and discovery URL. The blueprint
# pins the redirect URI to /accounts/oidc/authentik/login/callback/ —
# allauth derives that path from `provider_id: authentik`.
#
# OIDC creds, the secret key, and the postgres password all flow into
# tandoor's env file. clientCredsInAppEnv stays false because the
# canonical `client_id` / `client_secret` env vars are spliced inline
# into SOCIALACCOUNT_PROVIDERS via extraEnvLines instead — Tandoor
# only reads creds from the JSON blob.
#
# Nginx in the upstream image listens on TANDOOR_PORT; we set it to
# 8080 so the container can run as the unprivileged servers UID
# without needing CAP_NET_BIND_SERVICE.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.tandoor =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      tandoorHost = "tandoor.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
    in
    {
      myPostgresApp.tandoor.consumerService = "podman-tandoor.service";

      sops.secrets."tandoor/secret_key" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        restartUnits = [ "podman-tandoor.service" ];
      };

      myAuthentik.oidcApps.tandoor = {
        blueprintsDir = ./tandoor-blueprints;
        appRestartUnit = "podman-tandoor.service";
        clientCredsInAppEnv = false;
        extraEnvLines = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."tandoor/db_password"}
          SECRET_KEY=${config.sops.placeholder."tandoor/secret_key"}
          SOCIALACCOUNT_PROVIDERS={"openid_connect":{"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"${
            config.sops.placeholder."tandoor/oidc_client_id"
          }","secret":"${
            config.sops.placeholder."tandoor/oidc_client_secret"
          }","settings":{"server_url":"https://${authentikHost}/application/o/tandoor/.well-known/openid-configuration"}}]}}
        '';
        homepage = {
          group = "Home";
          icon = "tandoor-recipes";
          description = "Recipe manager";
        };
        homepageDisplayName = "Tandoor";
        homepageHref = "https://${tandoorHost}";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/tandoor 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/tandoor/staticfiles 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/tandoor/mediafiles 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.tandoor = {
        # renovate: datasource=docker depName=vabene1111/recipes
        image = "vabene1111/recipes:2.6.9";
        ports = [ "127.0.0.1:8083:8080" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/tandoor/staticfiles:/opt/recipes/staticfiles"
          "/var/lib/containers/tandoor/mediafiles:/opt/recipes/mediafiles"
        ];
        environment = {
          TZ = config.time.timeZone;
          TANDOOR_PORT = "8080";
          DEBUG = "0";
          ALLOWED_HOSTS = tandoorHost;
          DB_ENGINE = "django.db.backends.postgresql";
          POSTGRES_HOST = "host.containers.internal";
          POSTGRES_PORT = "5432";
          POSTGRES_USER = "tandoor";
          POSTGRES_DB = "tandoor";

          # OIDC. ENABLE_SIGNUP=0 disables the local signup form;
          # SOCIALACCOUNT_AUTO_SIGNUP=1 lets allauth provision accounts
          # on first OIDC login without forcing a signup form. New
          # users get the `user` role + default space access.
          SOCIAL_PROVIDERS = "allauth.socialaccount.providers.openid_connect";
          SOCIALACCOUNT_AUTO_SIGNUP = "1";
          SOCIAL_DEFAULT_GROUP = "user";
          SOCIAL_DEFAULT_ACCESS = "1";
          ENABLE_SIGNUP = "0";
        };
        environmentFiles = [ config.sops.templates."tandoor.env".path ];
      };

      myCaddy.apps.tandoor = {
        host = tandoorHost;
        routeConfig = ''
          reverse_proxy localhost:8083
        '';
      };
    };
}
