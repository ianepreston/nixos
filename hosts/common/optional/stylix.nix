{ pkgs, lib, ... }:

{

  stylix.enable = true;
  stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-latte.yaml";

  # Don't forget to apply wallpaper

  stylix.image = lib.custom.relativeToRoot "assets/wallpaper_oil_landscape.jpg";
  stylix.polarity = "light";

  # stylix.fonts = {
  #   monospace = {
  #     package = pkgs.nerd-fonts.fira-mono;
  #     name = "Firacode Nerd Font";
  #   };
  #   sansSerif = {
  #     package = pkgs.dejavu_fonts;
  #     name = "DejaVu Sans";
  #   };
  #   serif = {
  #     package = pkgs.dejavu_fonts;
  #     name = "DejaVu Serif";
  #   };
  # };
  #
}
