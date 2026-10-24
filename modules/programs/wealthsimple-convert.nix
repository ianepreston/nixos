# Wealthsimple Convert - HM Simple Aspect
# Converts Wealthsimple activity exports for Wealthfolio and for acb:
#
#   wealthsimple-convert <export.csv> [more.csv ...]
#
# writes INPUT-parsed.csv (Wealthfolio's canonical import CSV; use its generic
# CSV import, the columns map automatically) and INPUT-acb.csv (tsiemens/acb
# transactions) next to each input. Wealthsimple's export dates date-only rows
# a day early and its type codes don't fit Wealthfolio's built-in Wealthsimple
# template; see wealthsimple-convert.py for the mapping.
_: {
  flake.modules.homeManager.wealthsimple-convert =
    { pkgs, ... }:
    let
      # doCheck = false: ruff (git-hooks.nix) is the single Python authority,
      # as with jellyfin-trickplay-cleanup.
      wealthsimple-convert = pkgs.writers.writePython3Bin "wealthsimple-convert" {
        doCheck = false;
      } (builtins.readFile ./wealthsimple-convert.py);
    in
    {
      home.packages = [ wealthsimple-convert ];
    };
}
