{ lib, ... }:

{
  # Can only set this in NixOS. Home-manager standalone doesn't have stylix
  stylix.targets.neovim.enable = false;
  # This could probably go anywhere but it only matters in Nix
  stylix.targets.firefox.enable = false;
}
