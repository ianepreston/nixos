# NVIDIA server - Simple Aspect
# Headless proprietary driver wiring for a server with an NVIDIA GPU.
# Sized for Jellyfin transcoding (NVENC/NVDEC); no X server, no PRIME
# offload, no nvidia-settings.
#
# /dev/nvidia* are world-RW once the module loads, so no group change
# to server-${env} is needed for jellyfin (the consumer) to use them.
# `pkgs.jellyfin-ffmpeg` already ships NVENC/NVDEC/CUDA — no override
# required. In the jellyfin UI, pick "NVIDIA NVENC" as the hardware
# accelerator.
#
# The R555+ stable drivers (2024) lifted the consumer-card NVENC
# session cap, so the nvidia-patch overlay is no longer needed.
#
# `open = false` keeps the proprietary kernel module — works across
# every supported NVIDIA generation. Flip to `true` in the host
# config on a Turing+ card if the open module is preferred.
#
# Two non-obvious headless quirks in the upstream
# `hardware/video/nvidia.nix` module:
#
#   1. `hardware.nvidia.enabled` (gating the nouveau blacklist, kernel
#      module package, udev rules, etc.) is a readOnly computed option:
#      `lib.elem "nvidia" config.services.xserver.videoDrivers`. So we
#      set `videoDrivers = ["nvidia"]` even though there is no X server
#      — it's purely the flip that enables the rest of the wiring.
#      `services.xserver.enable` stays at its default (false).
#   2. The same module adds `nvidia`/`nvidia_modeset`/`nvidia_drm` to
#      `boot.kernelModules` only when `services.xserver.enable = true`.
#      On a headless box we add them ourselves so they actually load
#      at boot — without this, nouveau claims the GPU even with the
#      blacklist in place because the proprietary module is never
#      asked for.
_: {
  flake.modules.nixos.nvidia-server =
    { config, ... }:
    {
      services.xserver.videoDrivers = [ "nvidia" ];

      boot.kernelModules = [
        "nvidia"
        "nvidia_modeset"
        "nvidia_drm"
      ];

      hardware = {
        graphics.enable = true;
        nvidia = {
          modesetting.enable = true;
          nvidiaSettings = false;
          open = false;
          package = config.boot.kernelPackages.nvidiaPackages.stable;
        };
      };
    };
}
