# Server-apps profile - the user-facing services that run on top of
# the core `server` profile (postgres, caddy, authentik, ...). Hosts
# import both: `server` for the foundation, `server-apps` for the
# actual apps.
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server-apps (NixOS app bundle)
{ inputs, ... }:
{
  flake.modules.nixos.server-apps = _: {
    imports = with inputs.self.modules.nixos; [
      actualbudget
      audiobookshelf
      bazarr
      grimmory
      homeassistant
      jellyfin
      kapowarr
      kavita
      komga
      maintainerr
      mealie
      miniflux
      mylar3
      paperless-ngx
      profilarr
      prowlarr
      radarr
      readeck
      readmeabook
      sabnzbd
      seerr
      shelfmark
      sonarr
      tandoor
      watchstate
    ];
  };
}
