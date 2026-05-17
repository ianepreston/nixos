# Server profile - core infra for hosting other services.
# Hosts that actually run user-facing apps additionally extend
# `server-apps` (see profiles/server-apps.nix). This profile only
# carries the foundation: SSO, reverse proxy, databases, observability,
# container runtime, backups, etc.
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server (NixOS server config)
#
# Top-level assertions enforce the server-tier hostSpec contract:
# `serverDomain` and `serverEnvironment` are typed as `nullOr ...` in
# `hostSpecs/host-spec.nix` so workstation hosts can leave them unset,
# but every consumer of those fields under this profile (caddy,
# authentik, server-users, nfsclient, …) reads them unguarded. The
# fail-fast check lives here so importing `server` on a host that
# forgot to populate the fields surfaces one clear error at evaluation
# time instead of producing literal `"foo.null"` hostnames downstream.
{ inputs, ... }:
{
  flake.modules.nixos.server =
    { hostSpec, ... }:
    {
      imports = with inputs.self.modules.nixos; [
        apprise
        auto-rebuild
        authentik
        base
        caddy
        gatus
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

      assertions = [
        {
          assertion = hostSpec.serverEnvironment != null;
          message = ''
            The `server` profile requires `hostSpec.serverEnvironment` to be
            set ("dev" or "prod"). Host "${hostSpec.hostName}" leaves it
            null — populate it in hostSpecs/${hostSpec.hostName}.nix or
            drop the `server` profile from this host's modules.
          '';
        }
        {
          assertion = hostSpec.serverDomain != null;
          message = ''
            The `server` profile requires `hostSpec.serverDomain` to be set
            (e.g. "dnix.ipreston.net"). Host "${hostSpec.hostName}" leaves
            it null — caddy and authentik consumers would emit literal
            "<app>.null" hostnames. Populate it in
            hostSpecs/${hostSpec.hostName}.nix or drop the `server`
            profile from this host's modules.
          '';
        }
      ];

      # Home-manager modules common to all servers
      home-manager.sharedModules = with inputs.self.modules.homeManager; [
        core
      ];
    };
}
