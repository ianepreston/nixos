# Luna - Migrated to dendritic pattern
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

    # ========== New Dendritic Modules ==========
    inputs.self.modules.nixos.workstation # includes base + HM core
    inputs.self.modules.nixos.gnome # includes HM gnome
    inputs.self.modules.nixos.ssh # includes HM ssh
    inputs.self.modules.nixos.sops # includes HM sops

    # ========== Optional NixOS Configs (not yet converted) ==========
    (map customLib.relativeToRoot [
      "hosts/common/optional/services/printing.nix"
      "hosts/common/optional/audio.nix"
      "hosts/common/optional/docker.nix"
      "hosts/common/optional/flatpak.nix"
      "hosts/common/optional/gaming.nix"
      "hosts/common/optional/keyd.nix"
      "hosts/common/optional/nvidia-gtx1060.nix"
      "hosts/common/optional/obsidian.nix"
      "hosts/common/optional/smbclient.nix"
      "hosts/common/optional/themes.nix"
      "hosts/common/optional/xreal-headset.nix"
      "hosts/common/optional/zsa-keeb.nix"
    ])
  ];

  # ========== HM-only modules (not yet converted) ==========
  # These are added via sharedModules since they don't have NixOS counterparts
  home-manager.sharedModules = [
    (
      { customLib, ... }:
      {
        imports = map customLib.relativeToRoot [
          "home/optional/browser.nix"
          "home/optional/vibes.nix"
          "home/optional/moonlight.nix"
          "home/optional/comms.nix"
          "home/optional/media.nix"
        ];
      }
    )
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
