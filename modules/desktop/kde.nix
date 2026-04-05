# KDE - Simple Aspect
# KDE Plasma 6 desktop environment
_: {
  flake.modules.nixos.kde = _: {
    services.xserver = {
      enable = true;
      xkb = {
        layout = "us";
        variant = "";
      };
      displayManager.sddm = {
        enable = true;
        wayland.enable = true;
      };
      desktopManager.plasma6 = {
        enable = true;
      };
    };
  };
}
