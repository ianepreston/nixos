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
        # Two models, one at a time (#519), same router shape as terra
        # — see modules/hosts/terra.nix for the mechanism. amos1 wants it
        # arguably more: it is the always-on host, so its single model
        # choice is what constrains the fleet whenever terra is powered
        # off, and the two models below sit within 110 MiB of each other
        # (6080 and 6190 MiB measured), making `--models-max 1` eviction a
        # like-for-like swap with no headroom cliff between them.
        #
        # 12.4 GB of models against an 8.0 GB card. Nothing about this is
        # concurrent serving.
        #
        # Vision-capable (#524) — see modules/hosts/terra.nix for how
        # `-hf` picks up the mmproj and why PDFs don't work.
        #
        # Nothing loads at boot, which matters more here than on terra:
        # the GPU's other job is Jellyfin's NVENC transcoding, and staying
        # cold until a request arrives is strictly better for that budget
        # than the pre-router service's load-at-start. Idle eviction is
        # unchanged and still the mechanism that hands VRAM back mid-day
        # — verified to still work in router mode, where a child drops
        # from full residency to ~330 MiB after `sleepIdleSeconds`.
        #
        # VRAM budget (8.0 GB, shared with Jellyfin's NVENC transcoding),
        # worst case of the two, which is the vision model:
        #   Qwen3-VL-4B Q4_K_M weights ~2.5 GB
        #   mmproj (Q8_0, auto-picked) ~0.45 GB
        #   KV cache @ 32768 ctx       ~2.3 GB  (36 layers x 8 KV heads
        #                                        x 128 dim x 2 x q8_0
        #                                        = ~72 KB/token; f16 is
        #                                        ~144 KB/token)
        #   compute buffers            ~0.9 GB
        #
        # Contention numbers stand as measured in #517 with a model
        # resident: 1080p h264_nvenc peaks the card at 6586 MiB, 4K
        # hevc_nvenc at 7730 MiB, both succeeding. Re-checked in #524 with
        # a synthetic 4K cuda-decode -> scale_cuda -> hevc_nvenc pipeline,
        # which peaked at 7179 MiB — lower than Jellyfin's real figure
        # because it skips tone-mapping and subtitle burn-in, so treat
        # #517's 7730 as the number that binds.
        myLlamaCpp = {
          enable = true;
          cudaCapabilities = [ "8.6" ]; # RTX 3070, Ampere / sm_86

          models = {
            # Vision. Measured resident: 6188 MiB on the bench, 6132 MiB
            # on the pre-router service after a real image request, and
            # 6080 MiB under the router — below what Qwen3-8B held at
            # 16384, so the Jellyfin headroom #517 validated carries over
            # unchanged.
            #
            # 40960 does not clear that bar: it puts the model at
            # 6800 MiB, 612 MiB worse, which eats into the ~1.5 GB a 4K
            # transcode wants. Qwen3-VL-8B is out of the question here at
            # all — 7374 MiB at only 16384 ctx. So 32768 is the ceiling,
            # set by Jellyfin rather than by the model (Qwen3-VL trains to
            # 262144).
            #
            # Known weakness of the 4B specifically: given a three-field
            # ingredient schema it duplicates the food name into `unit` on
            # 10 of 11 ingredients. Schema `description` fields do not fix
            # it — llama.cpp compiles a JSON schema to a GBNF grammar and
            # drops descriptions — but an instruction in the prompt body
            # does. That lever belongs to the calling app, so Tandoor may
            # or may not have it. This is the cost of the 8 GB budget;
            # route to terra's `vision` when it matters. Document OCR
            # itself was flawless on both.
            "Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M" = {
              aliases = [ "vision" ];
              ctxSize = 32768;
              cacheTypeK = "q8_0";
              cacheTypeV = "q8_0";
            };

            # Generalist. The model #524 displaced, back as a peer: an
            # 8B-class text model against the 4B, for the jobs where the
            # 4B's instruction-following is the binding constraint and no
            # image is involved. 6199 MiB at 16384 per #517 and 6190 MiB
            # measured under the router, i.e. within 110 MiB of the vision
            # model above, so swapping between them never changes what
            # Jellyfin can expect to find free.
            "Qwen/Qwen3-8B-GGUF:Q4_K_M" = {
              aliases = [ "text" ];
              ctxSize = 16384;
              cacheTypeK = "q8_0";
              cacheTypeV = "q8_0";
            };
          };

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
