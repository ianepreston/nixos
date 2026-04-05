# Moonlight - HM Simple Aspect
# Game streaming client
_: {
  flake.modules.homeManager.moonlight =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          moonlight-qt
          ;
      };
    };
}
