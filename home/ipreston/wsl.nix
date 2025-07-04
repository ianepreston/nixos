{
  config,
  pkgs,
  lib,
  inputs,
  outputs,
  ...
}:
{
  imports = [
    ../../modules/common/host-spec.nix
    ../core/default.nix
    ../optional/wsl.nix
  ];
  config.hostSpec = {
    username = "ipreston";
    home = "/home/ipreston";
    handle = "ianepreston";
    inherit (inputs.nix-secrets)
      email
      userFullName
      ;
  };
}
