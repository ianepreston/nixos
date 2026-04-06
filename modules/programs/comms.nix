# Comms - HM Simple Aspect
# Signal Desktop
_: {
  flake.modules.homeManager.comms =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          signal-desktop
          ;
      };
      xdg.mimeApps.defaultApplications = {
        "x-scheme-handler/sgnl" = [ "signal.desktop" ];
        "x-scheme-handler/signalcaptcha" = [ "signal.desktop" ];
      };
    };
}
