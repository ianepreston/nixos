# Mealie - recipe manager
# Composes the OCI container, its caddy virtualHost, a postgres
# database/user with a sops-managed password (via myPostgresApp), and
# an authentik OIDC integration (via myAuthentik.oidcApps). Mealie
# speaks OIDC natively; the provider/application/policy binding live
# in modules/apps/mealie-blueprints/ and are wired into authentik via
# the aggregator's blueprintsDir option.
_: {
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
    in
    {
      myPostgresApp.mealie.consumerService = "podman-mealie.service";

      myAuthentik.oidcApps.mealie = {
        blueprintsDir = ./mealie-blueprints;
        appRestartUnit = "podman-mealie.service";
        extraEnvLines = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."mealie/db_password"}
        '';
        homepage = {
          group = "Consumption";
          icon = "mealie";
          description = "Recipe manager";
        };
        homepageDisplayName = "Mealie";
        homepageHref = "https://${mealieHost}";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/mealie 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.mealie = {
        # renovate: datasource=docker depName=ghcr.io/mealie-recipes/mealie
        image = "ghcr.io/mealie-recipes/mealie:v3.17.0";
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
          OIDC_USER_GROUP = "Users";
          OIDC_ADMIN_GROUP = "authentik Admins";
          OIDC_AUTO_REDIRECT = "false";
          OIDC_REMEMBER_ME = "true";
          OIDC_SIGNUP_ENABLED = "true";
        };
        environmentFiles = [ config.sops.templates."mealie.env".path ];
      };

      myCaddy.apps.mealie = {
        host = mealieHost;
        routeConfig = ''
          reverse_proxy localhost:9925
        '';
      };
    };
}
