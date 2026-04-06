# Media - HM Simple Aspect
# Spotify + VLC
_: {
  flake.modules.homeManager.media =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          spotify
          vlc
          ;
      };
      xdg.mimeApps = {
        defaultApplications = {
          "x-scheme-handler/spotify" = [ "spotify.desktop" ];
        };
      };
    };
}
