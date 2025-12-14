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
    };
  };

  home.sessionVariables = {
    TERM = "ghostty";
  };
}
