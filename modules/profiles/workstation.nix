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
    { hostSpec, ... }:
    let
      platform = if hostSpec.isDarwin then "darwin" else "nixos";
    in
    {
      imports = [
        ./_hm-core/direnv.nix
        ./_hm-core/git.nix
        ./_hm-core/neovim.nix
        ./_hm-core/packages.nix
        ./_hm-core/starship.nix
        ./_hm-core/zsh.nix
        ./_hm-core/${platform}.nix
      ];

      programs.home-manager.enable = true;

      home = {
        sessionVariables = {
          FLAKE = "$HOME/nixos";
          SHELL = "zsh";
          VISUAL = "nvim";
          EDITOR = "nvim";
        };
        preferXdgDirectories = true;
      };
    };

  # Workstation NixOS module - base + common desktop essentials
  flake.modules.nixos.workstation = _: {
    imports = with inputs.self.modules.nixos; [
      base
      sops
      ssh
      audio
      themes
    ];

    # Home-manager modules common to all workstations
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
      browser
      comms
      ghostty
      media
    ];
  };
}
