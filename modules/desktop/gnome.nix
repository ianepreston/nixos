# GNOME Desktop - Multi Context Aspect
# Consolidates NixOS + home-manager GNOME configuration
# When a host imports flake.modules.nixos.gnome, the HM config is automatically included
{ inputs, ... }:
{
  # NixOS-level GNOME configuration
  flake.modules.nixos.gnome =
    { pkgs, ... }:
    {
      services = {
        gnome.gcr-ssh-agent.enable = false;
        displayManager.gdm = {
          enable = true;
          wayland = true;
        };
        desktopManager.gnome.enable = true;
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
        wl-clipboard
        xclip
      ];

      environment.gnome.excludePackages = with pkgs; [
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
      ];

      # Automatically include home-manager GNOME config for all users
      home-manager.sharedModules = [
        inputs.self.modules.homeManager.gnome
      ];
    };

  # Home-manager-level GNOME configuration
  flake.modules.homeManager.gnome = _: {
    imports = [
      ./_gnome/dconf.nix
      ./_gnome/cursor.nix
      ./_gnome/ghostty.nix
      ./_gnome/stylix.nix
    ];
  };
}
