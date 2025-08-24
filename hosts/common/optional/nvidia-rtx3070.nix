{ lib, config, ... }:
let
  nvidiaPackage = config.hardware.nvidia.package;
in
{
  # boot = {
  #   # Combined with modesetting.enabled in nvidia this fixes artifact issues with external monitor
  #   kernelParams = [
  #     "nvidia-drm.modeset=1"
  #     "nvidia-drm.fbdev=1"
  #   ];
  #   # https://discourse.nixos.org/t/psa-for-those-with-hibernation-issues-on-nvidia/61834
  #   extraModprobeConfig = ''
  #     options nvidia_modeset vblank_sem_control=0
  #   '';
  # };
  #
  # enable the open source drivers if the package supports it
  hardware.nvidia.open = lib.mkOverride 990 (nvidiaPackage ? open && nvidiaPackage ? firmware);
  services.xserver.videoDrivers = lib.mkDefault [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    # package = config.boot.kernelPackages.nvidiaPackages.latest;
    # Latest isn't building at 2025-08-18, try again later
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    powerManagement.enable = true;
  };
}
