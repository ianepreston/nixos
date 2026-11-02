# Published operator contract; tasks consume this instead of platform internals.
{ config, lib, ... }:
let
  cfg = config.myLlamaCpp;
  exported =
    type: description:
    lib.mkOption {
      inherit type description;
      readOnly = true;
    };
in
{
  options.myLlamaCpp.operator = {
    platform = exported (lib.types.enum [
      "linux"
      "darwin"
    ]) "Where operator commands run.";
    cacheDirectory = exported lib.types.str "Persistent GGUF cache directory on the serving host.";
    apiKeyFile = exported lib.types.str "Runtime credential file on the serving host; never its contents.";
    apiKeyFormat = exported (lib.types.enum [
      "env"
      "raw"
    ]) "Credential file encoding.";
    port = (exported lib.types.port "Loopback API port on the serving host.") // {
      default = cfg.port;
    };
    baseUrl = (exported lib.types.str "OpenAI API base URL on the serving host.") // {
      default = "http://127.0.0.1:${toString cfg.port}/v1";
    };
    models =
      (exported (lib.types.listOf lib.types.str) "Configured routing names, including idle models.")
      // {
        default = lib.attrNames cfg.models;
      };
  };
}
