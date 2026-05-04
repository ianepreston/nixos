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
      inputs.nix-secrets.darwinModules.work
      {
        system.primaryUser = hostSpec.username;

        home-manager.sharedModules = [
          inputs.self.modules.homeManager.hammerspoon
          inputs.self.modules.homeManager.ghostty
          inputs.nix-secrets.homeManagerModules.work
        ];

        nixpkgs.hostPlatform = "aarch64-darwin";
        nix.enable = false;

        system.stateVersion = 6;
      }
    ];
  };
}
