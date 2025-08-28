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
  environment.systemPackages = with pkgs; [
    gnomeExtensions.user-themes
    gnomeExtensions.appindicator
    wl-clipboard
    xclip

  ];
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
