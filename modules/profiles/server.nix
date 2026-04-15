# Server profile - just enough to host other services
# Imports base + common desktop modules
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server (NixOS server config)
# - flake.modules.homeManager.core (core HM config for all users)
{ inputs, ... }:
{
  # Core home-manager module - git, zsh, starship, neovim, direnv, packages
  # This wraps the existing home/core modules
  flake.modules.homeManager.core = _: {
    imports = [
      ./_hm-core/direnv.nix
      ./_hm-core/git.nix
      ./_hm-core/neovim.nix
      ./_hm-core/packages.nix
      ./_hm-core/starship.nix
      ./_hm-core/zsh.nix
      ./_hm-core/nixos.nix
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

  # Server NixOS module - base + essentials
  flake.modules.nixos.server = _: {
    imports = with inputs.self.modules.nixos; [
      auto-rebuild
      base
      sops
      ssh
    ];

    # Home-manager modules common to all servers
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
    ];
  };
}
