# sops-nix - Multi Context Aspect
# Consolidates NixOS + home-manager secrets management
{ inputs, ... }:
let
  sopsFile = builtins.toString inputs.nix-secrets + "/sops/shared.yaml";
  sopsFolder = builtins.toString inputs.nix-secrets + "/sops";
in
{
  # NixOS-level sops configuration
  flake.modules.nixos.sops =
    {
      config,
      lib,
      hostSpec,
      ...
    }:
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      sops = {
        defaultSopsFile = sopsFile;
        validateSopsFiles = false;
        age = {
          # Automatically import host SSH keys as age keys
          sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        };
      };

      # Secrets for user creation and home-manager bootstrap
      sops.secrets = lib.mkMerge [
        {
          # Age key for home-manager sops (bootstrapped from host key)
          "keys/age" = {
            owner = config.users.users.${hostSpec.username}.name;
            inherit (config.users.users.${hostSpec.username}) group;
            path = "${hostSpec.home}/.config/sops/age/keys.txt";
          };
          # User password for creating the user
          "passwords/${hostSpec.username}" = {
            inherit sopsFile;
            neededForUsers = true;
          };
        }
      ];

      # Fix ownership of .config/sops/age directory
      system.activationScripts.sopsSetAgeKeyOwnership =
        let
          ageFolder = "${hostSpec.home}/.config/sops/age";
          user = config.users.users.${hostSpec.username}.name;
          inherit (config.users.users.${hostSpec.username}) group;
        in
        ''
          mkdir -p ${ageFolder} || true
          chown -R ${user}:${group} ${hostSpec.home}/.config
        '';

      # Automatically include home-manager sops config for all users
      home-manager.sharedModules = [
        inputs.self.modules.homeManager.sops
      ];
    };

  # Home-manager-level sops configuration
  flake.modules.homeManager.sops =
    {
      config,
      lib,
      hostSpec,
      ...
    }:
    let
      inherit (config.home) homeDirectory;
    in
    {
      imports = [ inputs.sops-nix.homeManagerModules.sops ];

      sops = {
        age.keyFile = "${homeDirectory}/.config/sops/age/keys.txt";
        defaultSopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        validateSopsFiles = false;
        secrets = lib.mkMerge [
          {
            "ssh/ed25519" = {
              path = "${homeDirectory}/.ssh/id_ed25519";
            };
          }
        ];
      };
    };
}
