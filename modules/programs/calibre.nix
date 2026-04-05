# Calibre - HM Simple Aspect
# Ebook management
_: {
  flake.modules.homeManager.calibre =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          calibre
          ;
      };
    };
}
