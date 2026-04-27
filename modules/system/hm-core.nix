# Core home-manager module - git, zsh, starship, neovim, direnv, packages
# Shared across server, workstation, and darwin profiles.
#
# Registers flake.modules.homeManager.core with platform-aware imports
# (Darwin vs NixOS) selected via hostSpec.isDarwin.
_: {
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
}
