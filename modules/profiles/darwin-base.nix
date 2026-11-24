# Darwin base profile - core configuration for all Darwin hosts
# Parallel to base.nix for NixOS hosts
#
# This is a flake-parts module that registers flake.modules.darwin.base
{ inputs, ... }:
{
  flake.modules.darwin.base =
    {
      config,
      lib,
      pkgs,
      hostSpec,
      ...
    }:
    {
      imports = [
        inputs.home-manager.darwinModules.home-manager
        inputs.sops-nix.darwinModules.sops
      ];

      # ========== Core System ==========
      nixpkgs.config.allowUnfree = true;

      environment.systemPackages = with pkgs; [
        openssh
        vim
        git
        curl
        wget
        tmux
      ];

      # ========== User & Shell ==========
      users.users.${hostSpec.username} = {
        name = hostSpec.username;
        shell = pkgs.zsh;
        inherit (hostSpec) home;
      };

      programs.zsh.enable = true;

      # Pinned nix-darwin applies launchd.user.envVariables only on activation,
      # not at login. Reapply them in the GUI session after each reboot.
      launchd.user.agents.session-environment = lib.mkIf (config.launchd.user.envVariables != { }) {
        script = ''
          set -e
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: value: "/bin/launchctl setenv ${lib.escapeShellArg name} ${lib.escapeShellArg value}"
            ) config.launchd.user.envVariables
          )}
        '';
        serviceConfig = {
          RunAtLoad = true;
          LimitLoadToSessionType = "Aqua";
        };
      };

      # ========== Home-Manager ==========
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "hm-backup";
        extraSpecialArgs = {
          inherit inputs hostSpec;
        };
        users.${hostSpec.username} = { };
        sharedModules = with inputs.self.modules.homeManager; [
          core
          neovim
          {
            home = {
              inherit (hostSpec) username;
              homeDirectory = hostSpec.home;
              stateVersion = "23.05";
            };
          }
        ];
      };
    };
}
