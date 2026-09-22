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
        sparkyfitness
        tandoor
        # Ships everywhere but is off unless a host sets
        # `myValheim.enable`, because the interesting question is not
        # which hosts import it but which run it and with which
        # networking backend — and tests-server, the other dev-environment
        # host, has no business downloading 1.5 GB of steamcmd for a
        # recovery drill. amos1 and hpp-1 opt in from their host files.
        # See modules/apps/valheim.nix.
        valheim
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
      # The network controller is the case that defines the list. There
      # is exactly one network and amos1 manages it, so a dev instance has
      # no subject: hpp-1's controller went months without an adoption while
      # holding ~1.1 GB of JVM. It would also be a hazard: two controllers
      # on one broadcast domain both answer device discovery, so a
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
      # `valheim` used to be here, for a reason that turned out to be
      # narrower than "one server per household": two *crossplay* servers
      # cannot coexist behind one public IP. Both hosts ran the container
      # on `--network=host` UDP 2456, so both registered the same public
      # endpoint with PlayFab, and a join code resolves to an endpoint —
      # whichever host claimed it most recently answered every code,
      # including the other's (2026-09-11, #644). A Steam-backend server
      # registers a PlayFab lobby too — it just never gets a join code, so
      # the collision came back silently on 2026-09-21 — but it is the
      # only one that moves off the default game port, which is what keeps
      # the two endpoints distinct. See "Crossplay exclusivity" in
      # ../apps/valheim.nix. valheim is in `commonApps` above, gated on
      # `myValheim.enable`, with crossplay itself the per-host toggle.
      prodOnlyApps = with inputs.self.modules.nixos; [
        omada
        omada-metrics
      ];

      # State dirs the impermanence guard expects to be preserved. The
      # app tier is derived from `config.myAppState` — the single source
      # of truth for server-owned on-disk state (see
      # modules/system/app-state.nix, which emits the preservation entry
      # and, by default, the restic path from the same declaration).
      # Adding an app-owned path is therefore one `myAppState.<app>` block
      # in the owning module and no edit here.
      #
      # Issue #136 was exactly this class of bug: native arrs / readeck
      # shipped on hpp-1 with impermanence enabled and no preservation
      # entries; only the lack of a reboot between deploy and the audit
      # kept it from silently wiping arr history. `myAppState` now makes
      # the preserve policy structural and carries the backup policy with
      # it, so neither can drift from the app that owns the path.
      #
      # Both sides of this assertion derive from `config.myAppState`, so
      # it cannot fire on a forgotten entry the way it did while the
      # profile still carried hand-written paths — an app that declares
      # nothing is invisible to it. What it still catches is the other
      # direction: anything that drops a declared dir back out of
      # `preservation.preserveAt` (a host-level `mkForce` on the list, a
      # future filter in app-state.nix) turns a silent wipe-on-reboot
      # into an eval failure.
      expectedPreservedDirs = map (a: a.stateDir) (lib.attrValues config.myAppState);

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
            source emits the preservation entry, the restic path (unless
            `backup = false`), and the derived guard here. No profile
            edit needed.
          '';
        }
      ];
    };
}
