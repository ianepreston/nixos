{ config, lib, ... }:
{
  # Combined with modesetting.enabled in nvidia this fixes artifact issues with external monitor
  boot.kernelParams = [ "nvidia-drm.modeset=1" ];
  powerManagement.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    # GTX 1060 is too old to use the open source drivers
    open = false;
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    powerManagement = {
      enable = true; # See if this helps with sleep/wake issues
      finegrained = true; # Also trying this for sleep/wake. Should toggle this if the issue persists
    };
    prime = {
      offload = {
        enable = true; # Enable PRIME offloading to integrated GPU
        enableOffloadCmd = lib.mkIf config.hardware.nvidia.prime.offload.enable true; # Provides `nvidia-offload` command.
      };
      sync.enable = false; # Always use nvidia GPU - supposed to be better for clamshell
      intelBusId = "PCI:00:02:0";
      nvidiaBusId = "PCI:01:00:0";
    };
  };
}
