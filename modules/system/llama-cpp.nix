# llama.cpp - Simple Aspect
# Runs llama.cpp's `llama-server` (OpenAI-compatible HTTP API) on a host
# with an NVIDIA GPU. Thin wrapper over nixpkgs' `services.llama-cpp`
# that adds this flake's cross-cutting concerns: a CUDA build scoped to
# the host's GPU, a sops-fed API key, and a source-scoped firewall hole
# for hosts that serve other machines on the LAN.
#
# Deliberately daemon-only. The HTTPS/authentik front door is *not* part
# of this module: on a server the route is a `myAuthentik.forwardAuthApps`
# entry next to the rest of the app fleet, and terra (a workstation, no
# caddy/authentik/tailscale) is fronted by a route on amos1 instead. See
# `modules/hosts/amos1.nix` for that side.
#
# ## Router mode (#519)
#
# llama-server runs as a **router**: the main process holds no model and
# instead spawns one child llama-server per model on a loopback ephemeral
# port, routing each request by the `"model"` field in the body (or the
# `?model=` query param on GET). That is what lets a host serve more than
# one model without a config edit and a rebuild — which matters because
# there is no single best model per host (see #517/#518/#524: vision and
# generalist capability do not fit in one GGUF that fits these cards).
#
# Three things follow from the mechanism and are worth knowing before
# editing this file:
#
# **The `model` field is mandatory and exact.** A request with no `model`
# gets `400 model name is missing from the request`; an unrecognised name
# gets `400 model 'x' not found`. Single-model mode ignored the field
# entirely, so any client that sent a placeholder ("gpt-3.5-turbo") stops
# working. `aliases` exists for this: it registers extra router-level
# names for a model, so a client can be pointed at a stable role name
# ("vision") that survives swapping the GGUF underneath it.
#
# **The cache is a model source, not just storage.** The router always
# enumerates `LLAMA_CACHE` in addition to the preset, deriving a name of
# `<repo>:<TAG>` per cached GGUF. So a leftover model from a previous
# config still shows up in `/v1/models` and is still routable — with only
# llama.cpp defaults applied, since no preset section names it. Keeping
# the cache pruned (`task llm:models:prune`) is therefore a correctness
# concern here, not just a disk one.
#
# A pruned cache is not sufficient, though, because that `<TAG>` is
# derived from the *filename* rather than from whatever `-hf` asked for:
# `common_list_cached_models` takes `get_gguf_split_info(path).tag`, which
# is the last `[-.]([A-Za-z0-9_]+)` run in the name. For a quant whose tag
# carries a prefix the filename keeps but the derivation drops — unsloth's
# `UD-` dynamic quants are the case in the fleet — the scan invents a
# *second* name for a file the preset already names, and the two do not
# merge because they are not spelled the same. terra therefore serves
# `unsloth/…-GGUF:Q4_K_XL` alongside the configured `:UD-Q4_K_XL`, both
# resolving to the same 17 GB of weights, one of them with no `ctxSize`
# and no `nCpuMoeLayers`. Nothing configures this away: `load_from_cache`
# is unconditional and there is no flag to skip it. Treat an unaliased
# entry in `/v1/models` as suspect, check it against the cache listing
# (`task llm:models`) before assuming it is prunable garbage, and don't
# point a client at one.
#
# **Router CLI flags outrank the preset.** llama.cpp merges the router's
# own argv into every child's preset at *highest* precedence, so a `-c` on
# the router would silently override every model's `ctxSize`. Anything
# model-shaped must live in `models.<name>`; only genuinely service-wide
# flags belong in `extraFlags`.
#
# `--models-max` is pinned to 1 below rather than exposed as an option:
# on both hosts that run this, no two configured models fit in VRAM at
# once (terra ~56 GB of models against a 16.3 GB card, amos1 12.4 GB
# against 8.0 GB — see #524). This is deliberately swap-on-demand, not
# concurrent serving. Measured swap cost on terra's NVMe is 3-4 s, cold
# page cache included, so the trade is cheap.
#
# Swapping is not uniformly cheap across the set, though: a model with
# `nCpuMoeLayers` set also has to stream its offloaded expert weights
# back into host RAM, so terra's `code` is the slow one to bring up.
#
# ## Model files
#
# GGUFs are gigabytes and are not nix-store material, so they are *not*
# fetched by nix. Each `models.<name>` attribute name is the `<repo>:<tag>`
# llama-server resolves as `-hf`, and it downloads the weights itself into
# `LLAMA_CACHE`. That directory is overridden below from the upstream
# module's `/var/cache/llama-cpp` to the state directory, so
# `systemctl clean --what=cache llama-cpp` (or anything else that treats
# /var/cache as disposable) doesn't silently trigger a multi-GB re-download.
#
# Nothing loads at service start: a model is downloaded and loaded by the
# first request that names it. So the first request for an uncached model
# blocks for the whole download and will almost certainly time out at the
# client, though the download itself continues and a later retry is a
# cache hit. `task llm:models:fetch HOST=<host>` does that warm-up
# deliberately, with a timeout that expects it.
#
# A vision model's mmproj (the projector) needs no declaration: `-hf`
# resolves and downloads it per model, and it does not leak across models
# in the same router — verified at b9190, where a text-only model in the
# same preset reports `input_modalities: ["text"]` while the vision model
# reports `["text","image"]`.
#
# ## CUDA build
#
# `pkgs.llama-cpp` in this flake is a CPU build (nothing sets
# `config.cudaSupport`), so a separate nixpkgs instance is imported with
# CUDA on and `cudaCapabilities` pinned to the *one* architecture the host
# actually has. That pin matters: the nixpkgs default builds nine
# architectures (7.5 through 12.1), and the CUDA kernels dominate the
# build. Scoping to one cuts the compile by roughly that factor.
#
# CUDA is unfree and no binary cache serves it, so this always builds
# locally the first time. Budget for it — it is not a `nixos-rebuild`
# you want to start five minutes before you need the machine.
{ inputs, ... }:
{
  flake.modules.nixos.llama-cpp =
    {
      config,
      lib,
      pkgs,
      ...
    }:
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

      pkgsCuda = import inputs.nixpkgs {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = pkgs.config // {
          cudaSupport = true;
          inherit (cfg) cudaCapabilities;
        };
      };

      allAliases = lib.concatMap (m: m.aliases) (lib.attrValues cfg.models);
    in
    {
      options.myLlamaCpp = {
        enable = lib.mkEnableOption "llama.cpp's llama-server with a CUDA build";

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
            same host fronts the service; widen it only in combination
            with `allowedClients`, which is what actually decides who can
            reach the port.
          '';
        };

        allowedClients = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "192.168.10.11" ];
          description = ''
            Source addresses (iptables `-s` syntax — a bare IPv4 address
            or a CIDR) allowed to reach `port`. Empty (the default) opens
            nothing, which is correct for a loopback-only bind. Prefer
            listing the single reverse-proxy host over a whole subnet: the
            hop is plaintext HTTP and llama-server's own `--api-key` is
            the only thing in front of it.
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

        cudaCapabilities = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          example = [ "12.0" ];
          description = ''
            CUDA compute capabilities to compile kernels for — exactly the
            host's GPU, nothing else. RTX 5080 (Blackwell) is "12.0",
            RTX 3070 (Ampere) is "8.6". Getting this wrong doesn't fail
            the build; it fails at runtime with no usable kernels.
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

        # The key never reaches `settings`/argv — /nix/store and /proc/*/cmdline
        # are both world-readable. llama-server reads `--api-key` from
        # LLAMA_API_KEY, so an EnvironmentFile keeps it off both.
        #
        # Router mode does not weaken this. llama.cpp strips LLAMA_API_KEY
        # from the preset it renders into each child's argv (so it is
        # absent from the argv that the *public* `/v1/models` endpoint
        # echoes back), and the children pick the key up from the
        # inherited environment instead.
        #
        # shared.yaml rather than the per-host file because the servers
        # fronting this need the same key: caddy injects it upstream on
        # behalf of an authentik-authenticated browser (see
        # modules/apps/llm-terra.nix). shared.yaml is decryptable by every
        # host in the fleet, which is wider than the three that need it —
        # acceptable for now, and the thing to fix when the sops files get
        # split more finely.
        sops.secrets."llama-cpp/api_key" = {
          sopsFile = "${inputs.nix-secrets}/sops/shared.yaml";
        };

        sops.templates."llama-cpp.env" = {
          content = ''
            LLAMA_API_KEY=${config.sops.placeholder."llama-cpp/api_key"}
          '';
          restartUnits = [ "llama-cpp.service" ];
        };

        services.llama-cpp = {
          enable = true;
          package = pkgsCuda.llama-cpp;
          host = cfg.listenAddress;
          inherit (cfg) port;

          # Rendered by the upstream module through `lib.generators.toINI`
          # into a store file passed as `--models-preset`. Section names
          # are the model names, and the keys are llama-server arguments
          # with their leading dashes stripped — `c` and `ctk` are the
          # short forms of `--ctx-size` and `--cache-type-k`.
          #
          # `hf-repo` repeats the section name on purpose. When the model
          # is already cached the two entries merge and it is a no-op; when
          # it is not, it is the only thing that tells the router where to
          # fetch the weights from, and without it a freshly-provisioned
          # host serves an empty model list.
          modelsPreset = lib.mapAttrs (
            name: model:
            {
              hf-repo = name;
              c = model.ctxSize;
              n-gpu-layers = model.nGpuLayers;
              ctk = model.cacheTypeK;
              ctv = model.cacheTypeV;
            }
            # Omitted rather than written as 0 for a dense model: the
            # flag is meaningless without experts and leaving it out
            # keeps the rendered preset readable as a description of
            # what each model actually needs.
            // lib.optionalAttrs (model.nCpuMoeLayers > 0) {
              n-cpu-moe = model.nCpuMoeLayers;
            }
            // lib.optionalAttrs (model.aliases != [ ]) {
              alias = lib.concatStringsSep "," model.aliases;
            }
          ) cfg.models;

          extraFlags = [
            # One resident model. See the header: nothing fits two at once
            # on either host, so this is the mode rather than a limit, and
            # leaving it at the default of 4 would let a second request
            # OOM the card instead of evicting.
            "--models-max"
            "1"
            "--sleep-idle-seconds"
            (toString cfg.sleepIdleSeconds)
            # Turns on each *child's* /metrics endpoint (#553). The router
            # itself has no metrics of its own — its `/metrics` is a proxy
            # that routes by `?model=` — so the flag is only useful for
            # what it does on the way down: llama.cpp merges the router's
            # argv into every child's preset, and `--metrics` is not one of
            # the reserved options it strips, so each child comes up with
            # `endpoint_metrics` on. Verified at b9190 by rendering the
            # child argv out of `/v1/models`.
            #
            # Costs nothing when unscraped: the endpoint stays behind
            # `--api-key` and the counters are already maintained.
            "--metrics"
          ]
          ++ cfg.extraFlags;
        };

        systemd.services.llama-cpp = {
          # sops-install-secrets runs as a unit (see modules/system/sops.nix),
          # so the env file is orderable. Without this edge the first start
          # after a switch can read a not-yet-rendered path and come up with
          # no API key at all — which llama-server treats as "auth disabled",
          # a silent open door rather than a crash.
          after = [ "sops-install-secrets.service" ];
          requires = [ "sops-install-secrets.service" ];

          serviceConfig = {
            EnvironmentFile = [ config.sops.templates."llama-cpp.env".path ];

            # Keep the downloaded GGUF in the state directory. Upstream
            # points LLAMA_CACHE at CacheDirectory, which invites a
            # multi-GB re-download from anything that prunes caches.
            Environment = lib.mkForce [ "LLAMA_CACHE=/var/lib/llama-cpp/models" ];

            # The NVIDIA userspace driver maps writable-then-executable
            # pages when it JITs kernels; upstream's MemoryDenyWriteExecute
            # kills a CUDA build on the first cuModuleLoad.
            MemoryDenyWriteExecute = lib.mkForce false;
          };
        };

        # Scoped by source address rather than `services.llama-cpp.openFirewall`,
        # which opens the port to everything that can route to the host.
        # iptables rather than nftables rules because the fleet is still on
        # the iptables backend (`networking.nftables.enable = false`), which
        # is what `extraInputRules` would need. IPv4-only: the LAN this
        # serves is v4 and the allowlist is written as v4 addresses.
        networking.firewall = lib.mkIf (cfg.allowedClients != [ ]) {
          extraCommands = lib.concatMapStringsSep "\n" (
            src: "iptables -A nixos-fw -p tcp -s ${src} --dport ${toString cfg.port} -j nixos-fw-accept"
          ) cfg.allowedClients;
          extraStopCommands = lib.concatMapStringsSep "\n" (
            src: "iptables -D nixos-fw -p tcp -s ${src} --dport ${toString cfg.port} -j nixos-fw-accept || true"
          ) cfg.allowedClients;
        };
      };
    };
}
