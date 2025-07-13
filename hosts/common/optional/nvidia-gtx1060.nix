{ config, ... }:
{
  # Hopefully will help with display artifacts when gaming on external monitor
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
      finegrained = false; # Also trying this for sleep/wake. Should toggle this if the issue persists
    };
    prime = {
      offload.enable = false; # Enable PRIME offloading to integrated GPU
      sync.enable = true; # Always use nvidia GPU - supposed to be better for clamshell
      intelBusId = "PCI:00:02:0";
      nvidiaBusId = "PCI:01:00:0";
    };
  };
}
