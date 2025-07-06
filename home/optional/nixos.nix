{ pkgs, ... }:

# Can only set this in NixOS. Home-manager standalone doesn't have stylix
{
  stylix.targets.neovim.enable = false;
  home.pointerCursor = {
    gtk.enable = true;
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic";
    size = 16;
  };
}
