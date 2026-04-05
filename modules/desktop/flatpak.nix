# Flatpak - Simple Aspect
# Flatpak runtime with Discord, BambuStudio, Chrome, Headlamp
_: {
  flake.modules.nixos.flatpak =
    { lib, pkgs, ... }:
    {
      xdg.portal = {
        enable = true;
        config = {
          common = {
            default = [
              "gtk"
            ];
          };
        };
        extraPortals = with pkgs; [
          xdg-desktop-portal-wlr
        ];
      };

      services.flatpak = {
        enable = true;
        remotes = lib.mkOptionDefault [
          {
            name = "flathub-beta";
            location = "https://flathub.org/beta-repo/flathub-beta.flatpakrepo";
          }
        ];
        update.auto.enable = false;
        uninstallUnmanaged = false;
        packages = [
          "com.discordapp.Discord"
          "com.bambulab.BambuStudio"
          "com.google.Chrome"
          "io.kinvolk.Headlamp"
        ];
      };
    };
}
