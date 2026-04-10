# Vibes - HM Simple Aspect
# Claude Code
_: {
  flake.modules.homeManager.vibes =
    { pkgs, inputs, ... }:
    let
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };
    in
    {
      home.packages = builtins.attrValues {
        inherit (pkgsUnstable)
          claude-code
          gemini-cli
          ;
      };
    };
}
