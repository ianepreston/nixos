# Intel QuickSync - Simple Aspect
# VAAPI / oneVPL stack for Intel iGPUs (Kaby Lake / HD 630 and newer).
# Drives jellyfin's Intel QSV transcoding via /dev/dri/renderD128.
_: {
  flake.modules.nixos.intel-quicksync =
    { pkgs, ... }:
    {
      hardware.graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver # iHD VAAPI driver (gen8+)
          vpl-gpu-rt # Intel oneVPL runtime for QSV
          intel-compute-runtime # OpenCL runtime; needed for tone-mapping
        ];
      };
    };
}
