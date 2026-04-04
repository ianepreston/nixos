# User config applicable to both nixos and darwin
{
  inputs,
  pkgs,
  hostSpec,
  customLib,
  lib,
  ...
}:
{
  users.users.${hostSpec.username} = {
    name = hostSpec.username;
    shell = pkgs.zsh; # default shell
    inherit (hostSpec) home;

  };

  # No matter what environment we are in we want these tools
  programs.zsh.enable = true;
  # environment.systemPackages = [
  #   pkgs.just
  #   pkgs.rsync
  # ];
}
# Import the user's personal/home configurations, unless the environment is minimal
// lib.optionalAttrs (inputs ? "home-manager") {
  home-manager = {
    backupFileExtension = "hm-backup";
    extraSpecialArgs = {
      inherit
        pkgs
        inputs
        hostSpec
        customLib
        ;
    };
    users.${hostSpec.username}.imports = lib.flatten (
      lib.optional (!hostSpec.isMinimal) [
        (
          { config, ... }:
          import (customLib.relativeToRoot "home/${hostSpec.username}/${hostSpec.hostNameFile}.nix") {
            inherit
              pkgs
              inputs
              config
              lib
              customLib
              hostSpec
              ;
          }
        )
      ]
    );
  };
}
