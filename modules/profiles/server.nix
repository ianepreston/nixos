# Server profile - just enough to host other services
# Imports base + common desktop modules
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server (NixOS server config)
{ inputs, ... }:
{
  # Server NixOS module - base + essentials
  flake.modules.nixos.server = _: {
    imports = with inputs.self.modules.nixos; [
      auto-rebuild
      base
      sops
      ssh
    ];

    # Home-manager modules common to all servers
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
    ];
  };
}
