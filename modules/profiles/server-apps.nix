# Server-apps profile - the user-facing services that run on top of
# the core `server` profile (postgres, caddy, authentik, ...). Hosts
# import both: `server` for the foundation, `server-apps` for the
# actual apps.
#
# This is a flake-parts module that registers:
# - flake.modules.nixos.server-apps (NixOS app bundle)
#
# The import set is parameterized by `hostSpec.serverEnvironment`:
# `commonApps` ship on every server; `devOnlyApps` ship only where
# `serverEnvironment == "dev"` (hpp-1, tests-server) and
# `prodOnlyApps` only where it is `"prod"` (amos1). Promoting an app
# dev->prod is a one-line move between the lists; adding a shared app
# is a single append to `commonApps`.
#
# Structural guard at the bottom: every native server-app with
# persistent state on /var/lib/<app> must have a matching
# `preservation.preserveAt."/persist".directories` entry. See the
# block-level comment above `expectedPreservedDirs` for the rationale.
{ inputs, ... }:
{
  flake.modules.nixos.server-apps =
    {
      config,
      lib,
      hostSpec,
      ...
    }:
    let
      # Apps that ship on every server, dev and prod alike.
      commonApps = with inputs.self.modules.nixos; [
        actualbudget
        audiobookshelf
        # bambuddy — code kept but dormant; proxy-mode printing is blocked on
        # an upstream bambuddy<->OrcaSlicer bind bug. Re-add when fixed. See #298.
        bazarr
        bindery
        bookorbit
        decluttarr
        flaresolverr
        homeassistant
        jellyfin
        komga
        lidarr
        matter-server
        manyfold
        miniflux
        mylar3
        paperless-ngx
        pinchflat
        profilarr
        prowlarr
        radarr
        sabnzbd
        seerr
        shelfmark
        sonarr
        tandoor
      ];

      # Apps that ship only on dev-environment servers.
      devOnlyApps = with inputs.self.modules.nixos; [
        kapowarr
        readeck
        ytdlp-web-player
      ];

      # Apps that ship only on prod-environment servers — the mirror of
      # `devOnlyApps`, for things whose subject only exists on prod.
      #
      # The network controllers are the case that defines the list. There
      # is exactly one network and amos1 manages it, so a dev instance has
      # no subject: hpp-1's UniFi controller had an empty `ace.device`
      # collection and its Omada controller had never logged an adoption,
      # after both had run for months. What they did have was cost —
      # ~1.1 GB resident for Omada's JVM and a 1.5 GB peak for UniFi OS
      # Server on a box that also runs Home Assistant, Jellyfin and the
      # arrs — and a hazard: two controllers of the same brand on one
      # broadcast domain both answer device discovery, so a
      # factory-default device shows as pending adoption in both UIs and
      # adopting from the wrong one costs a factory reset to undo.
      # Verifying a controller change on dev was never worth that, since
      # the thing under test (adoption, config push, firmware) only
      # happens where the devices are.
      #
      # `omada-metrics` is prod-only for the same reason one step removed:
      # it polls the Omada controller's Open API for per-device state,
      # which needs an Open API client minted in that controller's UI and
      # a device fleet to report on. See modules/apps/omada-metrics.nix.
      # `valheim` is prod-only for a different reason: two dedicated
      # servers cannot coexist behind one public IP. Both hosts ran the
      # container on `--network=host` UDP 2456, so both registered the
      # *same* public endpoint with PlayFab, and a join code resolves to
      # an endpoint — whichever host claimed it most recently answered
      # every code, including the other's. On 2026-09-11 amos1 restarted
      # last and silently swallowed hpp-1's joins: the client showed
      # hpp-1's session name (that travels with the code) while dropping
      # the player into amos1's world. A dev instance also doubles the
      # worlds a `worldGeneration` bump reseeds, which is how three days
      # of play ended up stranded on hpp-1's copy. See the "prod-only"
      # section in modules/apps/valheim.nix.
      prodOnlyApps = with inputs.self.modules.nixos; [
        omada
        omada-metrics
        unifi
        valheim
      ];

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
      #   /var/lib/sabnzbd-incomplete - preserve-only bind mount, deliberately not backed up (modules/apps/sabnzbd.nix)
      residualPreservedDirs = [
        "/var/lib/mosquitto"
        "/var/lib/private/authentik"
        "/var/lib/sabnzbd-incomplete"
      ]
      # Conditional, unlike the rest: the GGUF model cache only exists on a
      # server actually running llama-server, which needs a GPU — hpp-1
      # doesn't have one and doesn't import modules/apps/llm.nix, so
      # asserting it unconditionally would demand a directory that host
      # never creates. Keyed off the forward-auth app rather than
      # `myLlamaCpp` because that option only exists where
      # modules/system/llama-cpp.nix is imported, and referencing it here
      # would fail to evaluate on every other server.
      #
      # Preserve-only (not `myAppState`): a GGUF is re-downloadable bytes,
      # not authored state, so it must stay out of restic. See
      # modules/apps/llm.nix.
      ++ lib.optional (config.myAuthentik.forwardAuthApps ? llm) "/var/lib/private/llama-cpp"
      # Conditional for the same reason, one list apart: UniFi OS Server
      # keeps its state outside /var/lib/containers (the upstream
      # module's `stateDir`), so modules/apps/unifi.nix declares the
      # preservation entry by hand rather than getting it from
      # `myContainerApp`. Now that unifi is in `prodOnlyApps`, a dev
      # server never imports that module and never creates the
      # directory — asserting it flat would fail eval on hpp-1. Keyed
      # off the forward-auth app because `services.unifi-os-server` only
      # exists where the upstream module is imported.
      ++ lib.optional (config.myAuthentik.forwardAuthApps ? unifi) "/var/lib/unifi-os-server";

      expectedPreservedDirs =
        map (a: a.stateDir) (lib.attrValues config.myAppState) ++ residualPreservedDirs;

      preservedDirs = map (d: d.directory) (config.preservation.preserveAt."/persist".directories or [ ]);

      missing = lib.subtractLists preservedDirs expectedPreservedDirs;
    in
    {
      imports =
        commonApps
        ++ lib.optionals (hostSpec.serverEnvironment == "dev") devOnlyApps
        ++ lib.optionals (hostSpec.serverEnvironment == "prod") prodOnlyApps;

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
