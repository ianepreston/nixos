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
        # The model is **vision-capable** (#524). `-hf` resolves and
        # downloads the repo's mmproj (the vision projector) alongside the
        # weights with no extra option, and llama-server reports
        # `capabilities: ["completion","multimodal"]` once it loads. That
        # is what makes Tandoor's photo recipe import and paperless-ngx's
        # document AI usable against a local endpoint.
        #
        # Note the mtmd path takes **images only** — a `data:application/pdf`
        # URL is rejected with "Invalid url format", and there is no `file`
        # content part. A caller wanting PDF understanding has to rasterize
        # the pages itself.
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
        # Measured resident: 13734 MiB on the bench, 13574 MiB on the
        # deployed service (card total 14270 of 16303) — within 40 MiB of
        # what Qwen3-14B held at 40960, so this is 2.4x the context and
        # vision for the same VRAM. It is also *faster* on both axes:
        # 6058 tok/s prefill vs 3282, 96.5 tok/s generation vs 62.8, on
        # #518's fixed 16,701-token prompt. The trade is text quality,
        # 14B-class down
        # to 8B-class — accepted deliberately, since no vision model above
        # 8B fits this card without offloading experts to system RAM.
        #
        # 131072 does not fit: the KV cache alone wants 9792 MiB and
        # cudaMalloc fails before the model finishes loading. The model
        # trains to 262144, so the ceiling here is the card's, not the
        # model's — the inverse of the Qwen3-14B situation #517 described.
        # See #524 for the full table, including why Gemma 3 lost: it
        # encodes every image to a fixed 256 tokens (Qwen3-VL spent 1979
        # on the same invoice) and misreads dense tables as a result.
        myLlamaCpp = {
          enable = true;
          hfModel = "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M";
          ctxSize = 98304;
          cacheTypeK = "q8_0";
          cacheTypeV = "q8_0";
          cudaCapabilities = [ "12.0" ]; # RTX 5080, Blackwell / sm_120
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
