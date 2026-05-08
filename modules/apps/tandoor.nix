# Tandoor - recipe manager
# Container; OIDC against authentik gated to the Users group. Tandoor
# speaks OIDC via django-allauth: SOCIAL_PROVIDERS selects the
# openid_connect backend, SOCIALACCOUNT_PROVIDERS is a single-line JSON
# blob with the client credentials and discovery URL. The blueprint
# pins the redirect URI to /accounts/oidc/authentik/login/callback/ —
# allauth derives that path from `provider_id: authentik`.
#
# OIDC client creds live in sops once and feed two env files: tandoor
# itself reads SOCIALACCOUNT_PROVIDERS (constructed inline so the
# secret values land in the JSON), the authentik worker reads
# TANDOOR_OIDC_CLIENT_* so the blueprint's `!Env` placeholders resolve
# at apply time.
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
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "tandoor/db_password" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          owner = "postgres";
          restartUnits = [ "tandoor-db-password.service" ];
        };
        "tandoor/secret_key" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = [ "podman-tandoor.service" ];
        };
        "tandoor/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-tandoor.service" ];
        };
        "tandoor/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-tandoor.service" ];
        };
      };

      sops.templates = {
        "tandoor.env" = {
          content = ''
            POSTGRES_PASSWORD=${config.sops.placeholder."tandoor/db_password"}
            SECRET_KEY=${config.sops.placeholder."tandoor/secret_key"}
            SOCIALACCOUNT_PROVIDERS={"openid_connect":{"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"${
              config.sops.placeholder."tandoor/oidc_client_id"
            }","secret":"${
              config.sops.placeholder."tandoor/oidc_client_secret"
            }","settings":{"server_url":"https://${authentikHost}/application/o/tandoor/.well-known/openid-configuration"}}]}}
          '';
          restartUnits = [ "podman-tandoor.service" ];
        };
        "tandoor-authentik.env" = {
          content = ''
            TANDOOR_OIDC_CLIENT_ID=${config.sops.placeholder."tandoor/oidc_client_id"}
            TANDOOR_OIDC_CLIENT_SECRET=${config.sops.placeholder."tandoor/oidc_client_secret"}
          '';
          restartUnits = restartAuthentik;
        };
      };

      services.postgresql = {
        ensureDatabases = [ "tandoor" ];
        ensureUsers = [
          {
            name = "tandoor";
            ensureDBOwnership = true;
          }
        ];
      };

      systemd = {
        services = {
          tandoor-db-password = {
            description = "Set tandoor postgres role password from sops secret";
            after = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
            requires = [ "postgresql.service" ];
            wants = [ "postgresql-setup.service" ];
            wantedBy = [ "podman-tandoor.service" ];
            before = [ "podman-tandoor.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              Group = "postgres";
            };
            script = ''
              ${config.services.postgresql.package}/bin/psql -tAc \
                "ALTER USER tandoor WITH PASSWORD '$(cat ${config.sops.secrets."tandoor/db_password".path})'"
            '';
          };

          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."tandoor-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."tandoor-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."tandoor-authentik.env".path
          ];
        };

        tmpfiles.rules = [
          "d /var/lib/containers/tandoor 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/tandoor/staticfiles 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/tandoor/mediafiles 0750 ${toString serverUid} ${toString serverGid} -"
        ];
      };

      myAuthentik.extraBlueprints = [ ./tandoor-blueprints ];

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

      myHomepage.tiles.Tandoor = {
        group = "Consumption";
        href = "https://${tandoorHost}";
        icon = "tandoor";
        description = "Recipe manager";
      };
    };
}
