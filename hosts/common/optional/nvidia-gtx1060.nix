{ config, lib, ... }:
{
  # https://discourse.nixos.org/t/black-screen-after-suspend-hibernate-with-nvidia/54341/6
  # Tried this, didn't seem to fix things
  # systemd.services."systemd-suspend" = {
  #   serviceConfig = {
  #     Environment = ''"SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false"'';
  #   };
  # };
  boot = {
    # Combined with modesetting.enabled in nvidia this fixes artifact issues with external monitor
    kernelParams = [
      "nvidia-drm.modeset=1"
      "nvidia-drm.fbdev=1"
    ];
    # https://discourse.nixos.org/t/psa-for-those-with-hibernation-issues-on-nvidia/61834
    extraModprobeConfig = ''
      options nvidia_modeset vblank_sem_control=0
    '';
  };

  powerManagement.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    # GTX 1060 is too old to use the open source drivers
    open = false;
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    powerManagement = {
      # https://wiki.archlinux.org/title/GDM#Wayland_and_the_proprietary_NVIDIA_driver
      # Use systemd to persist video memory to disk
      enable = true;
      # Requires 9th gen intel processor or greater, I have 6th in the MSI laptop
      finegrained = false;
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
