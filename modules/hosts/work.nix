# Work - Darwin work machine
{
  inputs,
  hostSpecs,
  ...
}:
let
  hostSpec = hostSpecs.work;
in
{
  flake.darwinConfigurations.work = inputs.nix-darwin.lib.darwinSystem {
    specialArgs = {
      inherit inputs;
      inherit (inputs.nixpkgs-darwin) lib;
      inherit hostSpec;
    };
    modules = [
      inputs.self.modules.darwin.base
      inputs.self.modules.darwin.desktop
      inputs.self.modules.darwin.homebrew
      inputs.self.modules.darwin.yubikey
      inputs.self.modules.darwin.llama-cpp
      inputs.nix-secrets.darwinModules.work
      {
        system.primaryUser = hostSpec.username;

        # One model on demand; 48 GB is shared with desktop applications.
        # Keep the initial disk and context budget conservative (#884).
        myLlamaCpp = {
          enable = true;
          sleepIdleSeconds = 600;
          models."ggml-org/gpt-oss-20b-GGUF:MXFP4" = {
            aliases = [
              "code"
              "text"
            ];
            ctxSize = 32768;
          };
        };

        home-manager.sharedModules = [
          inputs.self.modules.homeManager.coding-sandbox
          inputs.self.modules.homeManager.hammerspoon
          inputs.self.modules.homeManager.ghostty
          inputs.self.modules.homeManager.wealthsimple-convert
          inputs.self.modules.homeManager.pi
          ({ osConfig, ... }: {
            myPi = {
              enable = true;
              providers.local = osConfig.myLlamaCpp.piProvider;
            };
          })
          inputs.nix-secrets.homeManagerModules.work
        ];

        nixpkgs.hostPlatform = "aarch64-darwin";
        nix.enable = false;

        system.stateVersion = 6;
      }
    ];
  };
}
