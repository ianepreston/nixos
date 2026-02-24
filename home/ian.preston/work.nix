{ ... }:
{
  imports = [
    ../core/default.nix
  ];
  xdg.configFile."ghostty/config" = {
    text = ''
      theme = Catppuccin Latte
      font-family = FiraCode Nerd Font Mono
      clipboard-read = allow
      clipboard-write = allow
      font-size = 11
    '';
  };
}
