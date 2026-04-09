# Homebrew - Simple Aspect
# Base Homebrew configuration with common packages for darwin hosts
_: {
  flake.modules.darwin.homebrew = _: {
    homebrew = {
      enable = true;
      onActivation = {
        cleanup = "none";
        autoUpdate = false;
        upgrade = false;
      };
      brews = [
        "node"
        "uv"
        "openjdk@17"
      ];
      casks = [
        "ghostty"
        "obsidian"
        "hammerspoon"
      ];
    };
    # Rest of zsh config shouldn't conflict with this.
    programs.zsh.interactiveShellInit = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '';
  };
}
