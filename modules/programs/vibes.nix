# Vibes - HM Simple Aspect
# Claude Code
_: {
  flake.modules.homeManager.vibes =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          claude-code
          gemini-cli
          ;
      };
    };
}
