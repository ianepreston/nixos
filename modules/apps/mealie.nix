# Mealie - recipe manager
# Composes the OCI container, its caddy virtualHost, a postgres
# database/user with a sops-managed password, and an authentik OIDC
# integration. Mealie speaks OIDC natively; the OAuth2 provider /
# application / policy binding live in modules/apps/mealie-blueprints/
# and are wired into authentik via myAuthentik.extraBlueprints.
#
# OIDC client credentials live in sops once and feed two systemd units
# under different env-var names: the mealie container needs
# OIDC_CLIENT_ID/OIDC_CLIENT_SECRET, the authentik worker needs
# MEALIE_OIDC_CLIENT_ID/MEALIE_OIDC_CLIENT_SECRET so the blueprint's
# `!Env` placeholders resolve when the worker applies the YAML.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.mealie =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      mealieHost = "mealie.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "mealie/db_password" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          owner = "postgres";
          # Re-apply the password to postgres whenever the secret changes.
          restartUnits = [ "mealie-db-password.service" ];
        };
        "mealie/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-mealie.service" ];
        };
        "mealie/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-mealie.service" ];
        };
      };

      sops.templates = {
        "mealie.env" = {
          content = ''
            POSTGRES_PASSWORD=${config.sops.placeholder."mealie/db_password"}
            OIDC_CLIENT_ID=${config.sops.placeholder."mealie/oidc_client_id"}
            OIDC_CLIENT_SECRET=${config.sops.placeholder."mealie/oidc_client_secret"}
          '';
          # Re-render env + restart container when the secret changes.
          restartUnits = [ "podman-mealie.service" ];
        };
        # Same secret values, exposed under MEALIE_OIDC_* names so the
        # authentik worker can substitute them into the blueprint at
        # apply time.
        "mealie-authentik.env" = {
          content = ''
            MEALIE_OIDC_CLIENT_ID=${config.sops.placeholder."mealie/oidc_client_id"}
            MEALIE_OIDC_CLIENT_SECRET=${config.sops.placeholder."mealie/oidc_client_secret"}
          '';
          restartUnits = restartAuthentik;
        };
      };

      services.postgresql = {
        ensureDatabases = [ "mealie" ];
        ensureUsers = [
          {
            name = "mealie";
            ensureDBOwnership = true;
          }
        ];
      };

      systemd = {
        services = {
          # Sets mealie's postgres password from the sops secret. Runs after
          # the role exists (postgresql-setup creates it via ensureUsers) and
          # before the container starts, so mealie never tries to connect
          # with a password that doesn't match what postgres has on file.
          # Splitting this out of postgresql-setup.postStart avoids the
          # failure mode where the secret hasn't been decrypted yet and
          # postgres clears the password.
          mealie-db-password = {
            description = "Set mealie postgres role password from sops secret";
            after = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
            requires = [ "postgresql.service" ];
            wants = [ "postgresql-setup.service" ];
            wantedBy = [ "podman-mealie.service" ];
            before = [ "podman-mealie.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              Group = "postgres";
            };
            script = ''
              ${config.services.postgresql.package}/bin/psql -tAc \
                "ALTER USER mealie WITH PASSWORD '$(cat ${config.sops.secrets."mealie/db_password".path})'"
            '';
          };

          # Append the mealie-authentik env file to the authentik units so
          # the worker has MEALIE_OIDC_* in scope when applying blueprints.
          # NixOS merges listOf path definitions, so this stacks on top of
          # the EnvironmentFile authentik-nix already sets.
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."mealie-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."mealie-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."mealie-authentik.env".path
          ];
        };

        tmpfiles.rules = [
          "d /var/lib/containers/mealie 0750 ${toString serverUid} ${toString serverGid} -"
        ];
      };

      myAuthentik.extraBlueprints = [ ./mealie-blueprints ];

      virtualisation.oci-containers.containers.mealie = {
        # renovate: datasource=docker depName=ghcr.io/mealie-recipes/mealie
        image = "ghcr.io/mealie-recipes/mealie:v3.15.0";
        ports = [ "127.0.0.1:9925:9000" ];
        volumes = [ "/var/lib/containers/mealie:/app/data" ];
        user = "${toString serverUid}:${toString serverGid}";
        environment = {
          ALLOW_SIGNUP = "false";
          BASE_URL = "https://${mealieHost}";
          DB_ENGINE = "postgres";
          POSTGRES_USER = "mealie";
          POSTGRES_SERVER = "host.containers.internal";
          POSTGRES_PORT = "5432";
          POSTGRES_DB = "mealie";
          TZ = config.time.timeZone;

          # OIDC. Auto-redirect stays off so password login still works
          # if SSO breaks; users can hit the "Login with Authentik"
          # button on the regular login page. Append `?direct=1` to the
          # URL to force the password form when needed.
          OIDC_AUTH_ENABLED = "true";
          OIDC_PROVIDER_NAME = "Authentik";
          OIDC_CONFIGURATION_URL = "https://${authentikHost}/application/o/mealie/.well-known/openid-configuration";
          OIDC_USER_GROUP = "Home";
          OIDC_ADMIN_GROUP = "authentik Admins";
          OIDC_AUTO_REDIRECT = "false";
          OIDC_REMEMBER_ME = "true";
          OIDC_SIGNUP_ENABLED = "true";
        };
        environmentFiles = [ config.sops.templates."mealie.env".path ];
      };

      services.caddy.virtualHosts.${mealieHost}.extraConfig = ''
        reverse_proxy localhost:9925
      '';
    };
}
