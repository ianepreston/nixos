# NVIDIA RTX 5080 - Simple Aspect
# Open-source drivers when available, proprietary fallback
_: {
  flake.modules.nixos.nvidia-rtx5080 =
    { lib, config, ... }:
    let
      nvidiaPackage = config.hardware.nvidia.package;
    in
    {
      services.xserver.videoDrivers = lib.mkDefault [ "nvidia" ];
      hardware = {
        graphics.enable = true;
        nvidia = {
          open = lib.mkOverride 990 (nvidiaPackage ? open && nvidiaPackage ? firmware);
          package = config.boot.kernelPackages.nvidiaPackages.stable;
          powerManagement.enable = true;
          modesetting.enable = true;
        };
      };
      systemd.services = {
        "nvidia-suspend".enable = false;
        "nvidia-resume".enable = false;
        "nvidia-hibernate".enable = false;
      };
    };
}
