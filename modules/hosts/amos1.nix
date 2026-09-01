# amos1 - Prod server
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.amos1 = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.amos1;
    extraModules = [
      ./_amos1-hardware.nix
      inputs.disko.nixosModules.disko
      ./_amos1-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      nvidia-server
      nvidia-exporter
      server
      server-apps
      # Fronts terra's llama-server with TLS + authentik; no inference of
      # its own (see modules/apps/llm-terra.nix).
      llm-terra
      # amos1's *own* llama-server: the daemon plus its route.
      llama-cpp
      llm
    ])
    ++ [
      {
        home-manager.sharedModules = with inputs.self.modules.homeManager; [
          ssh-homelan
        ];
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          networkmanager.enable = true;
        };

        # Always-on local inference on the RTX 3070. Complements terra's
        # larger model, which is only reachable when that desktop is on.
        #
        # VRAM budget (8.0 GB, shared with Jellyfin's NVENC transcoding):
        #   Qwen3-8B Q4_K_M weights  ~5.0 GB
        #   KV cache @ 8k ctx        ~1.2 GB  (36 layers x 8 KV heads
        #                                      x 128 dim x 2 x f16
        #                                      = ~144 KB/token)
        #   compute buffers          ~0.5 GB
        # ...leaving ~1.3 GB, which is the headroom a transcode has to fit
        # into if one starts while the model is resident. That is the
        # binding constraint here, not model quality — raising ctxSize
        # eats Jellyfin's margin, not spare capacity.
        myLlamaCpp = {
          enable = true;
          hfModel = "Qwen/Qwen3-8B-GGUF:Q4_K_M";
          ctxSize = 8192;
          cudaCapabilities = [ "8.6" ]; # RTX 3070, Ampere / sm_86
          # 8080 is unifi-os-server's on this host. Loopback-only: caddy
          # is the sole client, so no allowedClients and no firewall hole.
          port = 8091;
          # Shorter than terra's 600s: the GPU has a second job here, and
          # handing VRAM back to transcoding promptly matters more than
          # avoiding an occasional model reload.
          sleepIdleSeconds = 300;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
