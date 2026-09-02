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
        # Vision-capable (#524), same as terra's — see modules/hosts/terra.nix
        # for how `-hf` picks up the mmproj and why PDFs don't work.
        #
        # VRAM budget (8.0 GB, shared with Jellyfin's NVENC transcoding):
        #   Qwen3-VL-4B Q4_K_M weights ~2.5 GB
        #   mmproj (Q8_0, auto-picked) ~0.45 GB
        #   KV cache @ 32768 ctx       ~2.3 GB  (36 layers x 8 KV heads
        #                                        x 128 dim x 2 x q8_0
        #                                        = ~72 KB/token; f16 is
        #                                        ~144 KB/token)
        #   compute buffers            ~0.9 GB
        # Measured resident: 6188 MiB on the bench, 6132 MiB on the
        # deployed service after a real image request (card total 6141 of
        # 8192) — either way *below* what Qwen3-8B held at 16384, so the
        # Jellyfin headroom #517 validated carries over unchanged and the
        # context doubles on top. That equivalence is the argument: this
        # is vision plus 2x context for no VRAM at all.
        #
        # Contention numbers therefore stand as measured in #517 with the
        # model resident: 1080p h264_nvenc peaks the card at 6586 MiB, 4K
        # hevc_nvenc at 7730 MiB, both succeeding. Re-checked here with a
        # synthetic 4K cuda-decode -> scale_cuda -> hevc_nvenc pipeline
        # against the new model, which peaked at 7179 MiB — lower than
        # Jellyfin's real figure because it skips tone-mapping and
        # subtitle burn-in, so treat #517's 7730 as the number that binds.
        #
        # 40960 does not clear that bar: it puts the model at 6800 MiB,
        # 612 MiB worse than today, which eats into the ~1.5 GB a 4K
        # transcode wants. Qwen3-VL-8B is out of the question here at all
        # — 7374 MiB at only 16384 ctx. So 32768 is the ceiling, set by
        # Jellyfin rather than by the model (Qwen3-VL trains to 262144).
        #
        # Known weakness of the 4B specifically: given a three-field
        # ingredient schema it duplicates the food name into `unit` on
        # 10 of 11 ingredients. Schema `description` fields do not fix it
        # — llama.cpp compiles a JSON schema to a GBNF grammar and drops
        # descriptions — but an instruction in the prompt body does. That
        # lever belongs to the calling app, so Tandoor may or may not have
        # it. Qwen3-VL-8B has no such defect; this is the cost of the
        # 8 GB budget. Document OCR itself was flawless on both.
        myLlamaCpp = {
          enable = true;
          hfModel = "Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M";
          ctxSize = 32768;
          cacheTypeK = "q8_0";
          cacheTypeV = "q8_0";
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
