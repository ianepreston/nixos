# Auto-rebuild - Simple Aspect
# Periodically fetch latest config from GitHub and rebuild
_: {
  flake.modules.nixos.auto-rebuild =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    {
      system.autoUpgrade = {
        enable = true;
        flake = "github:ianepreston/nixos#${hostSpec.hostName}";
        # Policy default: stage the new generation to the bootloader
        # ("boot") rather than activating it in the running system
        # ("switch"). The impermanent servers (hpp-1, amos1) roll `@root`
        # back to `@root-blank` in initrd on every boot (via
        # `_rollback-root.nix`). With "boot" the upgrade sequence is
        # deterministic: reboot -> btrfs rollback -> preservation
        # bind-mounts -> new generation activates. "switch" instead
        # activates mid-session before the reboot, which can restart
        # units (sops-install-secrets, preservation mounts) against
        # state that the subsequent rollback then discards. `allowReboot
        # = true` on servers still fires the reboot that activates the
        # staged entry, so the end state is unchanged. Interactive hosts
        # (workstation profile) override this back to "switch" so an
        # overnight upgrade activates immediately without waiting for a
        # manual reboot.
        operation = lib.mkDefault "boot";
        dates = "04:40";
        randomizedDelaySec = "1h";
        persistent = true;
        # Policy default: servers reboot themselves to pick up kernel /
        # initrd updates. Interactive hosts (workstation profile) flip
        # this off so an overnight upgrade doesn't yank the desktop out
        # from under an active session.
        allowReboot = lib.mkDefault true;
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
