{
  lib,
  customLib,
  pkgs,
  inputs,
  ...
}:

{
  imports = lib.flatten [
    (map customLib.relativeToRoot [
      #
      # ========== Required Configs ==========
      #
      "hosts/common/core"

      #
      # ========== Optional Configs ==========
      #
    ])
  ];

  networking.hostName = inputs.nix-secrets.workvm_hostname;
  nixpkgs.hostPlatform = "aarch64-darwin";
  nix.enable = false; # let determinate installer manage this

  system.stateVersion = 6;

}
