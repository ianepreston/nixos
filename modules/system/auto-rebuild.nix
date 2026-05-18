# Auto-rebuild - Simple Aspect
# Periodically fetch latest config from GitHub and rebuild
_: {
  flake.modules.nixos.auto-rebuild =
    {
      config,
      hostSpec,
      ...
    }:
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

      # The flake depends on a private repo (nix-secrets) and fetches it
      # over SSH (see `nix-secrets` input in flake.nix). Provision the
      # per-host SSH key at the system level — root-owned, available
      # straight out of `sops-install-secrets.service` so it's ready
      # when the 04:40 timer fires regardless of whether the user has
      # logged in. The user's home-manager copy at
      # `${hostSpec.home}/.ssh/id_ed25519` is materialized by the
      # `sops-nix` *user* service on session start and is absent on
      # impermanent hosts after a reboot — pointing nixos-upgrade at
      # the system path side-steps that race entirely.
      sops.secrets."ssh/ed25519" = {
        inherit (hostSpec) sopsFile;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      systemd.services.nixos-upgrade.environment = {
        GIT_SSH_COMMAND = "ssh -i ${
          config.sops.secrets."ssh/ed25519".path
        } -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes";
      };
    };
}
