# Obsidian - Simple Aspect
_: {
  flake.modules.homeManager.obsidian =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          obsidian
          ;
      };
    };
}
