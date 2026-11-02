{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.myLlamaCpp;
  rendered = import ./render.nix { inherit lib cfg; };

  # The radar consumes this compact contract instead of `models`, which
  # is an implementation surface for llama-server. The mechanical fields
  # are derived below so a cache, context or offload change cannot drift
  # from the evaluation assumptions.
  targetType = lib.types.submodule {
    options = {
      role = lib.mkOption {
        type = lib.types.enum [
          "generalist"
          "coding"
          "vision"
        ];
        description = "The job this alias is evaluated to replace.";
      };
      modalities = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "text"
            "image"
          ]
        );
        default = [ "text" ];
        description = "Input modalities a candidate must support for this alias.";
      };
    };
  };

  modelNamesForAlias =
    alias: lib.attrNames (lib.filterAttrs (_: model: lib.elem alias model.aliases) cfg.models);
  modelNameForAlias = alias: lib.head (modelNamesForAlias alias);
  modelForAlias = alias: cfg.models.${modelNameForAlias alias};
  evaluationExport = {
    inherit (cfg.evaluation) residentBudgetMiB;
    targets = lib.mapAttrs (
      alias: target:
      let
        model = modelForAlias alias;
      in
      target
      // {
        incumbent = modelNameForAlias alias;
        contextTokens = model.ctxSize;
        inherit (model)
          cacheTypeK
          cacheTypeV
          nGpuLayers
          nCpuMoeLayers
          ;
      }
    ) cfg.evaluation.targets;
  };

  pkgsCuda = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = pkgs.config // {
      cudaSupport = true;
      inherit (cfg) cudaCapabilities;
    };
  };

in
{
  imports = [
    ./common.nix
    ./operator.nix
  ];
  options.myLlamaCpp = {
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

    evaluation = {
      residentBudgetMiB = lib.mkOption {
        type = lib.types.ints.positive;
        description = ''
          GPU memory available to a candidate after this host's desktop
          or NVENC workload has taken its share. This is an evaluation
          budget, not nominal card capacity.
        '';
      };
      targets = lib.mkOption {
        type = lib.types.attrsOf targetType;
        default = { };
        description = ''
          Alias-level evaluation roles. The radar derives active context,
          KV types and offload settings, then consumes only evalTargets.
        '';
      };
    };

    evalTargets = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = evaluationExport;
      description = ''
        Read-only evaluation-facing export for local tooling. Combines the
        declared role/budget with the active model's sizing assumptions.
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

  };

  config = lib.mkIf cfg.enable {
    myLlamaCpp.operator = {
      platform = "linux";
      cacheDirectory = "/var/lib/llama-cpp/models";
      apiKeyFile = config.sops.templates."llama-cpp.env".path;
      apiKeyFormat = "env";
    };
    # Child model processes are not units; their state is collected by
    # llm-metrics. The router itself is a normal service worth monitoring.
    myObservability.monitoredSystemdUnits = [ "llama-cpp" ];

    assertions = [
      {
        assertion = lib.all (alias: modelNamesForAlias alias != [ ]) (lib.attrNames cfg.evaluation.targets);
        message = ''
          myLlamaCpp.evaluation.targets declares an alias absent from
          myLlamaCpp.models: ${
            lib.concatStringsSep ", " (
              lib.filter (alias: modelNamesForAlias alias == [ ]) (lib.attrNames cfg.evaluation.targets)
            )
          }.
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
      inherit (rendered) modelsPreset;

      # The common renderer pins one resident model and idle sleep (README.md).
      extraFlags =
        rendered.routerFlags
        ++ [
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
        Environment = lib.mkForce [ "LLAMA_CACHE=${cfg.operator.cacheDirectory}" ];

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
}
