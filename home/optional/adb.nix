{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs)
      android-tools
      heimdall
      ;
  };
}
