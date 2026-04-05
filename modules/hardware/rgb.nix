# RGB Lighting - Simple Aspect
# OpenRGB with i2c support for AMD motherboard
{ inputs, ... }:
{
  flake.modules.nixos.rgb =
    { pkgs, hostSpec, ... }:
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
      boot.kernelModules = [
        "i2c-dev"
        "i2c-piix4"
        "i2c-mux"
        "i2c-designware-platform"
      ];
      boot.kernelParams = [ "acpi_enforce_resources=lax" ];
      users.users.${hostSpec.username}.extraGroups = [ "i2c" ];
    };
}
