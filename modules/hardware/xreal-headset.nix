# XReal Headset - Simple Aspect
# udev rules for firmware updates + Chrome for web updater
_: {
  flake.modules.nixos.xreal-headset =
    { pkgs, ... }:
    {
      services.udev.extraRules = ''
        # Rule for Xreal Air firmware updates
        SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3318", MODE="0666", GROUP="plugdev"
      '';
      environment.systemPackages = with pkgs; [
        google-chrome
        usbutils
      ];
    };
}
