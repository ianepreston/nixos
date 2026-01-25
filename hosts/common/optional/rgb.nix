{
  pkgs,
  inputs,
  ...
}:
let
  pkgsUnstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    # Optional but recommended: share config (allowUnfree, etc.)
    config = pkgs.config;
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
  ];
  boot.kernelParams = [ "acpi_enforce_resources=lax" ];
}
