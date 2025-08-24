# Should probably pull some of this out to dev or whatever later
{ config, pkgs, ... }:
{

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    # dig
    # whois
    # fzf
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
    # direnv
    # nix-direnv
    nixfmt-rfc-style
    keychain
    sops
    age
    coreutils
  ];

}
