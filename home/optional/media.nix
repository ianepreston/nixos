{ pkgs, ... }:
{
  home.packages = builtins.attrValues {
    inherit (pkgs)
      spotify
      vlc
      ;
  };
  # Configure XDG MIME associations
  xdg.mimeApps = {
    defaultApplications = {
      "x-scheme-handler/spotify" = [ "spotify.desktop" ];
    };
  };
}
