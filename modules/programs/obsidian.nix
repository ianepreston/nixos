# Obsidian - Simple Aspect
_: {
  flake.modules.nixos.obsidian =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.obsidian ];
    };
}
