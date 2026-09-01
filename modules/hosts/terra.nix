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
        #   KV cache @ 16k ctx         ~2.6 GB  (40 layers x 8 KV heads
        #                                        x 128 dim x 2 x f16
        #                                        = ~160 KB/token)
        #   compute buffers            ~1.0 GB
        # ...which leaves a couple of GB spare. Raising ctxSize eats that
        # headroom fast at 160 KB/token — 32k alone is ~5.2 GB of KV.
        myLlamaCpp = {
          enable = true;
          hfModel = "Qwen/Qwen3-14B-GGUF:Q4_K_M";
          ctxSize = 16384;
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
