# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  lib,
  customLib,
  pkgs,
  inputs,
  ...
}:

{
  hardware.nvidia = {
    # GTX 1060 is too old to use the open source drivers
    open = false;
    powerManagement.enable = true; # See if this helps with sleep/wake issues
    powerManagement.finegrained = false; # Also trying this for sleep/wake. Should toggle this if the issue persists
    # PRIME offloading means most stuff renders on integrated GPU
    prime.offload.enable = true; # Enable PRIME offloading to integrated GPU
    # prime.sync.enable = true; # Always use nvidia GPU
    prime.intelBusId = "PCI:00:02:0";
    prime.nvidiaBusId = "PCI:01:00:0";

  };
  imports = lib.flatten [
    #
    # ========== Hardware ==========
    #
    ./hardware-configuration.nix
    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-gpu-intel
    inputs.hardware.nixosModules.common-gpu-nvidia

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
      "hosts/common/optional/discordflatpak.nix"
      "hosts/common/optional/gnome.nix" # WM
      "hosts/common/optional/themes.nix"
      "hosts/common/optional/zsa-keeb.nix"
    ])
    inputs.stylix.nixosModules.stylix
  ];
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "luna"; # Define your hostname.
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
