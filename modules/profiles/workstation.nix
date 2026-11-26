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
      yubikey
    ];

    # Workstations track main on the same nightly timer as servers and
    # reboot themselves, but only inside an early-morning window. A
    # `switch` that changes the NVIDIA driver (or any kernel module)
    # would leave the running kernel module mismatched with the new
    # userspace until a reboot, so nixos-upgrade reboots instead of
    # switching when the kernel/initrd/modules change. The window
    # covers dates = "04:40" plus randomizedDelaySec = "1h" with
    # margin; because the timer is `persistent`, a run caught up at
    # boot outside the window stages the generation for the next boot
    # rather than rebooting an active session. luna inherits this.
    system.autoUpgrade = {
      allowReboot = true;
      rebootWindow = {
        lower = "04:00";
        upper = "06:30";
      };
    };

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
