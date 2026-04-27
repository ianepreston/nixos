# Workstation profile - desktop/laptop configuration
# Imports base + common desktop modules
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.workstation (NixOS desktop config)
{ inputs, ... }:
{
  # Workstation NixOS module - base + common desktop essentials
  flake.modules.nixos.workstation = _: {
    imports = with inputs.self.modules.nixos; [
      base
      sops
      ssh
      audio
      themes
    ];

    # Home-manager modules common to all workstations
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
      browser
      comms
      ghostty
      media
    ];
  };
}
