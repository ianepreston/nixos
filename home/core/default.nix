{
  # config,
  lib,
  hostSpec,
  ...
}:
let
  platform = if hostSpec.isDarwin then "darwin" else "nixos";
in
{
  imports = [
    ./direnv.nix
    ./git.nix
    ./neovim.nix
    ./packages.nix
    ./starship.nix
    ./zsh.nix
    ./${platform}.nix
  ];
  programs.home-manager.enable = true;
  home = {
    username = lib.mkDefault hostSpec.username;
    homeDirectory = builtins.trace "DEBUG ${hostSpec.home}" lib.mkDefault hostSpec.home;
    stateVersion = lib.mkDefault "23.05";
    # sessionPath = [
    #   "$HOME/.local/bin"
    #   "$HOME/scripts/talon_scripts"
    # ];
    sessionVariables = {
      FLAKE = "$HOME/nixos";
      SHELL = "zsh";
      # TERM = "kitty";
      # TERMINAL = "kitty";
      VISUAL = "nvim";
      EDITOR = "nvim";
      # MANPAGER = "batman"; # see ./cli/bat.nix
    };
    preferXdgDirectories = true; # whether to make programs use XDG directories whenever supported

  };

}
