# Luna - MSI GS43VR laptop
# https://www.msi.com/Laptop/GS43VR-6RE-Phantom-Pro/Specification
{
  lib,
  pkgs,
  inputs,
  customLib,
  ...
}:
{
  imports = lib.flatten [
    # ========== Hardware ==========
    ./hardware-configuration.nix
    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-gpu-intel
    inputs.hardware.nixosModules.common-gpu-nvidia

    # ========== Disk Layout ==========
    inputs.disko.nixosModules.disko
    (customLib.relativeToRoot "hosts/common/disks/luna.nix")

    # ========== Dendritic Modules ==========
    (with inputs.self.modules.nixos; [
      workstation # includes base + HM core
      gnome # includes HM gnome
      ssh # includes HM ssh
      sops # includes HM sops
      audio
      docker
      flatpak
      gaming
      keyd
      nvidia-gtx1060
      obsidian
      printing
      smbclient
      themes
      xreal-headset
      zsa-keeb
    ])
  ];

  # ========== HM-only modules ==========
  home-manager.sharedModules = with inputs.self.modules.homeManager; [
    browser
    vibes
    moonlight
    comms
    media
  ];

  # ========== Boot ==========
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelPackages = pkgs.linuxPackages_latest;
  };

  # ========== Networking ==========
  networking = {
    hostName = "luna";
    networkmanager.enable = true;
  };

  system.stateVersion = "25.05";
}
