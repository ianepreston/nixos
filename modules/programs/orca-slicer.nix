# OrcaSlicer - HM Simple Aspect
# Open (AGPL) FDM slicer; the deproprietary alternative to Bambu Studio
# for the Bambu Lab P1S. In this setup it's a pure offline slicer —
# bambuddy (Proxy Mode) does all printer/network communication, so Orca
# never needs the Bambu Network plugin, a cloud account, or reachability
# to the isolated printer VLAN. See modules/apps/bambuddy.nix.
_: {
  flake.modules.homeManager.orca-slicer =
    { pkgs, ... }:
    {
      home.packages = builtins.attrValues {
        inherit (pkgs)
          orca-slicer
          ;
      };
    };
}
