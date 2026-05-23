# XReal Headset - Simple Aspect
# udev rules for firmware updates + Chrome for web updater
_: {
  flake.modules.nixos.xreal-headset =
    { pkgs, ... }:
    {
      services.udev.extraRules = ''
        # Allow Chrome WebHID access for Xreal firmware updates
        SUBSYSTEM=="usb", ATTR{idVendor}=="3318", MODE="0666", TAG+="uaccess"
        KERNEL=="hidraw*", ATTRS{idVendor}=="3318", MODE="0666", TAG+="uaccess"
        KERNEL=="ttyUSB[0-9]*", ATTRS{idVendor}=="3318", MODE="0666", TAG+="uaccess"
        KERNEL=="ttyACM[0-9]*", ATTRS{idVendor}=="3318", MODE="0666", TAG+="uaccess"
      '';
      environment.systemPackages = with pkgs; [
        google-chrome
        usbutils
      ];
    };
}
