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
      # State dirs the impermanence guard expects to be preserved. The
      # app tier is derived from `config.myAppState` — the single source
      # of truth for native-app on-disk state (see
      # modules/system/app-state.nix, which emits the preservation and
      # restic entries from the same declaration). Adding a native app is
      # therefore one `myAppState.<app>` block in the app module and no
      # edit here.
      #
      # Issue #136 was exactly this class of bug: native arrs / readeck
      # shipped on hpp-1 with impermanence enabled and no preservation
      # entries; only the lack of a reboot between deploy and the audit
      # kept it from silently wiping arr history. `myAppState` now makes
      # the preserve+restic pair structural (they can't drift apart);
      # this assertion stays as the belt-and-suspenders that every
      # expected dir is actually present in `preservation.preserveAt` on
      # impermanence hosts.
      #
      # `residualPreservedDirs` covers preserved state NOT modeled as a
      # myAppState app, so it isn't in the derived set:
      #   /var/lib/mosquitto          - system MQTT broker (modules/system/mosquitto.nix)
      #   /var/lib/private/authentik  - DynamicUser SSO, bare-string preserve entry (modules/apps/authentik.nix)
      #   /var/lib/unifi-os-server    - container app whose state lives outside /var/lib/containers (modules/apps/unifi.nix)
      #   /var/lib/sabnzbd-incomplete - preserve-only bind mount, deliberately not backed up (modules/apps/sabnzbd.nix)
      residualPreservedDirs = [
        "/var/lib/mosquitto"
        "/var/lib/private/authentik"
        "/var/lib/sabnzbd-incomplete"
        "/var/lib/unifi-os-server"
      ];

      expectedPreservedDirs =
        map (a: a.stateDir) (lib.attrValues config.myAppState) ++ residualPreservedDirs;

      preservedDirs = map (d: d.directory) (config.preservation.preserveAt."/persist".directories or [ ]);

      missing = lib.subtractLists preservedDirs expectedPreservedDirs;
    in
    {
      imports = with inputs.self.modules.nixos; [
        actualbudget
        audiobookshelf
        bazarr
        bookorbit
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

            Declare `myAppState.<app>` in the owning app module (see
            e.g. modules/apps/bazarr.nix for the pattern) — that single
            source emits both the preservation entry and the restic path,
            and feeds the derived guard here. No profile edit needed.
          '';
        }
      ];
    };
}
