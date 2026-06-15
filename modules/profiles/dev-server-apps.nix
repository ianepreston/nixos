# Server-apps profile - the user-facing services that run on top of
# the core `server` profile (postgres, caddy, authentik, ...). Hosts
# import both: `server` for the foundation, `server-apps` for the
# actual apps.
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server-apps (NixOS app bundle)
#
# Structural guard at the bottom: every native server-app with
# persistent state on /var/lib/<app> must have a matching
# `preservation.preserveAt."/persist".directories` entry. See the
# block-level comment above `expectedPreservedDirs` for the rationale.
{ inputs, ... }:
{
  flake.modules.nixos.dev-server-apps =
    { config, lib, ... }:
    let
      # Native server-apps (and the one container-app whose volumes
      # live outside /var/lib/containers) that need an explicit
      # preservation entry on impermanence hosts. Container-only apps
      # (kapowarr, mylar3, profilarr, valheim, watchstate,
      # spierscraper, seerr, …) are covered transitively by the
      # wholesale `/var/lib/containers` entry in preservation-server.nix
      # and don't appear here. Stateless natives (miniflux — backed by
      # postgres, no local state) are also omitted.
      #
      # Issue #136 was exactly this class of bug: 5 native arrs / readeck
      # shipped on hpp-1 with impermanence enabled and no preservation
      # entries; only the lack of a reboot between deploy and the audit
      # kept it from silently wiping arr history. The assertion below
      # makes the check structural rather than human-memory.
      #
      # When you add a new native app with persistent state:
      #   1. Add a `preservation.preserveAt."/persist".directories`
      #      entry in that app's module (see modules/apps/bazarr.nix for
      #      the canonical pattern).
      #   2. Append the on-disk state-dir path to the list below.
      #
      # NOTE: Paths are the public /var/lib/<app>, not the DynamicUser
      # /var/lib/private/<app>. The exception is authentik, whose
      # preservation entry intentionally targets the private dir (see
      # modules/apps/authentik.nix for the why).
      #
      # NOTE: The check is hardcoded rather than fully generic because
      # nix doesn't expose a uniform "this service has a StateDirectory"
      # handle: modules variously use systemd `StateDirectory=`,
      # `services.<app>.dataDir`, `services.<app>.stateDir`, or
      # DynamicUser symlinks under /var/lib/private. Walking the
      # systemd unit table for `StateDirectory=` would catch most but
      # miss the dataDir/stateDir overrides — the hardcoded list keeps
      # the assertion simple and unambiguous at the cost of needing one
      # list update per new native app.
      expectedPreservedDirs = [
        "/var/lib/audiobookshelf"
        "/var/lib/bazarr"
        "/var/lib/jellyfin"
        "/var/lib/kavita"
        "/var/lib/komga"
        "/var/lib/mealie"
        "/var/lib/mosquitto"
        "/var/lib/private/matter-server"
        "/var/lib/paperless-ngx"
        "/var/lib/pinchflat"
        "/var/lib/private/authentik"
        "/var/lib/prowlarr"
        "/var/lib/radarr"
        "/var/lib/readeck"
        "/var/lib/sabnzbd"
        "/var/lib/sabnzbd-incomplete"
        "/var/lib/sonarr"
        # Container app whose volumes live OUTSIDE /var/lib/containers:
        # the upstream unifi-os-server flake module defaults its
        # `stateDir` to /var/lib/unifi-os-server.
        "/var/lib/unifi-os-server"
      ];

      preservedDirs = map (d: d.directory) (config.preservation.preserveAt."/persist".directories or [ ]);

      missing = lib.subtractLists preservedDirs expectedPreservedDirs;
    in
    {
      imports = with inputs.self.modules.nixos; [
        actualbudget
        audiobookshelf
        bazarr
        decluttarr
        flaresolverr
        grimmory
        homeassistant
        jellyfin
        kapowarr
        kavita
        komga
        matter-server
        manyfold
        mealie
        miniflux
        mylar3
        paperless-ngx
        pinchflat
        profilarr
        prowlarr
        radarr
        readeck
        readmeabook
        sabnzbd
        seerr
        shelfarr
        sonarr
        spierscraper
        tandoor
        unifi
        valheim
        watchstate
      ];

      assertions = [
        {
          # Only enforce when preservation is actually live on this
          # host; non-impermanence hosts have nothing to preserve.
          assertion = !config.preservation.enable || missing == [ ];
          message = ''
            server-apps: the following app state directories are
            missing a `preservation.preserveAt."/persist".directories`
            entry, and would be wiped on the next reboot under
            impermanence:

              ${lib.concatStringsSep "\n  " missing}

            Add an entry in the owning app module (see e.g.
            modules/apps/bazarr.nix for the pattern) and update
            `expectedPreservedDirs` in modules/profiles/server-apps.nix.
          '';
        }
      ];
    };
}
