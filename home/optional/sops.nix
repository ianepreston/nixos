# Home level sops. See hosts/common/optiona/sops.nix for hosts level
{
  inputs,
  config,
  lib,
  ...
}:
let
  sopsFile = builtins.toString inputs.nix-secrets + "/sops.secret.yaml";
  homeDirectory = config.home.homeDirectory;
in
{
  imports = [ inputs.sops-nix.homeManagerModules.sops ];
  sops = {
    age.keyFile = "${homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = "${sopsFile}";
    validateSopsFiles = false;
    secrets = lib.mkMerge [
      {
        "keys/ssh/luna/ed25519" = {
          path = "${homeDirectory}/.ssh/id_ed25519";
        };
        "keys/ssh/luna/rsa" = {
          path = "${homeDirectory}/.ssh/id_rsa";
        };
      }
    ];
  };
}
