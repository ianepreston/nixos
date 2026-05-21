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
      auto-rebuild
      base
      sops
      ssh
      audio
      nix-maintenance
      themes
    ];

    # Workstations track main on the same nightly timer as servers, but
    # don't reboot themselves — an interactive desktop shouldn't yank
    # the session out from under the user at 04:40. Kernel/initrd
    # updates land at the user's next manual reboot.
    system.autoUpgrade.allowReboot = false;

    # Home-manager modules common to all workstations
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
      browser
      comms
      ghostty
      media
      neovim
    ];
  };
}
