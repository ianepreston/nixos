{
  programs.ghostty = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      theme = "catppuccin-latte";
      font-family = "monospace";
      font-size = "11";
      # background-opacity = "0.85";
    };
  };

  home.sessionVariables = {
    TERM = "ghostty";
  };
}
