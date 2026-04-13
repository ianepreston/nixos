# ISO - Recovery/installer image
# Self-contained: doesn't use workstation profile or old host patterns.
# Provides a minimal environment with SSH access for recovery.
{ inputs, hostSpecs, ... }:
let
  hostSpec = hostSpecs.iso;
  pubKeys = builtins.attrValues (
    builtins.mapAttrs (name: _: builtins.readFile ../profiles/_ssh-keys/${name}) (
      builtins.readDir ../profiles/_ssh-keys
    )
  );
in
{
  flake.nixosConfigurations.iso = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs hostSpec;
    };
    modules = [
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
      inputs.home-manager.nixosModules.home-manager
      inputs.self.modules.nixos.minimal-user
      (
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          # ========== User ==========
          users.users.${hostSpec.username} = {
            name = hostSpec.username;
            shell = pkgs.zsh;
            inherit (hostSpec) home;
            openssh.authorizedKeys.keys = pubKeys;
          };
          users.extraUsers.root = {
            inherit (config.users.users.${hostSpec.username}) hashedPassword;
            initialHashedPassword = lib.mkForce null;
            openssh.authorizedKeys.keys = config.users.users.${hostSpec.username}.openssh.authorizedKeys.keys;
          };

          programs.zsh.enable = true;

          # ========== Home-Manager ==========
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "hm-backup";
            extraSpecialArgs = {
              inherit inputs hostSpec;
            };
            users.${hostSpec.username} = { };
            sharedModules = [
              inputs.self.modules.homeManager.core
              {
                home = {
                  inherit (hostSpec) username;
                  homeDirectory = hostSpec.home;
                  stateVersion = "23.05";
                };
              }
            ];
          };

          # ========== ISO Config ==========
          environment.etc.isoBuildTime = {
            text =
              if builtins ? currentTime then
                lib.readFile "${pkgs.runCommand "timestamp" {
                  env.when = builtins.currentTime;
                } "echo -n `date -d @$when  +%Y-%m-%d_%H-%M-%S` > $out"}"
              else
                "pure-eval";
          };

          programs.bash.promptInit = ''
            export PS1="\\[\\033[01;32m\\]\\u@\\h-$(cat /etc/isoBuildTime)\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\$ "
          '';

          isoImage.squashfsCompression = "zstd -Xcompression-level 3";

          nixpkgs = {
            hostPlatform = lib.mkDefault "x86_64-linux";
            config.allowUnfree = true;
          };

          nix = {
            settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
            extraOptions = "experimental-features = nix-command flakes";
          };

          services = {
            qemuGuest.enable = true;
            openssh = {
              ports = [ 22 ];
              settings.PermitRootLogin = lib.mkForce "yes";
            };
          };

          boot = {
            kernelPackages = pkgs.linuxPackages_latest;
            supportedFilesystems = lib.mkForce [
              "btrfs"
              "vfat"
            ];
          };

          networking.hostName = "iso";

          systemd = {
            services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];
            targets = {
              sleep.enable = false;
              suspend.enable = false;
              hibernate.enable = false;
              hybrid-sleep.enable = false;
            };
          };
        }
      )
    ];
  };
}
