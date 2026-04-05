# Penguin - WSL / standalone home-manager
{
  inputs,
  hostSpecs,
  customLib,
  ...
}:
{
  flake.homeConfigurations.penguin = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    extraSpecialArgs = {
      inherit customLib inputs;
      hostSpec = hostSpecs.penguin;
    };
    modules = [
      (customLib.relativeToRoot "home/ipreston/penguin.nix")
    ];
  };
}
