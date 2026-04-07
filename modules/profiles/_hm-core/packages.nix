# Should probably pull some of this out to dev or whatever later
{ pkgs, ... }:
{

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    gh
    curl
    wget
    unzip
    tree
    ripgrep
    fd
    lazygit
    neofetch
    jq
    yq-go
    shellcheck
    nixfmt-rfc-style
    sops
    age
  ];

}
