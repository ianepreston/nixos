# ADB - HM Simple Aspect
# Android Debug Bridge + Heimdall
_: {
  flake.modules.homeManager.adb =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          android-tools
          heimdall
          ;
      };
    };
}
