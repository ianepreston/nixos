# Browser - HM Simple Aspect
# Firefox with XDG MIME associations
_: {
  flake.modules.homeManager.browser = _: {
    programs.firefox.enable = true;
    # HM 26.05 changed the default to `$XDG_CONFIG_HOME/mozilla/firefox`.
    # Pin to the legacy path explicitly — `home.stateVersion = 25.05` would
    # do this implicitly, but the explicit set silences the migration
    # warning. Switch to the XDG path is a separate, on-disk migration.
    programs.firefox.configPath = ".mozilla/firefox";
    xdg.mimeApps.defaultApplications = {
      "text/html" = [ "firefox.desktop" ];
      "x-scheme-handler/http" = [ "firefox.desktop" ];
      "x-scheme-handler/https" = [ "firefox.desktop" ];
    };
  };
}
