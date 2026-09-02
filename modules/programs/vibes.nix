# Vibes - HM Simple Aspect
# Terminal coding agents: Claude Code and pi.
#
# gemini-cli used to be here and is gone: Google deprecated it, so it was
# dead weight on every workstation. pi (earendil-works/pi) replaces it.
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
# ## Local inference
#
# `~/.pi/agent/models.json` registers the fleet's own llama-server
# endpoints as OpenAI-compatible providers, so `pi` on a workstation can
# drive the models on amos1 and terra instead of a paid API. See
# modules/system/llama-cpp.nix for the servers and modules/apps/llm.nix /
# modules/apps/llm-terra.nix for the routes.
#
# Notes on the shape of that file, all verified against b9190 rather than
# assumed:
#
# **The model ids are the routers' aliases, not GGUF names.** Router mode
# requires an exact `model` field and rejects anything it doesn't know
# (#519), and `myLlamaCpp.models.<name>.aliases` exists precisely so
# clients can name a *role*. So `text`/`vision` here survive swapping the
# GGUF underneath on either host; the `<repo>:<tag>` names would not.
#
# **Tool calling needs no server-side change.** llama.cpp refuses a
# `tools` param without `--jinja` ("tools param requires --jinja flag"),
# but `--jinja` defaults to *enabled* in b9190, so `myLlamaCpp` gets it
# for free and a full pi agent loop (bash tool -> answer) works against
# terra as-is.
#
# **No `compat` overrides are needed.** pi's docs flag `developer`-role
# and `reasoning_effort` support as the usual breakage on OpenAI-compatible
# servers; llama-server accepts both (it ignores `reasoning_effort` for
# Qwen3 rather than 400ing), so the defaults are correct here.
#
# **Thinking is always on.** These are hybrid-thinking Qwen3 models and
# `reasoning_effort` does not gate them, so pi's `--thinking off` cannot
# suppress the `<think>` pass. The lever that does work is
# `chat_template_kwargs.enable_thinking = false`, which pi can send via a
# model's `samplingParams` (merged verbatim into the request body). Left
# unset deliberately — reasoning is worth its tokens for agentic work —
# but that's where to reach if a small-context model is burning its
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
# expected, not a fault; pick the `amos1` provider in `/model` instead.
#
# **Local inference is skipped where sops isn't.** penguin is a standalone
# home-manager config (WSL) that imports neither half of
# modules/system/sops.nix, so `sops.*` is not a declarable option there —
# and a definition at an undeclared path is an eval error whatever its
# value, so `lib.mkIf` does not help. The whole block therefore lives
# behind `imports`, gated on specialArgs: those are settled before the
# module fixpoint, whereas a condition read off `options` makes the
# module's own shape depend on the option tree and recurses. penguin
# gets a working `pi` for hosted providers and no dead provider entries.
#
# **settings.json is deliberately not managed.** pi writes it itself
# (`/model` Ctrl+S, `/settings`, `pi install`), so a read-only store
# symlink would break those. It doesn't need seeding: with no
# `defaultProvider`, pi picks the first model it has credentials for,
# which is one of ours. models.json *is* safe to symlink — pi only ever
# reads it.
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
      # single source of truth for both the secret's `path` and the `!cat`
      # baked into the store-resident models.json below, and holding it in
      # a plain string keeps the models.json derivation independent of an
      # option that doesn't exist on every host this module lands on.
      llamaKeyPath = "${config.xdg.configHome}/sops-nix/secrets/llama-cpp-api-key";

      # `!cmd` is pi's shell-command form for a credential; it runs per
      # request, so the key is never written into /nix/store (models.json
      # is world-readable there) and rotation is picked up without a
      # rebuild.
      llamaProvider = hostSuffix: models: {
        baseUrl = "https://llm${hostSuffix}.amos.ipreston.net/v1";
        api = "openai-completions";
        apiKey = "!cat ${llamaKeyPath}";
        inherit models;
      };

      textModel = name: ctxSize: maxTokens: {
        id = "text";
        inherit name;
        reasoning = true;
        contextWindow = ctxSize;
        inherit maxTokens;
      };

      visionModel = name: ctxSize: maxTokens: {
        id = "vision";
        inherit name;
        reasoning = true;
        input = [
          "text"
          "image"
        ];
        contextWindow = ctxSize;
        inherit maxTokens;
      };

      # Context windows mirror `myLlamaCpp.models.<name>.ctxSize` on each
      # host and have to be edited in lockstep with them; they are sized
      # against the card's VRAM, not the model's training limit, and the
      # reasoning for each number lives in modules/hosts/{amos1,terra}.nix.
      # maxTokens is a per-request output cap, kept well under the window so
      # a long generation can't crowd out the prompt on the 16k model.
      piModels = (pkgs.formats.json { }).generate "pi-models.json" {
        providers = {
          # Always-on, but the small pair: sized around leaving Jellyfin
          # enough VRAM to transcode on the same RTX 3070 (#517).
          amos1 = llamaProvider "" [
            (textModel "Qwen3-8B (amos1)" 16384 4096)
            (visionModel "Qwen3-VL-4B (amos1)" 32768 4096)
          ];
          # The RTX 5080 desktop: the one worth pointing an agent at, and
          # only up when terra is.
          terra = llamaProvider "-terra" [
            (textModel "Qwen3-14B (terra)" 40960 8192)
            (visionModel "Qwen3-VL-8B (terra)" 98304 8192)
          ];
        };
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
      };
    in
    {
      imports = lib.optional hasSops localInference;

      home.packages = builtins.attrValues {
        inherit (pkgsUnstable)
          claude-code
          pi-coding-agent
          worktrunk
          ;
      };

      home.file.".claude/settings.json".source = settings;
    };
}
