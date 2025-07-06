{ pkgs, customLib, ... }:

{

  stylix.enable = true;
  stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-latte.yaml";

  # Don't forget to apply wallpaper

  stylix.image = customLib.relativeToRoot "assets/wallpaper_oil_landscape.jpg";
  stylix.polarity = "light";

  stylix.fonts = {
    monospace = {
      package = pkgs.nerd-fonts.fira-code;
      name = "Firacode Nerd Font Mono";
    };
    emoji = {
      package = pkgs.noto-fonts-emoji;
      name = "Noto Color Emoji";
    };
    sansSerif = {
      package = pkgs.source-sans;
      name = "Source Sans 3";
    };
    serif = {
      package = pkgs.source-serif;
      name = "Source Serif 4";
    };
  };

}
