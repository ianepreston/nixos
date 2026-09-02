# Tandoor - recipe manager
# Native `services.tandoor-recipes` from nixpkgs (single systemd unit,
# `tandoor-recipes.service`, running bare gunicorn). OIDC against
# authentik gated to the Users group. Tandoor speaks OIDC via
# django-allauth: SOCIAL_PROVIDERS selects the openid_connect backend,
# SOCIALACCOUNT_PROVIDERS is a single-line JSON blob with the client
# credentials and discovery URL. The blueprint pins the redirect URI to
# /accounts/oidc/authentik/login/callback/ — allauth derives that path
# from `provider_id: authentik`.
#
# OIDC creds, the secret key, and the postgres password all flow into
# tandoor's env file. clientCredsInAppEnv stays false because the
# canonical `client_id` / `client_secret` env vars are spliced inline
# into SOCIALACCOUNT_PROVIDERS via extraEnvLines instead — Tandoor
# only reads creds from the JSON blob.
#
# Secrets: the upstream module has no `environmentFile` option — it
# builds `environment = env` from `extraConfig` straight into the unit,
# which is world-readable in the store. So the sops template is stacked
# on out-of-module as `serviceConfig.EnvironmentFile`. systemd reads
# EnvironmentFile= *after* Environment=, so overlapping keys resolve to
# the file (systemd.exec(5): "Settings from these files override
# settings made with Environment="), and it reads them "from the file
# system of the service manager, before any file system changes like
# bind mounts take place" — as root, so the default root:root 0400 sops
# template is readable despite the unit's PrivateUsers=true.
#
# Departures from the module defaults, all via `extraConfig`:
#
#   * GUNICORN_MEDIA — the upstream container fronted gunicorn with an
#     nginx that served /media directly; the nix unit is bare gunicorn,
#     and Django only routes /media/ when GUNICORN_MEDIA is set (see
#     recipes/urls.py:43). Without it every recipe image 404s. Static
#     assets need no equivalent: collectstatic runs at build time and
#     whitenoise serves $out/lib/tandoor-recipes/staticfiles.
#   * GUNICORN_CMD_ARGS — the module sets only `--bind`, which leaves
#     gunicorn on its default of one sync worker. The container ran 3
#     workers x 2 threads (boot.sh), and with GUNICORN_MEDIA every
#     thumbnail is also a request through that pool, so a single worker
#     serializes a recipe list page. Overriding the var wholesale means
#     `address`/`port` below no longer reach gunicorn on their own —
#     they and the bind flag are fed from the same let bindings so they
#     cannot drift.
#   * MEDIA_ROOT — the module only defaults this sanely at
#     stateVersion >= 26.05; both servers are on 25.11, where the
#     default puts media at the state-dir root (and warns). Setting it
#     to <stateDir>/media also makes the module add the matching
#     StateDirectory= entry.
#   * ALLOWED_HOSTS — defaults to `cfg.address`, which would reject the
#     caddy vhost.
#
# Postgres stays on the existing `tandoor` role/db over TCP + a sops
# password (myPostgresApp). The module's `database.createLocally` path
# would rename role and db to `tandoor_recipes` — destructive, and it
# buys only the loss of a password we already manage. Same call as
# paperless-ngx.
#
# Operator note: the module links a `tandoor-recipes-manage` wrapper
# into the state dir, but it bakes in only the store-visible `env` —
# not SECRET_KEY or POSTGRES_PASSWORD, so it cannot reach the database
# on its own. Hand it the sops env file through systemd rather than the
# shell:
#
#   sudo systemd-run --pty --wait --collect \
#     -p EnvironmentFile=/run/secrets/rendered/tandoor.env \
#     -p Environment=PATH=/run/current-system/sw/bin \
#     /var/lib/tandoor-recipes/tandoor-recipes-manage <cmd>
#
# The wrapper's own `set -o allexport` block only assigns the vars in
# `env`, so the secrets passed in survive. Do NOT `source` the env file
# from a shell instead: systemd preserves quotes appearing after the
# first non-whitespace character of a value (systemd.exec(5)), POSIX
# shell does not — sourcing strips the inner quotes out of the
# SOCIALACCOUNT_PROVIDERS JSON blob and settings.py dies in
# ast.literal_eval. PATH is needed because the wrapper shells out to
# `tr` and `nsenter`.
_: {
  flake.modules.nixos.tandoor =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      tandoorHost = "tandoor.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";

      address = "localhost";
      port = 8083;
      stateDir = "/var/lib/tandoor-recipes";
      mediaRoot = "${stateDir}/media";

      unit = "tandoor-recipes.service";
    in
    {
      myPostgresApp.tandoor.consumerService = [ unit ];

      sops.secrets."tandoor/secret_key" = {
        inherit (hostSpec) sopsFile;
        restartUnits = [ unit ];
      };

      myAuthentik.oidcApps.tandoor = {
        blueprintsDir = ./tandoor-blueprints;
        appRestartUnit = [ unit ];
        clientCredsInAppEnv = false;
        displayName = "Tandoor";
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
      };

      services.tandoor-recipes = {
        enable = true;
        inherit address port;

        # Sorting by favorite 500s on 2.6.13 — the sort key is annotated
        # but missing from the ALLOWED_KEYS injection guard. kitshn (iOS)
        # sorts its recipe list that way, so it's every request. See the
        # patch header for the upstream issue and the drop condition.
        package = pkgs.tandoor-recipes.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./tandoor-favorite-sort.patch ];
        });

        extraConfig = {
          GUNICORN_CMD_ARGS = "--bind=${address}:${toString port} --workers 3 --threads 2";
          GUNICORN_MEDIA = "1";
          MEDIA_ROOT = mediaRoot;
          ALLOWED_HOSTS = tandoorHost;

          # Reuse the existing tandoor role/db over TCP; see header.
          DB_ENGINE = "django.db.backends.postgresql";
          POSTGRES_HOST = "127.0.0.1";
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
      };

      # The module has no environmentFile option; see header for why
      # stacking it here is sound.
      systemd.services.tandoor-recipes.serviceConfig.EnvironmentFile = [
        config.sops.templates."tandoor.env".path
      ];

      myAppState.tandoor = {
        inherit stateDir;
        user = "tandoor_recipes";
        group = "tandoor_recipes";
      };

      myCaddy.apps.tandoor = {
        host = tandoorHost;
        routeConfig = ''
          reverse_proxy ${address}:${toString port}
        '';
      };
    };
}
