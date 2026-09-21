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
#     whitenoise serves $out/lib/tandoor-recipes/staticfiles. Serving
#     /media from caddy instead is not an option: the unit's UMask=0066
#     means uploads land 0600 tandoor_recipes, which only the app itself
#     can read.
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
# ## AI features, pointed at the fleet's own llama-server (#525)
#
# Tandoor's AI paths — recipe import from an image or PDF, sorting steps
# and assigning ingredients to them, extracting food/recipe properties —
# all go through LiteLLM, so any OpenAI-compatible endpoint serves them.
# The provider itself is a **database row, not config**: `AiProvider`
# (name, model name, API key, base URL) is created per space in the UI,
# or globally by a superuser. None of that is in the flake and a rebuild
# will not reproduce it. It lives in postgres, so it rides the existing
# `myPostgresApp` backup path — but it is UI state, the same shape as
# Home Assistant's `.storage`, and that is the price of the feature.
#
# The one piece that *is* declarative is the piece without which none of
# it runs. `AI_ALLOWED_URLS` defaults to empty, and any `AiProvider.url`
# absent from it raises before the request is made (cookbook/views/api.py
# 1278, 2089, 2816, 2930). That is an SSRF guard — the URL is
# user-supplied — so opting in is deliberate rather than a tuning knob.
#
# The value is derived from this host's own llama-server front doors
# rather than spelled out, so hpp-1 (terra's route only) and amos1 (its
# own, plus terra's) each allow exactly what they can reach and a third
# route needs no edit here. The filter is
# `upstreamBearerEnvVar == "LLAMA_API_KEY"`, which is precisely what
# makes a forward-auth route a llama-server one — see
# modules/apps/llm-caddy-auth.nix. A host with no such route (tests-server)
# gets an empty string, which is upstream's default: AI stays off.
#
# Membership is an **exact string match** against whatever was typed into
# the UI field, so both the slashed and unslashed spelling of each base
# URL are listed. LiteLLM normalizes the two into the same request, but a
# provider row that disagrees with this list by one character fails as a
# 500 with a traceback rather than as anything that reads like config.
#
# No caddy or gunicorn change is needed for the synchronous AI call, which
# upstream's docs warn about. Caddy sets neither a response timeout nor a
# body limit here, and `--threads 2` in GUNICORN_CMD_ARGS already puts
# gunicorn on the `gthread` worker (config.py:107 promotes `sync` when
# threads > 1), whose accept loop keeps notifying the arbiter from outside
# the request threads — so the 30 s `timeout` is an idle check, not a
# request deadline. A single sync worker would have been one.
#
# Those threads do cost something, in one place worth knowing about.
# Tandoor installs its usage-logging callback by assigning the *global*
# `litellm.callbacks` per request, so two AI calls overlapping inside one
# worker can have the second's handler in place before the first returns,
# and the first call's `AiLog` row is then attributed to the other
# request's space, user and function. That is an upstream defect, it costs
# accuracy in a usage log rather than correctness of the import, and the
# fix is not ours to make — but do not read a surprising AI Log row as
# evidence of something wrong on this side.
#
# Two things the operator still has to get right in the UI, neither of
# them expressible here:
#
#   * **Model name needs LiteLLM's provider prefix** — `openai/vision`,
#     not `vision`. That is what routes a custom `api_base` through
#     LiteLLM's OpenAI-compatible path; it strips the prefix again on the
#     wire, so llama.cpp's router sees the bare alias it expects. Image
#     import needs the vision model and a text-only one will fail it;
#     `openai/text` is the pick for the other three features.
#
#     **PDF import cannot work against llama-server at all**, whatever
#     model is chosen. Tandoor does not rasterize: when PIL fails to open
#     the upload it sends the raw bytes as an `image_url` content part
#     with a `data:application/pdf;base64,` URI, and llama.cpp's mtmd
#     path accepts `data:image/` only. Measured on hpp-1, that surfaces
#     as `InternalServerError: Invalid url format: data:application/pdf`
#     — an unhandled exception, so the operator gets a 500 rather than
#     the message Tandoor shows for a provider-side `BadRequestError`.
#     Feed it a photo or a screenshot of the page instead.
#   * **"Log credit cost" off.** Tandoor meters each call against a
#     monthly credit ceiling, and the cost it meters comes from LiteLLM's
#     estimate for the model — which is meaningless for a local one it has
#     no price list for. `log_credit_cost` gates the whole computation
#     (cookbook/helper/ai_helper.py:60), so turning it off takes the
#     ceiling with it and the space's `ai_credits_monthly` never binds.
#     That is why none of the `SPACE_AI_CREDITS_*` env vars are set below.
#     Usage still shows up in the AI Log either way, at zero cost.
#
# `llm.<serverDomain>` is the always-on endpoint; `llm-terra.<serverDomain>`
# is the bigger model when that desktop happens to be up, and 502s when it
# is not. Both are allowed, and which one a provider row names is a UI
# choice, not a rebuild.
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
      lib,
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

      # Every llama-server front door this host carries, in both
      # spellings Tandoor might be handed. See the header.
      llmBaseUrls =
        lib.concatMap
          (host: [
            "https://${host}/v1"
            "https://${host}/v1/"
          ])
          (
            lib.mapAttrsToList (_: app: app.host) (
              lib.filterAttrs (
                _: app: app.upstreamBearerEnvVar == "LLAMA_API_KEY"
              ) config.myAuthentik.forwardAuthApps
            )
          );
    in
    {
      myObservability.monitoredSystemdUnits = [ "tandoor-recipes" ];

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

          # AI provider allowlist; empty disables the feature entirely.
          # Derived rather than written out, and exact-match — see the header.
          AI_ALLOWED_URLS = lib.concatStringsSep "," llmBaseUrls;
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
