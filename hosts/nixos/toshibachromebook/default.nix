# Toshiba Chromebook (POS but good for testing on)

{
  lib,
  customLib,
  pkgs,
  inputs,
  ...
}:

{
  imports = lib.flatten [
    #
    # ========== Hardware ==========
    #
    ./hardware-configuration.nix
    inputs.hardware.nixosModules.common-cpu-intel
    #
    # ========== Disk Layout ==========
    #
    inputs.disko.nixosModules.disko
    (customLib.relativeToRoot "hosts/common/disks/toshibachromebook.nix")

    (map customLib.relativeToRoot [
      #
      # ========== Required Configs ==========
      #
      "hosts/common/core"

      #
      # ========== Optional Configs ==========
      #
      "hosts/common/optional/services/printing.nix" # Do I need this to print to PDF? Otherwise disable
      "hosts/common/optional/audio.nix" # WM
      "hosts/common/optional/flatpak.nix"
      "hosts/common/optional/gnome.nix" # WM
      "hosts/common/optional/obsidian.nix"
      "hosts/common/optional/themes.nix"
      "hosts/common/optional/zsa-keeb.nix"
    ])
    inputs.stylix.nixosModules.stylix
  ];
  # Bootloader.
  # boot.loader.grub.enable = true;
  # boot.loader.grub.device = "/dev/sda"; # Legacy BIOS needs the whole disk for bootloader
  boot.loader.grub.extraConfig = "cros_legacy"; # More chromebook stuff

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "toshibachromebook"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Install neovim - just while I'm getting dotfiles sorted out
  # programs.neovim = {
  #   enable = true;
  #   defaultEditor = true;
  # };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?

}
