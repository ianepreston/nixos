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

      # The flake depends on a private repo (nix-secrets). Its URL is
      # git+https://... (kept that way so Renovate can read it), but root
      # has no GitHub HTTPS creds. Rewrite to SSH at fetch time via git
      # config env vars and point GIT_SSH at the user's key — mirroring
      # the insteadOf rule in the user's home-manager gitconfig.
      systemd.services.nixos-upgrade.environment = {
        GIT_SSH_COMMAND = "ssh -i ${hostSpec.home}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new";
        GIT_CONFIG_COUNT = "1";
        GIT_CONFIG_KEY_0 = "url.git@github.com:ianepreston/.insteadOf";
        GIT_CONFIG_VALUE_0 = "https://github.com/ianepreston/";
      };
    };
}
