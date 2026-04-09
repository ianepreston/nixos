# Ghostty - HM Simple Aspect
# Ghostty terminal configuration for darwin (installed via Homebrew)
_: {
  flake.modules.homeManager.ghostty = _: {
    home.file."Library/Application Support/com.mitchellh.ghostty/config" = {
      text = ''
        theme = Catppuccin Latte
        font-family = FiraCode Nerd Font Mono
        clipboard-read = allow
        clipboard-write = allow
        font-size = 14
      '';
    };
  };
}
