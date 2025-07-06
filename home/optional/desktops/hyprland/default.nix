{
  pkgs,
  config,
  lib,
  hostSpec,
  ...
}:

{

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
      "$mod" = "SUPER";
      bind = [
        "$mod, F, exec, firefox"
        "$mod, T, exec, kitty"
      ];

    };
  };
}
