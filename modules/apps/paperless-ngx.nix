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
# The blob is single-quoted: systemd's EnvironmentFile parser strips
# the outer quotes, but `paperless-manage` sources the same file in
# bash, where an unquoted value loses its inner double quotes and
# Django dies on json.loads at import time.
#
# Postgres uses the existing `paperless_ngx` role/db over TCP +
# password (myPostgresApp helper). The upstream module's
# `database.createLocally = true` path would force the role/db to
# rename to `paperless`, so we point at the existing role over TCP
# instead.
#
# Secret-key handling: all four units take PAPERLESS_SECRET_KEY from
# the sops env file. The upstream module's paperless-secret-key.service
# only generates a key when the env file doesn't supply one; because
# ours does, it just creates the empty shim file the units'
# EnvironmentFile list expects (ours is listed second, so it wins).
#
# Version currency: nixos-26.05 pins 2.20.15, the tail of the old
# major, while upstream is on 3.x. Per CLAUDE.md ("wire a per-package
# overlay rather than flipping the whole flake to unstable") the
# package comes from nixpkgs-unstable. The 2.x -> 3.x module changed
# in lockstep with the package (Whoosh → Tantivy index with its own
# tmpfiles dir and a `reindex --if-needed` migration, the secret-key
# service above, `passthru.dependencies` instead of
# `propagatedBuildInputs` for the web unit's PYTHONPATH), so the
# stable module cannot drive a 3.x package — disabledModules swaps in
# the unstable module to match. Both track the flake's
# nixpkgs-unstable input, which the flake-update workflow bumps.
#
# Upgrade notes (2.20.15 → 3.x, #526): the scheduler preStart runs
# `migrate` then `document_index reindex --if-needed`, which converts
# the Whoosh index to Tantivy in place. One-way — take a restic
# snapshot first.
#
# Closure cost: 3.x hard-wires the AI subsystem's deps (llama-index +
# sentence-transformers + a CPU torch) into the package with no
# nixpkgs opt-out, taking it from 2.8 GB to 5.1 GB even with
# PAPERLESS_AI_ENABLED off. Accepted — #527 wants that subsystem
# anyway.
{ inputs, ... }:
{
  flake.modules.nixos.paperless-ngx =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      # Pin just the paperless package (and, via disabledModules below,
      # its NixOS module) to unstable; the rest of the system stays on
      # stable.
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };

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
      # The 3.x package needs the 3.x module (see the header comment).
      disabledModules = [ "services/misc/paperless.nix" ];
      imports = [ "${inputs.nixpkgs-unstable}/nixos/modules/services/misc/paperless.nix" ];

      myPostgresApp.paperless-ngx.consumerService = paperlessUnits;

      # No restartUnits here: the key is only consumed through
      # sops.templates."paperless-ngx.env" (built by myAuthentik.oidcApps
      # from extraEnvLines below), which already carries them.
      sops.secrets."paperless-ngx/secret_key".sopsFile = hostSpec.sopsFile;

      myAuthentik.oidcApps.paperless-ngx = {
        blueprintsDir = ./paperless-ngx-blueprints;
        appRestartUnit = paperlessUnits;
        clientCredsInAppEnv = false;
        displayName = "Paperless-ngx";
        extraEnvLines = ''
          PAPERLESS_DBPASS=${config.sops.placeholder."paperless-ngx/db_password"}
          PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless-ngx/secret_key"}
          PAPERLESS_SOCIALACCOUNT_PROVIDERS='{"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"${
            config.sops.placeholder."paperless-ngx/oidc_client_id"
          }","secret":"${
            config.sops.placeholder."paperless-ngx/oidc_client_secret"
          }","settings":{"server_url":"https://${authentikHost}/application/o/paperless-ngx/.well-known/openid-configuration","fetch_userinfo":true}}],"SCOPE":["openid","profile","email"]}}'
        '';
        homepage = {
          group = "Home";
          icon = "paperless-ngx";
          description = "Documents";
        };
      };

      services.paperless = {
        enable = true;
        package = pkgsUnstable.paperless-ngx;
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
      myAppState.paperless-ngx = {
        stateDir = dataDir;
        user = "paperless";
        group = "paperless";
      };

      services = {
        # Open a loopback TCP port on the upstream module's per-app redis
        # so redis_exporter (in modules/system/victoriametrics.nix) can
        # scrape it. Paperless itself keeps talking to the unix socket;
        # this is metrics-only.
        redis.servers.paperless = {
          port = 6382;
          bind = "127.0.0.1";
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
