_: {
  flake.modules.nixos.ipad =
    { pkgs, ... }:
    {
      services.usbmuxd.enable = true;
      environment.systemPackages = [
        pkgs.idevicerestore
        pkgs.libimobiledevice
        pkgs.ideviceinstaller
      ];
    };
}
