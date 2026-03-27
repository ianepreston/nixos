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

      # Copy/paste: super+c/v (D key on Voyager = cmd on macOS)
      # Tab/window management: ctrl+t/w/n (Linux-native convention)
      # keyd maps super+t/w/n → ctrl+t/w/n so D+t also works (matching macOS cmd+t)
      keybind = [
        "super+c=copy_to_clipboard"
        "super+v=paste_from_clipboard"
        "ctrl+t=new_tab"
        "ctrl+w=close_surface"
        "ctrl+n=new_window"
      ];
    };
  };

  home.sessionVariables = {
    TERM = "ghostty";
  };
}
