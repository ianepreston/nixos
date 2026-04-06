# RGB Lighting - Simple Aspect
# OpenRGB with i2c support for AMD motherboard
#
# Note: The motherboard (Gigabyte B650M) uses HID (IT5701 controller at /dev/hidraw*)
# rather than SMBus for RGB control. SMBus is used by RAM sticks.
#
# See openrgb.md for investigation notes on motherboard RGB not responding.
{ inputs, ... }:
{
  flake.modules.nixos.rgb =
    {
      pkgs,
      hostSpec,
      ...
    }:
    let
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };
    in
    {
      services.hardware.openrgb = {
        enable = true;
        package = pkgsUnstable.openrgb-with-all-plugins;
        motherboard = "amd";
      };
      hardware.i2c.enable = true;

      # Use Zen kernel which has the OpenRGB SMBus patch included
      boot = {
        kernelPackages = pkgs.linuxPackages_zen;
        kernelModules = [
          "i2c-dev"
          "i2c-piix4"
        ];
        kernelParams = [ "acpi_enforce_resources=lax" ];
      };
      users.users.${hostSpec.username}.extraGroups = [ "i2c" ];
    };
}
