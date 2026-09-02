# Vibes - HM Simple Aspect
# Terminal coding agents: Claude Code, pi, and opencode.
#
# gemini-cli used to be here and is gone: Google deprecated it, so it was
# dead weight on every workstation. pi (earendil-works/pi) and opencode
# (sst/opencode) replace it.
#
# ## Why nixpkgs' `pi-coding-agent` and not lukasl-dev/pi.nix
#
# pi.nix is the only Nix packaging upstream points at, but nixpkgs has
# `pi-coding-agent` and unstable tracks it closely — at the time of
# writing unstable and pi.nix's `VERSION.json` pin the *same* upstream
# rev (0.84.4), and the nixpkgs build is served by cache.nixos.org while
# pi.nix's is served by pi.cachix.org (a substituter we'd have to trust
# or build around). Stable lags harder (0.75.4), which is why this pulls
# from `pkgsUnstable` alongside claude-code rather than plain `pkgs`.
#
# The only thing pi.nix offers that nixpkgs doesn't is its jail.nix
# bubblewrap wrapper; its other options (rules, skills, themes, settings,
# models) are thin wrappers over writing files into the agent dir, which
# is what this module already does for Claude Code. Taking it would cost
# three transitive flake inputs (its own nixpkgs pin at unstable, bun2nix,
# jail.nix) and a second update cadence. Revisit if the sandbox becomes
# the point.
#
# opencode comes from `pkgsUnstable` for the same lag reason (1.18.25
# against stable's 1.15.10). It needs no equivalent decision — there is no
# competing community flake, and nixpkgs' wrapper already sets
# `OPENCODE_DISABLE_AUTOUPDATE=true`, which is the one thing that would
# otherwise fight a store-managed install.
#
# ## Local inference
#
# Both agents are pointed at the fleet's own llama-servers, so an agent
# loop runs on amos1/terra instead of a paid API: `~/.pi/agent/models.json`
# for pi, `~/.config/opencode/opencode.json` for opencode. `llamaHosts`
# below is the single description both are rendered from. See
# modules/system/llama-cpp.nix for the servers and modules/apps/llm.nix /
# modules/apps/llm-terra.nix for the routes.
#
# Notes on the shape of those files, all verified against b9190 and a real
# agent loop on each host rather than assumed:
#
# **The model ids are the routers' aliases, not GGUF names.** Router mode
# requires an exact `model` field and rejects anything it doesn't know
# (#519), and `myLlamaCpp.models.<name>.aliases` exists precisely so
# clients can name a *role*. So `text`/`code`/`text-qwen`/`vision` here
# survive swapping the GGUF underneath on either host; the `<repo>:<tag>`
# names would not. The role set is per-host and is whatever that host's
# `myLlamaCpp.models` aliases add up to — amos1's 8 GB card carries only
# `text` and `vision`, terra all four — so these two attrsets have to be
# edited in lockstep with modules/hosts/{amos1,terra}.nix.
#
# **Tool calling needs no server-side change.** llama.cpp refuses a
# `tools` param without `--jinja` ("tools param requires --jinja flag"),
# but `--jinja` defaults to *enabled* in b9190, so `myLlamaCpp` gets it
# for free and both agents complete a bash-tool -> answer loop against
# either host as deployed.
#
# **No OpenAI-compat shims are needed.** pi's docs flag `developer`-role
# and `reasoning_effort` support as the usual breakage on
# OpenAI-compatible servers; llama-server accepts both (it ignores
# `reasoning_effort` for Qwen3 rather than 400ing), so pi's `compat`
# escape hatches stay unset and opencode's stock
# `@ai-sdk/openai-compatible` needs no options beyond a URL and a key.
#
# **opencode's ai-sdk provider is bundled, not fetched.** Naming an `npm`
# package in a provider block normally implies a runtime install; this one
# ships inside the binary, verified by the absence of any `node_modules`
# under the data dir after a completed run. So the config works on a host
# that has never had network access to the npm registry.
#
# **Thinking is always on, and the lever differs per model.** The Qwen3
# models are hybrid-thinking and `reasoning_effort` does not gate them, so
# pi's `--thinking off` cannot suppress the `<think>` pass; what does work
# is `chat_template_kwargs.enable_thinking = false`, which pi can send via
# a model's `samplingParams` (merged verbatim into the request body) and
# opencode via a model's `options`. gpt-oss is the exception — it reasons
# through the harmony format, where `reasoning_effort` is a real knob
# (low/medium/high, default medium) rather than an ignored field. Both are
# left unset deliberately: reasoning is worth its tokens for agentic work.
# Reach for the matching one if a small-context model is burning its
# window on preamble.
#
# **Both endpoints go through caddy, including on terra itself.** terra
# runs the llama-server this points at, so its own requests loop out to
# amos1's caddy and back over the LAN. That's accepted in exchange for one
# identical file on every host: the alternative is a hostname conditional
# in here for the sake of one hop on a wired segment. The `/v1/*` routes
# bypass authentik when an `Authorization` header is present and are gated
# by llama-server's own key instead, which is what makes this reachable
# without a browser session — see the header of modules/apps/llm-terra.nix.
#
# The `llm-terra` route 502s whenever terra is powered off. That is
# expected, not a fault; pick an `amos1` model instead.
#
# **Local inference is skipped where sops isn't.** penguin is a standalone
# home-manager config (WSL) that imports neither half of
# modules/system/sops.nix, so `sops.*` is not a declarable option there —
# and a definition at an undeclared path is an eval error whatever its
# value, so `lib.mkIf` does not help. The whole block therefore lives
# behind `imports`, gated on specialArgs: those are settled before the
# module fixpoint, whereas a condition read off `options` makes the
# module's own shape depend on the option tree and recurses. penguin
# gets working agents for hosted providers and no dead provider entries.
#
# ## What is and isn't managed
#
# pi's `settings.json` is deliberately *not* managed: pi writes it itself
# (`/model` Ctrl+S, `/settings`, `pi install`), so a read-only store
# symlink would break those. It needs no seeding either — with no
# `defaultProvider`, pi picks the first model it has credentials for,
# which is one of ours. `models.json` is safe to symlink because pi only
# ever reads it.
#
# opencode has no such split: providers and every other setting share one
# `opencode.json`, so managing the providers means managing the file. The
# cost is that `opencode plugin --global` (which rewrites it) fails
# against a store symlink — declare plugins here instead. Project-local
# `opencode.json` still layers on top, and `opencode providers` writes
# credentials to a separate `auth.json`, so neither is affected.
#
# Neither agent gets a default model pinned. Both would then start on a
# local model even when a hosted provider is authenticated, which is the
# wrong default for the machines this lands on.
_: {
  flake.modules.homeManager.vibes =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      inputs,
      ...
    }@args:
    let
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };

      statusLine = pkgs.writeShellApplication {
        name = "claude-statusline";
        runtimeInputs = with pkgs; [
          jq
          git
          coreutils
        ];
        text = ''
          input=$(cat)
          model=$(jq -r '.model.display_name' <<<"$input")
          cwd=$(jq -r '.workspace.current_dir' <<<"$input")
          cost=$(jq -r '.cost.total_cost_usd // 0' <<<"$input")

          # context_window.* is populated by Claude Code from the most recent
          # API response, so the limit tracks the active model (200k vs 1M).
          # current_usage is null before the first API call and after /compact.
          pct=$(jq -r '.context_window.used_percentage // 0' <<<"$input" | cut -d. -f1)
          limit=$(jq -r '.context_window.context_window_size // 200000' <<<"$input")
          tokens=$(jq -r '
            (.context_window.current_usage // {}) as $u
            | ($u.input_tokens // 0)
              + ($u.cache_read_input_tokens // 0)
              + ($u.cache_creation_input_tokens // 0)
          ' <<<"$input")

          branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
          dir=$(basename "$cwd")

          printf '%s | %s%s | ctx %d%% (%dk/%dk) | $%.2f' \
            "$model" "$dir" "''${branch:+ ($branch)}" \
            "$pct" "$(( tokens / 1000 ))" "$(( limit / 1000 ))" "$cost"
        '';
      };

      settings = (pkgs.formats.json { }).generate "claude-settings.json" {
        model = "opus";
        effortLevel = "high";
        theme = "light";
        agentPushNotifEnabled = true;
        permissions.defaultMode = "auto";
        statusLine = {
          type = "command";
          command = "${statusLine}/bin/claude-statusline";
        };
      };

      # The home-manager half of modules/system/sops.nix is pulled into
      # `sharedModules` by the *NixOS* half of that same file, so it is
      # present on exactly the NixOS hosts. `osConfig` is the argument that
      # marks a system-driven home-manager, but it does not narrow far
      # enough on its own: nix-darwin's integration passes it too, and
      # darwin-base.nix wires sops at the system level only, leaving
      # `sharedModules` without it. Hence both halves of the test. See the
      # header for why this reads specialArgs and not `options ? sops`.
      hasSops = (args ? osConfig) && !hostSpec.isDarwin;

      # Fixed rather than read back off `config.sops.secrets`: it is the
      # single source of truth for both the secret's `path` and the
      # credential references baked into the store-resident configs below,
      # and holding it in a plain string keeps those derivations
      # independent of an option that doesn't exist on every host this
      # module lands on.
      llamaKeyPath = "${config.xdg.configHome}/sops-nix/secrets/llama-cpp-api-key";

      # One description of what the fleet serves, rendered below into each
      # agent's own config dialect. The two disagree about nearly every
      # field name and nest them differently, but not about the facts, so
      # the facts are stated once here.
      #
      # `ctxSize` mirrors `myLlamaCpp.models.<name>.ctxSize` on each host
      # and has to be edited in lockstep with it: the numbers are sized
      # against the card's VRAM, not the model's training limit, and the
      # reasoning for each lives in modules/hosts/{amos1,terra}.nix.
      # `maxTokens` is a per-request output cap, kept well under the window
      # so a long generation can't crowd out the prompt on the 16k model.
      #
      # The attribute names under `models` are the routers' aliases — see
      # the header for why that matters.
      llamaHosts = {
        # Always-on, but the small pair: sized around leaving Jellyfin
        # enough VRAM to transcode on the same RTX 3070 (#517).
        amos1 = {
          routeSuffix = "";
          models = {
            text = {
              label = "Qwen3-8B";
              ctxSize = 16384;
              maxTokens = 4096;
              vision = false;
            };
            vision = {
              label = "Qwen3-VL-4B";
              ctxSize = 32768;
              maxTokens = 4096;
              vision = true;
            };
          };
        };
        # The RTX 5080 desktop: the one worth pointing an agent at, and
        # only up when terra is.
        #
        # Four roles rather than amos1's two. `text` and `code` are both
        # here on purpose and are the point of #518: gpt-oss-20b wins
        # every measured axis, but throughput is not code quality, and
        # only real sessions against both settle which writes better
        # patches. `text-qwen` is the dense 14B that `text` displaced,
        # kept selectable for the same reason.
        terra = {
          routeSuffix = "-terra";
          models = {
            text = {
              label = "gpt-oss-20b";
              ctxSize = 131072;
              maxTokens = 16384;
              vision = false;
            };
            code = {
              label = "Qwen3-Coder-30B";
              ctxSize = 131072;
              maxTokens = 16384;
              vision = false;
            };
            text-qwen = {
              label = "Qwen3-14B";
              ctxSize = 40960;
              maxTokens = 8192;
              vision = false;
            };
            vision = {
              label = "Qwen3-VL-8B";
              ctxSize = 98304;
              maxTokens = 8192;
              vision = true;
            };
          };
        };
      };

      llamaBaseUrl = host: "https://llm${host.routeSuffix}.amos.ipreston.net/v1";

      # `!cmd` is pi's shell-command form for a credential; it runs per
      # request, so the key is never written into /nix/store (this file is
      # world-readable there) and rotation is picked up without a rebuild.
      piModels = (pkgs.formats.json { }).generate "pi-models.json" {
        providers = lib.mapAttrs (_hostName: host: {
          baseUrl = llamaBaseUrl host;
          api = "openai-completions";
          apiKey = "!cat ${llamaKeyPath}";
          models = lib.mapAttrsToList (
            role: model:
            {
              id = role;
              name = model.label;
              reasoning = true;
              contextWindow = model.ctxSize;
              inherit (model) maxTokens;
            }
            # pi defaults `input` to ["text"], so this is only ever an
            # addition.
            // lib.optionalAttrs model.vision {
              input = [
                "text"
                "image"
              ];
            }
          ) host.models;
        }) llamaHosts;
      };

      # `{file:...}` is opencode's equivalent of pi's `!cat`, resolved when
      # the config is read, and keeps the key out of the store for the same
      # reason.
      opencodeConfig = (pkgs.formats.json { }).generate "opencode.json" {
        "$schema" = "https://opencode.ai/config.json";
        provider = lib.mapAttrs (hostName: host: {
          npm = "@ai-sdk/openai-compatible";
          name = "llama.cpp (${hostName})";
          options = {
            baseURL = llamaBaseUrl host;
            apiKey = "{file:${llamaKeyPath}}";
          };
          models = lib.mapAttrs (_role: model: {
            name = model.label;
            tool_call = true;
            reasoning = true;
            attachment = model.vision;
            modalities.input = [ "text" ] ++ lib.optional model.vision "image";
            limit = {
              context = model.ctxSize;
              output = model.maxTokens;
            };
            # Stated rather than omitted: opencode reports per-session
            # spend, and these cost nothing to run.
            cost = {
              input = 0;
              output = 0;
            };
          }) host.models;
        }) llamaHosts;
      };

      # shared.yaml because that is where `myLlamaCpp` reads the same key
      # from — one token covers both hosts' llama-servers and caddy's
      # upstream injection (see modules/apps/llm-caddy-auth.nix). Decrypted
      # with the operator age key that modules/system/sops.nix bootstraps
      # into ~/.config/sops/age/keys.txt, not a host key.
      localInference = {
        sops.secrets."llama-cpp/api_key" = {
          sopsFile = "${inputs.nix-secrets}/sops/shared.yaml";
          path = llamaKeyPath;
        };

        home.file.".pi/agent/models.json".source = piModels;
        xdg.configFile."opencode/opencode.json".source = opencodeConfig;
      };
    in
    {
      imports = lib.optional hasSops localInference;

      home.packages = builtins.attrValues {
        inherit (pkgsUnstable)
          claude-code
          opencode
          pi-coding-agent
          worktrunk
          ;
      };

      home.file.".claude/settings.json".source = settings;
    };
}
