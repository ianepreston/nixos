{ pkgs, ... }:
{
  # Allow firmware updates to the headset from chrome
  services.udev.extraRules = ''
    # Rule for Xreal Air firmware updates
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3318", MODE="0666", GROUP="plugdev"
  '';
  environment.systemPackages = with pkgs; [
    google-chrome
    usbutils
  ];
}
