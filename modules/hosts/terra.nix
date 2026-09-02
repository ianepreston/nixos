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
        # Two models, one at a time (#519). llama-server runs as a
        # router and swaps on demand, because neither capability below is
        # reachable from a single GGUF that fits this card: #524 traded
        # 14B-class text quality away to get vision, and there is no
        # vision model above 8B that fits 16.3 GB without offloading
        # experts to system RAM. Router mode buys both back at the cost of
        # a measured 3-4 s swap (cold page cache included, NVMe).
        #
        # 27.5 GB of models against a 16.3 GB card, so `--models-max 1` in
        # modules/system/llama-cpp.nix is load-bearing, not a tuning knob.
        # Even the cheapest pairing (VL-8B dropped to 40960) is 23.2 GB.
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

            # Generalist. The model #524 displaced, back as a peer rather
            # than a replacement: 14B-class text quality, no vision, and
            # a hard 40960 ceiling that is the *model's* (n_ctx_train),
            # not the card's — the inverse of the VL-8B situation above.
            # Slower on both axes (3282 tok/s prefill, 62.8 tok/s
            # generation vs 6058 / 96.5 on #518's fixed 16,701-token
            # prompt); the reason to route here is quality, not speed.
            #
            # Measured resident: 12226 MiB under the router.
            "Qwen/Qwen3-14B-GGUF:Q4_K_M" = {
              aliases = [ "text" ];
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
