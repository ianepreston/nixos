# Paperless-ngx - document management + OCR
# Container; OIDC against authentik gated to the Home group. Paperless
# speaks OIDC via django-allauth with the openid_connect provider:
# PAPERLESS_APPS pulls in the Django app, PAPERLESS_SOCIALACCOUNT_PROVIDERS
# is a single-line JSON blob with the client credentials and discovery
# URL (constructed inline so secrets never leave sops). The blueprint
# pins the redirect URI to /accounts/oidc/authentik/login/callback/ —
# allauth derives that path from `provider_id: authentik`.
#
# Postgres lives on the shared native instance (tandoor pattern) and
# the password is rotated from sops via a `paperless-ngx-db-password`
# oneshot. Redis runs as a sidecar container on the default podman
# bridge so paperless and authentik don't share a broker.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.paperless-ngx =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      paperlessHost = "paperless-ngx.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      port = 8010;
    in
    {
      myPostgresApp.paperless-ngx.consumerService = "podman-paperless-ngx.service";

      sops.secrets."paperless-ngx/secret_key" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        restartUnits = [ "podman-paperless-ngx.service" ];
      };

      myAuthentik.oidcApps.paperless-ngx = {
        blueprintsDir = ./paperless-ngx-blueprints;
        appRestartUnit = "podman-paperless-ngx.service";
        clientCredsInAppEnv = false;
        extraEnvLines = ''
          PAPERLESS_DBPASS=${config.sops.placeholder."paperless-ngx/db_password"}
          PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless-ngx/secret_key"}
          PAPERLESS_SOCIALACCOUNT_PROVIDERS={"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"${
            config.sops.placeholder."paperless-ngx/oidc_client_id"
          }","secret":"${
            config.sops.placeholder."paperless-ngx/oidc_client_secret"
          }","settings":{"server_url":"https://${authentikHost}/application/o/paperless-ngx/.well-known/openid-configuration","fetch_userinfo":true}}],"SCOPE":["openid","profile","email"]}}
        '';
        homepage = {
          group = "Infrastructure";
          icon = "paperless-ngx";
          description = "Documents";
        };
        homepageDisplayName = "Paperless-ngx";
        homepageHref = "https://${paperlessHost}";
      };

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/paperless-ngx 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/paperless-ngx/data 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/paperless-ngx/media 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/paperless-ngx/export 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/paperless-ngx/consume 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/paperless-ngx/redis 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services = {
          # Paperless waits on its dedicated redis sidecar so the
          # broker is up before Django attempts to connect.
          podman-paperless-ngx = {
            after = [ "podman-paperless-ngx-redis.service" ];
            requires = [ "podman-paperless-ngx-redis.service" ];
          };
        };
      };

      virtualisation.oci-containers.containers = {
        paperless-ngx-redis = {
          # renovate: datasource=docker depName=redis
          image = "redis:8.6.3-alpine";
          cmd = [
            "redis-server"
            "--save"
            "60"
            "1"
            "--loglevel"
            "warning"
          ];
          user = "${toString serverUid}:${toString serverGid}";
          volumes = [
            "/var/lib/containers/paperless-ngx/redis:/data"
          ];
        };

        paperless-ngx = {
          # renovate: datasource=docker depName=ghcr.io/paperless-ngx/paperless-ngx
          image = "ghcr.io/paperless-ngx/paperless-ngx:2.20.15";
          ports = [ "127.0.0.1:${toString port}:${toString port}" ];
          user = "${toString serverUid}:${toString serverGid}";
          volumes = [
            "/var/lib/containers/paperless-ngx/data:/usr/src/paperless/data"
            "/var/lib/containers/paperless-ngx/media:/usr/src/paperless/media"
            "/var/lib/containers/paperless-ngx/export:/usr/src/paperless/export"
            "/var/lib/containers/paperless-ngx/consume:/usr/src/paperless/consume"
          ];
          dependsOn = [ "paperless-ngx-redis" ];
          environment = {
            TZ = config.time.timeZone;
            USERMAP_UID = toString serverUid;
            USERMAP_GID = toString serverGid;
            PAPERLESS_PORT = toString port;
            PAPERLESS_URL = "https://${paperlessHost}";
            PAPERLESS_REDIS = "redis://paperless-ngx-redis:6379";
            PAPERLESS_DBHOST = "host.containers.internal";
            PAPERLESS_DBPORT = "5432";
            PAPERLESS_DBNAME = "paperless_ngx";
            PAPERLESS_DBUSER = "paperless_ngx";
            PAPERLESS_OCR_LANGUAGE = "eng";
            PAPERLESS_TIME_ZONE = config.time.timeZone;
            PAPERLESS_USE_X_FORWARD_HOST = "true";
            PAPERLESS_USE_X_FORWARD_PORT = "true";
            PAPERLESS_PROXY_SSL_HEADER = ''["HTTP_X_FORWARDED_PROTO","https"]'';

            # OIDC via django-allauth: enable allauth, pull in the
            # openid_connect Django app, auto-create accounts on first
            # login, and redirect logout back through authentik so SSO
            # state stays in sync.
            PAPERLESS_ENABLE_ALLAUTH = "true";
            PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
            PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
            PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = "true";
            PAPERLESS_LOGOUT_REDIRECT_URL = "https://${authentikHost}/application/o/paperless-ngx/end-session/";
          };
          environmentFiles = [ config.sops.templates."paperless-ngx.env".path ];
        };
      };

      myCaddy.apps.paperless-ngx = {
        host = paperlessHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
