{
  config,
  lib,
  hostSpec,
  ...
}:
{
  imports = [
    ./direnv.nix
    ./git.nix
    ./packages.nix
    ./starship.nix
    ./zsh.nix
  ];
  inherit hostSpec;
  service.ssh-agent.enable = true;
  programs.home-manager.enable = true;
  home = {
    username = lib.mkDefault config.hostSpec.username;
    homeDirectory = lib.mkDefault config.hostSpec.home;
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

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";
}
