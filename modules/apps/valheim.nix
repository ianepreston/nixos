# Valheim - dedicated server (ghcr.io/community-valheim-tools/valheim-server
# container, formerly lloesche/valheim-server).
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
#   ssh amos1 -- sudo podman logs valheim 2>&1 | grep -i 'join code' | tail -1
#
# which prints a line of the form
#   Session "amos1-g2-valheim" with join code 123456 and IP a.b.c.d:2456 is active ...
#
# ## prod-only: one dedicated server per public IP
#
# Imported through `prodOnlyApps` in ../profiles/server-apps.nix, so this
# lands on amos1 only. That is not a cost-saving like the network
# controllers — it is a correctness requirement, and it was learned the
# hard way on 2026-09-11.
#
# A PlayFab join code resolves to a *network endpoint*, not to a server
# identity. This container runs `--network=host` on UDP 2456, so two
# hosts behind one home NAT register the identical public endpoint
# (`<public-ip>:2456`) with PlayFab. They collide, and the host that
# claimed the endpoint most recently answers every code — including the
# other host's. The failure is near-undebuggable from the client: the
# session *name* travels with the code, so joining with hpp-1's code
# showed "hpp-1-g2-valheim" in the UI while actually connecting to
# amos1's server and amos1's world. Only the two servers' logs
# disagreeing (one recording the join, the other recording nothing)
# makes it visible.
#
# Running the app on one host removes the collision outright. If a dev
# instance is ever wanted back, it needs a distinct game port, not just a
# distinct world name.
#
# The same incident showed the second reason. `worldGeneration` is one
# number shared by every host, so a bump reseeds once per host — the
# 2026-09-11 1.0/Deep North reseed created `hpp-1-g2` *and* `amos1-g2`,
# two unrelated maps. Players followed whichever join code they could
# see and built three days of world on the dev host's copy, which then
# had to be migrated onto amos1 by hand. One host, one world, one reseed.
#
# A contributing factor worth remembering, since it is the reason nobody
# noticed for three days: valheim-joincode-notify reads codes out of the
# journal, so journald rate-limiting is silent data loss for it. The
# GetPublicIP flood (see #590 and the log-filter notes below) was getting
# ~4,160 messages per 30s suppressed on amos1, the join-code line among
# them, so prod announced no code at all while looking perfectly healthy
# — unit `active (running)`, hundreds of MB of journal read, zero
# matches. The per-unit rate cap below plus the log filter close that
# window; the structural fix is that there is now only one server whose
# code can go missing.
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
# restarts.
#
# `RESTART_CRON` and `UPDATE_CRON` are independent, and an earlier version
# of this comment wrongly conflated them — disabling the restart cron does
# *not* cost you an up-to-date server. The image's valheim-updater bounces
# the server itself when a version actually lands: update() detects the
# changed files from its rsync, logs "Valheim Server was updated -
# restarting", and writes a restart file that check_server_restart() turns
# into `supervisorctl restart valheim-server`. That path runs off
# UPDATE_CRON's 15-minute check regardless of what RESTART_CRON is set to.
#
# So the daily bounce buys exactly one thing: a periodic clean slate as
# insurance against a game-server memory leak. That is also all upstream
# ever claimed for it — the README documents RESTART_CRON with no rationale
# at all, and the feature request that introduced it (lloesche/
# valheim-server-docker#65) asked for it "just in case there's an issue
# with a memory leak or similar in some release of the dedicated server".
# The leak reports behind that concern are real but come from busy servers
# with large worlds and week-long uptimes, which is not this.
#
# Pulling the cron back is tracked in #458, gated on the
# valheim-metrics exporter below having run long enough to establish a
# baseline. Don't change it before then: the metrics are what tell us
# whether the insurance was ever worth paying for.
#
# Some mods misbehave under the PlayFab backend, which is why the
# image leaves crossplay off by default — relevant if BEPINEX is ever
# turned on below.
#
# World state and the image's automatic world backups (every 2h by
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
# ## GetPublicIP log-rate runaway (upstream game bug, #590)
#
# One transient HTTP failure can wedge the game server into a permanent
# ~68/s logging loop. Seen once on hpp-1 on 2026-09-08: the container came
# up at 05:15 after a nixos-upgrade reboot, looped until it was restarted
# by hand at 09:05, and wrote 4,721,938 lines / 1.04 GB of journal in that
# 3h50m — ~96% of the host's entire 24h journal volume.
#
# `ZNet.GetPublicIP` walks a fallback list of public-IP endpoints, reusing
# one shared `HttpClient` and assigning `.Timeout` per attempt. In .NET that
# is illegal once a request has been sent, so the first genuine failure
# poisons the client permanently:
#
#   1 System.Net.Http.HttpRequestException   ipinfo.io returned non-2xx
#   942775 System.InvalidOperationException  "This instance has already
#                                            started one or more requests"
#
# Every attempt after the first throws in `set_Timeout` before touching the
# network — no I/O, no timeout, no backoff — so it spins as fast as the
# retry loop allows. Nothing here can fix it; the image only wraps the game
# binary. Recovery is `podman restart valheim`.
#
# Note the obvious mitigation does not work: `SERVER_PUBLIC = "false"` is
# already set below and the public-IP lookup runs regardless.
#
# Nothing alerted at the time — the unit stayed active, systemd never
# restarted it, the server kept serving and the exporter kept publishing.
# That gap is now covered generically by `JournalLogRateHigh` in
# modules/system/victoriametrics.nix rather than by anything Valheim-
# specific, since a service logging itself into the ground is not a
# Valheim-only failure mode.
#
# ### Recurrence on amos1, 2026-09-11 — and why there is now a filter
#
# It recurred, harder. amos1's server was restarted by the in-container
# UPDATE_CRON at ~07:16 and wedged at 09:08:21, running at **~400/s** (vs
# hpp-1's 68/s) until the unit was stopped at 16:05. `JournalLogRateHigh`
# fired and worked exactly as designed — it is what caught this.
#
# hpp-1's server restarted within 17 minutes of amos1's (same update) and
# did *not* wedge. So this is not amos1-specific: the loop starts from one
# transient HTTP failure on the first public-IP fetch after a server start,
# making every restart on every host a coin flip.
#
# The new cost this time was not disk, it was **retention**. Both hosts cap
# the journal at ~4G. hpp-1 gets ~9 days out of that budget; amos1 was
# reduced to 6.5 hours, its oldest surviving entry rotating forward faster
# than the incident itself (the 09:08 onset had already been vacuumed away
# by the time it was diagnosed). Losing every other unit's history on a prod
# host is a debugging capability you need most during an *unrelated*
# incident, which is a worse failure than the 1 GB of churn #590 measured.
#
# Hence the `VALHEIM_LOG_FILTER_CONTAINS_*` vars in the environment block
# below. The earlier stance here — "deliberately not filtered" — was about
# vector.nix, and that part still holds for a different reason than it
# claimed: vector reads *from* journald, so a vector rule drops these lines
# only after they have already been written to /var/log/journal and rotated
# the journal away. It would protect downstream log storage and nothing
# else. The image's own log filter runs inside the container, ahead of
# podman's log driver, and is the only layer that can protect retention.
#
# The filter is deliberately partial — see the comment on the vars for why
# suppressing all five lines would make the wedge undetectable.
#
# Adding mods later (BepInEx / Valheim+ / Jotunn):
# Set `BEPINEX = "true"` in the `environment` block below; on next
# start the image installs BepInEx into /config/bepinex. Drop mod
# DLLs into /var/lib/containers/valheim/config/bepinex/plugins/ and
# restart `podman-valheim.service`. Server-side-only mods just need
# the DLL; client-affecting mods need every player to install the
# same mod locally. See
# https://github.com/community-valheim-tools/valheim-server-docker#bepinex.
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
      # node_exporter textfile collector drop dir — defined in
      # modules/system/victoriametrics.nix's node exporter config. Kept in
      # sync by hand, same as server-backups.nix and _rollback-root.nix.
      textfileDir = "/var/lib/node-exporter-textfile-collector";

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
      # be numbers to keep in sync. Only amos1 runs this now (see the
      # prod-only section in the header), so a bump reseeds exactly one
      # world — when it shipped on both hosts it quietly made two, which
      # is how the g2 reseed stranded three days of play on hpp-1's copy.
      # The hostName prefix is retained so the world name still says which
      # host owns it.
      #
      # The old world's files are *not* deleted — they stay in
      # /var/lib/containers/valheim/config/worlds_local (and in restic) under
      # the previous name, so a bump is reversible by reverting this number.
      # Delete them by hand once you're sure you don't want them back.
      worldGeneration = 2;
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

      systemd = {
        services = {
          # Per-unit journald rate cap, so a GetPublicIP wedge (see that
          # section at the top of this file) can't consume the host's whole
          # journal again. 2400 per 30s = 80 lines/sec.
          #
          # This is deliberately a *per-unit* cap rather than the global
          # `RateLimitBurst` tightening floated in #590, because the global
          # lever no longer works. journald's stock setting is 10000/30s =
          # 333/s per service; the busiest legitimate burst on these hosts
          # (nix-gc) peaks around 137/s, and the wedge now runs at ~160/s
          # once the VALHEIM_LOG_FILTER_CONTAINS_* filters below have taken
          # 60% of it out. Those two numbers are close enough that no global
          # threshold is both safe for nix-gc and effective against the
          # runaway — filtering the flood closed the window a global cap
          # needed. A per-unit cap has no such conflict: it only constrains
          # the one unit with a known pathology.
          #
          # 80/s is ~25x healthy valheim traffic (~3/s), so this never binds
          # in normal operation, and it stays above the 50/s
          # `JournalLogRateHigh` threshold in modules/system/victoriametrics.nix
          # so a capped wedge still alerts rather than going quiet — same
          # reason the log filter is partial. journald additionally logs
          # "Suppressed N messages from podman-valheim.service" when the cap
          # engages, which names the culprit outright.
          #
          # Merges into the unit generated by virtualisation.oci-containers.
          podman-valheim.serviceConfig = {
            LogRateLimitIntervalSec = "30s";
            LogRateLimitBurst = 2400;
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
          valheim-joincode-notify = {
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

          # Valheim is invisible to every existing alert path, so this
          # publishes the missing signals to the node_exporter textfile
          # collector for vmalert to consume:
          #
          #   - gatus can't watch it — the server is UDP-only under
          #     crossplay and STATUS_HTTP is off, so there is no endpoint.
          #   - SystemdUnitFailed watches the wrong layer. supervisord
          #     restarts valheim-server *inside* the container, so systemd
          #     holds podman-valheim.service `active` the whole time the
          #     game server is crash-looping.
          #   - cAdvisor only scrapes /system.slice/podman-valheim.service,
          #     which is the conmon wrapper (~1 MiB, flat forever). The
          #     payload cgroup that actually holds the game server
          #     (/machine.slice/libpod-<id>.scope/container) is not in its
          #     series at all, so no timeseries tracked the server's memory.
          #
          # That last gap is the load-bearing one: the daily RESTART_CRON
          # bounce (see the restart-cadence notes at the top of this file)
          # exists upstream purely as insurance against a game-server memory
          # leak, and nothing here could have told us whether that leak was
          # real. These metrics are the prerequisite for pulling that cron
          # back — see #458.
          #
          # Everything is read from the host PID namespace: `--network=host`
          # means valheim_server.x86_64 is plainly visible in /proc, so this
          # never shells into the container. A wedged or paused podman can't
          # make the exporter hang, and there's no dependency on the podman
          valheim-metrics = {
            description = "publish valheim server health to node_exporter textfile collector";
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "PATH=${
                  lib.makeBinPath [
                    pkgs.coreutils
                    pkgs.procps
                    pkgs.gawk
                  ]
                }"
              ];
            };
            script = ''
              set -eu
              out=${textfileDir}/valheim.prom
              mkdir -p "$(dirname "$out")"

              up=0
              rss=0
              uptime=0
              cgmem=0

              # `|| true` so `set -e` survives the no-match case: pgrep exits
              # 1 when the server is down, which is a value we want to
              # publish (up=0), not an error that should kill the unit.
              pid=$(pgrep -f valheim_server.x86_64 | head -1 || true)
              if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
                up=1

                rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
                [ -n "$rss_kb" ] || rss_kb=0
                rss=$(( rss_kb * 1024 ))

                uptime=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -dc '0-9' || true)
                [ -n "$uptime" ] || uptime=0

                # Resolve the payload cgroup from the process itself rather
                # than hardcoding a libpod path — the container id changes
                # every time the container is recreated.
                cg=$(awk -F: 'NR==1{print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
                if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.current" ]; then
                  cgmem=$(cat "/sys/fs/cgroup$cg/memory.current" 2>/dev/null || echo 0)
                fi
              fi

              # Atomic write via tempfile + rename so a crashed run never
              # leaves node_exporter reading a half-written .prom.
              tmp=$(mktemp -p "$(dirname "$out")" .valheim.prom.XXXXXX)
              {
                echo "# HELP valheim_server_up Whether the valheim_server process is running (1) or not (0)."
                echo "# TYPE valheim_server_up gauge"
                echo "valheim_server_up $up"
                echo "# HELP valheim_server_rss_bytes Resident set size of the valheim_server process. The leak signal: anonymous memory only, so it is not inflated by the page cache that steamcmd and world saves push into the cgroup."
                echo "# TYPE valheim_server_rss_bytes gauge"
                echo "valheim_server_rss_bytes $rss"
                echo "# HELP valheim_server_uptime_seconds Seconds since the valheim_server process started. Resets on every supervisord restart, so a value that stays low means the server is crash-looping."
                echo "# TYPE valheim_server_uptime_seconds gauge"
                echo "valheim_server_uptime_seconds $uptime"
                echo "# HELP valheim_container_memory_bytes memory.current of the container payload cgroup. Total footprint including page cache, so it runs several GiB above RSS and is context rather than a leak signal."
                echo "# TYPE valheim_container_memory_bytes gauge"
                echo "valheim_container_memory_bytes $cgmem"
              } > "$tmp"
              chmod 0644 "$tmp"
              mv "$tmp" "$out"
            '';
          };
        };

        timers.valheim-metrics = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "2m";
            Unit = "valheim-metrics.service";
          };
        };
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
        image = "ghcr.io/community-valheim-tools/valheim-server:1.2.0@sha256:138c6f10759e8342309cfefe0b191221a956771ada1ea87157013d62e2befa19";
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
          # block at the top of this file for the LAN-join tradeoff.
          CROSSPLAY = "true";

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
        };
        environmentFiles = [ config.sops.templates."valheim.env".path ];
        extraOptions = [ "--network=host" ];
      };
    };
}
