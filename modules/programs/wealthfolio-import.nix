# Wealthfolio Import - HM Simple Aspect
# Converts Wealthsimple activity exports into Wealthfolio's canonical import
# CSV:
#
#   wealthfolio-import <export.csv> [more.csv ...]
#
# writes INPUT-parsed.csv next to each input. Wealthsimple's export dates
# date-only rows a day early and its type codes don't fit Wealthfolio's
# built-in Wealthsimple template; see wealthfolio-import.py for the mapping.
# Import the result with Wealthfolio's generic CSV import — its columns use
# Wealthfolio's own names, so they map automatically.
_: {
  flake.modules.homeManager.wealthfolio-import =
    { pkgs, ... }:
    let
      # doCheck = false: ruff (git-hooks.nix) is the single Python authority,
      # as with jellyfin-trickplay-cleanup.
      wealthfolio-import = pkgs.writers.writePython3Bin "wealthfolio-import" {
        doCheck = false;
      } (builtins.readFile ./wealthfolio-import.py);
    in
    {
      home.packages = [ wealthfolio-import ];
    };
}
