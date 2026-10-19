# RGB Lighting - Simple Aspect
# OpenRGB with i2c support for AMD motherboard
#
# Note: The motherboard (Gigabyte B650M) uses HID (IT5702 controller at /dev/hidraw*)
# rather than SMBus for RGB control. SMBus is used by RAM sticks.
#
# The case strip, AIO and fans hang off a Skytech ARGB hub fed by the board's D_LED
# header. The hub only follows D_LED in motherboard-sync mode: the case reset button
# is wired to the hub, tap cycles its built-in effects, hold ~3s to switch to sync.
# See https://github.com/ianepreston/nixos/issues/111.
#
# The startup profile lives in /var/lib/OpenRGB/profiles/terra.json and is saved
# from the GUI against the running server. It carries the D_LED zone size, which
# defaults to 0 (no pixel data sent).
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
        startupProfile = "terra";
      };
      hardware.i2c.enable = true;
      boot = {
        kernelModules = [
          "i2c-dev"
          "i2c-piix4"
        ];
        kernelParams = [ "acpi_enforce_resources=lax" ];
      };
      users.users.${hostSpec.username}.extraGroups = [ "i2c" ];
    };
}
