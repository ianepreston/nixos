# Quickemu - Simple Aspect
# Quick VM creation and management with QEMU/KVM
_: {
  flake.modules.nixos.quickemu =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        quickemu
        quickgui
      ];
      virtualisation.spiceUSBRedirection.enable = true;
    };
}
