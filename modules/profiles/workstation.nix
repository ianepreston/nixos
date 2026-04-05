# Workstation profile - desktop/laptop configuration
# Imports base + common desktop modules
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.workstation (NixOS desktop config)
# - flake.modules.homeManager.core (core HM config for all users)
{ inputs, ... }:
{
  # Core home-manager module - git, zsh, starship, neovim, direnv, packages
  # This wraps the existing home/core modules
  flake.modules.homeManager.core =
    { lib, hostSpec, ... }:
    let
      platform = if hostSpec.isDarwin then "darwin" else "nixos";
    in
    {
      imports = [
        ../../home/core/direnv.nix
        ../../home/core/git.nix
        ../../home/core/neovim.nix
        ../../home/core/packages.nix
        ../../home/core/starship.nix
        ../../home/core/zsh.nix
        ../../home/core/${platform}.nix
      ];

      programs.home-manager.enable = true;

      home = {
        username = lib.mkDefault hostSpec.username;
        homeDirectory = lib.mkDefault hostSpec.home;
        stateVersion = lib.mkDefault "23.05";
        sessionVariables = {
          FLAKE = "$HOME/nixos";
          SHELL = "zsh";
          VISUAL = "nvim";
          EDITOR = "nvim";
        };
        preferXdgDirectories = true;
      };
    };

  # Workstation NixOS module - base + desktop essentials
  flake.modules.nixos.workstation = _: {
    imports = [
      inputs.self.modules.nixos.base
    ];

    # Common workstation packages/services would go here
    # For now, this just imports base - audio/themes are still in optional/

    # Auto-include core HM modules for all users on workstations
    home-manager.sharedModules = [
      inputs.self.modules.homeManager.core
    ];
  };
}
