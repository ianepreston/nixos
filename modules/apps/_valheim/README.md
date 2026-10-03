# Valheim server — operations runbook

The operational narrative and incident history for the Valheim module.
Extracted verbatim from the former `modules/apps/valheim.nix` header. The
module contract itself is summarised at the top of `../valheim.nix`; the
component implementations are in this directory.

Valheim - dedicated server (ghcr.io/community-valheim-tools/valheim-server
container, formerly lloesche/valheim-server).
Gameplay is UDP and there's no web UI to put behind Caddy/Authentik.

Two instances, and `myValheim` below is what makes them differ. Both
run crossplay: the server reaches PlayFab outbound and players arrive
over that relay, so there is no inbound listening surface at all and
the game UDP ports stay shut. What lets a second instance exist is the
game port — amos1 on 2456, hpp-1 on 2466 — not the backend (see
"Endpoint exclusivity" below). hpp-1 can drop to the Steam backend as a
control, where the game UDP ports open on the host firewall and players
connect by typing its LAN address; its port does not move when it does.

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
See "Endpoint exclusivity" below — that is a second variable that
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
(`<public-ip>:<gamePort>`), per the endpoint-exclusivity section below.
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
and, when switched to the Steam backend, should read flat zero on the
stall counter — the A/B control mentioned under "What the dev instance
cannot tell you" below.

## Endpoint exclusivity: one game port per server per public IP

The constraint learned the hard way on 2026-09-11 is not "one Valheim
server per household" — it is one PlayFab *endpoint* per server, and a
PlayFab endpoint is `<public-ip>:<gamePort>`. The history below took
two wrong turns before landing there; `myValheim.gamePort` is the
result (#771).

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

So the port is the lever after all. What a lobby advertises is the
server's *configured* port, not a NAT-observed mapping — amos1 logs
`IP <public-ip>:2456`, which is its SERVER_PORT — so a distinct
SERVER_PORT is a distinct endpoint, and the two lobbies stop answering
for each other.

The first version of that fix derived the port from the backend (2456
with crossplay, 2466 without), which made it impossible to run crossplay
on dev: flipping the backend silently put hpp-1 back on 2456 and
recreated the collision. The port is now its own per-host option,
`myValheim.gamePort`, and both hosts run crossplay on distinct ports
(#771). It cannot be checked across two separate host evaluations, so
the two host files state their ports side by side.

What stops the *mechanism* of the original incident — players
following a dev join code into a dev world — is no longer "dev has no
join code" but "dev's code is not published where players look": hpp-1
posts its codes to its alerts channel (`joincodeWebhookSecret`), and
the players' channel only ever sees amos1's.

On the Steam backend reachability is fine for the intended audience.
LAN clients connect direct; tailnet clients arrive over behemoth's
subnet route as ordinary LAN traffic, so the one host-firewall rule
below covers both. No port-forward, no WAN exposure — the NAT stays the
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

1. Dev runs crossplay now (#771), so console players can reach it and
   a mod can be tested on the relay path — but only with whoever is at
   the terminal, not prod's player load. A mod that survives dev's
   relay with one or two peers is not thereby proven against the
   peer-relay stalls in #627, which scale with connected peers. Check
   the plugin's startup patch audit (`PATCH FAILED` / `PATCH SKIP`)
   before reading anything into a run.
2. Dev's watchdog detects an unconfirmed join code but never restarts
   to recover: `playerNotify = false` there, so it has no roster to
   prove nobody is on. Restart by hand.

Setting hpp-1 back to `crossplay = false` (keeping `gamePort = 2466`)
turns it into a Steam-backend A/B control — the stall counters should
read flat zero there.

### The second half of the 2026-09-11 damage, and why it's now harmless

`worldGeneration` is one number shared by every host, so a bump reseeds
once per host — the 2026-09-11 1.0/Deep North reseed created
`hpp-1-g2` *and* `amos1-g2`, two unrelated maps. Players followed
whichever join code they could see and built three days of world on the
dev host's copy, which then had to be migrated onto amos1 by hand.

Two worlds is fine again now, because the reason it hurt was that both
were *reachable by the same accident*. Dev's join code resolves to its
own endpoint and is posted only to a dev channel, and its world is
scratch; a bump reseeds it alongside prod and nobody notices. See the
note on `worldGeneration` in the `let` block below.

A contributing factor worth remembering, since it is the reason nobody
noticed for three days: valheim-joincode-notify reads codes out of the
journal, so journald rate-limiting is silent data loss for it. The
GetPublicIP flood (see #590 and the log-filter notes below) was getting
~4,160 messages per 30s suppressed on amos1, the join-code line among
them, so prod announced no code at all while looking perfectly healthy
— unit `active (running)`, hundreds of MB of journal read, zero
matches. The per-unit rate cap below plus the log filter close that
window.

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

World state and the image's automatic world backups (hourly by
default — `BACKUPS_CRON=5 * * * *`, kept 3 days — into /config/backups
inside the container; see the env-var reference below) live under
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

## Mods and dev experiments (BepInEx, server arguments — #772)

hpp-1 is where server-side changes get tried before anyone proposes them
for amos1. Experiments are declared in `modules/hosts/hpp-1.nix`, so the
reviewed mainline config is the record of what was tested; promoting a
result to amos1 is a separate change. amos1 sets none of these options,
and with them at their defaults the rendered container environment and
unit are identical to before (no empty `SERVER_ARGS`, no
`BEPINEX = "false"` — either would restart amos1 and rotate its join
code for nothing).

### Server arguments (`myValheim.worldModifiers`, `myValheim.serverArgs`)

Both render into the image's `SERVER_ARGS`: `worldModifiers` first, then
`serverArgs`, emitted only when the result is nonempty. The image expands
that variable unquoted, so the module asserts each `serverArgs` token has
no whitespace or glob characters, and rejects flags the image already
passes or a typed option owns: `-preset`, `-modifier`, `-setkey` and
`-resetmodifiers` belong to `worldModifiers` and are rejected in
`serverArgs`, matched case-insensitively as the game matches them.
Declare only an argument the server binary is verified to accept: an
invented one is silently ignored rather than rejected.

Sources: `Valheim Dedicated Server Manual.pdf`, which ships with the
server (`/opt/valheim/server/` in the container), and a decompile of
`FejdStartup` in `assembly_valheim.dll`. Both were checked against hpp-1's
1.0.16 server, the preset on 2026-09-30 and the rest on 2026-10-02 (#794).
After a game update, re-pull both rather than trusting this copy.

#### World difficulty (`myValheim.worldModifiers`)

| Field | Renders | Accepted values |
| --- | --- | --- |
| `preset` | `-preset <p>` | `normal`, `casual`, `easy`, `hard`, `hardcore`, `immersive`, `hammer` |
| `combat` | `-modifier Combat <v>` | `veryeasy`, `easy`, `hard`, `veryhard` |
| `deathPenalty` | `-modifier DeathPenalty <v>` | `casual`, `veryeasy`, `easy`, `hard`, `hardcore` |
| `resources` | `-modifier Resources <v>` | `muchless`, `less`, `more`, `muchmore`, `most`: **the drop-rate knob** |
| `raids` | `-modifier Raids <v>` | `none`, `muchless`, `less`, `more`, `muchmore` |
| `portals` | `-modifier Portals <v>` | `casual`, `hard`, `veryhard` |
| `setKeys` | `-setkey <k>` each | `nobuildcost`, `playerevents`, `passivemobs`, `nomap` |

Every field is unset by default. The enums are the only real validation,
because the game's own checks are weak:

- `-preset`: `Enum.TryParse<WorldPresets>`, case-insensitive. It logs
  `Setting world modifier preset: <p>`. An unknown value logs
  `Could not parse '<p>' as a world modifier preset.` and the server starts
  anyway.
- `-modifier`: both halves go through a case-insensitive `Enum.TryParse`,
  but against the *shared* `WorldModifierOption` enum, so `Raids most`
  parses. That logs `Setting world modifier: Raids->most` followed by
  `Slider Raids missing value to set: Most`, and changes nothing.
- `-setkey`: no parse at all. The argument is lowercased and added as a
  world key, with no log line and no error, so a typo becomes a
  meaningless global key.
- The flag names themselves are lowercased before matching, so `-Preset`
  works too.

**Order matters.** `-preset` (and `-resetmodifiers`) clears every starting
key before applying its own. A `-modifier` or `-setkey` placed before it is
wiped on the same start, which is why the module always renders the preset
first.

**All of these are sticky.** Each one writes the world's starting global
keys, which are saved in the world's metadata (`_main.<n>.fwl2` in a 1.0
world directory, `<world>.fwl` before that) and reapplied on every load.
Removing a field therefore does *not* undo it by itself:

- With `preset` set, the declaration is authoritative: each start clears
  the keys and re-applies preset, then modifiers, then setkeys. Removing a
  modifier or setkey takes effect on the next start.
- Without `preset`, a removed modifier or setkey stays in the world. To
  roll back, set `preset = "normal"` for one start, then unset it. That
  includes rolling back a preset itself.

hpp-1 runs `preset = "hard"` as the first experiment. Its log shows
`Setting world modifier preset: hard` on every start.

#### Other native game flags (not wired up)

The manual documents these. All of them are unset on both hosts, so the
game's defaults apply. Pass any of them through `serverArgs` once it has a
reason to change.

| Flag | Default | What it does |
| --- | --- | --- |
| `-saveinterval <s>` | `1800` | World save interval. |
| `-backups <n>` | `4` | Automatic backups kept: one "short", the rest "long". |
| `-backupshort <s>` | `7200` | Age of the first automatic backup. |
| `-backuplong <s>` | `43200` | Spacing of the remaining automatic backups. |
| `-savedir <path>` | Unity's per-user path | Save location. The image leaves it unset and symlinks the default (`~/.config/unity3d/IronGate/Valheim`) to `/config`. Do not override it. |
| `-logFile <path>` | — | Write the log to a file instead of stdout. The journal-driven notifiers read stdout. |
| `-instanceid <id>` | — | A distinct value per server keeps the PlayFab IDs of servers on one port and MAC apart. |

The game's `-backups`/`-backupshort`/`-backuplong` are a **separate
mechanism** from the image's `BACKUPS_*` cron (see "Backups" in the
environment reference below). The game writes
`<world>_backup_auto-<timestamp>` copies next to the world in
`/config/worlds_local`, while the image zips into `/config/backups`. Both
run at once, nothing reconciles them, and restic snapshots both. Tuning
either is separate work.

`-instanceid` is close kin to the incidents in "Endpoint exclusivity"
above. Per-host `gamePort` is the fix that resolved those (#771), so this
flag is documented here rather than wired up, in case a third collision
ever needs a second axis.

### Plugins (`myValheim.bepinexPlugins`)

`myValheim.bepinex = true` makes the image install the BepInEx framework
(its own Thunderstore lookup, unchanged). `bepinexPlugins` then selects
Nix-built plugin trees from `myValheim.availablePlugins`
(`bepinex-plugins.nix`): each a fixed version with a fixed hash, built as

```text
BepInEx/plugins/<dir>/…      the plugin and any dependent DLLs
BepInEx/patchers/<dir>/…     preloader patchers, only when needed
BepInEx/config/<guid>.cfg    only the keys the declaration sets
```

Before every container start, `bepinex-materialize.sh` (an ExecStartPre
of `podman-valheim.service`) copies the merged tree into
`/config/bepinex/{plugins,patchers}/nix-managed/` and writes the declared
configs. The image's own sync then carries it into the running install
and prunes what an earlier sync put there and is now gone. The script
owns exactly those two subdirectories and the configs listed in
`/config/bepinex/.nix-managed-configs`. BepInEx's own files, a config a
plugin generated for itself, and anything dropped by hand are left alone.

A declared config is rewritten from the declaration on every start, so
an in-game edit to a managed key does not survive a restart; the place to
change it is the host file. A plugin declared with no `settings` writes
its own defaults on first load, and that file is unmanaged: it outlives
the plugin's removal (harmless, and kept so a re-test starts from the
same values; delete it by hand for a clean slate).

Rollback is removing the entry and deploying hpp-1. Revert one plugin at
a time so each result stays attributable.

**Bumping a plugin:** change `version` in `bepinex-plugins.nix`, run
`task hashes` (each `src` carries a `regen-hash` marker — Renovate does
not track these), re-read upstream's changelog for client requirements,
and update the table below.

**Unmanaged exploration** is still possible: with `bepinex = true`, a DLL
dropped directly into
`/var/lib/containers/valheim/config/bepinex/plugins/` loads on the next
restart. Nothing reviews or cleans it, so it is for a quick look only;
anything worth a result goes through `bepinexPlugins`.

### Packaged plugins

| Plugin | Version | Source / licence | Dependencies | Clients | Status on hpp-1 |
| --- | --- | --- | --- | --- | --- |
| BetterNetworking10 (`DIT.BetterNetworking10`) | 1.2.0 | [GitHub release](https://github.com/LabodiDavid/BetterNetworking10/releases/tag/v1.2.0), MIT | image's BepInExPack | optional: compression only engages when both ends run it; the queue-size patch is server-side | enabled (#671 A/B, side A); load-verified |
| FiresGhettoNetworking (`com.Fire.FiresGhettoNetworkMod`) | 1.5.17 | [Thunderstore](https://thunderstore.io/c/valheim/p/VerdantsAscent/FiresGhettoNetworking/) ([source](https://github.com/fire-VA/FiresGhettoNetworking)), MIT | image's BepInExPack | optional for the server-side half; client half needs every client on the same version | packaged, not enabled (#671 A/B, side B); load-verified |

The two take **opposite** positions on the crossplay queue, which is what
makes them an A/B rather than two tries at one idea. Both start from the
same fact — PlayFab's `GetSendQueueSize` reports a quarter of the bytes
actually in flight. BetterNetworking10 raises the ZDO send budget
(`Queue Size`, 10 KB → 32 KB), i.e. lets more through. FiresGhettoNetworking
caps crossplay peers at a fixed `Crossplay In-Flight KB` (20 KB real bytes),
i.e. holds less in flight because PlayFab recovers from loss slowly, and adds
server-side traffic reduction (RPC area-of-interest filtering, ZDO delta
compression) that works on either transport. Its transport tuning,
compression and HyperBoost are Steam-socket only and do nothing on amos1.

The module asserts at most one of them is selected at a time. Neither
`Force Crossplay` setting is declared: both default to following the
command line, which `myValheim.crossplay` already drives, and forcing it
in a plugin config would let the plugin silently contradict the module's
backend, firewall and join-code wiring.

What counts as a result, per plugin:

1. **It loaded.** The BepInEx chain-loader lines in
   `journalctl -u podman-valheim` name the plugin and version. Present on
   disk is not proof it ran.
2. **It patched.** BetterNetworking10 logs `PATCH OK` / `PATCH SKIP` /
   `PATCH FAILED` per patch and `Valheim compatibility verified: <ver>`;
   any `PATCH FAILED` voids the run. FiresGhettoNetworking prints its
   version banner and, on a dedicated server, the join address.
3. **It helped.** Only a multiplayer session can say that for #671, and
   dev carries a handful of peers, not prod's load (see "What the dev
   instance cannot tell you" above).

Load results on hpp-1, Valheim `l-1.0.16`, BepInExPack 5.4.2351
(2026-09-30):

| Plugin | Loaded | Patch / startup audit | Notes |
| --- | --- | --- | --- |
| BetterNetworking10 1.2.0 | `Loading [Better Networking 1.0 Safe 1.2]`; chainloader 1 loaded, 0 failed | `Patch audit complete: 15 applied, 4 skipped, 0 failed. Mode=Balanced`, including `PATCH OK ZDO queue budget: ZDOMan.SendZDOs`. Skips: update rate (100% = off), new-connection buffer, force crossplay (vanilla), player limit | Warns that 1.0.16 is outside its audited 1.0.12–1.0.15 range; every patch still verified its IL pattern. Recheck the audit after each game update. |
| FiresGhettoNetworking 1.5.17 | `Loading [FiresGhettoNetworkMod 1.5.17]`; chainloader 1 loaded, 0 failed; `Fires Ghetto Networking Loaded.` | `Running on DEDICATED SERVER`; server auto-tune picked tier Medium (Queue Size 48 KB); server-side sim off, delta + throttle + AI LOD + WearNTear on | Writes a ~60 KB `com.Fire.FiresGhettoNetworkMod.cfg` of its own (undeclared, so unmanaged). |

Neither has had a multiplayer session yet, so neither has a #671 result.
Swapping between them was exercised on the host: the materializer
deleted the outgoing plugin's declared config, and the image's sync
pruned its DLL from the running tree on the same start.

Some mods misbehave specifically on the PlayFab backend, which is why
the image ships crossplay off by default; dev runs crossplay too (#771),
so that failure shows up there first.

## Full environment-variable reference (image v1.4.0, #793)

Everything `ghcr.io/community-valheim-tools/valheim-server` reads from its
environment, so tuning a knob does not start from a cold read of upstream.
Taken from the image's `README.md` table and its `defaults` file at the
**`v1.4.0`** tag, which is the pinned image. Both files were byte-identical
to upstream `main` when this was written (2026-10-01). Where the scripts
disagree with upstream's README, the scripts win, and the row says so.
Re-check this section when renovate bumps the image tag.

The **Here** column says what this module does with each variable. "default"
means the variable is not set and the image default applies.

Two conventions from `defaults` that matter for almost every row:

- **Empty vs unset.** Most variables use `${VAR:-default}`, so an empty
  value falls back to the default. A few use `${VAR-default}`, where an
  explicitly empty value is kept and **turns the feature off**. Those are
  `UPDATE_CRON`, `RESTART_CRON`, `BACKUPS_CRON`, `STEAMCMD_ARGS`,
  `SERVER_PASS`, and the `VALHEIM_LOG_FILTER_MATCH` / `_STARTSWITH`
  defaults. `RESTART_CRON = ""` means "never restart", not "the default
  schedule".
- **Booleans are the literal strings `true` / `false`.** The one
  exception is `SERVER_PUBLIC`, which `defaults` normalises to `1` / `0`.
  Nix values go through `lib.boolToString` or a string literal for that
  reason.

### Identity and network

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `SERVER_NAME` | `My Server` | string | Name shown in the server browser and in the join-code log line. | `${worldName}-valheim`, per host. |
| `SERVER_PORT` | `2456` | UDP port | Game port. The query port is always `SERVER_PORT + 1` (`SERVER_QUERY_PORT` is derived in `defaults` and cannot be set on its own). | `myValheim.gamePort` (amos1 2456, hpp-1 2466). See "Endpoint exclusivity". |
| `WORLD_NAME` | `Dedicated` | string | World directory under `worlds_local/` (or the `.db`/`.fwl` basename on pre-1.0 saves). | `worldName` (host + `worldGeneration`). |
| `SERVER_PASS` | `secret` | string, at least 5 characters | Join password. Set-but-empty is kept, not defaulted. Also forced empty when `VPCFG_Server_disableServerPassword=true`. | Set from sops via the `valheim.env` template. |
| `SERVER_PASS_FILE` | — | path inside the container | Read `SERVER_PASS` from a file instead. | Unused. The sops env template sets `SERVER_PASS` directly, which has the same effect. |
| `SERVER_PUBLIC` | `true` | `true`/`false` (normalised to `1`/`0`) | List in the community server browser. It also picks how the idle check works (see Idle detection). | Always `false`. |
| `SERVER_ARGS` | — | space-separated string | Extra game CLI arguments, expanded unquoted. | `myValheim.worldModifiers` then `myValheim.serverArgs`, emitted only when nonempty (the "Server arguments" section). |
| `CROSSPLAY` | `false` | `true`/`false` | Use the PlayFab backend instead of Steam. `-crossplay` in `SERVER_ARGS` also counts. | `myValheim.crossplay`. See "Crossplay". |
| `TZ` | `Etc/UTC` | tz database name | Container time zone, and so the zone every `*_CRON` runs in. An unknown zone warns and falls back to UTC. | Set to `config.time.timeZone` by the oci-containers wrapper. |

### Access control

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `ADMINLIST_IDS` | — | space-separated SteamID64s | Rewrites `/config/adminlist.txt` with exactly these IDs. | Unset. |
| `BANNEDLIST_IDS` | — | same | Rewrites `/config/bannedlist.txt`. | Unset. |
| `PERMITTEDLIST_IDS` | — | same | Rewrites `/config/permittedlist.txt` (whitelist). | Unset. |

The lists **overwrite rather than merge**. `write_serverlist` in the image's
`common` replaces the whole file on every start whenever the variable is
nonempty. An in-game `ban`/`unban`, or an admin change made during a
session, survives only until the next container start and then silently
reverts. An empty or unset variable leaves the file alone, which is how
this module runs today: `/config/*list.txt` is hand-edited state under
`/var/lib/containers/valheim/config`, covered by the restic snapshot. Wiring
one of these into a `myValheim` option makes the Nix value the only source
of truth for that list.

### Idle detection

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `IDLE_DATAGRAM_WINDOW` | `3` | seconds | How long the idle check counts incoming UDP datagrams. | **Not settable in v1.4.0.** See below. |
| `IDLE_DATAGRAM_MAX_COUNT` | `30` | integer | Datagram count above which the server counts as busy. | **Not settable in v1.4.0.** See below. |

Upstream's README lists both as environment variables, but `defaults`
assigns them unconditionally (`IDLE_DATAGRAM_WINDOW=3`, no `${…:-…}`), so a
value passed in is overwritten before anything reads it. They are listed
here so nobody sets them and expects a change.

The mechanism still matters here. `server_is_idle` (in `common`) uses this
datagram count instead of an A2S player query whenever `SERVER_PUBLIC=0` or
crossplay is on. Both are true on both hosts. The count comes from `nstat`
`UdpInDatagrams`, a per-network-namespace counter. This container runs
`--network=host`, so the count includes **every UDP datagram the host
receives** (tailscale/WireGuard, DNS replies, mDNS), not just game traffic.
It is known to misfire. #631 found the updater logging "Players
connected" 39 times in a window where the world file never changed a byte,
which it put down to PlayFab lobby chatter. Host traffic adds to the same
counter. So an empty server can read as busy, and that skips
`UPDATE_IF_IDLE` / `RESTART_IF_IDLE` work and keeps `BACKUPS_IF_IDLE=false`
backups running. It is not stuck busy, though: the 2026-09-11 amos1 restart
came from `UPDATE_CRON` with `UPDATE_IF_IDLE` at its default. That is why
`valheim_players_online` (in `_valheim/metrics.nix`) is derived from the
player-notify roster and not from anything the image reports. Treat every
`*_IF_IDLE` gate as best-effort.

### Update cadence

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `UPDATE_CRON` | `*/15 * * * *` | cron, or empty to disable | When the in-container updater checks Steam for a new game build. If one is found, it downloads it and restarts the server. | Default. The image tag pin is only the wrapper; the game updates itself. |
| `UPDATE_IF_IDLE` | `true` | `true`/`false` | Only check or update when the server is idle. | Default. |
| `STEAMCMD_ARGS` | `validate` | string; empty is kept | Extra `steamcmd` arguments for each update. | Default. |
| `PUBLIC_TEST` | `false` | `true`/`false` | Appends the public-test beta branch flags to `STEAMCMD_ARGS`. | Default. |
| `UPDATE_INTERVAL` | `315360000` | seconds | Legacy. **Do not set.** | Unset. |

`bootstrap` installs the `UPDATE_CRON` entry only while `UPDATE_INTERVAL`
still equals its sentinel default of `315360000` (10 years). Setting
`UPDATE_INTERVAL` to any other value silently drops the cron and puts the
updater back on the old fixed-interval sleep loop.

### Restart cadence

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `RESTART_CRON` | `10 5 * * *` | cron, or empty to disable | Scheduled `supervisorctl restart valheim-server`. Every restart rotates the crossplay join code. | `10 5 * * 1` (weekly). See "Restart cadence vs. the join code" (#458). |
| `RESTART_IF_IDLE` | `true` | `true`/`false` | Restart only if idle. A busy occurrence is skipped, not deferred. | Default. The idle caveat above applies. |

### Backups

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `BACKUPS` | `true` | `true`/`false` | Periodic world backups, plus one on startup. | Default. |
| `BACKUPS_CRON` | `5 * * * *` | cron, or empty to disable | Backup schedule: **hourly at minute 5**. | Default. |
| `BACKUPS_DIRECTORY` | `/config/backups` | path inside the container | Backup target. Must not be under `/config/worlds_local/`. | Default, so it lands at `/var/lib/containers/valheim/config/backups` and goes into the daily restic snapshot. |
| `BACKUPS_MAX_AGE` | `3` | days | Delete backups older than this. Always enforced, even under `BACKUPS_MAX_COUNT`. | Default. |
| `BACKUPS_MAX_COUNT` | `0` | integer, `0` = unlimited | Keep at most this many backups. | Default. |
| `BACKUPS_IF_IDLE` | `true` | `true`/`false` | `true` backs up regardless of activity. `false` backs up only with players connected, or within the grace period after the last one leaves. | Default. |
| `BACKUPS_IDLE_GRACE_PERIOD` | `3600` | seconds | Grace period for `BACKUPS_IF_IDLE=false`. It should cover one 20-minute world save plus one `BACKUPS_CRON` tick. | Default. |
| `BACKUPS_ZIP` | `true` | `true`/`false` | Zip each backup. `false` stores 1.0 worlds as directories. | Default. |
| `BACKUPS_INTERVAL` | `315360000` | seconds | Legacy. **Do not set.** Same sentinel trap as `UPDATE_INTERVAL`: any other value drops the `BACKUPS_CRON` entry. | Unset. |

So with the defaults, the in-container backup directory holds roughly 72
hourly zips (3 days' worth) at any time. restic snapshots that whole set
daily, alongside the live world.

### Permissions

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `PUID` | `0` | uid | Uid the game server runs as. | `hostSpec.serverUid`, emitted by the oci-containers wrapper because of `myContainerApp.valheim.linuxServer = true`. |
| `PGID` | `0` | gid | Gid. | `hostSpec.serverGid`, same mechanism. |
| `PERMISSIONS_UMASK` | `022` | octal umask | Permissions applied to config, worlds, backups and mod config. | Default. |

The derived per-tree modes are under Undocumented below.

### Mods

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `BEPINEX` | `false` | `true`/`false` | Install BepInExPack Valheim. Config is in `/config/bepinex`, plugins in `/config/bepinex/plugins`. | `myValheim.bepinex`. Emitted only when true, so amos1's unit does not change. |
| `VALHEIM_PLUS` | `false` | `true`/`false` | Install ValheimPlus instead. `valheim-bootstrap` refuses to start with both this and `BEPINEX` enabled. | Unset. |
| `VALHEIM_PLUS_REPO` | `Grantapher/ValheimPlus` | `owner/repo` | Which V+ fork to download. | Unset. |
| `VALHEIM_PLUS_RELEASE` | `latest` | `latest` or `tags/<tag>` | Which V+ release to download. | Unset. |
| `VPCFG_<section>_<key>` | — | value | Merged into `valheim_plus.cfg` on start. | Unused. |
| `BEPINEXCFG_<section>_<key>` | — | value | Merged into `BepInEx.cfg` on start. | Unused, deliberately. |

The image's env-to-config mechanism (`env2cfg`) encodes characters that
are illegal in variable names: `_DOT_` → `.`, `_HYPHEN_` → `-`,
`_UNDERSCORE_` → `_`, `_PLUS_` → `+`, `_SPACE_` → a space. So
`BEPINEXCFG_Logging_DOT_Console_Enabled=true` writes `[Logging.Console]
Enabled=true`. Existing keys are kept, and the old file is saved as
`*.cfg.old`.

BepInEx, not ValheimPlus, because BepInEx is the framework the plugins in
`bepinexPlugins` target. ValheimPlus is one monolithic mod with its own
loader.

**Do not propose `BEPINEXCFG_*` as a simplification.** Plugin config here
comes from `_valheim/bepinex-materialize.sh`, which installs Nix-built,
pinned config files into the Nix-managed subtree before every start. That
config is reviewable in a diff, removes its own files when a plugin is
dropped, and changes the `ExecStartPre` line, so a deploy restarts the
server. A sprawl of encoded env vars has none of those properties, and it
only reaches `BepInEx.cfg`, not plugin config files.

### Supervisor HTTP

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `SUPERVISOR_HTTP` | `false` | `true`/`false` | Start supervisord's web UI/XML-RPC API (start, stop, restart, tail). | Unused. |
| `SUPERVISOR_HTTP_PORT` | `9001` | TCP port | Its listen port. | — |
| `SUPERVISOR_HTTP_USER` | `admin` | string | Basic-auth user. Auth is applied only if both user and pass are set. | — |
| `SUPERVISOR_HTTP_PASS` | — | string | Basic-auth password. | — |
| `SUPERVISOR_HTTP_PASS_FILE` | — | path | Read the password from a file. | — |

It binds `:<port>` on every interface. Under `--network=host` that means
the host itself, so turning it on would need a firewall decision and a sops
secret for the password. Everything it offers is already available via
`podman exec valheim supervisorctl …`.

### Status HTTP

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `STATUS_HTTP` | `false` | `true`/`false` | Start busybox httpd plus an updater that writes `status.json` (players, version and so on) every 10 s from an A2S query. | Unused. |
| `STATUS_HTTP_PORT` | `80` | TCP port | httpd port. Under host networking this would claim the host's port 80. | — |
| `STATUS_HTTP_CONF` | `/config/httpd.conf` | path | busybox httpd config. | — |
| `STATUS_HTTP_HTDOCS` | `/opt/valheim/htdocs` | path | Where `status.json` is written. | — |

**Inert as configured.** Nothing in `bootstrap` stops `STATUS_HTTP` from
starting, but the data comes from A2S queries, which upstream says private
(`SERVER_PUBLIC=false`) servers do not answer, and which answer 0 players
under crossplay anyway. This module sets both, so the page would serve a
timeout error at best. The player count
it would carry is already published by the module's own exporter
(`_valheim/metrics.nix` and the player-notify roster).

### Remote syslog

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `SYSLOG_REMOTE_HOST` | — | host/IP | Ship the in-container syslogd output to a remote syslog. | Unused. |
| `SYSLOG_REMOTE_PORT` | `514` | UDP port | Remote port. | — |
| `SYSLOG_REMOTE_AND_LOCAL` | `true` | `true`/`false` | Keep logging to stdout too. | — |

Unused because stdout already reaches journald through podman's log driver,
and vector ships it to VictoriaLogs from there. Note that setting
`SYSLOG_REMOTE_AND_LOCAL=false` would drop the server's output from the
journal, and with it everything `joincode.nix`, `player-notify.nix` and
`JournalLogRateHigh` read.

### Log filters

| Variable | Default | Values | What it does | Here |
| --- | --- | --- | --- | --- |
| `VALHEIM_LOG_FILTER_EMPTY` | `true` | `true`/`false` | Drop empty lines. | Default. |
| `VALHEIM_LOG_FILTER_UTF8` | `true` | `true`/`false` | Drop invalid UTF-8. | Default. |
| `VALHEIM_LOG_FILTER_MATCH*` | `` ` `` (one space) | string | Drop lines exactly equal to the value. | Default. |
| `VALHEIM_LOG_FILTER_STARTSWITH*` | `(Filename:` | string | Drop lines with this prefix. | Default. |
| `VALHEIM_LOG_FILTER_ENDSWITH*` | — | string | Drop lines with this suffix. | — |
| `VALHEIM_LOG_FILTER_CONTAINS*` | — | string | Drop lines containing this substring (case-sensitive). | Three `…_GetPublicIP*` filters (#590). See "GetPublicIP log-rate runaway". |
| `VALHEIM_LOG_FILTER_REGEXP*` | — | Go regexp | Drop matching lines. | — |
| `ON_VALHEIM_LOG_FILTER_<kind>*` | — | shell command | Instead of dropping the line, run the command with the line on stdin. | Avoided, deliberately. |
| `VALHEIM_LOG_FILTER_VERBOSE` | `2` | integer | glog `-v` level of `valheim-logfilter` itself. Only in `defaults`, not in upstream's README. | Default. |

Every filter except `_EMPTY` and `_UTF8` is a **prefix**: any variable
whose name starts with it defines another filter (the `*` above), and the
suffix is just a unique name. `defaults` ships two more out of the box:
`VALHEIM_LOG_FILTER_STARTSWITH_AssertionFailed` (the packet-timeout
assertion flood). When `BEPINEX` or `VALHEIM_PLUS` is on, it also ships
`VALHEIM_LOG_FILTER_STARTSWITH_BepInEx` (`Fallback handler could not load
library`).

The `ON_*` hooks run `/bin/bash -c` once per matching line. The comment on
the GetPublicIP filters in `../valheim.nix` explains why that is the wrong
tool at that log rate. It is also why the notifiers here tail the journal
instead of hooking log lines.

### Event hooks

All default to empty. Each hook is a shell command run **inside the
container**. The scripts run every one of them with a synchronous `eval`,
so each hook holds up whatever invoked it until it returns. That includes
the two upstream does not describe as blocking.

| Variable | Runs | Blocks |
| --- | --- | --- |
| `PRE_SUPERVISOR_HOOK` | in `bootstrap`, before supervisord starts | container startup |
| `PRE_BOOTSTRAP_HOOK` / `POST_BOOTSTRAP_HOOK` | around `valheim-bootstrap` (the POST hook is where upstream suggests installing extra packages) | startup |
| `PRE_BACKUP_HOOK` / `POST_BACKUP_HOOK` | around each backup; `@BACKUP_FILE@` is replaced with its path | that backup and the next |
| `PRE_UPDATE_CHECK_HOOK` / `POST_UPDATE_CHECK_HOOK` | around each `UPDATE_CRON` check | the check and later updates |
| `PRE_START_HOOK` / `POST_START_HOOK` | around the updater's first server start | that start, then later restarts and updates |
| `PRE_RESTART_HOOK` / `POST_RESTART_HOOK` | around an updater-driven restart | that restart, then later ones |
| `PRE_SERVER_RUN_HOOK` / `POST_SERVER_RUN_HOOK` | around the game process itself | server start / shutdown (POST times out after 29 s) |
| `PRE_SERVER_LISTENING_HOOK` / `POST_SERVER_LISTENING_HOOK` | before / once the server accepts connections (status `running`) | the listening poll |
| `PRE_SERVER_SHUTDOWN_HOOK` / `POST_SERVER_SHUTDOWN_HOOK` | around shutdown | shutdown (PRE is hard-killed at 90 s) |
| `PRE_BEPINEX_CONFIG_HOOK` / `POST_BEPINEX_CONFIG_HOOK` | around writing `BepInEx.cfg` (POST is where upstream suggests running `env2cfg` for plugin config) | startup |

That is 19 hooks. Upstream's README table lists all of them, though
`POST_SERVER_SHUTDOWN_HOOK` is easy to miss.

**The built-in Discord pattern, and why this repo does not use it.**
`DISCORD_WEBHOOK` and `DISCORD_MESSAGE` are not image variables. They are
a convention from upstream's examples: define them yourself, then reference
them from a hook such as `PRE_RESTART_HOOK='curl … "$DISCORD_WEBHOOK" &&
sleep 60'`, or from an `ON_VALHEIM_LOG_FILTER_CONTAINS_*` hook on `Got
character ZDOID from` for player joins. This repo instead uses its own
systemd notifier units (`_valheim/joincode.nix`, `_valheim/player-notify.nix`)
that tail the journal. The hooks run on the container's hot path, so a slow
or hanging `curl` delays a backup, a restart or a shutdown. They also get no
retry, restart, watchdog or alerting of their own, and they would need the
webhook URL in the container environment. The systemd units are decoupled
from the game process, are watched by the module's own alerts, and read the
webhook from sops. Revisiting that choice is separate work.

### Undocumented (`defaults` only)

Upstream's README says these "could break things if configured wrong" and
points at `defaults` without documenting them. They are listed here with
that warning standing. None is set here, and none should be without
reading the script that consumes it.

| Variable | Default | What it does |
| --- | --- | --- |
| `DEBUG_START_FRESH` | `false` | Wipe all downloaded server data on start (config untouched). |
| `DEBUG_REINSTALL_VALHEIM_PLUS` | `false` | Make the V+ updater reinstall the V+ zip over the vanilla server. |
| `DEBUG_REINSTALL_BEPINEX` | `false` | Same for BepInEx. |
| `VALHEIM_PLUS_CFG_ENV_PREFIX` | `VPCFG_` | Prefix the V+ env-to-config pass looks for. |
| `BEPINEX_CFG_ENV_PREFIX` | `BEPINEXCFG_` | Prefix the BepInEx env-to-config pass looks for. |
| `SERVER_STATUS_FILE` | `/var/run/valheim/valheim-server.status` | Where the image records its own server state (starting/running/stopped). Its scripts read it. |
| `DEFAULT_DIRECTORY_PERMISSIONS` / `DEFAULT_FILE_PERMISSIONS` | `0777` / `0666` masked by `PERMISSIONS_UMASK` (so `0755` / `0644`) | Base modes the per-tree variables below inherit. |
| `CONFIG_DIRECTORY_PERMISSIONS` / `CONFIG_FILE_PERMISSIONS` | the defaults above | Modes applied under `/config`. |
| `WORLDS_DIRECTORY_PERMISSIONS` / `WORLDS_FILE_PERMISSIONS` | the defaults above | Modes applied to the worlds directories. |
| `BACKUPS_DIRECTORY_PERMISSIONS` / `BACKUPS_FILE_PERMISSIONS` | the defaults above | Modes applied to `BACKUPS_DIRECTORY`. |
| `VALHEIM_PLUS_CONFIG_DIRECTORY_PERMISSIONS` / `VALHEIM_PLUS_CONFIG_FILE_PERMISSIONS` | the defaults above | Modes for `/config/valheimplus` when V+ is on. |
| `BEPINEX_CONFIG_DIRECTORY_PERMISSIONS` / `BEPINEX_CONFIG_FILE_PERMISSIONS` | the defaults above | Modes for `/config/bepinex` when BepInEx is on. The materializer's tree lives here, so the image re-chmods it on each start. |
