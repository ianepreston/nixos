# One pi installation and models.json writer on Linux and Darwin. Providers
# contribute through myPi.providers; pi keeps its writable settings and state.
{ inputs, ... }:
{
  flake.modules.homeManager.pi =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.myPi;
      json = pkgs.formats.json { };
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };
      modelType = lib.types.submodule {
        freeformType = json.type;
        options.id = lib.mkOption {
          type = lib.types.str;
          description = "Model identifier sent to this provider.";
        };
      };
      providerType = lib.types.submodule {
        # Keep provider-specific compatibility flags and native API fields
        # extensible without copying pi's evolving schema into Nix.
        freeformType = json.type;
        options = {
          baseUrl = lib.mkOption {
            type = lib.types.str;
            description = "API base URL, before pi adds its API-specific path.";
          };
          api = lib.mkOption {
            type = lib.types.str;
            default = "openai-completions";
            description = "pi API dialect, such as openai-responses or anthropic-messages.";
          };
          apiKey = lib.mkOption {
            type = lib.types.str;
            description = "Runtime credential reference, for example !command or $ENV_VAR; never a secret value.";
          };
          models = lib.mkOption {
            type = lib.types.listOf modelType;
            description = "Models advertised by this provider, with optional pi metadata.";
          };
        };
      };
    in
    {
      options.myPi = {
        enable = lib.mkEnableOption "the pi coding agent";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgsUnstable.pi-coding-agent;
          description = "pi package, shared by Linux and Darwin configurations.";
        };
        providers = lib.mkOption {
          type = lib.types.attrsOf providerType;
          default = { };
          description = "Additive provider declarations rendered into one models.json. Work-only providers belong in the private work module.";
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];
        home.file.".pi/agent/models.json" = lib.mkIf (cfg.providers != { }) {
          source = json.generate "pi-models.json" { inherit (cfg) providers; };
        };
        assertions = lib.mapAttrsToList (name: provider: {
          assertion =
            let
              ids = map (model: model.id) provider.models;
            in
            builtins.length ids == builtins.length (lib.unique ids);
          message = "myPi.providers.${name} contains duplicate model identifiers.";
        }) cfg.providers;
      };
    };
}
