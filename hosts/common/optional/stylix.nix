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
      package = pkgs.nerd-fonts.fira-code;
      name = "Firacode Nerd Font Mono";
    };
    sansSerif = {
      package = pkgs.source-serif;
      name = "SourceSerif4";
    };
    serif = {
      package = pkgs.source-sans;
      name = "SourceSans3";
    };
  };

}
