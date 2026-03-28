{
  programs.ghostty = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      theme = "Catppuccin Latte";
      font-family = "monospace";
      clipboard-read = "allow";
      clipboard-write = "allow";
      font-size = "11";
      # background-opacity = "0.85";

      # macOS parity: super+key for all common shortcuts (D key on Voyager = cmd)
      # xremap excludes Ghostty so we receive raw super+key presses
      keybind = [
        "super+c=copy_to_clipboard"
        "super+v=paste_from_clipboard"
        "super+t=new_tab"
        "super+w=close_surface"
        "super+n=new_window"
      ];
    };
  };

  home.sessionVariables = {
    TERM = "ghostty";
  };
}
