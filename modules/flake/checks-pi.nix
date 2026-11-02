# Exercise real HM merging across independently contributed providers, including
# native API metadata, and keep pi's mutable files out of the managed file set.
{ inputs, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      evaluate =
        modules:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            inputs.self.modules.homeManager.pi
            {
              home = {
                username = "pi-test";
                homeDirectory = if pkgs.stdenv.hostPlatform.isDarwin then "/Users/pi-test" else "/home/pi-test";
                stateVersion = "23.05";
              };
              myPi.enable = true;
            }
          ]
          ++ modules;
        };
      local = {
        myPi.providers.local = {
          baseUrl = "http://127.0.0.1:8080/v1";
          apiKey = "!cat '/path with spaces/api-key'";
          models = [
            {
              id = "code";
              contextWindow = 32768;
            }
          ];
        };
      };
      remote = {
        myPi.providers.work = {
          baseUrl = "https://example.invalid/native";
          api = "anthropic-messages";
          apiKey = "!runtime-token";
          authHeader = true;
          compat.supportsEagerToolInputStreaming = false;
          models = [ { id = "work-model"; } ];
        };
      };
      merged =
        (evaluate [
          local
          remote
        ]).config;
      duplicate =
        builtins.tryEval
          (evaluate [
            local
            local
          ]).activationPackage.drvPath;
      empty = (evaluate [ ]).config;
      valid =
        assert
          lib.attrNames merged.myPi.providers == [
            "local"
            "work"
          ];
        assert merged.myPi.providers.work.compat.supportsEagerToolInputStreaming == false;
        assert merged.myPi.providers.work.authHeader;
        assert merged.myPi.providers.local.api == "openai-completions";
        assert !(merged.home.file ? ".pi/agent/settings.json");
        assert !(merged.home.file ? ".pi/agent/auth.json");
        assert !(empty.home.file ? ".pi/agent/models.json");
        assert !duplicate.success;
        merged.home.file.".pi/agent/models.json".source;
    in
    {
      checks.pi-providers =
        pkgs.runCommand "pi-provider-composition" { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            jq -e '
              (.providers | keys) == ["local", "work"] and
              .providers.local.models[0].contextWindow == 32768 and
              .providers.work.api == "anthropic-messages" and
              .providers.work.compat.supportsEagerToolInputStreaming == false
            ' ${valid} > /dev/null
            touch "$out"
          '';
    };
}
