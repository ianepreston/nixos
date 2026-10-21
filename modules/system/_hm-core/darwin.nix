{ config, ... }:
let
  # Homebrew's python3 tracks the newest CPython (3.15 at time of writing) and
  # the Databricks-managed git hooks (~/.databricks/githooks, `#!/usr/bin/env
  # python3`) call importlib APIs removed in 3.15. Shadow only python3 with the
  # system one, ahead of Homebrew, rather than putting all of /usr/bin first
  # (that would also shadow Homebrew's openssl and pip3). Drop this once the
  # managed hooks ship a 3.15-compatible release.
  pythonShimDir = ".local/share/python-shim";
in
{
  home = {
    file."${pythonShimDir}/python3".source = config.lib.file.mkOutOfStoreSymlink "/usr/bin/python3";

    # Homebrew env for ALL shells, not just interactive ones. homebrew.nix sets
    # `brew shellenv` via interactiveShellInit (-> /etc/zshrc), which is invisible
    # to non-interactive shells (e.g. tools launched from tmux). These land in
    # hm-session-vars.sh (sourced by ~/.zshenv) and cover the binary paths there.
    sessionPath = [
      "${config.home.homeDirectory}/${pythonShimDir}"
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
    ];
    sessionVariables = {
      HOMEBREW_PREFIX = "/opt/homebrew";
      HOMEBREW_CELLAR = "/opt/homebrew/Cellar";
      HOMEBREW_REPOSITORY = "/opt/homebrew";
    };
  };

  # `brew shellenv` unconditionally prepends /opt/homebrew/bin, burying the
  # sessionPath entry above in interactive shells. ~/.zshrc runs after
  # /etc/zshrc, so re-assert the shim at the front here.
  programs.zsh.initContent = ''
    path=("$HOME/${pythonShimDir}" ''${path:#"$HOME/${pythonShimDir}"})
  '';
}
