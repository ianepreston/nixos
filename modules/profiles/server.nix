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
    { hostSpec, pkgs, ... }:
    {
      imports = with inputs.self.modules.nixos; [
        apprise
        auto-rebuild
        authentik
        base
        caddy
        gatus
        homepage
        iot-network
        mariadb
        mosquitto
        nfsclient
        nix-maintenance
        nut-client
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

      # Servers reboot themselves on kernel/initrd updates — that's the
      # whole point of running the upgrade timer unattended.
      system.autoUpgrade.allowReboot = true;

      # Swap Redis for Valkey across every `services.redis.servers.*`
      # instance on this profile. Valkey is the LF fork of Redis 7.2
      # under the original BSD-3-Clause license (Redis Inc. relicensed
      # to BSL/SSPL in March 2024). The nixpkgs redis module dispatches
      # via `cfg.package.serverBin`, so a single package swap covers
      # every named server.
      #
      # NOTE: on-disk RDB state is *not* portable from nixpkgs's Redis
      # 8.x (RDB v13) to Valkey 8.x (max RDB v11) — our existing redis
      # consumers (authentik sessions, paperless celery broker, manyfold
      # sidekiq queue, readmeabook cache) are all ephemeral, so the
      # first switch wipes `/var/lib/redis*/dump.rdb` and lets each
      # instance start fresh. Closes #132.
      services.redis.package = pkgs.valkey;

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
