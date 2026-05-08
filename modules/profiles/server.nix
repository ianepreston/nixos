# Server profile - just enough to host other services
# Imports base + common desktop modules
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server (NixOS server config)
{ inputs, ... }:
{
  # Server NixOS module - base + essentials
  flake.modules.nixos.server = _: {
    imports = with inputs.self.modules.nixos; [
      actualbudget
      arr-auth
      audiobookshelf
      auto-rebuild
      authentik
      base
      bazarr
      caddy
      grimmory
      homeassistant
      homepage
      jellyfin
      kapowarr
      kavita
      komga
      mariadb
      nfsclient
      oci-containers
      postgresql
      mealie
      miniflux
      mylar3
      nix-maintenance
      observability
      paperless-ngx
      prowlarr
      radarr
      readeck
      readmeabook
      sabnzbd
      seerr
      server-backups
      server-users
      shelfmark
      sonarr
      sops
      ssh
      tailscale
      tandoor
      watchstate
    ];

    # Home-manager modules common to all servers
    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      core
    ];
  };
}
