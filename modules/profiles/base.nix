# Base profile - core configuration for all NixOS hosts
# Replaces hosts/common/core/ with a registered module
#
# This is a flake-parts module that registers flake.modules.nixos.base
# Hosts import this module to get essential NixOS configuration
{ inputs, ... }:
{
  flake.modules.nixos.base =
    {
      config,
      lib,
      pkgs,
      hostSpec,
      ...
    }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        inputs.sops-nix.nixosModules.sops
      ];

      # ========== Core System ==========
      environment.enableAllTerminfo = true;
      hardware.enableRedistributableFirmware = true;
      nixpkgs.config.allowUnfree = true;

      # System-wide packages
      environment.systemPackages = with pkgs; [
        openssh
        vim
        git
        curl
        wget
      ];

      # ========== Localization ==========
      i18n.defaultLocale = lib.mkDefault "en_CA.UTF-8";
      time.timeZone = lib.mkDefault "America/Edmonton";

      # ========== Sudo ==========
      security.sudo.extraConfig = ''
        Defaults lecture = never
        Defaults pwfeedback
        Defaults timestamp_timeout=120
        Defaults env_keep+=SSH_AUTH_SOCK
      '';

      # ========== Nix Settings ==========
      nix = {
        registry = lib.mapAttrs (_: value: { flake = value; }) inputs;
        nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;
        optimise.automatic = true;

        settings = {
          connect-timeout = 5;
          log-lines = 25;
          min-free = 128000000; # 128MB
          max-free = 1000000000; # 1GB
          trusted-users = [ "@wheel" ];
          warn-dirty = false;
          allow-import-from-derivation = true;
          experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
      };

      # ========== User & Home-Manager ==========
      users.users.${hostSpec.username} = {
        name = hostSpec.username;
        shell = pkgs.zsh;
        inherit (hostSpec) home;
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        hashedPasswordFile = config.sops.secrets."passwords/${hostSpec.username}".path;
      };

      programs.zsh.enable = true;

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "hm-backup";
        extraSpecialArgs = {
          inherit inputs hostSpec;
          customLib = import ../../lib { inherit (inputs.nixpkgs) lib; };
        };
        # Create the user entry - sharedModules will provide the actual config
        users.${hostSpec.username} = { };
      };
    };
}
