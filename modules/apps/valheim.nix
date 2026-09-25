# Valheim dedicated server (ghcr.io/community-valheim-tools/valheim-server
# container, formerly lloesche/valheim-server). Gameplay is UDP and there is no
# web UI to put behind Caddy/Authentik.
#
# This file is the module contract: the `myValheim` option surface, the per-app
# secrets, the container declaration, the host firewall rule, and the module
# registration. The three implementation components live beside it in
# `_valheim/` and are merged back in below:
#
#   _valheim/paths.nix          /run + /var/lib paths and join-code timing
#                               constants shared between the components.
#   _valheim/metrics.nix        node_exporter textfile collector, the per-unit
#                               journald rate cap, the vmalert rule group, the
#                               relay-counter app-state. Always merged.
#   _valheim/joincode.nix       crossplay join-code notifier + watchdog. Merged
#                               only when `crossplay` is set.
#   _valheim/player-notify.nix  player-presence notifier + roster. Merged only
#                               when `playerNotify` is set.
#
# The full operational narrative — the crossplay backend mechanics, the PlayFab
# join-code failure modes and incident history, the peer-relay stall analysis,
# the memory/RESTART_CRON evidence, the GetPublicIP log runaway, and the mods
# notes — lives in `_valheim/README.md`. Option and alert-rule descriptions
# that say "at the top of this file" or "modules/apps/valheim.nix" mean the
# sections summarised below and, for the detail, that runbook.
#
# ## Two instances
#
# `myValheim` is what makes the two servers differ. amos1 runs crossplay: it
# reaches PlayFab outbound and players arrive over that relay, so there is no
# inbound listening surface and the game UDP ports stay shut. hpp-1 runs the
# Steam backend — the game UDP ports are open on the host firewall and players
# connect by LAN address.
#
# ## Crossplay
#
# `CROSSPLAY=true` swaps the networking backend from Steam matchmaking to
# PlayFab Party: non-Steam clients (console, Microsoft Store) can join, and
# traffic is relayed so a client outside the LAN needs no port-forward — at the
# cost of losing connect-by-address entirely (everyone joins by the 6-digit
# join code, which rotates on every restart). Full tradeoff, and the
# player-facing peer-relay cost, in `_valheim/README.md`.
#
# ## Crossplay exclusivity: one crossplay server per public IP
#
# A PlayFab join code resolves to a network endpoint, not a server identity,
# and this container runs `--network=host`. Two crossplay hosts behind one NAT
# register the identical `<public-ip>:2456` and silently answer each other's
# codes (the 2026-09-11 incident). At most one host behind a public IP may set
# `crossplay`; `gamePort` moves the Steam-backend instance to 2466 so the two
# PlayFab lobbies carry distinct endpoints even though the Steam backend also
# registers one. Full account in `_valheim/README.md`.
#
# ## Mods (BepInEx)
#
# `myValheim.bepinex = true` installs BepInEx into /config/bepinex on next
# container start; drop mod DLLs into
# /var/lib/containers/valheim/config/bepinex/plugins/ and restart
# podman-valheim.service. A mod that works on the Steam-backend dev instance is
# not thereby cleared for crossplay — some misbehave on the PlayFab backend.
# See `_valheim/README.md`.
_: {
  flake.modules.nixos.valheim =
    {
      config,
      lib,
      pkgs,
      hostSpec,
      ...
    }:
    let
      cfg = config.myValheim;

      # UDP game port. The query port is always this + 1 — the image
      # derives `SERVER_QUERY_PORT=$((SERVER_PORT + 1))` and offers no
      # separate knob.
      #
      # The Steam-backend instance moves off the image's default 2456 so
      # that the PlayFab lobby it registers (it does register one, even
      # with `CROSSPLAY=false`) advertises a distinct
      # `<public-ip>:<port>` and stops overwriting the crossplay host's.
      # See "Crossplay exclusivity" in the header for the 2026-09-21
      # collision this fixes and why `crossplay = false` alone was not
      # enough.
      gamePort = if cfg.crossplay then 2456 else 2466;

      # Bump to reseed. WORLD_NAME is the basename of the world's .db/.fwl in
      # /config/worlds_local; the image generates a fresh map whenever that
      # basename has no save behind it. So incrementing this starts a brand
      # new world on next container start — which is the intended mechanism
      # for wiping and re-rolling. g2 is the 1.0 / Deep North reseed: the
      # final biome only generates in terrain a world has never streamed in,
      # so carrying g1 forward would leave the new content stranded behind
      # already-explored map.
      #
      # This is deliberately one value rather than a hostSpec option: a
      # reseed is a "start over" decision, and a per-host knob would just
      # be numbers to keep in sync. So a bump reseeds both hosts' worlds,
      # which is fine — the hostName prefix keeps them distinct saves, and
      # dev's is scratch. What made that hurt in 2026-09-11 was not two
      # worlds but two *reachable* worlds: both hosts were on PlayFab, so
      # players followed a dev join code into the dev copy and lost three
      # days of building there. A non-crossplay dev instance has no join
      # code to follow, so a double reseed costs nothing. See "Crossplay
      # exclusivity" in the header.
      #
      # The old world's files are *not* deleted — they stay in
      # /var/lib/containers/valheim/config/worlds_local (and in restic) under
      # the previous name, so a bump is reversible by reverting this number.
      # Delete them by hand once you're sure you don't want them back.
      worldGeneration = 2;
      worldName = "${hostSpec.hostName}-g${toString worldGeneration}";

      paths = import ./_valheim/paths.nix;
      metrics = import ./_valheim/metrics.nix {
        inherit
          lib
          pkgs
          config
          cfg
          paths
          ;
      };
      joincode = import ./_valheim/joincode.nix { inherit pkgs config paths; };
      player = import ./_valheim/player-notify.nix { inherit pkgs config paths; };
    in
    {
      options.myValheim = {
        enable = lib.mkEnableOption ''
          the Valheim dedicated server container.

          Gated on an option rather than on the import site because this
          module ships via `commonApps` in ../profiles/server-apps.nix,
          which also covers tests-server — and making the quarterly
          recovery-drill VM download 1.5 GB of steamcmd and run a game
          server is pure cost. The two real servers opt in from their host
          files, which also puts "does this host run Valheim, and with
          crossplay?" in one place instead of split across the profile and
          a host module.
        '';

        crossplay = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Run on Microsoft's PlayFab Party relay (`CROSSPLAY=true`)
            instead of the Steam backend. See "Crossplay" and "Crossplay
            exclusivity" at the top of this file for the full tradeoff.

            **At most one host behind a given public IP may set this.** A
            PlayFab join code resolves to a network endpoint, and this
            container runs `--network=host`, so two crossplay hosts behind
            one NAT register the identical `<public-ip>:2456` and silently
            answer each other's codes — the 2026-09-11 incident.
            Defaulting to `false` (the image's own default) keeps the host
            that needs the relay the one that has to ask for it.

            It does not, on its own, keep the hosts apart: a Steam-backend
            server registers a PlayFab lobby too, just without a join code
            (2026-09-21). So this option also picks the game port via
            `gamePort` — 2456 with the relay, 2466 without — and that is
            what makes the two endpoints distinct.

            `true` gets non-Steam clients (console, Microsoft Store) and
            needs no inbound port-forward, at the cost of losing
            connect-by-address entirely. `false` opens the game UDP ports
            on the host firewall and players join by typing
            `<host-lan-ip>:2466`, Steam clients only.
          '';
        };

        bepinex = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Install BepInEx into /config/bepinex on next container start,
            so mod DLLs dropped into
            /var/lib/containers/valheim/config/bepinex/plugins/ load. See
            the "Mods" section at the top of this file, including why a
            mod that works here is not thereby cleared for a crossplay
            server.
          '';
        };

        playerNotify = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Post player join/leave to the `valheim/player_webhook`
            Discord channel.

            Unlike `valheim-joincode-notify`, this is a channel-noise
            choice and not a backend requirement — the journal lines it
            keys off (`Got character ZDOID`, `Destroying abandoned non
            persistent zdo`) are emitted identically on the Steam
            backend. Turned off on the dev instance because the audience
            for a mod-test server is whoever is at the terminal, and its
            join/leave traffic in the players' channel is noise. If dev
            traffic is ever wanted, point `valheim/player_webhook` in
            that host's sops file at a different channel
            (`task secrets:edit:<host>`) and flip this back on.
          '';
        };
      };

      config = lib.mkIf cfg.enable (
        lib.mkMerge [
          {
            myObservability.monitoredSystemdUnits = [
              "podman-valheim"
              "valheim-joincode-(notify|watchdog)"
            ];

            myRecovery.apps.valheim = {
              kind = "volume";
              order = 300;
              units = [ "podman-valheim.service" ];
              paths = [ "/var/lib/containers/valheim" ];
            };

            sops = {
              # `optionalAttrs` rather than declaring all three unconditionally.
              # A secret with no consumer is still decrypted to /run on every
              # activation, and its `restartUnits` would name a unit that does
              # not exist on that host — pointless at best. Verified on hpp-1:
              # /run/secrets/valheim/ holds server_password alone.
              #
              # Both webhook keys are present in every host's sops file
              # regardless of the toggles, so flipping one back on needs no
              # `task secrets:*` run.
              secrets = {
                "valheim/server_password" = {
                  inherit (hostSpec) sopsFile;
                };
              }
              // lib.optionalAttrs cfg.crossplay {
                # Consumed directly (the notifier reads the path in its script)
                # rather than through a template, so the restart trigger has to
                # live on the secret — there's no template to bind it to. See
                # AGENTS.md "restartUnits goes on the template, not the secret",
                # direct-consumption exception.
                "valheim/discord_webhook" = {
                  inherit (hostSpec) sopsFile;
                  # Only the follower, deliberately. valheim-joincode-watchdog
                  # reads this same secret, but it is a oneshot fired by a 1m
                  # timer — it re-reads the file on every tick, so there is no
                  # long-lived process holding a stale value and nothing for a
                  # restart to fix. Adding it here would bounce a unit that is
                  # not running.
                  restartUnits = [ "valheim-joincode-notify.service" ];
                };
              }
              // lib.optionalAttrs cfg.playerNotify {
                # Deliberately a second key rather than reusing
                # `discord_webhook`, even though both currently hold the same
                # URL. Join codes and player join/leave are different feeds with
                # different volumes — the join code fires a handful of times a
                # day, player traffic fires on every session — so they want to be
                # separately routable to different channels. Splitting the key now
                # means repointing this feed is a `task secrets:edit:<host>` away
                # instead of a module change. Same direct-consumption exception as
                # above: read by path in the notifier's script, so `restartUnits`
                # lives on the secret.
                "valheim/player_webhook" = {
                  inherit (hostSpec) sopsFile;
                  restartUnits = [ "valheim-player-notify.service" ];
                };
              };

              # restartUnits lives on the template (not the secret): the container
              # consumes the rendered template via environmentFiles, and sops-nix
              # writes secrets and re-renders templates in separate phases. Binding
              # the restart to the template guarantees it fires after the re-render
              # flushes the rotated credential. See AGENTS.md "restartUnits goes on
              # the template, not the secret".
              templates."valheim.env" = {
                content = ''
                  SERVER_PASS=${config.sops.placeholder."valheim/server_password"}
                '';
                restartUnits = [ "podman-valheim.service" ];
              };
            };

            # No `port` — valheim uses `--network=host`, so nothing is published
            # on 127.0.0.1 and there is no caddy route; inbound reachability is
            # the host firewall block below, on a Steam-backend host only.
            # linuxServer drives the in-image PUID/PGID drop.
            myContainerApp.valheim = {
              linuxServer = true;
              stateDirs = [
                "/var/lib/containers/valheim"
                "/var/lib/containers/valheim/config"
                "/var/lib/containers/valheim/cache"
              ];
            };

            # Inbound game ports — only on a Steam-backend host.
            #
            # Under crossplay the client cannot connect by LAN or loopback
            # address at all (verified on amos1: joining by IP stopped working
            # the moment CROSSPLAY=true landed, while the join code works), and
            # outbound relay traffic to PlayFab needs no inbound rule. So on a
            # crossplay host nothing can reach these ports by design and
            # opening them is exposure that buys nothing — hence the gate
            # rather than an unconditional block.
            #
            # `gamePort` is the game port and `gamePort + 1` its query port —
            # 2466/2467 on the Steam backend, since that instance is the one
            # moved off the image's default (see `gamePort` above). Upstream
            # documents three ports and the image's own compose files open all
            # three, but the third is the PlayFab one, so a Steam-backend
            # server never binds it — verified with `ss -ulnp` on hpp-1, where
            # valheim_server.x86_64 held 2456 and 2457 only. Opening exactly
            # what is bound rather than copying upstream's range.
            #
            # Deliberately not interface-scoped. The audience is LAN clients
            # and tailnet clients, and the latter arrive over behemoth's subnet
            # route as ordinary LAN traffic (see the tailnet DNS/routing
            # topology notes) — so one rule covers both, and the NAT is still
            # the boundary against the internet. Nothing is port-forwarded.
            networking.firewall.allowedUDPPortRanges = lib.optionals (!cfg.crossplay) [
              {
                from = gamePort;
                to = gamePort + 1;
              }
            ];

            virtualisation.oci-containers.containers.valheim = {
              # `ghcr.io/community-valheim-tools/valheim-server` is the canonical
              # image. The project was formerly lloesche/valheim-server-docker (the
              # GitHub repo now redirects to the community org) and it still mirrors
              # builds to the old Docker Hub name, but that image self-describes as
              # a "Legacy container image mirror" and the README only promises
              # drop-in compatibility "for the moment" — so track the real one.
              #
              # This was a same-revision cutover, not a version bump: Docker Hub
              # `lloesche/valheim-server:latest` and GHCR `1.2.0`/`latest` both carry
              # org.opencontainers.image.revision=a134fb4dc7a850eec5b3ba7f0bc89bce434f0348.
              # The digest differs purely because each registry serves its own
              # manifest index; it is not different content.
              #
              # GHCR also publishes real semver tags (1.0.0, 1.1.0, 1.2.0), which the
              # old Docker Hub mirror did not — hence the `<version>@sha256:` pin
              # used everywhere else in this repo, rather than the digest-of-`latest`
              # pin this line used to carry.
              #
              # Cost of the move, accepted deliberately: renovate cannot read a
              # per-tag publish time from ghcr.io, so per the `timestamp-optional`
              # rule in renovate.json this image no longer serves the 7-day
              # minimumReleaseAge cooldown that Docker Hub images get — updates land
              # unaged. Tolerable here because the container self-updates the game
              # on its own UPDATE_CRON anyway, so the image tag is only the wrapper.
              # renovate: datasource=docker depName=ghcr.io/community-valheim-tools/valheim-server
              image = "ghcr.io/community-valheim-tools/valheim-server:1.4.0@sha256:f3ccde9a4e292663cf5096d502ff33cc9617015f6d70b6a9ca0968543f165ef2";
              volumes = [
                "/var/lib/containers/valheim/config:/config"
                "/var/lib/containers/valheim/cache:/opt/valheim"
              ];
              environment = {
                # Both derive from hostSpec.hostName + worldGeneration (see the
                # `let` at the top of the module) so hpp-1 and amos1 don't share a
                # server identity or a world save name. SERVER_NAME is what the
                # join-code notifier puts in the Discord message, so it wants to
                # say which host it is.
                SERVER_NAME = "${worldName}-valheim";
                WORLD_NAME = worldName;
                # SERVER_PUBLIC=false keeps the server out of the public
                # community browser. Joining is by 6-digit join code (see
                # the crossplay notes at the top of this file) — the code is
                # a PlayFab session lookup and is independent of the browser
                # listing, so unlisted + join-code is the minimum-exposure
                # combination that still lets a console player in.
                #
                # It does *not* suppress the game's public-IP lookup, so it is
                # not a mitigation for the GetPublicIP logging loop — see that
                # section in the header (#590).
                SERVER_PUBLIC = "false";
                # Switch the networking backend from Steam to PlayFab so
                # non-Steam clients can join and traffic is relayed rather
                # than requiring an inbound port-forward. See the crossplay
                # block at the top of this file for the LAN-join tradeoff, and
                # `myValheim.crossplay` for why at most one host may set it.
                CROSSPLAY = lib.boolToString cfg.crossplay;
                # 2456 under crossplay, 2466 on the Steam backend, so the two
                # hosts' PlayFab lobbies carry different endpoints. See
                # `gamePort` in the `let` block above.
                SERVER_PORT = toString gamePort;

                # Weekly rather than upstream's daily default — every restart
                # rotates the join code, and the metrics say the daily clean
                # slate was insurance against a leak that isn't there. Full
                # evidence in the "Phase 1" section at the top of this file
                # (#458).
                #
                # This is the container's own crontab, not a systemd calendar
                # spec, and it runs in host local time: the oci-containers
                # wrapper in modules/system/oci-containers.nix sets
                # `TZ = config.time.timeZone` on every container. So Mondays
                # 05:10 America/Edmonton, same wall-clock slot the daily
                # bounce used.
                #
                # `RESTART_IF_IDLE` (default true) skips rather than defers,
                # so a restart that lands on a populated server is lost until
                # the next occurrence — 14 days, not 48 hours as under the
                # daily cron. That is acceptable precisely because the RSS
                # data says nothing depends on the bounce happening; if it
                # ever does, that is a reason to reconsider the slot, not to
                # go back to daily.
                RESTART_CRON = "10 5 * * 1";

                # Drop the three stack-frame lines of the GetPublicIP wedge (see
                # that section at the top of this file). The loop emits five lines
                # per iteration; these three are pure noise, carrying no
                # incremental information after the first occurrence, so this cuts
                # the flood by 60% without losing a single diagnostic.
                #
                # The two informative lines are kept on purpose, because the flood
                # is also the detector: `JournalLogRateHigh` fires on journald
                # event rate, so filtering all five would make the wedge silent and
                # nothing else would notice it (that is exactly the gap #590 was
                # opened about). The ~160/s that survives still clears the 50/s
                # threshold comfortably, so detection is unchanged while the burn
                # rate drops 2.5x. Filtering the remaining
                # "Could not extract valid IP address" line would take this to 80%
                # and is a one-line addition — but it trades away that detection,
                # so make it deliberately, not as a drive-by.
                #
                # Matching is case-sensitive substring (valheim-logfilter is Go,
                # `strings.Contains`). The suffix after the prefix is just a unique
                # name. Do NOT reach for the `ON_VALHEIM_LOG_FILTER_*` hook
                # variants here: runHook does exec.Command("/bin/bash", "-c", ...)
                # per matching line, so at this rate the mitigation would cost far
                # more than the logging it replaces.
                VALHEIM_LOG_FILTER_CONTAINS_GetPublicIPCheckDisposed = "at System.Net.Http.HttpClient.CheckDisposedOrStarted";
                VALHEIM_LOG_FILTER_CONTAINS_GetPublicIPSetTimeout = "at System.Net.Http.HttpClient.set_Timeout";
                VALHEIM_LOG_FILTER_CONTAINS_GetPublicIPFrame = "at ZNet.<GetPublicIP>g__DownloadStringAsync";
              }
              // lib.optionalAttrs cfg.bepinex {
                # Install BepInEx on next start so mod DLLs dropped into
                # /config/bepinex/plugins load. See the "Mods" section at the
                # top of this file.
                #
                # Set only when true, rather than always emitting
                # `BEPINEX = "false"`. The image's own default is off, so the
                # two are equivalent to the container — but the var is part of
                # the generated unit, so emitting it unconditionally would
                # rewrite podman-valheim.service on the crossplay host and
                # bounce it for no behavioural reason, which on that host
                # rotates the join code out from under every player holding
                # one.
                BEPINEX = "true";
              };
              environmentFiles = [ config.sops.templates."valheim.env".path ];
              extraOptions = [ "--network=host" ];
            };
          }
          metrics
          (lib.mkIf cfg.crossplay joincode)
          (lib.mkIf cfg.playerNotify player)
        ]
      );
    };
}
