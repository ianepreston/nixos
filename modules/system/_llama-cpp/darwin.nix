{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.myLlamaCpp;
  home = config.users.users.${config.system.primaryUser}.home;
  rendered = import ./render.nix { inherit lib cfg; };
  preset = pkgs.writeText "llama-models.ini" (lib.generators.toINI { } rendered.modelsPreset);
  keyFile = "${cfg.dataDirectory}/api-key";
  cacheDirectory = "${cfg.dataDirectory}/models";
  runner = pkgs.writers.writePython3 "llama-cpp-local" { } (builtins.readFile ./serve.py);
  piModels = (pkgs.formats.json { }).generate "pi-local-models.json" {
    providers.local = {
      baseUrl = cfg.operator.baseUrl;
      api = "openai-completions";
      apiKey = "!cat ${lib.escapeShellArg keyFile}";
      models = lib.concatLists (
        lib.mapAttrsToList (
          name: model:
          map (alias: {
            id = alias;
            name = "${alias} (${name})";
            reasoning = true;
            input = [ "text" ];
            contextWindow = model.ctxSize;
            maxTokens = lib.min 8192 (model.ctxSize / 4);
          }) (if model.aliases == [ ] then [ name ] else model.aliases)
        ) cfg.models
      );
    };
  };
  # Keep the existing prune algorithm and its keep-set/live-model guards.
  # Its GNU tools and Bash 4 features must not resolve to macOS /usr/bin.
  prunePackage = import ./prune-package.nix { inherit pkgs; };
in
{
  imports = [
    ./common.nix
    ./operator.nix
  ];
  options.myLlamaCpp.dataDirectory = lib.mkOption {
    type = lib.types.str;
    default = "${home}/Library/Application Support/llama-cpp";
    description = "User-owned persistent model data and local API credential; outside the Nix store.";
  };
  options.myLlamaCpp.operator.prunePackage = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "Darwin prune executable with the same algorithm and GNU runtime as Linux.";
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isAarch64;
        message = "The Darwin llama.cpp adapter requires Apple Silicon for Metal acceleration.";
      }
      {
        assertion = cfg.listenAddress == "127.0.0.1";
        message = "Darwin local inference must bind to 127.0.0.1.";
      }
      {
        assertion = lib.hasPrefix "${home}/" cfg.dataDirectory;
        message = "myLlamaCpp.dataDirectory must be inside the primary user's home.";
      }
    ];
    myLlamaCpp.operator = {
      platform = "darwin";
      inherit cacheDirectory;
      apiKeyFile = keyFile;
      apiKeyFormat = "raw";
      inherit prunePackage;
    };
    # An example rather than a managed ~/.pi config: using local inference
    # must not replace the workstation's unrelated providers or settings.
    environment.etc."llama-cpp/pi-models.json".source = piModels;
    system.activationScripts.preActivation.text = ''
      install -d -m 700 -o ${lib.escapeShellArg config.system.primaryUser} \
        ${lib.escapeShellArg "${home}/Library/Logs/llama-cpp"}
    '';
    launchd.user.agents.llama-cpp.serviceConfig = {
      Label = "org.nixos.llama-cpp";
      ProgramArguments = [
        "${runner}"
        "--cache-dir"
        cacheDirectory
        "--key-file"
        keyFile
        "--"
        "${pkgs.llama-cpp}/bin/llama-server"
        "--host"
        cfg.listenAddress
        "--port"
        (toString cfg.port)
        "--models-preset"
        "${preset}"
      ]
      ++ rendered.routerFlags
      ++ cfg.extraFlags
      ++ [ "--no-webui" ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 30;
      ExitTimeOut = 30;
      ProcessType = "Background";
      StandardOutPath = "${home}/Library/Logs/llama-cpp/server.log";
      StandardErrorPath = "${home}/Library/Logs/llama-cpp/server.log";
    };
  };
}
