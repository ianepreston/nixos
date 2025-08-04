# Home level sops. See hosts/common/optiona/sops.nix for hosts level
{
  inputs,
  config,
  lib,
  hostSpec,
  ...
}:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
  homeDirectory = config.home.homeDirectory;
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
}
