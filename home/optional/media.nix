{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs)
      spotify
      vlc
      ;
  };
}
