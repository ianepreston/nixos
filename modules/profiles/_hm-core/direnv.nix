{ pkgs, ... }:
{
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    nix-direnv.enable = true; # better than native direnv nix functionality - https://github.com/nix-community/nix-direnv
    # WORKAROUND (2026-04-13): direnv 2.37.1 fish test gets killed (signal 9) in
    # macOS nix sandbox. Disable checks until fixed upstream in nixpkgs-25.11-darwin.
    # Track: https://github.com/NixOS/nixpkgs/issues — search "direnv fish test darwin"
    package = pkgs.direnv.overrideAttrs (_: {
      doCheck = false;
    });
  };
}
