# NVIDIA GTX 1060 - Simple Aspect
# Proprietary drivers with PRIME offload for Intel+NVIDIA laptop
{ inputs, ... }:
{
  flake.modules.nixos.nvidia-gtx1060 =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # nixpkgs stable is on nvidia 595.71.05, which does not compile
      # against linux 7.x: nvidia/os-interface.c and friends call
      # strncpy()/strscpy() in ways 7.x dropped, so the module build dies
      # on `implicit declaration of function 'strncpy'`. That is what
      # forced luna off linuxPackages_latest in #512. NVIDIA fixed it in
      # 595.99.02, which is only in nixpkgs-unstable so far — take the
      # driver from there (same `production` branch stable's `latest`
      # resolves to) and keep the host on the latest kernel. Drop this
      # override once stable ships >= 595.99.02.
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };
    in
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
        package =
          (pkgsUnstable.linuxPackagesFor config.boot.kernelPackages.kernel).nvidiaPackages.production;
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
