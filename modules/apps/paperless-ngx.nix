# Paperless-ngx - document management + OCR
# Native services.paperless from nixpkgs (4 systemd units:
# paperless-{scheduler,task-queue,consumer,web}; the module also wires
# a private redis instance on a unix socket via
# services.redis.servers.paperless). OIDC against authentik gated to
# the Home group; speaks OIDC via django-allauth with the
# openid_connect provider, so PAPERLESS_SOCIALACCOUNT_PROVIDERS is a
# single-line JSON blob with the client credentials and discovery URL
# (constructed inline so secrets never leave sops). The blueprint
# pins the redirect URI to /accounts/oidc/authentik/login/callback/.
#
# Postgres uses the existing `paperless_ngx` role/db over TCP +
# password (myPostgresApp helper). The upstream module's
# `database.createLocally = true` path would force the role/db to
# rename to `paperless`, so we point at the existing role over TCP
# instead.
#
# Secret-key handling: paperless-web's runtime script reads its key
# from /var/lib/paperless-ngx/nixos-paperless-secret-key (auto-
# generated on first start), while the other three units read
# PAPERLESS_SECRET_KEY from the env file. A oneshot pre-seeds the
# file from sops on first run so all four agree on the same key.
_: {
  flake.modules.nixos.paperless-ngx =
    {
      config,
      hostSpec,
      ...
    }:
    let
      paperlessHost = "paperless-ngx.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      port = 8010;
      dataDir = "/var/lib/paperless-ngx";
      paperlessUnits = [
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-consumer.service"
        "paperless-web.service"
      ];
    in
    {
      myPostgresApp.paperless-ngx.consumerService = paperlessUnits;

      sops.secrets."paperless-ngx/secret_key" = {
        inherit (hostSpec) sopsFile;
        restartUnits = paperlessUnits;
      };

      myAuthentik.oidcApps.paperless-ngx = {
        blueprintsDir = ./paperless-ngx-blueprints;
        appRestartUnit = paperlessUnits;
        clientCredsInAppEnv = false;
        displayName = "Paperless-ngx";
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
          group = "Home";
          icon = "paperless-ngx";
          description = "Documents";
        };
      };

      services.paperless = {
        enable = true;
        inherit dataDir port;
        address = "127.0.0.1";
        environmentFile = config.sops.templates."paperless-ngx.env".path;
        settings = {
          # Reuse the existing paperless_ngx role/db — the module's
          # `database.createLocally` path would rename them to
          # `paperless`, which would mean a destructive SQL migration.
          PAPERLESS_DBENGINE = "postgresql";
          PAPERLESS_DBHOST = "127.0.0.1";
          PAPERLESS_DBPORT = "5432";
          PAPERLESS_DBNAME = "paperless_ngx";
          PAPERLESS_DBUSER = "paperless_ngx";

          PAPERLESS_URL = "https://${paperlessHost}";
          PAPERLESS_OCR_LANGUAGE = "eng";
          PAPERLESS_USE_X_FORWARD_HOST = true;
          PAPERLESS_USE_X_FORWARD_PORT = true;
          PAPERLESS_PROXY_SSL_HEADER = [
            "HTTP_X_FORWARDED_PROTO"
            "https"
          ];

          # OIDC via django-allauth — same wiring as the container.
          PAPERLESS_ENABLE_ALLAUTH = true;
          PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
          PAPERLESS_SOCIAL_AUTO_SIGNUP = true;
          PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = true;
          PAPERLESS_LOGOUT_REDIRECT_URL = "https://${authentikHost}/application/o/paperless-ngx/end-session/";
        };
      };

      # Preservation defaults the bind-mount root to root:root mode
      # 0755, but paperless runs its data-dir writability check at
      # startup (django framework check) and fails if the top-level
      # dir isn't owned by the paperless user — subdirs being owned
      # correctly isn't enough. Match the service user/group.
      preservation.preserveAt."/persist".directories = [
        {
          directory = dataDir;
          user = "paperless";
          group = "paperless";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ dataDir ];

      # paperless-web persists its secret key into the data dir and
      # ignores PAPERLESS_SECRET_KEY from the env. The other three
      # units read the env. Without this oneshot the four units would
      # disagree on the key — fine in normal operation (workers don't
      # sign user-facing tokens) but an unnecessary footgun. Seed the
      # file from sops on first run so they agree.
      systemd.services.paperless-secret-key-init = {
        description = "Seed paperless web secret key from sops";
        before = paperlessUnits;
        wantedBy = paperlessUnits;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0700 -o paperless -g paperless ${dataDir}
          if [ ! -f ${dataDir}/nixos-paperless-secret-key ]; then
            install -m 0400 -o paperless -g paperless \
              ${config.sops.secrets."paperless-ngx/secret_key".path} \
              ${dataDir}/nixos-paperless-secret-key
          fi
        '';
      };

      myCaddy.apps.paperless-ngx = {
        host = paperlessHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
