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
# PAPERLESS_AI_ENABLED off. Both halves of that subsystem are now paid
# for: chat and classification run against terra's llama-server
# (#527), and embeddings run in-process on the bundled CPU torch
# (#557) — see the AI block in `settings` below.
#
# The embedding half puts a vector store on disk at
# `<dataDir>/llm_index/llmindex.db` (SQLite + sqlite-vec, WAL) and a
# downloaded model cache at `<dataDir>/hf_cache`. Both land inside the
# preserved stateDir, so impermanence is handled — but neither is
# quiesced for restic and the nightly rebuild currently fires at 02:10,
# inside the backup window. That is #558.
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

      # llama-server's bearer token, for PAPERLESS_AI_LLM_API_KEY below.
      # shared.yaml rather than the host file because it is the fleet-wide
      # key `myLlamaCpp` enforces wherever it runs (see
      # modules/system/llama-cpp.nix). Both servers already declare this
      # same secret through modules/apps/llm-caddy-auth.nix; the
      # definitions are identical, so the module system merges them.
      sops.secrets."llama-cpp/api_key".sopsFile = "${inputs.nix-secrets}/sops/shared.yaml";

      myAuthentik.oidcApps.paperless-ngx = {
        blueprintsDir = ./paperless-ngx-blueprints;
        appRestartUnit = paperlessUnits;
        clientCredsInAppEnv = false;
        displayName = "Paperless-ngx";
        extraEnvLines = ''
          PAPERLESS_DBPASS=${config.sops.placeholder."paperless-ngx/db_password"}
          PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless-ngx/secret_key"}
          PAPERLESS_AI_LLM_API_KEY=${config.sops.placeholder."llama-cpp/api_key"}
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

          # AI-assisted classification (#527): correspondent / type /
          # tags / title suggestions from terra's llama-server. The
          # subsystem is text-only — the classifier reads `doc.content`,
          # which paperless has already produced with tesseract/ocrmypdf
          # — so nothing here wants terra's `vision` alias.
          #
          # Suggestions are pull-only: the document detail page's
          # suggestions call, or an AI workflow action (a DB object
          # nobody has created). Consumption never touches the LLM, so
          # terra being powered off degrades this to a 503 on that one
          # endpoint rather than breaking intake.
          #
          # Careful: `AIConfig.__post_init__` is `app_config.X or
          # settings.X` for every field below, so a non-empty value saved
          # on the UI's AI configuration page silently wins over what is
          # declared here — the same trap as Home Assistant's `.storage`.
          # Configure this from the module, never from the web UI.
          PAPERLESS_AI_ENABLED = true;

          # OpenAILike: plain /v1/chat/completions with a bearer token.
          # That token is PAPERLESS_AI_LLM_API_KEY, set in extraEnvLines
          # above — `settings` renders into /nix/store, so it can't hold
          # a secret. The classifier asks for a tool call
          # (`chat_with_tools(tool_required=True)`), which llama-server
          # serves because `--jinja` defaults on — see the tool-calling
          # note in modules/programs/vibes.nix.
          PAPERLESS_AI_LLM_BACKEND = "openai-like";

          # terra's llama-server directly over the LAN, not the
          # llm-terra HTTPS route: every call goes through
          # `PinnedHostHTTPTransport`, which resolves the endpoint once
          # and pins the address, so this has to be the name that
          # resolves to terra's LAN IP from a server (a tailnet name
          # would not). terra's firewall already allows both servers.
          # amos1 serves a `text` alias of its own on :8091, but terra's
          # 5080 carries the better model, so both servers point here.
          # Paperless's SSRF guard
          # (PAPERLESS_AI_LLM_ALLOW_INTERNAL_ENDPOINTS) already defaults
          # to allowing private addresses, so a private endpoint needs no
          # opt-in.
          PAPERLESS_AI_LLM_ENDPOINT = "http://terra.ipreston.net:8080/v1";

          # The router alias, verbatim — not the GGUF name. That is the
          # whole point of the aliases in modules/system/llama-cpp.nix:
          # swapping the model underneath stays a change to
          # modules/hosts/terra.nix.
          PAPERLESS_AI_LLM_MODEL = "text";

          # Default is 8192; terra's `text` serves 131072. Safe to match
          # the served context exactly: llama-index's PromptHelper
          # reserves 512 tokens for the reply before it truncates
          # document content to fit.
          PAPERLESS_AI_LLM_CONTEXT_SIZE = 131072;

          # Embeddings, and with them the RAG index (#557). There is no
          # separate index switch: `AIConfig.llm_index_enabled` is just
          # `ai_enabled and llm_embedding_backend`, so naming a backend
          # here is what creates the vector store, schedules the nightly
          # `llmindex_index` rebuild, keeps the index in step with
          # consume/edit/delete, and lets `ai_classifier.py` take its
          # RAG path (`retrieve_similar_nodes` + taxonomy weighting)
          # instead of `build_prompt_without_rag`. Chat has no non-RAG
          # fallback at all.
          #
          # huggingface rather than pointing the `openai-like` embedding
          # backend at terra: llama-server runs with `--models-max 1`, so
          # one suggestion — retrieve with an embedding model, then
          # classify with `text` — would evict and reload a model on
          # every request. Serving embeddings from terra is llama-cpp
          # module work (an `--embeddings` child, a re-budgeted
          # `--models-max`), not paperless work.
          PAPERLESS_AI_LLM_EMBEDDING_BACKEND = "huggingface";

          # Upstream's own default, pinned explicitly. The store is a
          # `vec0` virtual table whose vectors are fixed at the model's
          # dimension, so a changed default on some future package bump
          # would invalidate every embedding already written; naming the
          # model makes that a diff rather than a surprise.
          #
          # It runs on the CPU: the torch in the paperless closure is
          # nixpkgs' default `cudaSupport = false` build, and MiniLM at
          # document-ingest rates does not need a GPU — making it one
          # would mean overriding paperless's whole python set to
          # torchWithCuda and then competing with Jellyfin transcodes for
          # amos1's 3070. Measure before revisiting.
          #
          # First use downloads ~90 MB into the dataDir's `hf_cache`,
          # so a cold rebuild needs the network before suggestions work.
          PAPERLESS_AI_LLM_EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2";
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
