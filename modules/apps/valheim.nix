# Valheim - dedicated server (lloesche/valheim-server container).
# Gameplay is UDP and there's no web UI to put behind Caddy/Authentik.
# Since crossplay went on there is no inbound listening surface at all:
# the server reaches PlayFab outbound and players arrive over that
# relay, so the game UDP ports are commented out further down rather
# than opened. Joining is by 6-digit join code, from every client —
# LAN, tailnet and console alike.
#
# ## Crossplay (CROSSPLAY=true)
#
# `CROSSPLAY=true` makes the image append `-crossplay` to the server
# args, which swaps the networking backend from Steam matchmaking to
# Microsoft's PlayFab Party. That does two things:
#
# 1. Non-Steam clients (Xbox / Microsoft Store / PS5 / Switch 2) can
#    join at all — they cannot reach a Steam-backend server, period.
# 2. Traffic is relayed through PlayFab, so a client outside the LAN
#    connects without any inbound port-forward on the home router.
#    That's the reason this is on: a friend on a console who isn't a
#    tailnet peer has no other route in.
#
# The tradeoff: with `-crossplay` the client can no longer connect by
# LAN or loopback address (upstream's dedicated-server guide is
# explicit about this). Everyone — LAN, tailnet, console — joins with
# the 6-digit join code instead. The code is issued by PlayFab and
# regenerates on every server restart, so it has to be re-shared after
# a container bounce. Read the current one off the server log:
#
#   ssh hpp-1 -- sudo podman logs valheim 2>&1 | grep -i 'join code' | tail -1
#
# which prints a line of the form
#   Session "hpp-1-g1-valheim" with join code 123456 and IP a.b.c.d:2456 is active ...
#
# ## Restart cadence vs. the join code
#
# The image runs its own cron inside the container: `UPDATE_CRON` checks
# for a game update every 15 minutes and `RESTART_CRON` restarts daily at
# 05:10 — both left at their upstream defaults here. Every one of those
# restarts rotates the join code (it's a fresh PlayFab session), which is
# what valheim-joincode-notify below exists to announce.
#
# That is less disruptive than it sounds because `UPDATE_IF_IDLE` and
# `RESTART_IF_IDLE` also default to `true`: the container only takes
# either action when no players are connected, so the code never rotates
# out from under a live session. The cost is entirely "look up the new
# code before you next sit down to play" — a player holding yesterday's
# code has a stale one, and the saved server entry (Join Game -> Add
# server) is keyed on the code, so it needs deleting and re-adding rather
# than reconnecting. Upstream Valheim offers no way to pin a code across
# restarts; there is no config to change here, only the choice to disable
# the crons and restart manually, which trades an updated server for a
# stabler code. Not worth it.
#
# Some mods misbehave under the PlayFab backend, which is why the
# image leaves crossplay off by default — relevant if BEPINEX is ever
# turned on below.
#
# World state and lloesche's automatic world backups (every 2h by
# default into /config/backups inside the container) live under
# /var/lib/containers/valheim/config, which the daily restic snapshot
# in modules/system/server-backups.nix picks up automatically. The
# Steam install of the game itself lives under
# /var/lib/containers/valheim/cache so it lands inside the existing
# `/var/lib/containers/*/cache` restic exclude — it's ~1.5 GB and the
# image re-downloads it on next start if missing.
#
# `--network=host` so the host firewall (INPUT chain) is the real gate
# on the game ports rather than relying on podman's DNAT/FORWARD
# behaviour. UDP > 1024, so the remapped PUID user can bind without
# CAP_NET_BIND_SERVICE.
#
# Adding mods later (BepInEx / Valheim+ / Jotunn):
# Set `BEPINEX = "true"` in the `environment` block below; on next
# start the image installs BepInEx into /config/bepinex. Drop mod
# DLLs into /var/lib/containers/valheim/config/bepinex/plugins/ and
# restart `podman-valheim.service`. Server-side-only mods just need
# the DLL; client-affecting mods need every player to install the
# same mod locally. See
# https://github.com/lloesche/valheim-server-docker#bepinex.
_: {
  flake.modules.nixos.valheim =
    {
      config,
      pkgs,
      hostSpec,
      ...
    }:
    let
      # Bump to reseed. WORLD_NAME is the basename of the world's .db/.fwl in
      # /config/worlds_local; the image generates a fresh map whenever that
      # basename has no save behind it. So incrementing this starts a brand
      # new world on next container start — which is the intended mechanism
      # for wiping and re-rolling when 1.0 lands.
      #
      # This is deliberately one value shared by every host rather than a
      # hostSpec option: a reseed is a "start over everywhere" decision, and
      # a per-host knob would just be two numbers to keep in sync. The
      # hostName prefix is what keeps hpp-1's and amos1's worlds distinct.
      #
      # The old world's files are *not* deleted — they stay in
      # /var/lib/containers/valheim/config/worlds_local (and in restic) under
      # the previous name, so a bump is reversible by reverting this number.
      # Delete them by hand once you're sure you don't want them back.
      worldGeneration = 1;
      worldName = "${hostSpec.hostName}-g${toString worldGeneration}";
    in
    {
      sops = {
        secrets = {
          "valheim/server_password" = {
            inherit (hostSpec) sopsFile;
          };

          # Consumed directly (the notifier reads the path in its script)
          # rather than through a template, so the restart trigger has to
          # live on the secret — there's no template to bind it to. See
          # CLAUDE.md "restartUnits goes on the template, not the secret",
          # direct-consumption exception.
          "valheim/discord_webhook" = {
            inherit (hostSpec) sopsFile;
            restartUnits = [ "valheim-joincode-notify.service" ];
          };
        };

        # restartUnits lives on the template (not the secret): the container
        # consumes the rendered template via environmentFiles, and sops-nix
        # writes secrets and re-renders templates in separate phases. Binding
        # the restart to the template guarantees it fires after the re-render
        # flushes the rotated credential. See CLAUDE.md "restartUnits goes on
        # the template, not the secret".
        templates."valheim.env" = {
          content = ''
            SERVER_PASS=${config.sops.placeholder."valheim/server_password"}
          '';
          restartUnits = [ "podman-valheim.service" ];
        };
      };

      # No `port` — valheim uses `--network=host` and opens its UDP game
      # ports on the firewall directly (below), so nothing is published on
      # 127.0.0.1. linuxServer drives the in-image PUID/PGID drop.
      myContainerApp.valheim = {
        linuxServer = true;
        stateDirs = [
          "/var/lib/containers/valheim"
          "/var/lib/containers/valheim/config"
          "/var/lib/containers/valheim/cache"
        ];
      };

      # The crossplay join code is issued fresh by PlayFab on every
      # server start — an auto-upgrade or a container bounce silently
      # invalidates whatever code players are holding. This watches the
      # server log and pushes each new code to Discord so nobody has to
      # notice the hard way.
      #
      # Source is journalctl rather than `podman logs` so the watcher
      # survives the container being recreated (a new container id
      # orphans a `podman logs -f`).
      #
      # The read is deliberately two passes rather than one following
      # invocation, because neither single-pass form is correct:
      #
      #   `-b -f`               `-f` implies `--lines=10` and that cap
      #                         beats `-b`, so this backfills ten lines,
      #                         not the boot. The join-code line sits
      #                         thousands of lines back in a running
      #                         server's journal, so a watcher starting
      #                         any time after server startup matches
      #                         nothing and stays mute forever.
      #   `-b -f --lines=all`   Replays every code line since boot on
      #                         every watcher start. The marker below
      #                         only suppresses repeats of the code it
      #                         last announced, so a boot that saw
      #                         several distinct codes re-announces the
      #                         whole sequence on each restart — one
      #                         burst of stale Discord messages per
      #                         deploy.
      #
      # So: pass 1 reads the backlog and announces only the newest code
      # in it; pass 2 follows from a cursor for live changes. Exactly one
      # announcement per distinct code.
      #
      # The cursor is captured *before* the backlog scan, not after. That
      # ordering is what closes the gap: a code landing between the two
      # reads is at or after the cursor, so it is caught by the follow
      # (and possibly also by the backlog scan — an overlap the marker
      # collapses). Reading the cursor after the scan would instead leave
      # a window in which a code is in neither pass and is never
      # announced.
      #
      # Dedupe state lives in RuntimeDirectory (/run), not /var/lib, on
      # purpose: a reboot restarts the server and therefore rotates the
      # code, so losing the marker exactly when it stops being true is
      # the correct behaviour — and it keeps this out of the
      # preservation/restic bookkeeping in server-apps.nix entirely.
      systemd.services.valheim-joincode-notify = {
        description = "Post the Valheim crossplay join code to Discord when it changes";
        # The sops edge is load-bearing, not decorative: without it this
        # unit starts during activation before sops-install-secrets has
        # written the webhook, dies on the missing file, and takes the
        # whole `switch-to-configuration` to exit 4 (= some units failed)
        # — i.e. a red deploy. `restartUnits` on the secret does heal it
        # a beat later, but the failed-unit window is what breaks the
        # deploy. Ordering only (no requires/wants): the unit is
        # Type=oneshot *without* RemainAfterExit, so it deactivates after
        # running and a hard dependency would drag this down with it.
        after = [
          "sops-install-secrets.service"
          "podman-valheim.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Restart = "always";
          RestartSec = 10;
          RuntimeDirectory = "valheim-joincode-notify";
          # Without this systemd deletes RuntimeDirectory every time the
          # unit stops, so the dedupe marker vanishes on each restart and
          # every deploy re-announces an unchanged code. "yes" keeps it
          # across unit restarts while /run being a tmpfs still clears it
          # on reboot — which is the wanted semantics, since a reboot
          # rotates the code anyway.
          RuntimeDirectoryPreserve = "yes";
          # Root: needs to read both the full journal and the sops
          # secret. Everything below is off by default for a root unit.
          ProtectHome = true;
          ProtectSystem = "strict";
          PrivateTmp = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };

        script = ''
          set -uo pipefail

          marker=/run/valheim-joincode-notify/last
          webhook="$(cat ${config.sops.secrets."valheim/discord_webhook".path})"
          server=${config.virtualisation.oci-containers.containers.valheim.environment.SERVER_NAME}

          notify() {
            code="$1"
            if [ -f "$marker" ] && [ "$(cat "$marker")" = "$code" ]; then
              echo "join code $code already announced, skipping"
              return 0
            fi

            payload="$(${pkgs.jq}/bin/jq -nc \
              --arg code "$code" \
              --arg server "$server" \
              '{content: ("Valheim server **" + $server + "** is up.\nCrossplay join code: **" + $code
                          + "**\n_This code changes every time the server restarts._")}')"

            # url via `-K -` (stdin) so the webhook secret never lands
            # in the process cmdline. A failed POST must not kill the
            # watcher — log it and keep following the journal.
            if printf 'url = "%s"\n' "$webhook" \
              | ${pkgs.curl}/bin/curl -fsS -K - \
                  -X POST -H 'Content-Type: application/json' -d "$payload"; then
              echo "announced join code $code"
              echo "$code" > "$marker"
            else
              echo "failed to post join code $code to discord" >&2
            fi
          }

          journalctl=${pkgs.systemd}/bin/journalctl
          grep=${pkgs.gnugrep}/bin/grep

          # Position first, read second — see the cursor note above.
          # `--show-cursor` appends a `-- cursor: <id>` line after the
          # last entry, which is what -n 1 is here to produce cheaply.
          cursor="$("$journalctl" -u podman-valheim.service -b -n 1 -o cat --show-cursor 2>/dev/null \
            | ${pkgs.gnused}/bin/sed -n 's/^-- cursor: //p')"

          # Pass 1 — backlog. `-oE 'registered with join code [0-9]+'`
          # yields exactly five whitespace-separated fields; the code is
          # the last, so ''${line##* } is the code. Only the newest match
          # is announced; earlier ones in this boot are already stale.
          backlog="$("$journalctl" -u podman-valheim.service -b --lines=all -o cat 2>/dev/null \
            | "$grep" -oE 'registered with join code [0-9]+' \
            | tail -1)"
          if [ -n "$backlog" ]; then
            notify "''${backlog##* }"
          else
            echo "no join code in the journal for this boot yet; following for one"
          fi

          # Pass 2 — live. Following from the cursor means no historical
          # entry is re-emitted, so the marker is a guard against the
          # server relogging one unchanged code rather than the thing
          # holding back a replay burst.
          if [ -n "$cursor" ]; then
            set -- -f --after-cursor="$cursor"
          else
            # Empty journal for this unit this boot: nothing to anchor
            # to, so follow from now and take only new entries.
            set -- -b -f --lines=0
          fi

          "$journalctl" -u podman-valheim.service "$@" -o cat \
            | "$grep" --line-buffered -oE 'registered with join code [0-9]+' \
            | while read -r _ _ _ _ code; do
                notify "$code"
              done
        '';
      };

      # Inbound game ports — deliberately commented out, not deleted.
      #
      # Under crossplay the client cannot connect by LAN or loopback
      # address at all (verified on this server: joining by IP stopped
      # working the moment CROSSPLAY=true landed, while the join code
      # works), and outbound relay traffic to PlayFab needs no inbound
      # rule. So nothing can reach these ports by design and leaving
      # them open is exposure that buys nothing.
      #
      # Kept here as the revert path for the day PlayFab has an outage
      # and direct connect is the only way in. To restore: uncomment
      # the block below *and* set CROSSPLAY = "false" in the container
      # environment — the ports alone won't help while the server is on
      # the PlayFab backend. That also drops non-Steam clients, so it's
      # a deliberate fallback, not a both-ways config.
      #
      # gamePort..gamePort+2; the third port is the one the PlayFab
      # backend uses under crossplay.
      #
      # networking.firewall.allowedUDPPortRanges =
      #   let
      #     gamePort = 2456;
      #   in
      #   [
      #     {
      #       from = gamePort;
      #       to = gamePort + 2;
      #     }
      #   ];

      virtualisation.oci-containers.containers.valheim = {
        # lloesche tags by date (`latest`, `YYYY-MM-DD`) rather than
        # semver, so pin to the digest of `latest` for reproducibility;
        # renovate tracks `latest` and bumps the digest on its own
        # (see renovate.json's digest manager).
        # renovate: datasource=docker depName=lloesche/valheim-server
        image = "lloesche/valheim-server:latest@sha256:20fde516ce311e6084f82f295c9eb6934af57b357c657937a04f62bdf5946149";
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
          SERVER_PUBLIC = "false";
          # Switch the networking backend from Steam to PlayFab so
          # non-Steam clients can join and traffic is relayed rather
          # than requiring an inbound port-forward. See the crossplay
          # block at the top of this file for the LAN-join tradeoff.
          CROSSPLAY = "true";
        };
        environmentFiles = [ config.sops.templates."valheim.env".path ];
        extraOptions = [ "--network=host" ];
      };
    };
}
