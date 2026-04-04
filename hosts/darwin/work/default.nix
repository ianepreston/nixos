{
  lib,
  customLib,
  inputs,
  hostSpec,
  ...
}:

{
  system.primaryUser = hostSpec.username;
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
    ./homebrew.nix
    ./system-settings.nix
    ./yubikey.nix
  ];

  networking.hostName = inputs.nix-secrets.workvm_hostname;
  nixpkgs.hostPlatform = "aarch64-darwin";
  nix.enable = false; # let determinate installer manage this

  system.stateVersion = 6;

}
