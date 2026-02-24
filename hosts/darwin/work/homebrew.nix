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
}
