# Terra - AMD desktop workstation
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.terra = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.terra;
    extraModules = [
      ./_terra-hardware.nix
      inputs.hardware.nixosModules.common-cpu-amd
      inputs.disko.nixosModules.disko
      ./_terra-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
      docker
      flatpak
      gaming
      keyd
      llama-cpp
      moonshine
      nvidia-rtx5080
      printing
      rgb
      smbclient
      quickemu
      xreal-headset
      zsa-keeb
    ])
    ++ [
      {
        home-manager.sharedModules = with inputs.self.modules.homeManager; [
          vibes
          adb
          calibre
          freecad
          mesh-tools
          obsidian
          # orca-slicer — code kept but dormant; printing through bambuddy is
          # blocked upstream (see #298). Re-add when fixed.
          browser
          ssh-homelan
        ];

        boot = {
          loader = {
            systemd-boot.enable = true;
            efi.canTouchEfiVariables = true;
          };
        };

        networking = {
          networkmanager.enable = true;
        };

        # Local LLM inference on the RTX 5080. terra has no caddy/authentik
        # of its own (workstation profile), so HTTPS + SSO come from a
        # `myAuthentik.forwardAuthApps.llm-terra` route on the servers that
        # proxies here over the LAN — see modules/apps/llm-terra.nix. Both
        # hpp-1 (dev) and amos1 (prod) carry it. Those routes
        # resolves `terra.ipreston.net`, which is a DHCP-registered name:
        # terra needs a DHCP reservation on the router or the address (and
        # the route with it) drifts on lease renewal.
        #
        # Four models, one at a time (#519). llama-server runs as a
        # router and swaps on demand, because no single GGUF that fits
        # this card covers all four jobs: #524 traded 14B-class text
        # quality away to get vision, and there is no vision model above
        # 8B that fits 16.3 GB without offloading experts to system RAM.
        # Router mode buys them all back at the cost of a measured 3-4 s
        # swap (cold page cache included, NVMe).
        #
        # ~56 GB of models against a 16.3 GB card, so `--models-max 1` in
        # modules/system/llama-cpp.nix is load-bearing, not a tuning knob.
        # Even the cheapest pairing (VL-8B dropped to 40960) is 23.2 GB.
        #
        # The two coding-oriented models below are here to be *compared*
        # (#518): throughput is measured and settled, code quality is not,
        # and nothing but real agentic sessions will settle it. Both are
        # therefore reachable by name from pi and opencode rather than one
        # being picked on paper — see modules/programs/vibes.nix.
        #
        # Nothing is loaded at boot. The first request for a model pays
        # its load; `task llm:models:fetch HOST=terra` pre-warms the cache
        # after a rebuild, which is the only case where that wait is a
        # multi-GB download rather than three seconds.
        myLlamaCpp = {
          enable = true;
          cudaCapabilities = [ "12.0" ]; # RTX 5080, Blackwell / sm_120

          models = {
            # Vision. `-hf` resolves and downloads the repo's mmproj (the
            # vision projector) alongside the weights with no extra
            # option, and the router reports `input_modalities:
            # ["text","image"]` for this model and `["text"]` for the
            # other — projectors do not leak between models in one preset.
            # This is what makes Tandoor's photo recipe import and
            # paperless-ngx's document AI usable against a local endpoint.
            #
            # The mtmd path takes **images only** — a `data:application/pdf`
            # URL is rejected with "Invalid url format", and there is no
            # `file` content part. A caller wanting PDF understanding has
            # to rasterize the pages itself.
            #
            # VRAM budget (16.3 GB total, minus ~1 GB the GNOME session holds):
            #   Qwen3-VL-8B Q4_K_M weights ~5.0 GB
            #   mmproj (Q8_0, auto-picked) ~0.75 GB
            #   KV cache @ 98304 ctx       ~6.8 GB  (36 layers x 8 KV heads
            #                                        x 128 dim x 2 x q8_0
            #                                        = ~72 KB/token; f16 would
            #                                        be ~144 KB/token, which
            #                                        does not fit)
            #   compute buffers            ~1.0 GB
            # Measured resident: 13734 MiB on the bench, 13574 MiB on
            # the pre-router service and 13576 MiB under the router (card
            # total 14270 of 16303) — routing costs no VRAM of its own.
            #
            # 131072 does not fit: the KV cache alone wants 9792 MiB and
            # cudaMalloc fails before the model finishes loading. The
            # model trains to 262144, so the ceiling here is the card's,
            # not the model's. See #524 for the full table, including why
            # Gemma 3 lost: it encodes every image to a fixed 256 tokens
            # (Qwen3-VL spent 1979 on the same invoice) and misreads dense
            # tables as a result.
            "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M" = {
              aliases = [ "vision" ];
              ctxSize = 98304;
              cacheTypeK = "q8_0";
              cacheTypeV = "q8_0";
            };

            # Default generalist, and the model an agent should reach
            # for unless it has a reason not to (#518). MXFP4 weights and
            # ~3.6B active parameters of 20B (4 of 32 experts) make it
            # both smaller and faster than the dense 14B below while
            # holding 3.2x the context — it beats every other candidate
            # measured on *every* axis, which is why it takes `text`.
            #
            # Sliding-window attention is what makes 131072 affordable:
            # alternating layers cap their cache at a 128-token window, so
            # KV + compute buffers together come to only ~1254 MiB at full
            # context on top of 12.1 GB of weights. The naive
            # bytes-per-token arithmetic that sizes every other model on
            # this host predicts ~3.1 GB and is simply wrong here.
            #
            # Measured resident: 13352 MiB at 131072 with q8_0 KV under
            # the router (card total 13909 of 16303 with the GNOME
            # session) — the largest footprint here, and better than the
            # 14892 MiB #518 measured on the bench. f16 KV at the same
            # context OOMs, so the quantized cache is a prerequisite
            # rather than a tuning choice. Host RAM is 1.5 GB. Throughput
            # on #518's fixed 16,701-token prompt: 10817 tok/s prefill,
            # 189.5 tok/s generation.
            #
            # Text-only, like both models below it — `vision` is the
            # only entry here that takes an image, and nothing about
            # gpt-oss changes that.
            "ggml-org/gpt-oss-20b-GGUF:MXFP4" = {
              aliases = [ "text" ];
              ctxSize = 131072;
              cacheTypeK = "q8_0";
              cacheTypeV = "q8_0";
            };

            # Coding specialist, and the other half of #518's open
            # question: it is a *coding* model against gpt-oss's general
            # reasoning, and no throughput number decides between them.
            # Routed by name so both are selectable from an agent.
            #
            # 17.7 GB of weights do not fit a 16.3 GB card, but this is an
            # MoE (~3.3B active of 30B), so `nCpuMoeLayers` keeps
            # attention and the whole KV cache on the GPU while 40 of the
            # 48 layers' expert FFN weights sit in system RAM. That is the
            # only reason 131072 is reachable at all here.
            #
            # Its cache is also unusually cheap for its size — 48 layers
            # but only 4 KV heads, so ~48 KB/token at q8_0, 40% less than
            # the 14B below despite being twice the model.
            #
            # Measured at ncmoe=40 under the router: 10846 MiB VRAM
            # (card total 11403 of 16303), against #518's bench figure of
            # 12391. Throughput 1034 tok/s prefill, 30.0 tok/s generation.
            #
            # The 14.3 GB of host RAM this costs is *not* committed
            # memory, which the bench's phrasing obscures: of 14.3 GB
            # RSS, 13.6 GB is `RssFile` — the offloaded expert weights are
            # an mmap of the GGUF, so the kernel accounts them as
            # reclaimable page cache and `free` still reports ~26 GB
            # available. Only ~0.5 GB is anonymous. That makes it far
            # kinder to a 30 GB desktop than "14 GB gone" suggests, but
            # it is not free either: reclaiming those pages under memory
            # pressure means re-reading experts from NVMe per token, so
            # the throughput above assumes they stay resident.
            #
            # ncmoe=30 is the faster config at the same context
            # (1283/37.0) and was rejected: 15655 MiB leaves ~650 MiB on a
            # card that is also running a GNOME session. Fewer offloaded
            # layers is monotonically faster, so the bound is VRAM, not
            # tuning.
            #
            # The `UD-` prefix costs a phantom: llama.cpp's cache scan
            # derives a model name from the *filename*, drops the prefix,
            # and so publishes an unconfigured
            # `unsloth/…-GGUF:Q4_K_XL` next to this one, pointing at the
            # same weights with no ctxSize and no nCpuMoeLayers. It is
            # not a stale download and `task llm:models:prune` will not
            # (and should not) remove it — the cache holds exactly one
            # file here. See the cache section in
            # modules/system/llama-cpp.nix; the practical consequence is
            # that `code` is the name to use and the bare `Q4_K_XL` one
            # would OOM the card.
            "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q4_K_XL" = {
              aliases = [ "code" ];
              ctxSize = 131072;
              cacheTypeK = "q8_0";
              cacheTypeV = "q8_0";
              nCpuMoeLayers = 40;
            };

            # Fallback generalist. The model #524 displaced, kept as a
            # named peer rather than the default: 14B-class *dense* text
            # quality, no vision, and a hard 40960 ceiling that is the
            # model's (n_ctx_train), not the card's — the inverse of the
            # VL-8B situation above.
            #
            # It lost `text` to gpt-oss on measurements, not taste (3282
            # vs 10817 tok/s prefill, 62.8 vs 189.5 generation, 40k vs
            # 128k context on #518's fixed prompt), and a dense model can
            # still behave differently from a sparse one on the same
            # request. `text-qwen` is what makes that comparison a request
            # header rather than a rebuild.
            #
            # Measured resident: 12226 MiB under the router.
            "Qwen/Qwen3-14B-GGUF:Q4_K_M" = {
              aliases = [ "text-qwen" ];
              ctxSize = 40960;
              cacheTypeK = "q8_0";
              cacheTypeV = "q8_0";
            };
          };

          # Bound on the LAN so the servers can reach it, but only they
          # get through the firewall; every other client goes via one of
          # their HTTPS routes. Addresses come from the hostSpecs rather
          # than literals so the allowlist can't drift from the servers'
          # actual pinned IPs.
          listenAddress = "0.0.0.0";
          allowedClients = [
            hostSpecs.amos1.serverLanIp
            hostSpecs.hpp-1.serverLanIp
          ];
          # terra is a gaming machine first. Ten idle minutes and the GPU
          # goes back to whatever else wants it.
          sleepIdleSeconds = 600;
        };

        system.stateVersion = "25.05";
      }
    ];
  };
}
