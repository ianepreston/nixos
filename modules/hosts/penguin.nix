# Penguin - WSL / standalone home-manager
{ inputs, hostSpecs, ... }:
{
  flake.homeConfigurations.penguin = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    extraSpecialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.penguin;
    };
    modules = with inputs.self.modules.homeManager; [
      core
      ssh
      ssh-homelan
      vibes
    ];
  };
}
