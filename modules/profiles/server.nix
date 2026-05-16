# Server profile - core infra for hosting other services.
# Hosts that actually run user-facing apps additionally extend
# `server-apps` (see profiles/server-apps.nix). This profile only
# carries the foundation: SSO, reverse proxy, databases, observability,
# container runtime, backups, etc.
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server (NixOS server config)
{ inputs, ... }:
{
  flake.modules.nixos.server = _: {
    imports = with inputs.self.modules.nixos; [
      apprise
      auto-rebuild
      authentik
      base
      caddy
      homepage
      mariadb
      nfsclient
      nix-maintenance
      observability
      oci-containers
      postgresql
      preservation-server
      server-backups
      server-users
      sops
      ssh
      tailscale
    ];

    # Home-manager modules common to all servers
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
    ];
  };
}
