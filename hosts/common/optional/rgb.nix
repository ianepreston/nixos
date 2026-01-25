{
  pkgs,
  ...
}:
{
  services.hardware.openrgb = {
    enable = true;
    package = pkgs.openrgb-with-all-plugins;
    motherboard = "amd";
  };
  hardware.i2c.enable = true;
  boot.kernelModules = [
    "i2c-dev"
    "i2c-piix4"
  ];
  boot.kernelParams = [ "acpi_enforce_resources=lax" ];
}
