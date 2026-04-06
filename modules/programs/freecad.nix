# FreeCAD - HM Simple Aspect
_: {
  flake.modules.homeManager.freecad =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          freecad
          ;
      };
    };
}
