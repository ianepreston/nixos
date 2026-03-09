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

      # Unified keybindings — match macOS physical keys
      # Super+c/v for copy/paste (cmd on Voyager = Super on Linux)
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
