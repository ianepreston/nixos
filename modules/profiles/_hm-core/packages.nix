{ pkgs, inputs, ... }:
let
  pkgsUnstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (pkgs) config;
  };
in
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
    pkgsUnstable.prek
  ];

}
