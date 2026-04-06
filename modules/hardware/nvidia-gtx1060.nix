# NVIDIA GTX 1060 - Simple Aspect
# Proprietary drivers with PRIME offload for Intel+NVIDIA laptop
_: {
  flake.modules.nixos.nvidia-gtx1060 =
    { config, lib, ... }:
    {
      boot = {
        kernelParams = [
          "nvidia-drm.modeset=1"
          "nvidia-drm.fbdev=1"
        ];
        extraModprobeConfig = ''
          options nvidia_modeset vblank_sem_control=0
        '';
      };

      powerManagement.enable = true;
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.graphics.enable = true;
      hardware.nvidia = {
        open = false;
        modesetting.enable = true;
        package = config.boot.kernelPackages.nvidiaPackages.latest;
        powerManagement = {
          enable = true;
          finegrained = false;
        };
        prime = {
          offload = {
            enable = true;
            enableOffloadCmd = lib.mkIf config.hardware.nvidia.prime.offload.enable true;
          };
          sync.enable = false;
          intelBusId = "PCI:00:02:0";
          nvidiaBusId = "PCI:01:00:0";
        };
      };
    };
}
