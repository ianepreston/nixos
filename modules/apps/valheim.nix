# Valheim - dedicated server (lloesche/valheim-server container).
# Gameplay is UDP and there's no web UI to put behind Caddy/Authentik,
# so the exposed surface is just the three game UDP ports. They're
# open on every interface (LAN + tailscale0) — joining over LAN is
# the path used from machines without tailscale. The host sits behind
# the home router's NAT, so WAN reachability isn't part of the
# threat model. If hpp-1 ever moves to a routable address, tighten
# this to `networking.firewall.interfaces.<lan>.allowedUDPPortRanges`
# + the tailscale0 rule.
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
#   Session "hpp-valheim" with join code 123456 and IP a.b.c.d:2456 is active ...
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
      gamePort = 2456;
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
      # orphans a `podman logs -f`). `-b -f` replays this boot before
      # following, which re-emits the current code when the watcher
      # itself restarts; the dedupe below is what makes that harmless.
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

          # `-oE 'registered with join code [0-9]+'` yields exactly five
          # whitespace-separated fields; the code is the last.
          ${pkgs.systemd}/bin/journalctl -u podman-valheim.service -b -f -o cat \
            | ${pkgs.gnugrep}/bin/grep --line-buffered -oE 'registered with join code [0-9]+' \
            | while read -r _ _ _ _ code; do
                notify "$code"
              done
        '';
      };

      # gamePort..gamePort+2 — the third port is what the PlayFab
      # backend uses under crossplay.
      networking.firewall.allowedUDPPortRanges = [
        {
          from = gamePort;
          to = gamePort + 2;
        }
      ];

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
          SERVER_NAME = "hpp-valheim";
          WORLD_NAME = "hpp";
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
