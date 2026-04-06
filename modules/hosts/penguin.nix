# Penguin - WSL / standalone home-manager
{ inputs, hostSpecs, ... }:
{
  flake.homeConfigurations.penguin = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    extraSpecialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.penguin;
    };
    modules = [
      inputs.self.modules.homeManager.core
    ];
  };
}
