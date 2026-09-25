# Valheim server — operations runbook

The operational narrative and incident history for the Valheim module.
Extracted verbatim from the former `modules/apps/valheim.nix` header. The
module contract itself is summarised at the top of `../valheim.nix`; the
component implementations are in this directory.

Valheim - dedicated server (ghcr.io/community-valheim-tools/valheim-server
container, formerly lloesche/valheim-server).
Gameplay is UDP and there's no web UI to put behind Caddy/Authentik.

Two instances, and `myValheim` below is what makes them differ. amos1
runs crossplay: the server reaches PlayFab outbound and players arrive
over that relay, so there is no inbound listening surface at all and
the game UDP ports stay shut. hpp-1 runs the Steam backend, which is
the opposite shape — the game UDP ports are open on the host firewall
and players connect by typing its LAN address. That asymmetry is not
incidental; it is the whole reason a second instance can exist (see
"Crossplay exclusivity" below).

## Crossplay (myValheim.crossplay)

`CROSSPLAY=true` makes the image append `-crossplay` to the server
args, which swaps the networking backend from Steam matchmaking to
Microsoft's PlayFab Party. That does two things:

1. Non-Steam clients (Xbox / Microsoft Store / PS5 / Switch 2) can
   join at all — they cannot reach a Steam-backend server, period.
2. Traffic is relayed through PlayFab, so a client outside the LAN
   connects without any inbound port-forward on the home router.
   That's the reason this is on: a friend on a console who isn't a
   tailnet peer has no other route in.

The tradeoff: with `-crossplay` the client can no longer connect by
LAN or loopback address (upstream's dedicated-server guide is
explicit about this). Everyone — LAN, tailnet, console — joins with
the 6-digit join code instead. The code is issued by PlayFab and
regenerates on every server restart, so it has to be re-shared after
a container bounce. Read the current one off the server log:

  ssh amos1 -- sudo podman logs valheim 2>&1 | grep -i 'join code' | tail -1

which prints a line of the form
  Session "amos1-g2-valheim" with join code 123456 and IP a.b.c.d:2456 is active ...

Grep for `is active` specifically, not for any line mentioning a join
code. The server logs the code in three different shapes and only that
one is authoritative:

  Session "<name>" registered with join code <N>      the code *offered*
  Created new join code <N> for session "<name>"      a candidate
  Session "<name>" with join code <N> ... is active   confirmed live

PlayFab can reject the offered code and mint a replacement, and a
candidate can fail the server's own `Retry join-code check`. Both
happened on 2026-09-18: re-registration echoed 496995, PlayFab issued
809934 then 555295, and the session went live on 555295 while the
Discord watcher — then keyed on the `registered with` line — kept
advertising 496995. Remote players got "unable to resolve join code";
anyone holding the real code connected fine, so the server looked
healthy from the inside. Fixed in #661; the watcher below now reads
the same line this runbook does.

**If that grep returns nothing for the current container run, the
server is broken — it is not that no code was issued.** The three
shapes above describe a confirmation that arrives; there is a fourth
state, where it never does. On 2026-09-20 the `registered with` line
was followed a second later by

  NullReferenceException: Object reference not set to an instance of an object
    at ZPlayFabMatchmaking.OnCheckJoinCodeSuccess (…FindLobbiesResult result)

which killed the confirmation state machine outright: no `Retry
join-code check` countdown, no `is active` line, ever. The registered
code did not resolve for any client, and because the runbook grep and
the watcher both key on `is active`, both went quiet rather than
wrong — and a quiet watcher is indistinguishable from an idle healthy
server. amos1 stayed that way for 3h32m until a player said so (#683).

valheim-joincode-watchdog below announces this state to Discord within
~3m, and ValheimJoinCodeUnconfirmed in ../system/victoriametrics.nix
alerts on it.

### A restart is a probe, not a remediation (#694)

The obvious response is `systemctl restart podman-valheim`, and an
earlier version of this comment called it "the remediation". It is not.
These failures arrive in *episodes*: a window in which every
registration fails, however it is triggered, ending on PlayFab's
schedule and nobody else's.

  episode 1  2026-09-20 07:23:57 -> 10:56:16   <= 3h32m, 1 failed registration
  episode 2  2026-09-21 05:10:39 -> 06:54:58   1h19m-1h44m, 3 failed

Inside episode 2 a container restart, an in-container `supervisorctl
restart valheim-server`, a fresh PlayFab identity (SERVER_NAME changed)
and a reverted identity all failed. Outside an episode every
registration confirms in 1-2s. The only variable that tracks the
outcome is *when*, so a restart succeeds if and only if the episode has
already ended — it tests the outage, it does not end it.

One caveat on "the only variable": both episodes also fall inside a
window where hpp-1 held a PlayFab lobby on the same public endpoint.
See "Crossplay exclusivity" below — that is a second variable that
tracks the outcome, and 2466 below is the test of it.

That still makes it the right thing to run, because the server never
re-checks on its own: the NRE kills the join-code state machine
permanently while the lobby-refresh loop keeps going, so waiting
passively recovers nothing (episode 1 sat 3h32m proving it). Restart,
and if it comes back unconfirmed, restart again in ~15 minutes.

valheim-joincode-watchdog now runs exactly that loop by itself (#701),
uncapped, for as long as the code stays unconfirmed and the player
roster stays empty — so the operator woken by the Discord message has
nothing to do. Both episodes above would have ended within 15 minutes.
By hand it is still:

  ssh amos1 -- sudo systemctl restart podman-valheim

15 minutes rather than faster because ValheimServerRestartLoop trips
below ~10m spacing; see joincodeRetryInterval below for the derivation.

Note the restart hands back the *same* digits, so an unchanged code is
not evidence it did nothing. That is not the deterministic custom ID —
it is because a join code resolves to the network endpoint
(`<public-ip>:2456`), per the crossplay-exclusivity section below.
Changing SERVER_NAME mints a new custom ID and a new entity ID and the
code stays put; verified on 2026-09-21. Check for the `is active` line,
not for a new number.

### PlayFab peer-relay stalls — what crossplay actually costs players (#627)

The section above frames the crossplay tradeoff as "you lose
connect-by-address". That is the administrative cost. The cost players
*feel* is this one, and it is the more important half.

Every peer reaches a crossplay server through Microsoft's PlayFab Party
relay. When a peer's relay endpoint is torn down under the game, Valheim
keeps calling the Party API with the now-stale handle:

  Keep socket for playfab/<peer>, try to reconnect before timeout
  PlayFab network error ... code '4098': the operation was called with
    an invalid handle
  Failed to send, suspend TX on playfab/<peer> while trying to reconnect
  ... 90 seconds ...
  ZRpc timeout detected
  Destroying abandoned non persistent zdo <peer-prefix>:<n> owner <peer-prefix>

The server *deliberately* keeps the dead peer's socket, hoping for a
reconnect, and holds it for the full `ZRpc timeout set to 90s` it logs on
every handshake. Valheim distributes simulation by ZDO ownership, so for
those 90s everything that peer owned — their character and every
creature or object their client was simulating — is frozen for all other
players. In a boss fight that is most of what is moving on screen, which
is why it reads as "the server died" rather than "one player lagged out".

Three things make this hard to diagnose from the inside, and all three
are why the counters below exist:

  - The host is idle and healthy throughout. CPU, RSS, NIC errors, UDP
    errors, conntrack and kernel log were all clean across the
    2026-09-13 incident window; `valheim_server_up` never dipped and
    uptime never reset, so it is not a supervisord crash-loop.
  - It looks like a player quitting. In that incident a second player
    left one second *before* the ZRpc timeout expired, so the freeze
    appeared to clear because they quit. The two events were
    coincidental — the timeout was always going to fire at 90s.
  - It is frequent, not exceptional: 12 occurrences over two days of
    play, across six distinct peers on both Steam and PlayStation. So it
    is not one player's ISP and not one bad client. Note that plain
    `Keep socket ... try to reconnect` lines *without* the `suspend TX`
    follow-up are ordinary clean disconnects that recover instantly; the
    pathological signature is the `suspend TX` → `ZRpc timeout detected`
    pair, which is exactly what the counters key on.

Nothing here can fix it. The 90s timeout is a game constant, not a server
setting, and the container only wraps the binary — there is no way to
shorten the stall or evict a wedged peer sooner.

`CROSSPLAY=false` is the only real fix, because it removes PlayFab from
the path entirely — and it is not on the table. There is a PlayStation
player in the group, and a non-Steam client cannot reach a Steam-backend
server at all. The section above presents crossplay as a deliberate
choice with a fallback; this is the concrete evidence that the fallback
costs a real person their access, so it is not something to reach for
casually when someone next complains about a freeze.

What is left is visibility, so: `valheim_peer_relay_stall_total` and
`valheim_zrpc_timeout_total` in the valheim-metrics exporter below. The
frequency is the thing worth watching — a 90s stall is over before anyone
could act on a page, so these are for trending, not alerting, and there
is deliberately no vmalert rule. They are also the only way to tell
whether a future image or game update helped. hpp-1 publishes them too
and, running the Steam backend, should read flat zero on the stall
counter — the A/B control mentioned under "What the dev instance cannot
tell you" below.

## Crossplay exclusivity: one *crossplay* server per public IP

The constraint learned the hard way on 2026-09-11 is not "one Valheim
server per household" — it is one *PlayFab* server per public IP, and
the distinction is what `myValheim.crossplay` exists to exploit.

A PlayFab join code resolves to a *network endpoint*, not to a server
identity. This container runs `--network=host` on UDP 2456, so two
crossplay hosts behind one home NAT register the identical public
endpoint (`<public-ip>:2456`) with PlayFab. They collide, and the host
that claimed the endpoint most recently answers every code — including
the other host's. The failure is near-undebuggable from the client: the
session *name* travels with the code, so joining with hpp-1's code
showed "hpp-1-g2-valheim" in the UI while actually connecting to
amos1's server and amos1's world. Only the two servers' logs
disagreeing (one recording the join, the other recording nothing)
makes it visible. The app was made prod-only in 0b3c56b to stop that.

An earlier version of this comment concluded a dev instance would need
a distinct *game port*. A later one called that the wrong lever,
because with `crossplay = false` "the dev server never registers with
PlayFab at all, so there is no endpoint to collide on". That second
claim is false, and it cost a play session on 2026-09-21. A
Steam-backend server still logs into PlayFab and still registers a
lobby for its own `<public-ip>:<port>` — hpp-1, with `CROSSPLAY=false`:

  14:55:05  Sending PlayFab login request (attempt 1)
  14:55:23  Registering lobby
  18:37:49  ZPlayFabMatchmaking::UnregisterServer ... State: Uninitialized

What it does not do is obtain a join code — that is what
`State: Uninitialized` means, against the `State: Active` the same line
printed while hpp-1 was still on crossplay — so it issues nothing the
greps above can see and looks, from amos1, exactly like the absence the
old comment assumed. The endpoint is registered all the same. Both
hosts run `--network=host` on the image's default port behind one NAT,
so the collision is the 2026-09-11 one unchanged: players using amos1's
published code reached hpp-1's empty g2 map, and saw a join code that
was not the one in Discord.

So the port is the lever after all, and `gamePort` in the `let` block
below moves the Steam-backend instance to 2466 (query 2467). What a
lobby advertises is the server's *configured* port, not a NAT-observed
mapping — amos1 logs `IP <public-ip>:2456`, which is its SERVER_PORT —
so a distinct SERVER_PORT is a distinct endpoint, and the two lobbies
stop answering for each other.

Two things the `crossplay = false` argument got right, and which the
port change keeps:

  - No join code on dev, which removes the *mechanism* of the original
    incident rather than just the collision: nobody can follow a dev
    join code into a dev world, because there is no dev join code.
    Players reach dev only by deliberately typing its LAN address into
    Join Game -> Add server — now `<host-lan-ip>:2466`.
  - Reachability is fine for the intended audience. LAN clients connect
    direct; tailnet clients arrive over behemoth's subnet route as
    ordinary LAN traffic, so the one host-firewall rule below covers
    both. No port-forward, no WAN exposure — the NAT stays the
    boundary.

Suspected, not proven: the "PlayFab episodes" above may be this
collision rather than PlayFab-side weather. Every failed registration
in the journal falls inside a window where hpp-1 held a lobby (the
2026-09-18 mismatch and both episodes); the five days hpp-1 ran no
server at all were clean across eight registrations; and the NRE is
thrown from `OnCheckJoinCodeSuccess(FindLobbiesResult)` — the callback
that reads a lobby lookup for its own endpoint. It is not sufficient on
its own, since plenty of registrations confirmed fine inside those
windows. If the episodes stop after this change, that was the cause;
the watchdog and ValheimJoinCodeUnconfirmed earn their keep either way.

### What the dev instance cannot tell you

Two honest limits, worth having in the file rather than rediscovering:

1. Console / non-Steam players cannot join dev at all — they can't
   reach a Steam-backend server, period. Dev is a Steam-client-only
   test bed.
2. A mod that passes on dev is not proven under crossplay. The image
   leaves crossplay off by default precisely because some mods
   misbehave on the PlayFab backend. Dev de-risks "does this load, does
   it corrupt the world, does it survive a restart"; it cannot de-risk
   "does it survive the relay". Prod stays the only place the relay path
   exists — see also #627, where PlayFab peer-relay drops freeze world
   objects for ~90s. (Small upside: a Steam-backend instance is a useful
   A/B control for exactly that issue.)

### The second half of the 2026-09-11 damage, and why it's now harmless

`worldGeneration` is one number shared by every host, so a bump reseeds
once per host — the 2026-09-11 1.0/Deep North reseed created
`hpp-1-g2` *and* `amos1-g2`, two unrelated maps. Players followed
whichever join code they could see and built three days of world on the
dev host's copy, which then had to be migrated onto amos1 by hand.

Two worlds is fine again now, because the reason it hurt was that both
were *reachable by the same accident*. Dev has no join code to follow
and its world is scratch; a bump reseeds it alongside prod and nobody
notices. See the note on `worldGeneration` in the `let` block below.

A contributing factor worth remembering, since it is the reason nobody
noticed for three days: valheim-joincode-notify reads codes out of the
journal, so journald rate-limiting is silent data loss for it. The
GetPublicIP flood (see #590 and the log-filter notes below) was getting
~4,160 messages per 30s suppressed on amos1, the join-code line among
them, so prod announced no code at all while looking perfectly healthy
— unit `active (running)`, hundreds of MB of journal read, zero
matches. The per-unit rate cap below plus the log filter close that
window; and the unit now only exists on the crossplay host, so there is
still exactly one server whose code can go missing.

## Restart cadence vs. the join code

The image runs its own cron inside the container: `UPDATE_CRON` checks
for a game update every 15 minutes (upstream default) and
`RESTART_CRON` restarts the game server — set below to Mondays 05:10
rather than upstream's daily 05:10, see "Phase 1" further down. Every
one of those restarts rotates the join code (it's a fresh PlayFab
session), which is what valheim-joincode-notify below exists to
announce.

That is less disruptive than it sounds because `UPDATE_IF_IDLE` and
`RESTART_IF_IDLE` also default to `true`: the container only takes
either action when no players are connected, so the code never rotates
out from under a live session. The cost is entirely "look up the new
code before you next sit down to play" — a player holding a code from
before the last bounce has a stale one, and the saved server entry
(Join Game -> Add server) is keyed on the code, so it needs deleting
and re-adding rather than reconnecting. Upstream Valheim offers no way
to pin a code across restarts.

`RESTART_CRON` and `UPDATE_CRON` are independent, and an earlier version
of this comment wrongly conflated them — disabling the restart cron does
*not* cost you an up-to-date server. The image's valheim-updater bounces
the server itself when a version actually lands: update() detects the
changed files from its rsync, logs "Valheim Server was updated -
restarting", and writes a restart file that check_server_restart() turns
into `supervisorctl restart valheim-server`. That path runs off
UPDATE_CRON's 15-minute check regardless of what RESTART_CRON is set to.

So the bounce buys exactly one thing: a periodic clean slate as
insurance against a game-server memory leak. That is also all upstream
ever claimed for it — the README documents RESTART_CRON with no rationale
at all, and the feature request that introduced it (lloesche/
valheim-server-docker#65) asked for it "just in case there's an issue
with a memory leak or similar in some release of the dedicated server".
The leak reports behind that concern are real but come from busy servers
with large worlds and week-long uptimes, which is not this.

### Phase 1 — daily to weekly, 2026-09-14 (#458)

The valheim-metrics exporter below exists to answer whether that
insurance was ever worth paying for. Seven days of
`valheim_server_rss_bytes` against `valheim_server_uptime_seconds` on
amos1, spanning 8 restart cycles and the first real multiplayer session
(3 concurrent players, ZDOS ~114,500, 2026-09-13), say it was not. RSS
*falls* with uptime, in mean and in max:

  uptime    0h     1h     4h     8h    10h    15h    22h
  mean    1252   1305   1201   1058    622    633    548   MB
  max     1518   1511   1521   1518    786    829    852   MB

Every cycle starts at 1.48-1.52 GB in hour 0-1, decays to a 430-850 MB
steady state by hour 9-10, and then sits flat for the rest of the cycle
(09-08 15:00 -> 09-09 05:00: 428.5 -> 426.4 MB over 14h). Player load
is a ~+170 MB bump that comes back on logoff, so RSS tracks occupancy,
not uptime. Peak across the whole window was 1.52 GB, at uptime 4.7h.

So the restart *creates* the high-water mark rather than preventing
one. The 1.5 GB is a startup transient — the exporter reads VmRSS from
/proc of the pgrep'd pid every 2m, so that decay is one process's own
RSS, not a pid switch.

What the daily cron made unobservable is the week-scale question: no
cycle ever exceeded a 24h uptime, so a slow leak could not have shown
up in that data even if it were there. Weekly uptimes are the first
window where one could, which is why Phase 2 (`RESTART_CRON = ""`,
leaving restarts to update/reboot/deploy) is still gated rather than
taken in the same change.

Detection for that window is `ValheimMemoryBaselineHigh` in
modules/system/victoriametrics.nix. The pre-existing 4 GiB
`ValheimMemoryHigh` is a survival ceiling: a leak carrying RSS from
600 MB to 2 GB over a week would clear a whole weekly cycle in
silence, which was fine when the process was reset every 24h and is
not fine when detecting that leak is the point of the phase.

World state and the image's automatic world backups (every 2h by
default into /config/backups inside the container) live under
/var/lib/containers/valheim/config, which the daily restic snapshot
in modules/system/server-backups.nix picks up automatically. The
Steam install of the game itself lives under
/var/lib/containers/valheim/cache so it lands inside the existing
`/var/lib/containers/*/cache` restic exclude — it's ~1.5 GB and the
image re-downloads it on next start if missing.

`--network=host` so the host firewall (INPUT chain) is the real gate
on the game ports rather than relying on podman's DNAT/FORWARD
behaviour. UDP > 1024, so the remapped PUID user can bind without
CAP_NET_BIND_SERVICE.

## GetPublicIP log-rate runaway (upstream game bug, #590)

One transient HTTP failure can wedge the game server into a permanent
~68/s logging loop. Seen once on hpp-1 on 2026-09-08: the container came
up at 05:15 after a nixos-upgrade reboot, looped until it was restarted
by hand at 09:05, and wrote 4,721,938 lines / 1.04 GB of journal in that
3h50m — ~96% of the host's entire 24h journal volume.

`ZNet.GetPublicIP` walks a fallback list of public-IP endpoints, reusing
one shared `HttpClient` and assigning `.Timeout` per attempt. In .NET that
is illegal once a request has been sent, so the first genuine failure
poisons the client permanently:

  1 System.Net.Http.HttpRequestException   ipinfo.io returned non-2xx
  942775 System.InvalidOperationException  "This instance has already
                                           started one or more requests"

Every attempt after the first throws in `set_Timeout` before touching the
network — no I/O, no timeout, no backoff — so it spins as fast as the
retry loop allows. Nothing here can fix it; the image only wraps the game
binary. Recovery is `podman restart valheim`.

Note the obvious mitigation does not work: `SERVER_PUBLIC = "false"` is
already set below and the public-IP lookup runs regardless.

Nothing alerted at the time — the unit stayed active, systemd never
restarted it, the server kept serving and the exporter kept publishing.
That gap is now covered generically by `JournalLogRateHigh` in
modules/system/victoriametrics.nix rather than by anything Valheim-
specific, since a service logging itself into the ground is not a
Valheim-only failure mode.

### Recurrence on amos1, 2026-09-11 — and why there is now a filter

It recurred, harder. amos1's server was restarted by the in-container
UPDATE_CRON at ~07:16 and wedged at 09:08:21, running at **~400/s** (vs
hpp-1's 68/s) until the unit was stopped at 16:05. `JournalLogRateHigh`
fired and worked exactly as designed — it is what caught this.

hpp-1's server restarted within 17 minutes of amos1's (same update) and
did *not* wedge. So this is not amos1-specific: the loop starts from one
transient HTTP failure on the first public-IP fetch after a server start,
making every restart on every host a coin flip.

The new cost this time was not disk, it was **retention**. Both hosts cap
the journal at ~4G. hpp-1 gets ~9 days out of that budget; amos1 was
reduced to 6.5 hours, its oldest surviving entry rotating forward faster
than the incident itself (the 09:08 onset had already been vacuumed away
by the time it was diagnosed). Losing every other unit's history on a prod
host is a debugging capability you need most during an *unrelated*
incident, which is a worse failure than the 1 GB of churn #590 measured.

Hence the `VALHEIM_LOG_FILTER_CONTAINS_*` vars in the environment block
below. The earlier stance here — "deliberately not filtered" — was about
vector.nix, and that part still holds for a different reason than it
claimed: vector reads *from* journald, so a vector rule drops these lines
only after they have already been written to /var/log/journal and rotated
the journal away. It would protect downstream log storage and nothing
else. The image's own log filter runs inside the container, ahead of
podman's log driver, and is the only layer that can protect retention.

The filter is deliberately partial — see the comment on the vars for why
suppressing all five lines would make the wedge undetectable.

## Mods (BepInEx / Valheim+ / Jotunn)

`myValheim.bepinex = true` makes the image install BepInEx into
/config/bepinex on next start. Drop mod DLLs into
/var/lib/containers/valheim/config/bepinex/plugins/ and restart
`podman-valheim.service`. Server-side-only mods just need the DLL;
client-affecting mods need every player to install the same mod
locally. See
https://github.com/community-valheim-tools/valheim-server-docker#bepinex.

This is on for hpp-1 and off for amos1 — testing mods is the reason the
dev instance exists. Note the limit from "What the dev instance cannot
tell you" above: some mods misbehave specifically on the PlayFab
backend, which is why the image ships crossplay off by default, so a
green run on dev does not clear a mod for prod's relay path.
