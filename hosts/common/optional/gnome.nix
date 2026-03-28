{ pkgs, ... }:
{
  services.gnome.gcr-ssh-agent.enable = false;
  services = {
    displayManager.gdm = {
      enable = true;
      wayland = true;
    };
    desktopManager.gnome = {
      enable = true;
    };
    xserver = {
      enable = true;
      xkb = {
        layout = "us";
        variant = "";
      };

    };
  };
  environment.systemPackages = with pkgs; [
    gnomeExtensions.user-themes
    gnomeExtensions.appindicator
    gnomeExtensions.xremap # Required for xremap to detect focused application
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
