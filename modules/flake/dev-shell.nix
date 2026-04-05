# Development shell with tools and pre-commit hooks
_: {
  perSystem =
    { config, pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        # Pre-commit hook installation from git-hooks module
        shellHook = config.pre-commit.installationScript;

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
            pre-commit-hook-ensure-sops

            # Linting (also available via pre-commit, but useful standalone)
            statix
            deadnix
          ]);
      };
    };
}
