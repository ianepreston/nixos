{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs)
      # discord
      signal-desktop
      ;
  };
  xdg.mimeApps.defaultApplications = {
    "x-scheme-handler/sgnl" = [ "signal.desktop" ];
    "x-scheme-handler/signalcaptcha" = [ "signal.desktop" ];
  };
}
