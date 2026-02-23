{
  config,
  customLib,
  lib,
  inputs,
  pkgs,
  hostSpec,
  ...
}:
let
  platform = if hostSpec.isDarwin then "darwin" else "nixos";
  platformModules = "${platform}Modules";
in
{
  imports = lib.flatten [
    inputs.home-manager.${platformModules}.home-manager
    inputs.sops-nix.${platformModules}.sops
    (map customLib.relativeToRoot [
      "hosts/common/core/${platform}.nix"
      "hosts/common/users/primary"
      "hosts/common/users/primary/${platform}.nix"
    ])
  ];
  #
  # ========== Core Host Specifications ==========
  #
  # System-wide packages, in case we log in as root
  environment.systemPackages = [ pkgs.openssh ];


}
