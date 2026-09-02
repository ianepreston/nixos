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
        # VRAM budget (16.3 GB total, minus ~1 GB the GNOME session holds):
        #   Qwen3-14B Q4_K_M weights   ~9.0 GB
        #   KV cache @ 40960 ctx       ~3.4 GB  (40 layers x 8 KV heads
        #                                        x 128 dim x 2 x q8_0
        #                                        = ~85 KB/token; f16 would
        #                                        be ~160 KB/token, i.e. 6.4
        #                                        GB, which does not fit)
        #   compute buffers            ~1.0 GB
        # Quantizing the KV cache to q8_0 is what makes 40960 reachable
        # at all — it costs ~4% generation throughput (89.9 -> 86.1 tok/s)
        # and buys 2.5x the context. The deployed service measures 40960
        # at 86.8 tok/s holding 12226 MiB, card total 12937 of 16303 MiB.
        # 40960 is Qwen3-14B's n_ctx_train, so this is the model's ceiling
        # rather than the card's; going past it needs RoPE scaling and
        # degrades quality. See #517 for the full measurement table.
        myLlamaCpp = {
          enable = true;
          hfModel = "Qwen/Qwen3-14B-GGUF:Q4_K_M";
          ctxSize = 40960;
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
