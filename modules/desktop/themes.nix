# Themes - Simple Aspect
# Stylix theming with Catppuccin Latte
{ inputs, ... }:
{
  flake.modules.nixos.themes =
    { pkgs, customLib, ... }:
    {
      imports = [ inputs.stylix.nixosModules.stylix ];

      stylix = {
        enable = true;
        autoEnable = false;
        targets = {
          gnome.enable = true;
          font-packages.enable = true;
          fontconfig.enable = true;
          gtk.enable = true;
        };
        base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-latte.yaml";
        image = customLib.relativeToRoot "assets/wallpaper_oil_landscape.jpg";
        polarity = "light";
        fonts = {
          monospace = {
            package = pkgs.nerd-fonts.fira-code;
            name = "Firacode Nerd Font Mono";
          };
          emoji = {
            package = pkgs.noto-fonts-color-emoji;
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
      };
    };
}
