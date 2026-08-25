# Development shell with tools and pre-commit hooks
_: {
  perSystem =
    { config, pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        # Wire up the git hooks on shell entry. The hook runner is prek (see
        # git-hooks.nix), a lightweight Rust binary that — unlike upstream
        # `pre-commit` — doesn't drag in a costly Darwin build.
        #
        # On Linux, use git-hooks.nix's installation script as-is: it installs
        # a prek shim into .git/hooks and points core.hooksPath at it.
        #
        # On this Darwin machine a global `core.hooksPath` already owns the
        # hooks dir, and its managed hook chains to prek itself whenever a repo
        # has a .pre-commit-config.yaml. So we must NOT install a .git/hooks
        # shim or set a local core.hooksPath — either would shadow that global
        # hook, and `prek install` refuses outright while a global hooksPath is
        # active. We only materialize the generated config so the global hook
        # picks prek up, and drop any stale local override a previous
        # `pre-commit` install left behind.
        shellHook =
          if pkgs.stdenv.isDarwin then
            ''
              if ${pkgs.git}/bin/git rev-parse --git-dir >/dev/null 2>&1; then
                ${pkgs.git}/bin/git config --local --unset-all core.hooksPath 2>/dev/null || true
                ln -fs ${config.pre-commit.settings.configFile} \
                  "$(${pkgs.git}/bin/git rev-parse --show-toplevel)/${config.pre-commit.settings.configPath}"
              fi
            ''
          else
            config.pre-commit.installationScript;

        packages =
          config.pre-commit.settings.enabledPackages
          ++ (with pkgs; [
            # NixOS management
            nixos-rebuild

            # Development tools
            go-task
            dconf2nix
            nushell
            pciutils

            # Secrets management
            sops
            ssh-to-age
            age
            yq-go
            pre-commit-hook-ensure-sops

          ]);
      };
    };
}
