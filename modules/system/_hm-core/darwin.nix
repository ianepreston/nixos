_: {
  # Homebrew env for ALL shells, not just interactive ones. homebrew.nix sets
  # `brew shellenv` via interactiveShellInit (-> /etc/zshrc), which is invisible
  # to non-interactive shells (e.g. tools launched from tmux). These land in
  # hm-session-vars.sh (sourced by ~/.zshenv) and cover the binary paths there.
  home.sessionPath = [
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
  ];
  home.sessionVariables = {
    HOMEBREW_PREFIX = "/opt/homebrew";
    HOMEBREW_CELLAR = "/opt/homebrew/Cellar";
    HOMEBREW_REPOSITORY = "/opt/homebrew";
  };
}
