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
# ## Model files
#
# GGUFs are gigabytes and are not nix-store material, so they are *not*
# fetched by nix. `myLlamaCpp.hfModel` is passed to llama-server as
# `-hf <repo>:<quant>`, and llama-server downloads the weights itself into
# `LLAMA_CACHE` on first start. That directory is overridden below from
# the upstream module's `/var/cache/llama-cpp` to the state directory, so
# `systemctl clean --what=cache llama-cpp` (or anything else that treats
# /var/cache as disposable) doesn't silently trigger a multi-GB re-download.
#
# The first start therefore takes as long as the download takes and needs
# working egress to huggingface.co; subsequent starts are cache hits.
# Switching models is a `hfModel` change plus one re-download.
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

      pkgsCuda = import inputs.nixpkgs {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = pkgs.config // {
          cudaSupport = true;
          inherit (cfg) cudaCapabilities;
        };
      };
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

        hfModel = lib.mkOption {
          type = lib.types.str;
          example = "Qwen/Qwen3-14B-GGUF:Q4_K_M";
          description = ''
            Hugging Face repo and quant tag passed as `-hf`. llama-server
            resolves and downloads the GGUF on first start; see the module
            header for where it lands.
          '';
        };

        ctxSize = lib.mkOption {
          type = lib.types.ints.positive;
          example = 32768;
          description = ''
            Context window in tokens (`-c`). Sized per host: the KV cache
            for this context has to fit in whatever VRAM the model weights
            leave behind.
          '';
        };

        nGpuLayers = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 99;
          description = ''
            Layers offloaded to the GPU (`-ngl`). The default is the
            "everything" idiom — any value at or above the model's layer
            count offloads the whole model. Lower it only to deliberately
            keep layers on the CPU because the model doesn't fit.
          '';
        };

        sleepIdleSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          example = 600;
          description = ''
            Idle seconds after which llama-server sleeps and hands its
            VRAM back (`--sleep-idle-seconds`). The point on a machine
            that is also used for something else (a workstation that
            games); the next request pays a reload.
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
          description = "Additional llama-server flags appended after the ones this module builds.";
        };
      };

      config = lib.mkIf cfg.enable {
        # The key never reaches `settings`/argv — /nix/store and /proc/*/cmdline
        # are both world-readable. llama-server reads `--api-key` from
        # LLAMA_API_KEY, so an EnvironmentFile keeps it off both.
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
          extraFlags = [
            "-hf"
            cfg.hfModel
            "-c"
            (toString cfg.ctxSize)
            "-ngl"
            (toString cfg.nGpuLayers)
            "--sleep-idle-seconds"
            (toString cfg.sleepIdleSeconds)
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
