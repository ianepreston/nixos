{ pkgs, ... }:
{
  # TODO: Break out X11 piece, maybe switch to Wayland
  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  services.xserver = {
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
