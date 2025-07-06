{ inputs, pkgs, ... }:
let
  tuigreet = "${pkgs.greetd.tuigreet}/bin/tuigreet";
in
{
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${tuigreet} --time --remember --cmd Hyprland";
      user = "ipreston";
    };
  };
  programs.hyprland = {
    enable = true;
  };
}
