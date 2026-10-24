# Wealthsimple Convert - HM Simple Aspect
# Converts Wealthsimple activities and Shareworks Transaction History exports
# for Wealthfolio and acb:
#
#   wealthsimple-convert <export.csv> [more.csv ...]
#
# writes INPUT-parsed.csv (Wealthfolio's canonical import CSV; use its generic
# CSV importer) and INPUT-acb.csv (tsiemens/acb transactions) next to each
# input. See the colocated README for the reports to export and
# wealthsimple-convert.py for the strict source mappings.
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
