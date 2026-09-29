# NVIDIA GTX 1060 - Simple Aspect
# Proprietary drivers with PRIME offload for Intel+NVIDIA laptop
#
# The driver branch is pinned to the 580 LTSB line on purpose. The GTX 1060
# is Pascal (GP106M), and NVIDIA dropped Maxwell/Pascal/Volta from the 590+
# mainline branch — a 595 driver loads, prints "The NVIDIA GeForce GTX 1060
# GPU installed in this system is supported through the NVIDIA 580.xx Legacy
# drivers", refuses the card, and unloads. Nothing fails: the desktop stays
# up and every GL/Vulkan client silently renders on the Intel iGPU instead.
# That is exactly what a `nvidiaPackages.latest` pin did here for 12 boots
# over 47 days (#767).
#
# So do not "helpfully" restore `latest`/`stable`/`production`: those are
# moving selectors, and this card's architecture is fixed. 580 is an LTSB
# branch supported until Aug 2028; after that the card needs nouveau/NVK or
# replacing.
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
        # `nvidiaPackages.legacy_580`, not `linuxPackages.nvidia_x11_legacy580`
        # — nixpkgs never added the 580 legacy entry to
        # top-level/linux-kernels.nix, so only this attribute exists.
        package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
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
