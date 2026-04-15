# Auto-rebuild - Simple Aspect
# Periodically fetch latest config from GitHub and rebuild
_: {
  flake.modules.nixos.auto-rebuild =
    { hostSpec, ... }:
    {
      system.autoUpgrade = {
        enable = true;
        flake = "github:ianepreston/nixos#${hostSpec.hostName}";
        operation = "switch";
        dates = "04:40";
        randomizedDelaySec = "1h";
        persistent = true;
        allowReboot = true;
      };

      # The flake depends on a private repo (nix-secrets) fetched via SSH.
      # The upgrade service runs as root, so point GIT_SSH to the user's key.
      systemd.services.nixos-upgrade.serviceConfig.Environment = [
        "GIT_SSH_COMMAND=ssh -i ${hostSpec.home}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new"
      ];

      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
        persistent = true;
      };
    };
}
