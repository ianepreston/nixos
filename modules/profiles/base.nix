# Base profile - core configuration for all NixOS hosts
# Replaces hosts/common/core/ with a registered module
#
# This is a flake-parts module that registers flake.modules.nixos.base
# Hosts import this module to get essential NixOS configuration
{ inputs, ... }:
let
  pubKeys = builtins.attrValues (
    builtins.mapAttrs (name: _: builtins.readFile ./_ssh-keys/${name}) (builtins.readDir ./_ssh-keys)
  );
in
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
      security.sudo.wheelNeedsPassword = false;

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
      users.mutableUsers = false;
      users.users.${hostSpec.username} = {
        name = hostSpec.username;
        shell = pkgs.zsh;
        inherit (hostSpec) home;
        isNormalUser = true;
        hashedPasswordFile = config.sops.secrets."passwords/${hostSpec.username}".path;
        description = hostSpec.userFullName;
        openssh.authorizedKeys.keys = pubKeys;
        extraGroups =
          let
            ifTheyExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
          in
          lib.flatten [
            "wheel"
            (ifTheyExist [
              "audio"
              "video"
              "docker"
              "git"
              "networkmanager"
              "plugdev"
              "scanner"
              "lp"
              "render"
            ])
          ];
      };

      programs.zsh.enable = true;
      programs.git.enable = true;

      # Create ssh sockets directory
      systemd.tmpfiles.rules =
        let
          user = config.users.users.${hostSpec.username}.name;
          inherit (config.users.users.${hostSpec.username}) group;
        in
        [
          "d /home/${hostSpec.username}/.ssh 0750 ${user} ${group} -"
          "d /home/${hostSpec.username}/.ssh/sockets 0750 ${user} ${group} -"
        ];

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "hm-backup";
        extraSpecialArgs = {
          inherit inputs hostSpec;
        };
        # Create the user entry - sharedModules will provide the actual config
        users.${hostSpec.username} = { };
      };
    };
}
