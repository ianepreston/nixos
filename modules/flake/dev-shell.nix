# Development shell with tools and pre-commit hooks
_: {
  perSystem =
    { config, pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        # Installing git hooks pulls in pre-commit itself.  On Darwin that
        # currently entails a costly local .NET SDK build, while this machine
        # is not used for repository work that needs commit-hook enforcement.
        # Keep automatic installation on Linux hosts.
        shellHook = if pkgs.stdenv.isDarwin then "" else config.pre-commit.installationScript;

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
