{ ... }:
{
  homebrew = {
    enable = true;
    onActivation = {
      cleanup = "none";
      autoUpdate = false;
      upgrade = false;
    };
    taps = [
      "hashicorp/tap"
    ];
    brews = [
      "awscli"
      "azure-cli"
      "hashicorp/tap/terraform"
    ];
    casks = [
      "ghostty"
    ];
  };
  # Rest of my zsh config shouldn't conflict with this.
  programs.zsh.interactiveShellInit = ''
    eval "$(/opt/homebrew/bin/brew shellenv)"
  '';
}
