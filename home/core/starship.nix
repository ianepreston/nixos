{ ... }:
{
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
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
