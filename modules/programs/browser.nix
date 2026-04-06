# Browser - HM Simple Aspect
# Firefox with XDG MIME associations
_: {
  flake.modules.homeManager.browser = _: {
    programs.firefox.enable = true;
    xdg.mimeApps.defaultApplications = {
      "text/html" = [ "firefox.desktop" ];
      "x-scheme-handler/http" = [ "firefox.desktop" ];
      "x-scheme-handler/https" = [ "firefox.desktop" ];
    };
  };
}
