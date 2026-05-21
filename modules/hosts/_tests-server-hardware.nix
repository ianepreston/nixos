# Generic qemu-guest hardware config — mirrors _tests-desktop-hardware.nix
# since both run under quickemu/qemu with virtio devices. Not generated
# by nixos-generate-config because the VM doesn't exist until first
# `task vm:up`; this hand-rolled file is sufficient for qemu virtio +
# AHCI + USB HID, which is all quickemu exposes.
{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ohci_pci"
    "ehci_pci"
    "virtio_pci"
    "ahci"
    "usbhid"
    "sr_mod"
    "virtio_blk"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
