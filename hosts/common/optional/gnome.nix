{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    xkb = {
      layout = "us";
      variant = "";
    };
    displayManager.gdm = {
      enable = true;
      wayland = true;
    };
    desktopManager.gnome = {
      enable = true;
    };
  };
  environment.gnome.excludePackages = (
    with pkgs;
    [
      atomix
      baobab
      epiphany
      geary
      gedit
      gnome-contacts
      gnome-calendar
      gnome-maps
      gnome-music
      gnome-photos
      gnome-tour
      hitori
      iagno
      simple-scan
      tali
      yelp
    ]
  );
}
