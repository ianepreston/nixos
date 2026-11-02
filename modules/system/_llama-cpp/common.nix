{ config, lib, ... }:
let
  cfg = config.myLlamaCpp;
  # The KV-cache quantizations llama.cpp actually accepts for -ctk/-ctv.
  cacheType = lib.types.enum [
    "f32"
    "f16"
    "bf16"
    "q8_0"
    "q5_0"
    "q5_1"
    "q4_0"
    "q4_1"
    "iq4_nl"
  ];

  allAliases = lib.concatMap (m: m.aliases) (lib.attrValues cfg.models);
in
{
  options.myLlamaCpp = {
    enable = lib.mkEnableOption "llama.cpp's on-demand model router";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        TCP port llama-server listens on. Also the port a Caddy route
        (local or cross-host) reverse-proxies to.

        Only the router binds this. Each loaded model gets its own
        child process on an ephemeral loopback port, which the router
        proxies to — those are not reachable from off-host, and they
        inherit `LLAMA_API_KEY` from the router's environment, so they
        are not an unauthenticated side door either.
      '';
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Bind address. Leave at loopback when a reverse proxy on the
        same host fronts the service. NixOS may widen it in combination
        with `allowedClients`, which decides who can reach the port.
        Darwin requires 127.0.0.1.
      '';
    };

    models = lib.mkOption {
      description = ''
        The models this host's router serves, keyed by the
        `<hf-repo>:<quant-tag>` string llama-server uses as both the
        `-hf` argument and the model's routing name.

        The key has to be exactly that string. The router derives the
        same name independently when it scans `LLAMA_CACHE`, and the
        two are merged by name — a key in any other shape produces a
        *second*, unconfigured entry alongside the cached one, and a
        client can reach it with llama.cpp's defaults instead of the
        sizing below.
      '';
      example = lib.literalExpression ''
        {
          "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M" = {
            aliases = [ "vision" ];
            ctxSize = 98304;
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            aliases = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "vision" ];
              description = ''
                Extra names this model answers to, in addition to its
                `<repo>:<tag>` key. Point clients at a role name here
                rather than the GGUF's name, so swapping the model
                underneath is a change to this file and not to every
                client. Must not collide with another model's key or
                aliases; llama-server refuses to start if they do.
              '';
            };

            ctxSize = lib.mkOption {
              type = lib.types.ints.positive;
              example = 32768;
              description = ''
                Context window in tokens (`-c`). Sized per model *and*
                per host: the KV cache for this context has to fit in
                whatever VRAM the model weights leave behind. Only one
                model is resident at a time (`--models-max 1`), so
                each is budgeted against the whole card, not a share.
              '';
            };

            cacheTypeK = lib.mkOption {
              type = cacheType;
              default = "f16";
              description = ''
                KV cache data type for keys (`-ctk`). Quantizing the
                cache is what buys context on a card the model has
                already mostly filled: `q8_0` halves the per-token KV
                cost for a few percent of generation throughput and a
                quality hit far smaller than quantizing weights
                further. Set both this and `cacheTypeV` — llama.cpp
                takes them separately and there is no reason to split
                them here.
              '';
            };

            cacheTypeV = lib.mkOption {
              type = cacheType;
              default = "f16";
              description = "KV cache data type for values (`-ctv`). See `cacheTypeK`.";
            };

            nGpuLayers = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 99;
              description = ''
                Layers offloaded to the GPU (`-ngl`). The default is
                the "everything" idiom — any value at or above the
                model's layer count offloads the whole model. Lower it
                only to deliberately keep layers on the CPU because
                the model doesn't fit.
              '';
            };

            nCpuMoeLayers = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 0;
              example = 40;
              description = ''
                For a mixture-of-experts model, how many of its layers
                keep their *expert* weights in system RAM (`-ncmoe`).
                Zero (the default) is "none", which is the only
                correct value for a dense model — it has no experts to
                move.

                This is a different lever from `nGpuLayers` and they
                compose: `-ngl 99 -ncmoe N` keeps attention and the KV
                cache for every layer on the GPU while the first N
                layers' expert FFN weights live in host RAM. That
                split is what makes a model whose weights exceed the
                card usable at all — an MoE activates a small
                fraction of its parameters per token, so the traffic
                over PCIe is far smaller than the resident size
                suggests, whereas moving whole layers with `-ngl`
                would drag the KV cache off the card with them.

                Cost is paid twice: throughput drops monotonically as
                N rises, and the offloaded weights occupy host RAM for
                as long as the model is loaded (~14 GB for
                Qwen3-Coder-30B at N=40 — see modules/hosts/terra.nix).
                That second cost is gentler than it looks — the
                experts are an mmap of the GGUF, so almost all of it
                is reclaimable page cache rather than committed
                memory — but the throughput above assumes it stays
                resident, and `sleepIdleSeconds` hands back VRAM, not
                this.
              '';
            };
          };
        }
      );
    };

    sleepIdleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      example = 600;
      description = ''
        Idle seconds after which a loaded model sleeps and hands its
        VRAM back (`--sleep-idle-seconds`). The point on a machine
        that is also used for something else (a workstation that
        games, a server that transcodes); the next request pays a
        reload.

        Passed to the router, which is inherited by every child, so it
        is uniform across a host's models by construction. It is a
        separate mechanism from `--models-max` eviction and both
        apply: a sleeping model still counts as loaded, so asking for
        a different model unloads the sleeper outright rather than
        waiting for it to wake.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--flash-attn"
        "on"
      ];
      description = ''
        Additional llama-server flags appended after the ones this
        module builds.

        Service-wide only. llama.cpp merges the router's argv into
        every child at the *highest* precedence, above both the
        per-model preset section and the preset's global section — so
        a model-shaped flag here (`-c`, `-ngl`, `-ctk`) silently wins
        over every `models.<name>` entry. Put those in `models`.
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.models != { };
        message = ''
          myLlamaCpp.models is empty. The router would still serve
          whatever GGUFs happen to be in LLAMA_CACHE, with llama.cpp's
          default context and no GPU offload, so an empty set is a
          silently-degraded service rather than a disabled one.
        '';
      }
      {
        # `-hf repo` without a tag is legal and resolves to a default
        # quant, but then the router's cache scan names the model
        # `repo:<that quant>` while the preset section is still named
        # `repo` — two entries, only one of them sized. Requiring the
        # tag up front is the cheap way to keep the two in lockstep.
        assertion = lib.all (n: lib.match "[^/:]+/[^/:]+:[^/:]+" n != null) (lib.attrNames cfg.models);
        message = ''
          myLlamaCpp.models: every name must be `<owner>/<repo>:<QUANT>`,
          exactly the string llama-server takes as `-hf` and derives
          again when it scans the cache. Offending:
          ${
            lib.concatStringsSep ", " (
              lib.filter (n: lib.match "[^/:]+/[^/:]+:[^/:]+" n == null) (lib.attrNames cfg.models)
            )
          }.
        '';
      }
      {
        assertion = lib.length (lib.unique allAliases) == lib.length allAliases;
        message = "myLlamaCpp.models: duplicate alias in ${lib.concatStringsSep ", " allAliases}.";
      }
      {
        assertion = lib.intersectLists allAliases (lib.attrNames cfg.models) == [ ];
        message = ''
          myLlamaCpp.models: an alias collides with a model's own
          name (${lib.concatStringsSep ", " (lib.intersectLists allAliases (lib.attrNames cfg.models))}).
        '';
      }
    ];
  };
}
