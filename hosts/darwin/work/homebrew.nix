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
      "databricks/tap"
    ];
    brews = [
      "awscli"
      "azure-cli"
      "node"
      "uv"
      "sf"
      "databricks/tap/databricks"
      "hashicorp/tap/terraform"
    ];
    casks = [
      "ghostty"
      "obsidian"
      "gcloud-cli"
    ];
  };
  # Rest of my zsh config shouldn't conflict with this.
  programs.zsh.interactiveShellInit = ''
    eval "$(/opt/homebrew/bin/brew shellenv)"
  '';
}
