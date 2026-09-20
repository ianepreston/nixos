# Valheim - dedicated server (ghcr.io/community-valheim-tools/valheim-server
# container, formerly lloesche/valheim-server).
# Gameplay is UDP and there's no web UI to put behind Caddy/Authentik.
#
# Two instances, and `myValheim` below is what makes them differ. amos1
# runs crossplay: the server reaches PlayFab outbound and players arrive
# over that relay, so there is no inbound listening surface at all and
# the game UDP ports stay shut. hpp-1 runs the Steam backend, which is
# the opposite shape — the game UDP ports are open on the host firewall
# and players connect by typing its LAN address. That asymmetry is not
# incidental; it is the whole reason a second instance can exist (see
# "Crossplay exclusivity" below).
#
# ## Crossplay (myValheim.crossplay)
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
# Grep for `is active` specifically, not for any line mentioning a join
# code. The server logs the code in three different shapes and only that
# one is authoritative:
#
#   Session "<name>" registered with join code <N>      the code *offered*
#   Created new join code <N> for session "<name>"      a candidate
#   Session "<name>" with join code <N> ... is active   confirmed live
#
# PlayFab can reject the offered code and mint a replacement, and a
# candidate can fail the server's own `Retry join-code check`. Both
# happened on 2026-09-18: re-registration echoed 496995, PlayFab issued
# 809934 then 555295, and the session went live on 555295 while the
# Discord watcher — then keyed on the `registered with` line — kept
# advertising 496995. Remote players got "unable to resolve join code";
# anyone holding the real code connected fine, so the server looked
# healthy from the inside. Fixed in #661; the watcher below now reads
# the same line this runbook does.
#
# **If that grep returns nothing for the current container run, the
# server is broken — it is not that no code was issued.** The three
# shapes above describe a confirmation that arrives; there is a fourth
# state, where it never does. On 2026-09-20 the `registered with` line
# was followed a second later by
#
#   NullReferenceException: Object reference not set to an instance of an object
#     at ZPlayFabMatchmaking.OnCheckJoinCodeSuccess (…FindLobbiesResult result)
#
# which killed the confirmation state machine outright: no `Retry
# join-code check` countdown, no `is active` line, ever. The registered
# code did not resolve for any client, and because the runbook grep and
# the watcher both key on `is active`, both went quiet rather than
# wrong — and a quiet watcher is indistinguishable from an idle healthy
# server. amos1 stayed that way for 3h32m until a player said so (#683).
#
# The remediation is a restart, which re-registers and confirms:
#
#   ssh amos1 -- sudo systemctl restart podman-valheim
#
# Note it may hand back the *same* digits — PlayFab keys the lobby on a
# deterministic custom ID — so an unchanged code is not evidence the
# restart did nothing. Check for the `is active` line, not for a new
# number. valheim-joincode-watchdog below now announces this state to
# Discord within ~3m, and ValheimJoinCodeUnconfirmed in
# ../system/victoriametrics.nix alerts on it.
#
# ### PlayFab peer-relay stalls — what crossplay actually costs players (#627)
#
# The section above frames the crossplay tradeoff as "you lose
# connect-by-address". That is the administrative cost. The cost players
# *feel* is this one, and it is the more important half.
#
# Every peer reaches a crossplay server through Microsoft's PlayFab Party
# relay. When a peer's relay endpoint is torn down under the game, Valheim
# keeps calling the Party API with the now-stale handle:
#
#   Keep socket for playfab/<peer>, try to reconnect before timeout
#   PlayFab network error ... code '4098': the operation was called with
#     an invalid handle
#   Failed to send, suspend TX on playfab/<peer> while trying to reconnect
#   ... 90 seconds ...
#   ZRpc timeout detected
#   Destroying abandoned non persistent zdo <peer-prefix>:<n> owner <peer-prefix>
#
# The server *deliberately* keeps the dead peer's socket, hoping for a
# reconnect, and holds it for the full `ZRpc timeout set to 90s` it logs on
# every handshake. Valheim distributes simulation by ZDO ownership, so for
# those 90s everything that peer owned — their character and every
# creature or object their client was simulating — is frozen for all other
# players. In a boss fight that is most of what is moving on screen, which
# is why it reads as "the server died" rather than "one player lagged out".
#
# Three things make this hard to diagnose from the inside, and all three
# are why the counters below exist:
#
#   - The host is idle and healthy throughout. CPU, RSS, NIC errors, UDP
#     errors, conntrack and kernel log were all clean across the
#     2026-09-13 incident window; `valheim_server_up` never dipped and
#     uptime never reset, so it is not a supervisord crash-loop.
#   - It looks like a player quitting. In that incident a second player
#     left one second *before* the ZRpc timeout expired, so the freeze
#     appeared to clear because they quit. The two events were
#     coincidental — the timeout was always going to fire at 90s.
#   - It is frequent, not exceptional: 12 occurrences over two days of
#     play, across six distinct peers on both Steam and PlayStation. So it
#     is not one player's ISP and not one bad client. Note that plain
#     `Keep socket ... try to reconnect` lines *without* the `suspend TX`
#     follow-up are ordinary clean disconnects that recover instantly; the
#     pathological signature is the `suspend TX` → `ZRpc timeout detected`
#     pair, which is exactly what the counters key on.
#
# Nothing here can fix it. The 90s timeout is a game constant, not a server
# setting, and the container only wraps the binary — there is no way to
# shorten the stall or evict a wedged peer sooner.
#
# `CROSSPLAY=false` is the only real fix, because it removes PlayFab from
# the path entirely — and it is not on the table. There is a PlayStation
# player in the group, and a non-Steam client cannot reach a Steam-backend
# server at all. The section above presents crossplay as a deliberate
# choice with a fallback; this is the concrete evidence that the fallback
# costs a real person their access, so it is not something to reach for
# casually when someone next complains about a freeze.
#
# What is left is visibility, so: `valheim_peer_relay_stall_total` and
# `valheim_zrpc_timeout_total` in the valheim-metrics exporter below. The
# frequency is the thing worth watching — a 90s stall is over before anyone
# could act on a page, so these are for trending, not alerting, and there
# is deliberately no vmalert rule. They are also the only way to tell
# whether a future image or game update helped. hpp-1 publishes them too
# and, running the Steam backend, should read flat zero on the stall
# counter — the A/B control mentioned under "What the dev instance cannot
# tell you" below.
#
# ## Crossplay exclusivity: one *crossplay* server per public IP
#
# The constraint learned the hard way on 2026-09-11 is not "one Valheim
# server per household" — it is one *PlayFab* server per public IP, and
# the distinction is what `myValheim.crossplay` exists to exploit.
#
# A PlayFab join code resolves to a *network endpoint*, not to a server
# identity. This container runs `--network=host` on UDP 2456, so two
# crossplay hosts behind one home NAT register the identical public
# endpoint (`<public-ip>:2456`) with PlayFab. They collide, and the host
# that claimed the endpoint most recently answers every code — including
# the other host's. The failure is near-undebuggable from the client: the
# session *name* travels with the code, so joining with hpp-1's code
# showed "hpp-1-g2-valheim" in the UI while actually connecting to
# amos1's server and amos1's world. Only the two servers' logs
# disagreeing (one recording the join, the other recording nothing)
# makes it visible. The app was made prod-only in 0b3c56b to stop that.
#
# An earlier version of this comment concluded a dev instance would need
# a distinct *game port*. That was the wrong lever. With
# `crossplay = false` the dev server never registers with PlayFab at all,
# so there is no endpoint to collide on and no port to keep in sync:
#
#   - Nothing to collide. The Steam backend publishes no relay session,
#     and `SERVER_PUBLIC=false` keeps it out of the community browser
#     too, so it has no public identity whatsoever. amos1's PlayFab
#     session is untouched.
#   - No join code on dev, which removes the *mechanism* of the original
#     incident rather than just the collision: nobody can follow a dev
#     join code into a dev world, because there is no dev join code.
#     Players reach dev only by deliberately typing its LAN address into
#     Join Game -> Add server.
#   - Reachability is fine for the intended audience. LAN clients connect
#     direct; tailnet clients arrive over behemoth's subnet route as
#     ordinary LAN traffic, so the one host-firewall rule below covers
#     both. No port-forward, no WAN exposure — the NAT stays the
#     boundary.
#
# ### What the dev instance cannot tell you
#
# Two honest limits, worth having in the file rather than rediscovering:
#
# 1. Console / non-Steam players cannot join dev at all — they can't
#    reach a Steam-backend server, period. Dev is a Steam-client-only
#    test bed.
# 2. A mod that passes on dev is not proven under crossplay. The image
#    leaves crossplay off by default precisely because some mods
#    misbehave on the PlayFab backend. Dev de-risks "does this load, does
#    it corrupt the world, does it survive a restart"; it cannot de-risk
#    "does it survive the relay". Prod stays the only place the relay path
#    exists — see also #627, where PlayFab peer-relay drops freeze world
#    objects for ~90s. (Small upside: a Steam-backend instance is a useful
#    A/B control for exactly that issue.)
#
# ### The second half of the 2026-09-11 damage, and why it's now harmless
#
# `worldGeneration` is one number shared by every host, so a bump reseeds
# once per host — the 2026-09-11 1.0/Deep North reseed created
# `hpp-1-g2` *and* `amos1-g2`, two unrelated maps. Players followed
# whichever join code they could see and built three days of world on the
# dev host's copy, which then had to be migrated onto amos1 by hand.
#
# Two worlds is fine again now, because the reason it hurt was that both
# were *reachable by the same accident*. Dev has no join code to follow
# and its world is scratch; a bump reseeds it alongside prod and nobody
# notices. See the note on `worldGeneration` in the `let` block below.
#
# A contributing factor worth remembering, since it is the reason nobody
# noticed for three days: valheim-joincode-notify reads codes out of the
# journal, so journald rate-limiting is silent data loss for it. The
# GetPublicIP flood (see #590 and the log-filter notes below) was getting
# ~4,160 messages per 30s suppressed on amos1, the join-code line among
# them, so prod announced no code at all while looking perfectly healthy
# — unit `active (running)`, hundreds of MB of journal read, zero
# matches. The per-unit rate cap below plus the log filter close that
# window; and the unit now only exists on the crossplay host, so there is
# still exactly one server whose code can go missing.
#
# ## Restart cadence vs. the join code
#
# The image runs its own cron inside the container: `UPDATE_CRON` checks
# for a game update every 15 minutes (upstream default) and
# `RESTART_CRON` restarts the game server — set below to Mondays 05:10
# rather than upstream's daily 05:10, see "Phase 1" further down. Every
# one of those restarts rotates the join code (it's a fresh PlayFab
# session), which is what valheim-joincode-notify below exists to
# announce.
#
# That is less disruptive than it sounds because `UPDATE_IF_IDLE` and
# `RESTART_IF_IDLE` also default to `true`: the container only takes
# either action when no players are connected, so the code never rotates
# out from under a live session. The cost is entirely "look up the new
# code before you next sit down to play" — a player holding a code from
# before the last bounce has a stale one, and the saved server entry
# (Join Game -> Add server) is keyed on the code, so it needs deleting
# and re-adding rather than reconnecting. Upstream Valheim offers no way
# to pin a code across restarts.
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
# So the bounce buys exactly one thing: a periodic clean slate as
# insurance against a game-server memory leak. That is also all upstream
# ever claimed for it — the README documents RESTART_CRON with no rationale
# at all, and the feature request that introduced it (lloesche/
# valheim-server-docker#65) asked for it "just in case there's an issue
# with a memory leak or similar in some release of the dedicated server".
# The leak reports behind that concern are real but come from busy servers
# with large worlds and week-long uptimes, which is not this.
#
# ### Phase 1 — daily to weekly, 2026-09-14 (#458)
#
# The valheim-metrics exporter below exists to answer whether that
# insurance was ever worth paying for. Seven days of
# `valheim_server_rss_bytes` against `valheim_server_uptime_seconds` on
# amos1, spanning 8 restart cycles and the first real multiplayer session
# (3 concurrent players, ZDOS ~114,500, 2026-09-13), say it was not. RSS
# *falls* with uptime, in mean and in max:
#
#   uptime    0h     1h     4h     8h    10h    15h    22h
#   mean    1252   1305   1201   1058    622    633    548   MB
#   max     1518   1511   1521   1518    786    829    852   MB
#
# Every cycle starts at 1.48-1.52 GB in hour 0-1, decays to a 430-850 MB
# steady state by hour 9-10, and then sits flat for the rest of the cycle
# (09-08 15:00 -> 09-09 05:00: 428.5 -> 426.4 MB over 14h). Player load
# is a ~+170 MB bump that comes back on logoff, so RSS tracks occupancy,
# not uptime. Peak across the whole window was 1.52 GB, at uptime 4.7h.
#
# So the restart *creates* the high-water mark rather than preventing
# one. The 1.5 GB is a startup transient — the exporter reads VmRSS from
# /proc of the pgrep'd pid every 2m, so that decay is one process's own
# RSS, not a pid switch.
#
# What the daily cron made unobservable is the week-scale question: no
# cycle ever exceeded a 24h uptime, so a slow leak could not have shown
# up in that data even if it were there. Weekly uptimes are the first
# window where one could, which is why Phase 2 (`RESTART_CRON = ""`,
# leaving restarts to update/reboot/deploy) is still gated rather than
# taken in the same change.
#
# Detection for that window is `ValheimMemoryBaselineHigh` in
# modules/system/victoriametrics.nix. The pre-existing 4 GiB
# `ValheimMemoryHigh` is a survival ceiling: a leak carrying RSS from
# 600 MB to 2 GB over a week would clear a whole weekly cycle in
# silence, which was fine when the process was reset every 24h and is
# not fine when detecting that leak is the point of the phase.
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
# ## Mods (BepInEx / Valheim+ / Jotunn)
#
# `myValheim.bepinex = true` makes the image install BepInEx into
# /config/bepinex on next start. Drop mod DLLs into
# /var/lib/containers/valheim/config/bepinex/plugins/ and restart
# `podman-valheim.service`. Server-side-only mods just need the DLL;
# client-affecting mods need every player to install the same mod
# locally. See
# https://github.com/community-valheim-tools/valheim-server-docker#bepinex.
#
# This is on for hpp-1 and off for amos1 — testing mods is the reason the
# dev instance exists. Note the limit from "What the dev instance cannot
# tell you" above: some mods misbehave specifically on the PlayFab
# backend, which is why the image ships crossplay off by default, so a
# green run on dev does not clear a mod for prod's relay path.
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

      # node_exporter textfile collector drop dir — defined in
      # modules/system/victoriametrics.nix's node exporter config. Kept in
      # sync by hand, same as server-backups.nix and _rollback-root.nix.
      textfileDir = "/var/lib/node-exporter-textfile-collector";

      # The single interface between valheim-player-notify and
      # valheim-metrics (#631). Deliberately a pair of files in /run rather
      # than a systemd dependency — the exporter must stay readable when a
      # wedged podman has the notifier stuck, so it reads the roster
      # opportunistically and publishes nothing when it isn't there. That
      # makes the *path* the whole contract, so both sides name it from here
      # rather than each hardcoding it.
      #
      # `ready` exists because `roster` alone is not a safe signal: the
      # notifier truncates it at startup and only refills it once the journal
      # replay finishes, so a reader keyed on the roster file would see an
      # authoritative-looking "0 players" for the length of every rebuild.
      # The marker is written after the replay, and systemd drops the whole
      # RuntimeDirectory on stop/restart (no RuntimeDirectoryPreserve), so it
      # is absent for exactly the window in which the roster is a lie.
      playerNotifyRuntimeDir = "/run/valheim-player-notify";
      playerRoster = "${playerNotifyRuntimeDir}/roster";
      playerRosterReady = "${playerNotifyRuntimeDir}/ready";

      # valheim-joincode-notify's state, and the seam between it,
      # valheim-joincode-watchdog and valheim-metrics (#683). Same shape as
      # the roster pair above and for the same reason: three units read or
      # write these paths, so they are named once here rather than three
      # times in three scripts.
      #
      # All three live in the notifier's RuntimeDirectory, which is /run and
      # therefore cleared on reboot. That is still the wanted semantics — a
      # reboot restarts the server, which re-registers — but note it is no
      # longer the *whole* story for `marker`; see the re-announce path in
      # valheim-joincode-notify below.
      #
      #   marker    the code last announced to Discord. Suppresses a repeat
      #             of an unchanged code.
      #   pending   "<code> <epoch>" for a registration whose confirming
      #             `is active` line has not arrived. Written by the
      #             notifier, cleared by it on confirmation, and read by
      #             both the watchdog (to alert) and valheim-metrics (to
      #             publish the age as a gauge).
      #   alerted   set by the watchdog once it has announced the current
      #             pending as unconfirmed. Stops it re-posting every minute,
      #             and is what tells the notifier that the eventual
      #             confirmation is *news* even at unchanged digits.
      joincodeRuntimeDir = "/run/valheim-joincode-notify";
      joincodeMarker = "${joincodeRuntimeDir}/last";
      joincodePending = "${joincodeRuntimeDir}/pending";
      joincodeAlerted = "${joincodeRuntimeDir}/alerted";

      # How long a registration may go unconfirmed before it is treated as
      # broken (#683).
      #
      # Derived, not picked: the server's own `Retry join-code check`
      # countdown starts at 99 and decrements once a second, so ~99s is the
      # longest wait the server itself will tolerate before giving up on a
      # code. Measured on amos1 — 2026-09-19 05:35:30/31/32 are checks
      # 99/98/97, one per second, with the `is active` line at 05:35:33; 30
      # retry lines across the 14 days to 2026-09-20, longest run 3. So every
      # healthy confirmation lands 1-4s after registration and the worst case
      # the protocol allows is ~99s. 120s clears that with margin.
      #
      # Do not re-derive this from a comment elsewhere in the file: it comes
      # from those log timestamps.
      joincodeGraceSeconds = 120;

      # The join-code gauge's two halves, as bindings rather than inline
      # `lib.optionalString` calls: an interpolation opening at column 0
      # inside an indented string would reset Nix's indentation stripping for
      # the whole script.
      #
      # Crossplay-gated so a Steam-backend host's exporter is byte-identical
      # to before #683 — it has no join code, so there is nothing to measure
      # and no reason to change hpp-1's closure for this.
      #
      # The `\n`-prefixed `*Line` wrappers are what make "byte-identical"
      # literally true rather than nearly true. Interpolating on its own
      # source line leaves that line's indentation behind when the string is
      # empty, so a Steam-backend host got a script differing from
      # origin/main by one line of trailing whitespace — no behaviour change,
      # but enough to rebuild the closure and to make a diff-based claim
      # false. Carrying the newline inside the optional string instead means
      # the crossplay=false expansion is exactly the empty string.
      joincodeGaugeReadLine = lib.optionalString cfg.crossplay "\n${joincodeGaugeRead}";
      joincodeGaugeEmitLine = lib.optionalString cfg.crossplay "\n${joincodeGaugeEmit}";

      joincodeGaugeRead = ''
        # Age of an unconfirmed join-code registration (#683). Read from
        # valheim-joincode-notify's pending file rather than from the
        # journal: the notifier already parses those lines, and duplicating
        # the parse here would be a second place to get the wording wrong.
        #
        # Opportunistic, exactly like the player roster above — an absent
        # file means "confirmed, nothing pending" and publishes no series.
        joincode_unconfirmed=
        if [ -f ${joincodePending} ]; then
          read -r _jccode _jcwhen _jcrest < ${joincodePending} || true
          case "''${_jcwhen:-}" in
            "" | *[!0-9]*) _jcwhen= ;;
          esac
          if [ -n "''${_jcwhen:-}" ]; then
            joincode_unconfirmed=$(( $(date +%s) - _jcwhen ))
            # A clock step backwards is the only way this goes negative,
            # and a negative age would read as "confirmed" to the rule.
            if [ "$joincode_unconfirmed" -lt 0 ]; then
              joincode_unconfirmed=0
            fi
          fi
        fi
      '';

      joincodeGaugeEmit = ''
        # Absent rather than 0 when there is nothing pending, for the same
        # reason valheim_players_online is: 0 is a meaningful value here
        # ("registered this instant") and must not double as no-data.
        #
        # Note this legitimately reads 1-4 on an ordinary re-registration,
        # since every confirmation is preceded by a brief pending window.
        # The alert threshold is what distinguishes that from a fault; see
        # ValheimJoinCodeUnconfirmed in ../system/victoriametrics.nix.
        if [ -n "''${joincode_unconfirmed:-}" ]; then
          echo "# HELP valheim_joincode_unconfirmed_seconds Seconds since the server registered a PlayFab join code without its confirming 'is active' line arriving. Absent while the live code is confirmed. A value past ${toString joincodeGraceSeconds} means the server's own join-code check never completed and the advertised code most likely does not resolve (#683)."
          echo "# TYPE valheim_joincode_unconfirmed_seconds gauge"
          echo "valheim_joincode_unconfirmed_seconds $joincode_unconfirmed"
        fi
      '';

      # Persistent state for the journal-derived relay counters (#627).
      # /var/lib rather than /run precisely because these are counters: the
      # point is a total that outlives the timer, the journal window and a
      # reboot.
      #
      # Which means it needs the preservation entry in the `config` block
      # below. Both valheim hosts are impermanent — `preservation.enable`
      # arrives via the `server` profile, not from anything in
      # modules/hosts/<host>.nix, so grepping the host files says otherwise
      # and is wrong. Without that entry `_rollback-root.nix` recreates
      # @root from @root-blank on every boot, the exporter takes its
      # first-run branch and re-seeds at the tail, and every event between
      # the last run and the reboot is dropped silently — with /var/log/journal
      # preserved, the evidence would still be on disk while the counter
      # said zero. `expectedPreservedDirs` in ../profiles/server-apps.nix
      # would not have caught it either; that assertion only derives from
      # `myAppState`, so eval stays green.
      #
      # Preserve-only, deliberately not `myAppState`: same call as
      # /var/lib/private/llama-cpp in ../apps/llm.nix. These are derived
      # counters, not authored state — restoring a month-old total out of
      # restic would be worse than starting from zero, because it would
      # publish a number that silently disagrees with the journal.
      metricsStateDir = "/var/lib/valheim-metrics";
      relayCursorFile = "${metricsStateDir}/journal-cursor";
      relayTotalsFile = "${metricsStateDir}/relay-totals";

      # The two journal lines the counters are built from, verified against
      # amos1's journal (30 and 25 occurrences respectively in the 14 days to
      # 2026-09-19). Anchored strings, not loose ones: `ZRpc timeout` alone
      # also matches `ZRpc timeout set to 90s`, which the server logs on every
      # handshake — it is the constant being announced, not a fault, and
      # grepping for it would swamp the signal with an order more matches.
      relayStallMatch = "Failed to send, suspend TX";
      relayTimeoutMatch = "ZRpc timeout detected";
      relayJournalPattern = "${relayStallMatch}|${relayTimeoutMatch}";

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
            container runs `--network=host` on UDP 2456, so two crossplay
            hosts behind one NAT register the identical
            `<public-ip>:2456` and silently answer each other's codes —
            the 2026-09-11 incident. Defaulting to `false` (the image's
            own default) keeps the host that needs the relay the one that
            has to ask for it.

            `true` gets non-Steam clients (console, Microsoft Store) and
            needs no inbound port-forward, at the cost of losing
            connect-by-address entirely. `false` opens the game UDP ports
            on the host firewall and players join by typing
            `<host-lan-ip>:2456`, Steam clients only.
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

      config = lib.mkIf cfg.enable {
        # The relay counters' totals and cursor (#627). See the
        # `metricsStateDir` note in the `let` block above for why this is
        # preserved but deliberately kept out of restic.
        preservation.preserveAt."/persist".directories = [ metricsStateDir ];

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
            # CLAUDE.md "restartUnits goes on the template, not the secret",
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
          # flushes the rotated credential. See CLAUDE.md "restartUnits goes on
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

        systemd = {
          # Split into three merged attrsets because the two notify units
          # are per-host. `optionalAttrs` rather than `mkIf` on the unit
          # value: `services.<name> = mkIf false {...}` leaves the attribute
          # name in place with no definitions, so the submodule evaluates to
          # defaults and systemd still gets a (blank) unit generated for it.
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
            # That last gap is the load-bearing one: the RESTART_CRON bounce
            # (see the restart-cadence notes at the top of this file) exists
            # upstream purely as insurance against a game-server memory leak,
            # and nothing here could have told us whether that leak was real.
            # These metrics are what paid for pulling the cron back from daily
            # to weekly, and they are what Phase 2 will be judged on — see
            # #458.
            #
            # Everything is read from the host PID namespace: `--network=host`
            # means valheim_server.x86_64 is plainly visible in /proc, so this
            # never shells into the container. A wedged or paused podman can't
            # make the exporter hang, and there's no dependency on the podman
            # units at all — no `after=`, no `requires=`.
            #
            # `valheim_players_online` (#631) keeps that property. It comes
            # from valheim-player-notify's roster, but by reading two files
            # out of /run, not by depending on the unit: a stuck notifier
            # costs the gauge and nothing else. See the `playerRoster` notes
            # at the top of this file.
            #
            # So do the relay counters (#627), which read the journal rather
            # than the container: journalctl talks to /var/log/journal, so a
            # wedged or paused podman still can't stall this unit — the
            # container's output has already been written by the time this
            # reads it. See "PlayFab peer-relay stalls" at the top of this
            # file for what they measure and why they are worth having.
            valheim-metrics = {
              description = "publish valheim server health to node_exporter textfile collector";
              serviceConfig = {
                Type = "oneshot";
                User = "root";
                # Holds the relay counters' running totals and journal
                # cursor (#627). Root unit, so this is ${metricsStateDir}
                # rather than /var/lib/private.
                StateDirectory = baseNameOf metricsStateDir;
                Environment = [
                  "PATH=${
                    lib.makeBinPath [
                      pkgs.coreutils
                      pkgs.procps
                      pkgs.gawk
                      # journalctl, for the relay counters below.
                      pkgs.systemd
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
                players=${joincodeGaugeReadLine}

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

                # Player count, one line per connected player, straight off
                # valheim-player-notify's roster (#631). Read outside the
                # `up` block on purpose: the roster is the notifier's state,
                # not the game process's, and gating it on pgrep would make
                # the gauge vanish for a different reason than it already
                # does below.
                #
                # Every other presence signal this server emits is known bad
                # under crossplay — the A2S query always answers 0, the
                # `IDLE_DATAGRAM_*` counting the image uses instead trips on
                # PlayFab lobby chatter, and the `now N player(s)` log lines
                # are internally inconsistent (a 3->2 leave logged "now 3").
                # The roster is derived from ZDO ownership instead, which is
                # why it is the source here.
                #
                # `$players` stays empty unless the marker says the roster is
                # both present and rebuilt, and an empty value omits the
                # series entirely rather than publishing 0. The asymmetry is
                # deliberate and load-bearing for #458, which wants to gate
                # the restart cron on an empty server: a wrong 0 bounces a
                # server with players on it, while a missing sample just
                # fails the rule's guard and skips the bounce. A companion
                # `_valid` gauge would instead keep publishing that wrong 0
                # next to a flag any rule can forget to check. So: absent.
                # Ask with `absent_over_time(valheim_players_online[...])` if
                # the gap itself ever needs alerting.
                #
                # This is also why hpp-1 never publishes the series at all —
                # it runs `playerNotify = false`, so there is no roster to
                # read and no gauge, with no extra gating needed here.
                if [ -e ${playerRosterReady} ]; then
                  players=$(awk 'END { print NR }' ${playerRoster} 2>/dev/null || true)
                fi

                # PlayFab peer-relay stalls (#627). Under crossplay a peer
                # whose relay endpoint faults leaves its socket held open for
                # the full 90s ZRpc timeout, and Valheim distributes
                # simulation by ZDO ownership — so for those 90s every
                # creature and object that peer was simulating is frozen for
                # everyone else. Players read that as "the server died"; the
                # host is idle and healthy throughout, and nothing else in
                # the monitoring stack can see it. These two counters are
                # what make the frequency trendable, and the only way to tell
                # whether a future image or game update helped.
                #
                # Counted incrementally against a saved cursor rather than by
                # rescanning, for two independent reasons:
                #
                #   - Honesty. journald is a *window*, not a ledger. amos1's
                #     4G cap fell to 6.5 hours of retention during the #590
                #     wedge, so a rescanned total would drop when the journal
                #     vacuumed — which PromQL reads as a counter reset and
                #     turns into a phantom increase, exactly inverting the
                #     trend this is for.
                #   - Cost. A --grep over amos1's retained journal for this
                #     unit takes over two minutes; this timer fires every
                #     two. Anchored to a cursor, each run reads one interval.
                #
                # Both counters are unlabelled on purpose. The natural label
                # is the peer id, but those are per-connection and unbounded
                # over time (six distinct peers in the two days #627 sampled),
                # so labelling would grow the textfile series set without
                # limit for a question — "is this getting worse?" — that is
                # asked in aggregate anyway. The per-peer breakdown stays a
                # journal grep.
                stalls=0
                timeouts=0
                if [ -r ${relayTotalsFile} ]; then
                  read -r stalls timeouts < ${relayTotalsFile} || true
                fi
                case "$stalls" in "" | *[!0-9]*) stalls=0 ;; esac
                case "$timeouts" in "" | *[!0-9]*) timeouts=0 ;; esac

                # The unit's newest cursor, read *before* counting. Used to
                # seed the first run, and as a fallback position if the
                # counting pass reports none.
                #
                # Reading it first is what makes that fallback safe: an entry
                # written while the counting pass runs is necessarily *after*
                # this cursor, so falling back to it can only ever re-read
                # entries, never skip past unread ones. Cheap — journalctl
                # seeks straight to the tail.
                tailcursor=$(journalctl -u podman-valheim.service -n 1 -o cat --show-cursor 2>/dev/null \
                  | awk '/^-- cursor: /{ print substr($0, 12) }' || true)

                if [ -s ${relayCursorFile} ]; then
                  # awk rather than grep for the tally because one pass has
                  # to yield three things — two independent counts and the
                  # trailing cursor — and grep gives one. (Not for the reason
                  # it first looks like: `-o cat` does emit the container's
                  # trailing newline as a blank line after every entry, which
                  # doubles a `wc -l`, but a blank line matches neither
                  # pattern so `grep -c` would have been fine on that count.)
                  delta=$(journalctl -u podman-valheim.service -o cat --show-cursor \
                    --after-cursor="$(cat ${relayCursorFile})" \
                    --grep=${lib.escapeShellArg relayJournalPattern} 2>/dev/null \
                    | awk '
                        /${relayStallMatch}/   { s++ }
                        /${relayTimeoutMatch}/ { t++ }
                        /^-- cursor: /         { c = substr($0, 12) }
                        END { printf "%d %d %s\n", s, t, c }
                      ' || true)
                  read -r dstalls dtimeouts dcursor <<<"$delta" || true
                  case "$dstalls" in "" | *[!0-9]*) dstalls=0 ;; esac
                  case "$dtimeouts" in "" | *[!0-9]*) dtimeouts=0 ;; esac
                  stalls=$(( stalls + dstalls ))
                  timeouts=$(( timeouts + dtimeouts ))
                  # `--show-cursor` reports the position the scan *ended* at,
                  # not the last matching entry — verified on amos1: a run
                  # with an impossible --grep pattern still prints a cursor,
                  # byte-identical to the unit's tail. So the cursor advances
                  # to the tail every run, matches or not, and an idle server
                  # never re-scans a growing span.
                  #
                  # The fallback covers the one case that prints nothing at
                  # all: a unit with no journal entries yet. Kept rather than
                  # relying on the above, since that behaviour is observed
                  # rather than documented, and it costs one already-taken
                  # variable.
                  [ -n "$dcursor" ] || dcursor="$tailcursor"

                  # Known limit, measured rather than assumed: a stored
                  # cursor that journald has already vacuumed past does not
                  # error. journalctl seeks to the *head* of what survives and
                  # re-emits it, so that one pass re-counts the whole retained
                  # window (verified on amos1 with a hand-rewound cursor: it
                  # returned the full 30/25 rather than 0/0). The counter
                  # steps up once and stays consistent after.
                  #
                  # Deliberately not guarded. The cursor is dragged to the
                  # journal tail every two minutes, so falling behind
                  # retention needs this unit absent for longer than the
                  # journal keeps — which is not the #590 wedge (the timer
                  # keeps advancing the cursor right through it) but a host
                  # down or the unit stopped for days. Against a counter read
                  # as a trend, a one-off step of at most one retention
                  # window is not worth machinery to detect.
                else
                  # First run, or state lost. Seed at the tail and start
                  # counting from now rather than backfilling the journal:
                  # every historical event would otherwise land in one scrape
                  # interval as a single false spike, dated to today instead
                  # of to when it happened.
                  dcursor="$tailcursor"
                fi
                # Both state files are written tempfile + rename, for the same
                # reason the .prom below is: a torn write is silent here, and
                # worse than a crash. A half-written cursor makes journalctl
                # fail its seek ("Failed to seek to cursor: Invalid
                # argument") — which prints no `-- cursor:` line at all, so
                # the fallback above quietly jumps to the tail and every
                # entry in between goes uncounted, with nothing in the log to
                # say so. A torn totals file just reads back as garbage and
                # is floored to 0 by the guards above, silently discarding
                # the running total.
                #
                # `if` rather than `[ -n … ] && …`: the script runs under the
                # `set -e` NixOS injects into `script =`, and a bare `&&` list
                # whose left side is false returns non-zero, which would kill
                # the unit on the perfectly ordinary "unit has no journal
                # entries yet" path. Same class as the #640 fix in
                # valheim-player-notify below.
                if [ -n "$dcursor" ]; then
                  ctmp=$(mktemp -p ${metricsStateDir} .journal-cursor.XXXXXX)
                  printf '%s\n' "$dcursor" > "$ctmp"
                  mv "$ctmp" ${relayCursorFile}
                fi
                ttmp=$(mktemp -p ${metricsStateDir} .relay-totals.XXXXXX)
                printf '%s %s\n' "$stalls" "$timeouts" > "$ttmp"
                mv "$ttmp" ${relayTotalsFile}

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
                  echo "# HELP valheim_peer_relay_stall_total PlayFab relay faults that suspended TX to a peer ('Failed to send, suspend TX'). Each one freezes every ZDO that peer owned for up to the 90s ZRpc timeout. Counted incrementally from a saved journal cursor, so it survives journald vacuuming; resets only if ${metricsStateDir} is lost."
                  echo "# TYPE valheim_peer_relay_stall_total counter"
                  echo "valheim_peer_relay_stall_total $stalls"
                  echo "# HELP valheim_zrpc_timeout_total Peers evicted by Valheim's 90s ZRpc timeout ('ZRpc timeout detected'), which is when the objects a stalled peer owned unfreeze. Trails valheim_peer_relay_stall_total, since a peer that reconnects in time never times out."
                  echo "# TYPE valheim_zrpc_timeout_total counter"
                  echo "valheim_zrpc_timeout_total $timeouts"
                  if [ -n "$players" ]; then
                    echo "# HELP valheim_players_online Players currently connected, from the valheim-player-notify roster. Absent rather than 0 whenever that roster is missing or mid-rebuild, so no-data and nobody-online stay distinguishable."
                    echo "# TYPE valheim_players_online gauge"
                    echo "valheim_players_online $players"
                  fi${joincodeGaugeEmitLine}
                } > "$tmp"
                chmod 0644 "$tmp"
                mv "$tmp" "$out"
              '';
            };
          }
          // lib.optionalAttrs cfg.crossplay {
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
            #
            # That rationale holds for reboots and is why it is still /run,
            # but it is not the whole rule any more. A *container* restart
            # also re-registers, and PlayFab will hand back the same digits
            # off the deterministic custom ID — so "restarted" and "rotated"
            # are not the same event, and the marker can outlive the code's
            # validity without outliving its value. #683 is exactly that
            # case: recovering from an unconfirmed code re-registered the
            # identical number and the marker swallowed the announcement
            # that it worked again. `handle_active` below drops the marker
            # when the watchdog has flagged the episode, so liveness gets
            # announced even when the digits do not change (#683).
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

                marker=${joincodeMarker}
                pending=${joincodePending}
                alerted=${joincodeAlerted}
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

                # A registration, i.e. a code the server has *offered*. Not
                # announced — that is still the `is active` line's job, and
                # #661 is what happens when this line is trusted instead.
                # Recorded so that a confirmation which never arrives becomes
                # observable: valheim-joincode-watchdog alerts on the age of
                # this file and valheim-metrics publishes it as a gauge.
                #
                # An unchanged code already pending keeps its original
                # timestamp. The server re-logs `registered with` on every
                # lobby re-registration (3 times on 2026-09-12 alone), and
                # rewriting the epoch each time would walk the deadline
                # forward forever and the watchdog would never fire. Same
                # code with no confirmation in between is one unconfirmed
                # episode, not a new one.
                handle_reg() {
                  code="$1"
                  when="$2"
                  # `pcode` is pre-set because this script runs under
                  # `set -u`: a torn or empty pending file makes `read`
                  # return non-zero having assigned nothing, and an unbound
                  # expansion below would take the whole unit down. Same
                  # class of foot-gun as #640, different trigger.
                  pcode=
                  if [ -f "$pending" ]; then
                    read -r pcode _rest < "$pending" || true
                    if [ "$pcode" = "$code" ]; then
                      return 0
                    fi
                  fi
                  # Reaching here means a *different* code is now pending,
                  # which is a new episode: drop the watchdog's
                  # already-announced flag so this one can be announced on
                  # its own merits. Without this, a restart that re-registers
                  # under a fresh number and fails again inherits the old
                  # flag and goes unreported.
                  rm -f "$alerted"
                  printf '%s %s\n' "$code" "$when" > "$pending"
                }

                # A confirmation. Clears the pending registration, then
                # announces under the usual dedupe.
                #
                # The `alerted` branch is the one non-obvious part. A
                # container restart does not necessarily rotate the code:
                # PlayFab hands back the same digits via the deterministic
                # custom ID, which is exactly what happened recovering from
                # #683 — the fix-restart re-registered 496995 and the marker
                # suppressed the announcement as "already announced". By the
                # dedupe rule that is correct; in context it is wrong, because
                # what changed was whether the code *resolves*, not what it
                # is. So when the watchdog has told the channel this code is
                # broken, drop the marker and let the confirmation through:
                # the news is liveness, not novelty.
                #
                # Deliberately *not* dropping the marker on every `reg`. That
                # would re-announce on each ordinary lobby re-registration —
                # 1-3 unchanged-code messages a day, which is the stale-burst
                # the dedupe exists to prevent.
                handle_active() {
                  code="$1"
                  rm -f "$pending"
                  if [ -e "$alerted" ]; then
                    echo "join code $code confirmed after being announced unconfirmed; re-announcing"
                    rm -f "$marker" "$alerted"
                  fi
                  notify "$code"
                }

                # Route one tagged event. Tags come from the sed programs
                # below, which is the only place the journal's wording is
                # known.
                dispatch() {
                  while read -r tag code when; do
                    case "$tag" in
                      reg) handle_reg "$code" "''${when:-$(date +%s)}" ;;
                      active) handle_active "$code" ;;
                    esac
                  done
                }

                journalctl=${pkgs.systemd}/bin/journalctl
                sed=${pkgs.gnused}/bin/sed

                # Position first, read second — see the cursor note above.
                # `--show-cursor` appends a `-- cursor: <id>` line after the
                # last entry, which is what -n 1 is here to produce cheaply.
                #
                # `|| true` because NixOS generates this script with `set -e`
                # in the wrapper, so with pipefail any stage of this pipeline
                # exiting non-zero aborts the whole unit. See the longer note
                # on the replay guard in valheim-player-notify below (#640).
                # An empty cursor is already handled: it selects the
                # follow-from-now branch further down.
                #
                # No stage here is currently known to exit non-zero at
                # runtime. An earlier version of this comment blamed
                # journalctl "legitimately exiting 1 when the container has
                # logged nothing this boot yet"; that was never measured and
                # is wrong — journalctl exits 0 for a unit with no entries,
                # for an unknown unit, and when it cannot read the journal,
                # and reaches 1 only on malformed arguments, which is a
                # build-time bug rather than a runtime state. The real #640
                # culprit was grep, in the backlog pass below. So treat this
                # as deliberate insurance for a future edit that reintroduces
                # a filter which does exit non-zero on no-match, not as a
                # guard against something live.
                cursor="$("$journalctl" -u podman-valheim.service -b -n 1 -o cat --show-cursor 2>/dev/null \
                  | "$sed" -n 's/^-- cursor: //p')" || true

                # Pass 1 — backlog. The pattern matches the *authoritative*
                # line, which is
                #
                #   Session "<name>" with join code <N> and IP <ip>:<port> is active with <n> player(s)
                #
                # and not the `registered with join code <N>` line this used
                # to key on. That one reports the code the server *offered* at
                # re-registration, which PlayFab is free to reject and
                # replace. On 2026-09-18 it did: re-registration echoed
                # 496995, PlayFab minted 809934 and then 555295 a second
                # later, the session went live on 555295 — and this watcher
                # announced 496995, which no remote player could resolve
                # (#661). Nothing in the unit's own output looked wrong,
                # because the stale code matched the dedupe marker from that
                # morning and was skipped as "already announced".
                #
                # The `is active` line cannot name a dead code: the server
                # emits it only after its own `Retry join-code check`
                # countdown confirms the code resolves. It is also the line
                # the header comment tells an operator to grep by hand, so
                # watcher and runbook now agree rather than disagreeing
                # silently.
                #
                # It can, however, fail to appear at all — the corollary
                # #661 did not have to think about and #683 is. A line that
                # cannot lie is still no use when it is never written, and
                # keying on it alone made silence carry two meanings. Hence
                # the `reg` shape below: not to announce from (that is still
                # forbidden), but to know that a confirmation is *owed*, so
                # its absence becomes a fact the watchdog can act on rather
                # than the absence of a fact.
                #
                # Deliberately *not* also matching `Created new join code
                # <N>`. It fires ~3s earlier, but it names every candidate
                # including ones that go on to fail the retry check — 809934
                # above is exactly such a code.
                #
                # `sed -n` capture rather than `grep -oE` plus a positional
                # read: the IP field makes the match variable-length, so
                # counting whitespace fields no longer finds the code. Only
                # the newest match is announced; earlier ones in this boot are
                # already stale.
                #
                # `|| true` for the same reason as the cursor above: under
                # pipefail + the wrapper's `set -e`, a non-zero exit in this
                # pipeline kills the unit — which is what 4 failed starts on
                # 2026-09-15 were, clearing only once a code appeared at
                # 05:19:59 (#640).
                #
                # That was `grep` exiting 1 on no-match, and this pass no
                # longer runs grep: `sed -n ...p` exits 0 whether or not it
                # printed. The guard is therefore no longer load-bearing, and
                # is kept only so that swapping the filter back to something
                # grep-like cannot silently re-arm #640. "No code yet" is
                # exactly what the empty branch below is written to handle,
                # and it is reached via sed's empty output, not via this
                # guard.
                # `-o short-unix` rather than `-o cat` for this pass only.
                # The backlog can end on an *unconfirmed* registration, and
                # seeding the watchdog's deadline from it needs that line's
                # real timestamp — `date +%s` would restart the clock at unit
                # start and a restart during an outage would postpone the
                # alert indefinitely. The live pass below keeps `-o cat`,
                # where the line has just arrived and now is its timestamp.
                #
                # Both sed programs stay anchored on `.*` prefixes, so the
                # added `<epoch>.<usec> <host> <unit>:` prefix changes
                # nothing about what they match. The two shapes cannot
                # collide: the confirmation reads `" with join code"` and the
                # registration `"registered with join code"`, and only the
                # former carries `and IP … is active`. The image's third
                # shape (`New session server … that has join code ,` — note
                # the empty code) matches neither.
                backlog="$("$journalctl" -u podman-valheim.service -b --lines=all -o short-unix 2>/dev/null \
                  | "$sed" -n -E \
                      -e 's/^([0-9]+)\.[0-9]+ .*with join code ([0-9]+) and IP .* is active.*/active \2 \1/p' \
                      -e 's/^([0-9]+)\.[0-9]+ .*registered with join code ([0-9]+).*/reg \2 \1/p' \
                  | tail -1)" || true
                if [ -n "$backlog" ]; then
                  # Only the newest event matters. If that is a confirmation,
                  # announce it; if it is a registration with no confirmation
                  # after it, this boot is *currently* in the #683 state and
                  # the watchdog takes it from the pending file. Any earlier
                  # code in the backlog is stale either way.
                  printf '%s\n' "$backlog" | dispatch
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

                # `-u` is what keeps this streaming: sed otherwise block-
                # buffers into a pipe and the announcement waits on a full
                # buffer's worth of journal, which on an idle server is
                # unbounded. It is the counterpart of the `grep
                # --line-buffered` this replaces.
                # No timestamp field emitted here, unlike the backlog pass:
                # `dispatch` fills a missing one with `date +%s`, which is
                # right for a line that has this instant come off the
                # journal.
                "$journalctl" -u podman-valheim.service "$@" -o cat \
                  | "$sed" -n -E -u \
                      -e 's/.*with join code ([0-9]+) and IP .* is active.*/active \1/p' \
                      -e 's/.*registered with join code ([0-9]+).*/reg \1/p' \
                  | dispatch
              '';
            };

            # The other half of #683: announce the *absence* of a
            # confirmation. valheim-joincode-notify is edge-triggered on the
            # `is active` line, so when that line never comes it emits
            # nothing — and nothing is also what a healthy idle server emits.
            # On 2026-09-20 an upstream NullReferenceException in
            # `ZPlayFabMatchmaking.OnCheckJoinCodeSuccess` killed the
            # confirmation state machine a second after registration, and
            # amos1 advertised an unresolvable code for 3h32m while every
            # signal on the host read healthy. A player found it.
            #
            # A timer rather than a read timeout inside the notifier's follow
            # loop: `read -t` only expires when the journal goes quiet, so on
            # a busy server the deadline would keep being reset — silent
            # exactly when the server is in use. Polling a timestamp is
            # indifferent to journal volume.
            #
            # This deliberately does not restart anything. The remediation is
            # mechanical (`systemctl restart podman-valheim`, verified during
            # #683) and the temptation to automate it is real, but a log
            # pattern that bounces a prod game server is a bigger commitment
            # than one occurrence in 30 days of retained logs justifies.
            # Revisit with a second data point.
            valheim-joincode-watchdog = {
              description = "Alert to Discord when a registered Valheim join code is never confirmed";
              # Same sops edge as the notifier above — without it the first
              # run after activation dies on a missing webhook file. A
              # oneshot on a timer, so a failed run is not a failed deploy,
              # but ordering it costs nothing and keeps the pair symmetric.
              after = [
                "sops-install-secrets.service"
                "network-online.target"
              ];
              wants = [ "network-online.target" ];

              serviceConfig = {
                Type = "oneshot";
                # Shares the notifier's RuntimeDirectory rather than owning
                # one: these two units read and write the same three files,
                # and that sharing is the interface. `Preserve` must match
                # the notifier's, or a run of this oneshot would take the
                # directory — dedupe marker included — down with it on exit.
                RuntimeDirectory = baseNameOf joincodeRuntimeDir;
                RuntimeDirectoryPreserve = "yes";
                # Root: reads the sops secret. ProtectSystem=strict makes
                # /run read-only except for RuntimeDirectory, which is
                # exactly the one path this writes.
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

                pending=${joincodePending}
                alerted=${joincodeAlerted}

                # Nothing registered, or the confirmation already landed and
                # the notifier cleared it. The overwhelmingly common case.
                if [ ! -f "$pending" ]; then
                  exit 0
                fi

                # Already announced for this episode. Cleared by the notifier
                # when a confirmation finally arrives, which is also what
                # makes that confirmation re-announce.
                if [ -e "$alerted" ]; then
                  exit 0
                fi

                # `if` rather than `&&`/`||` chains throughout this unit:
                # NixOS injects `set -e` into `script =`, so a bare test
                # returning non-zero kills the run. That is #640, and the
                # early-exit style above is what keeps it from coming back.
                read -r code when _rest < "$pending" || exit 0
                case "$when" in
                  "" | *[!0-9]*) exit 0 ;;
                esac

                age=$(( $(date +%s) - when ))
                if [ "$age" -lt ${toString joincodeGraceSeconds} ]; then
                  exit 0
                fi

                webhook="$(cat ${config.sops.secrets."valheim/discord_webhook".path})"
                server=${config.virtualisation.oci-containers.containers.valheim.environment.SERVER_NAME}

                # The wording matters more than it looks. #661 was a stale
                # code presented as usable, and this message names a code
                # too — so it has to say plainly that the code is *not*
                # expected to work. Never reuse the healthy announcement's
                # phrasing here.
                payload="$(${pkgs.jq}/bin/jq -nc \
                  --arg code "$code" \
                  --arg server "$server" \
                  --arg mins "$(( age / 60 ))" \
                  '{content: ("⚠️ Valheim server **" + $server
                              + "** registered join code **" + $code + "** " + $mins
                              + "m ago, but PlayFab never confirmed it.\n"
                              + "**That code most likely does not work** — do not share it.\n"
                              + "_Fix: `sudo systemctl restart podman-valheim` on the host._")}')"

                # Same `-K -` stdin trick as the notifier: the webhook must
                # not reach the process cmdline. A failed POST leaves
                # `alerted` unset so the next tick retries, which is the
                # right direction to fail for an outage alert.
                if printf 'url = "%s"\n' "$webhook" \
                  | ${pkgs.curl}/bin/curl -fsS -K - \
                      -X POST -H 'Content-Type: application/json' -d "$payload"; then
                  echo "announced unconfirmed join code $code (pending ''${age}s)"
                  touch "$alerted"
                else
                  echo "failed to post unconfirmed join code $code to discord" >&2
                fi
              '';
            };

          }
          // lib.optionalAttrs cfg.playerNotify {
            # Post player join/leave to Discord. Sibling of the join-code
            # watcher above and the same shape — root journal follower, secret
            # read by path, `curl -K -` so the webhook never reaches the
            # cmdline — but it keys off different lines, and *which* lines is
            # the whole design. See #609.
            #
            # ## Why not the "Player joined/connection lost" lines
            #
            # The obvious candidates look purpose-built:
            #
            #   Player joined server "<world>" that has join code <code>, now 2 player(s)
            #   Player connection lost server "<world>" that has join code <code>, now 3 player(s)
            #
            # All three parts of that are untrustworthy under crossplay,
            # measured against a real 3-player session (2026-09-13 16:55–20:40,
            # amos1):
            #
            #   - The count is wrong. It logged "now 3 player(s)" on a leave
            #     that took the server from 3 to 2, and "now 2 player(s)" on a
            #     *join*. It is sampled at some point that doesn't correspond
            #     to the event being applied, so it can't drive a player count.
            #   - `Player connection lost` fires on transient PlayFab relay
            #     faults, not just real departures — a peer whose relay socket
            #     faults logs it immediately and reconnects ~90s later, which
            #     is why the naive version of this needed a debounce.
            #   - It still misses real departures. One of the five that
            #     evening (a ZRpc timeout) produced no such line at all.
            #
            # ## What this uses instead
            #
            # A prefix→name roster, built from two lines that are reliable:
            #
            #   Got character ZDOID from <name> : <prefix>:<n>
            #   Destroying abandoned non persistent zdo <prefix>:<n> owner <prefix>
            #
            # `<prefix>` is stable for the lifetime of one player connection
            # and freshly allocated on reconnect, which is what makes the
            # roster work as both the identity map and the dedupe state:
            #
            #   - A ZDOID line whose prefix is *already* on the roster is a
            #     respawn (death, portal, bed), not a new session — so roster
            #     membership is exactly the "already announced" test, and no
            #     separate marker is needed.
            #   - A destroy burst emits one line per ZDO the leaver owned (2–7
            #     of them, all within the same second). The first removes the
            #     roster entry; the rest find nothing and are dropped. The
            #     removal *is* the dedupe.
            #   - Leave gets a name, which the "connection lost" line can't
            #     give — and the destroy bursts matched real departures 5/5
            #     that evening, including the timeout one, with zero false
            #     positives on the relay fault. The debounce #609 anticipated
            #     is unnecessary because the false signal never reaches here.
            #   - `<prefix>:0` with `<n>` 0 is a death rather than a spawn; it
            #     is filtered, per the noise-budget note on #609.
            #
            # ## Restarts
            #
            # A server restart disconnects everyone *without* emitting any
            # destroy lines, so the roster has to be cleared on the lifecycle
            # lines instead: `Game - OnApplicationQuit` going down and `New
            # session server` coming back up. Both, because neither is
            # reliably present on its own (this boot: 7 session-starts, 8
            # join-code registrations — the code line re-fires without a
            # restart, which is why it is not the anchor here even though the
            # sibling unit keys on it). Truncating an already-empty roster is
            # a no-op, so using both costs nothing.
            #
            # No leave notifications are posted for a restart. The join-code
            # unit already announces the server coming back, which tells the
            # channel everyone was dropped, and five simultaneous "left"
            # messages at 05:10 would be noise.
            valheim-player-notify = {
              description = "Post Valheim player join/leave to Discord";
              # Same ordering rationale as valheim-joincode-notify above —
              # the sops edge is what keeps a deploy from going red on a
              # missing secret. Ordering only, no requires/wants.
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
                # No RuntimeDirectoryPreserve, unlike the join-code unit: the
                # roster is fully reconstructed from the journal on every
                # start (see the replay pass below), so carrying the old file
                # across a restart would only risk stale entries surviving a
                # reset they should have been cleared by. That teardown is
                # also what makes the `ready` marker below a correct
                # readiness signal for valheim-metrics.
                #
                # Left at the default RuntimeDirectoryMode (0755) with the
                # unit's default root ownership, so the root valheim-metrics
                # reads the roster without any extra grant.
                RuntimeDirectory = baseNameOf playerNotifyRuntimeDir;
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

                rundir=${playerNotifyRuntimeDir}
                roster=${playerRoster}
                ready=${playerRosterReady}
                cursorfile="$rundir/cursor"
                webhook="$(cat ${config.sops.secrets."valheim/player_webhook".path})"
                server=${config.virtualisation.oci-containers.containers.valheim.environment.SERVER_NAME}

                awk=${pkgs.gawk}/bin/awk
                curl=${pkgs.curl}/bin/curl
                jq=${pkgs.jq}/bin/jq
                journalctl=${pkgs.systemd}/bin/journalctl
                sed=${pkgs.gnused}/bin/sed

                : > "$roster"

                # Set for the replay pass below, cleared before the live
                # follow: the roster is rebuilt silently so that restarting
                # this unit mid-session doesn't re-announce the session's
                # whole history to the channel.
                quiet=1

                post() {
                  # allowed_mentions parse:[] because the player name is
                  # attacker-controlled — a character called "@everyone"
                  # would otherwise ping the server every time they spawn.
                  payload="$("$jq" -nc --arg t "$1" \
                    '{content: $t, allowed_mentions: {parse: []}}')"

                  # url via `-K -` (stdin) so the webhook secret never lands
                  # in the process cmdline. A failed POST must not kill the
                  # watcher — log it and keep following the journal.
                  if printf 'url = "%s"\n' "$webhook" \
                    | "$curl" -fsS -K - \
                        -X POST -H 'Content-Type: application/json' -d "$payload"; then
                    echo "posted: $1"
                  else
                    echo "failed to post to discord: $1" >&2
                  fi
                }

                online() { "$awk" 'END { print NR }' "$roster"; }

                # awk rather than grep for the lookup: prefixes are signed and
                # a negative one ("-367286238") would be parsed as an option.
                roster_name() {
                  "$awk" -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$roster"
                }

                join() {
                  prefix="$1"
                  name="$2"
                  # Already present: a respawn, not a new session.
                  [ -n "$(roster_name "$prefix")" ] && return 0
                  printf '%s\t%s\n' "$prefix" "$name" >> "$roster"
                  [ "$quiet" = 1 ] && return 0
                  post "**$name** joined **$server** — $(online) online"
                }

                leave() {
                  prefix="$1"
                  name="$(roster_name "$prefix")"
                  # Absent: either a later line of the same destroy burst, or
                  # a ZDO owned by someone who was never on the roster.
                  [ -n "$name" ] || return 0
                  "$awk" -F'\t' -v p="$prefix" '$1 != p' "$roster" > "$roster.tmp" \
                    && mv "$roster.tmp" "$roster"
                  [ "$quiet" = 1 ] && return 0
                  post "**$name** left **$server** — $(online) online"
                }

                # Normalise the journal to tab-separated events, so the
                # dispatcher below is the same code for the replay and the
                # live follow. J=spawn, L=zdo destroyed, R=server lifecycle,
                # C=journal cursor (emitted by --show-cursor, last in a
                # non-following stream).
                #
                # `-u` is load-bearing, not a tidiness flag. sed's stdout here
                # is a pipe, so without it stdio picks full buffering and holds
                # output until 4 KiB accumulates. Events are a few dozen bytes
                # and arrive minutes to hours apart, so in the *live* pass that
                # buffer never fills and every notification is stranded — the
                # unit sits `active (running)`, journalctl keeps flushing into
                # it (verified: journalctl -f flushes per entry), and nothing is
                # ever posted. The replay pass hid it, because EOF flushes: the
                # roster rebuilt correctly, which is exactly why the unit looked
                # healthy while announcing nothing from 09-14 through 09-15.
                # `valheim-joincode-notify` above dodges this with `sed -u`
                # — the same flag on the same tool. (It used
                # `grep --line-buffered` when this comment was written; #661
                # moved it to sed and this cross-reference went stale.) Cost
                # is nil — journalctl's --grep means sed only ever sees the
                # handful of matching lines, not the raw journal.
                normalize() {
                  "$sed" -u -nE \
                    -e 's/.*Got character ZDOID from (.+) : (-?[0-9]+):[0-9]+[[:space:]]*$/J\t\2\t\1/p' \
                    -e 's/.*Destroying abandoned non persistent zdo -?[0-9]+:[0-9]+ owner (-?[0-9]+)[[:space:]]*$/L\t\1/p' \
                    -e 's/.*(New session server |Game - OnApplicationQuit).*/R/p' \
                    -e 's/^-- cursor: (.*)$/C\t\1/p'
                }

                # Runs in a subshell on the right of a pipe, so all state it
                # touches is deliberately on disk rather than in shell vars.
                dispatch() {
                  while IFS="$(printf '\t')" read -r kind a b; do
                    case "$kind" in
                      # prefix 0 is a death (ZDOID "0:0"), not a spawn.
                      J) [ "$a" = 0 ] || join "$a" "$b" ;;
                      L) leave "$a" ;;
                      R) : > "$roster" ;;
                      C) printf '%s\n' "$a" > "$cursorfile" ;;
                    esac
                  done
                }

                # --grep so the match happens inside journalctl instead of
                # dragging this boot's entire journal (tens of millions of
                # lines after a GetPublicIP wedge — see the top of this file)
                # through a pipe on every restart. stderr is deliberately not
                # suppressed: if --grep ever fails, this unit silently
                # announcing nothing forever is the worst outcome.
                pattern='Got character ZDOID from|Destroying abandoned non persistent zdo|New session server |Game - OnApplicationQuit'

                # Replay and position in a single pass. --show-cursor reports
                # the cursor of the last entry this pass actually consumed, so
                # the follow resumes exactly there: no entry is seen twice,
                # and none falls into a gap between the two passes. (The
                # join-code unit above reads its cursor separately and
                # tolerates the overlap because its marker collapses a repeat;
                # here a repeat would be absorbed silently by the roster and
                # the notification would be *lost*, so the boundary has to be
                # exact.)
                #
                # The `if !` is load-bearing, not style (#640). NixOS emits
                # this script with `set -e` in the generated wrapper — the
                # script's own `set -uo pipefail` deliberately omits `-e`,
                # which is moot — so combined with pipefail a non-zero
                # journalctl aborts the unit outright, before even the
                # "roster rebuilt" line below. journalctl exits 1 both for
                # "no entries matched" and for a real error, and *no entries
                # matched is the normal state for the first ~60s of a boot*:
                # the container has not logged a session line yet. So this
                # raced the container on every boot and fail-looped both
                # notify units until it happened to win — 4 failed starts on
                # 2026-09-15, 10 on 09-14, each recovering ~2s after the
                # first matching line appeared. An empty backlog is a fine
                # starting state; the live follow below catches everything
                # after it. A genuine journalctl error stays visible because
                # stderr is still not suppressed.
                if ! "$journalctl" -u podman-valheim.service -b --lines=all -o cat \
                  --show-cursor --grep="$pattern" | normalize | dispatch; then
                  echo "no matching entries for this boot yet (or journalctl failed — check stderr above); starting from an empty roster"
                fi

                echo "roster rebuilt from journal: $(online) player(s) online"

                # Only now is the roster an answer rather than a half-filled
                # file. valheim-metrics keys its gauge on this marker; see the
                # `playerRosterReady` note at the top of this file for why the
                # roster file's own existence is not enough.
                : > "$ready"

                quiet=0

                if [ -s "$cursorfile" ]; then
                  set -- -f --after-cursor="$(cat "$cursorfile")"
                else
                  # Nothing matched this boot, so there is no cursor to anchor
                  # to: follow from now and take only new entries.
                  set -- -b -f --lines=0
                fi

                "$journalctl" -u podman-valheim.service "$@" -o cat --grep="$pattern" \
                  | normalize | dispatch
              '';
            };
          };

          # `//` at the `timers` level, not at `systemd` — the operator is
          # shallow, so unioning whole `timers` attrsets would drop
          # valheim-metrics on the crossplay host rather than adding to it.
          # Same shape as `services` above for the same reason.
          timers = {
            valheim-metrics = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "2m";
                OnUnitActiveSec = "2m";
                Unit = "valheim-metrics.service";
              };
            };
          }
          // lib.optionalAttrs cfg.crossplay {
            # Crossplay-only, like the unit it drives: a Steam-backend
            # server has no join code and nothing to confirm (#683).
            #
            # 1m rather than the exporter's 2m. Total detection latency is
            # the grace window plus one tick, so this puts the Discord
            # message inside ~3m of a failed confirmation against a ~99s
            # protocol worst case. Every tick but the broken one is two stat
            # calls and an exit.
            #
            # OnBootSec deliberately past the grace window: at boot nothing
            # has registered yet, so earlier ticks would only exit immediately.
            valheim-joincode-watchdog = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "3m";
                OnUnitActiveSec = "1m";
                Unit = "valheim-joincode-watchdog.service";
              };
            };
          };
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
        # 2456 is the game port and 2457 its query port. Upstream
        # documents 2456-2458 and the image's own compose files open all
        # three, but the third is the PlayFab one, so a Steam-backend
        # server never binds it — verified with `ss -ulnp` on hpp-1, where
        # valheim_server.x86_64 holds 2456 and 2457 only. Opening exactly
        # what is bound rather than copying upstream's range.
        #
        # Deliberately not interface-scoped. The audience is LAN clients
        # and tailnet clients, and the latter arrive over behemoth's subnet
        # route as ordinary LAN traffic (see the tailnet DNS/routing
        # topology notes) — so one rule covers both, and the NAT is still
        # the boundary against the internet. Nothing is port-forwarded.
        networking.firewall.allowedUDPPortRanges = lib.optionals (!cfg.crossplay) [
          {
            from = 2456;
            to = 2457;
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
      };
    };
}
