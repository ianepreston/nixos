_: {
  programs.starship = {
    enable = true;
    # Disable auto-integration - we'll do it manually with a graceful fallback in zsh.nix
    enableZshIntegration = false;
    settings = {
      git_metrics.disabled = false;
      git_status = {
        disabled = false;
        ahead = "⇡\${count}";
        diverged = "⇕⇡\${ahead_count}⇣\${behind_count}";
        behind = "⇣\${count}";
      };
      container.disabled = false;
      kubernetes.disabled = false;
    };
  };
}
