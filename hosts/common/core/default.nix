{
  config,
  customLib,
  lib,
  inputs,
  pkgs,
  ...
}:
let
  platform = "nixos"; # Can be extended later to handle darwin or other linux when I need it
  platformModules = "${platform}Modules";
in
{
  imports = lib.flatten [
    inputs.home-manager.${platformModules}.home-manager
    inputs.sops-nix.${platformModules}.sops
    (map customLib.relativeToRoot [
      "modules/common"
      "hosts/common/core/${platform}.nix"
      "hosts/common/core/ssh.nix"
      "hosts/common/core/sops.nix"
      "hosts/common/users/primary"
      "hosts/common/users/primary/${platform}.nix"
    ])
  ];
  #
  # ========== Core Host Specifications ==========
  #
  hostSpec = {
    username = "ipreston";
    handle = "ianepreston";
    inherit (inputs.nix-secrets)
      email
      userFullName
      ;
  };
  # System-wide packages, in case we log in as root
  environment.systemPackages = [ pkgs.openssh ];

  #
  # ========== Nix Nix Nix ==========
  #
  nix = {
    # This will add each flake input as a registry
    # To make nix3 commands consistent with your flake
    registry = lib.mapAttrs (_: value: { flake = value; }) inputs;

    # This will add your inputs to the system's legacy channels
    # Making legacy nix commands consistent as well, awesome!
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;

    settings = {
      # See https://jackson.dev/post/nix-reasonable-defaults/
      connect-timeout = 5;
      log-lines = 25;
      min-free = 128000000; # 128MB
      max-free = 1000000000; # 1GB

      trusted-users = [ "@wheel" ];
      # Deduplicate and optimize nix store
      auto-optimise-store = true;
      warn-dirty = false;

      allow-import-from-derivation = true;

      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };

}
