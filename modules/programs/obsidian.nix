# Obsidian, from nixpkgs-unstable so it tracks upstream closely, and kept on
# that packaged build rather than one it downloads itself (#915). The
# activation step disables self-updates, deletes already-downloaded app
# bundles, and drops Electron's code cache when the package changes; see
# _obsidian/reset-state.sh for why each is needed.
{ inputs, ... }:
{
  flake.modules.homeManager.obsidian =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };
      package = pkgsUnstable.obsidian;
      resetState = pkgs.writeShellApplication {
        name = "obsidian-reset-state";
        runtimeInputs = [
          pkgs.jq
          pkgs.procps
        ];
        text = builtins.readFile ./_obsidian/reset-state.sh;
      };
    in
    {
      home.packages = [ package ];

      home.activation.obsidianState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe resetState} \
          ${lib.escapeShellArg "${config.xdg.configHome}/obsidian"} ${package}
      '';
    };
}
