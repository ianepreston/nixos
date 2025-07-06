{
  pkgs,
  config,
  lib,
  hostSpec,
  ...
}:

{

  imports = [
    ./wlogout.nix
    ./binds.nix
  ];
  # Switch to ghostty eventually but EM and hyprland default use kitty
  programs.kitty.enable = true;
  wayland.windowManager.hyprland = {
    enable = true;
    # https://wiki.hypr.land/Nix/Hyprland-on-Home-Manager/#using-the-home-manager-module-with-nixos
    package = null;
    portalPackage = null;
    # https://wiki.hypr.land/Nix/Hyprland-on-Home-Manager/#programs-dont-work-in-systemd-services-but-do-on-the-terminal
    systemd.variables = [ "--all" ];
    settings = {
      env = [
        "NIXOS_OZONE_WL, 1" # for ozone-based and electron apps to run on wayland
        "MOZ_ENABLE_WAYLAND, 1" # for firefox to run on wayland
        "MOZ_WEBRENDER, 1" # for firefox to run on wayland
        "XDG_SESSION_TYPE,wayland"
        "WLR_NO_HARDWARE_CURSORS,1"
        "WLR_RENDERER_ALLOW_SOFTWARE,1"
        "QT_QPA_PLATFORM,wayland"
      ];

    };
  };
}
