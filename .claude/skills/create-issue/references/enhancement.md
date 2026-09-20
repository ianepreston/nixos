# Filling the enhancement template

Skeleton: `.github/ISSUE_TEMPLATE/enhancement.md`. Label `enhancement`.
Exemplars: **#644** (option surface, per-host toggle — the most complete one in
the repo), **#636** (observability rule design), **#625** (process/CI change),
**#631** (small, scoped, with design notes).

The job is to leave the implementing session with nothing to re-derive. Every
section below exists because its absence cost a PR something real.

## Summary + why now

What changes, what it enables, and the constraint that makes this the right
move. When an earlier PR deliberately deferred this, link it — that history is
the justification:

> Deliberately left out of #609 to keep that PR scoped to the Discord notifier,
> and because the consumer side belongs with #458. (#631)

## Why the obvious approach doesn't work

Where you're proposing a new mechanism because existing ones are inadequate,
disqualify each one with a measurement. #631 is the model — four candidate
presence signals, each killed with evidence:

> - **A2S query** returns 0 always; the image's own `server_is_idle` says so.
> - **`IDLE_DATAGRAM_*` counting** trips on PlayFab lobby chatter — the updater
>   logged "Players connected" 39 times in a window where the world file never
>   changed a byte.
> - **The `now N player(s)` lines** are internally inconsistent: a leave that
>   took the server 3→2 logged `now 3`, and a *join* logged `now 2`.

Without this the implementer tries the obvious thing first and rediscovers why
it fails.

## Proposed approach

Concrete. For an option surface, show the Nix:

```nix
myValheim = {
  enable = true;
  crossplay = false;
  bepinex = true;
};
```

...and say why the shape is what it is (`enable` rather than import-site gating,
because the profile also ships to tests-server and downloading 1.5 GB of
steamcmd for the recovery-drill VM is pure cost).

Where several designs are viable, list them **with a recommendation**, not as a
bare menu — #636 offered three rule shapes and named option 2 as "probably the
best regression signal", which is what the PR built.

Tabulate what a toggle gates, including the rows where the answer is "nothing":

| | `crossplay = true` | `crossplay = false` |
| --- | --- | --- |
| Inbound firewall | none — relay is outbound-only | UDP game ports open |
| joincode-notify | on | off — no session, no code |

**Ask whether an open question changes the option surface.** #644 framed
player-notify on dev as a wiring choice ("off, or its own channel?"); at PR time
it became a fourth option, because gating it on `crossplay` would have
conflated a channel-noise preference with a backend requirement.

## Work

One checkbox per edit, naming the file. Include this repo's structural
obligations for the shape you're building, since they are easy to forget and
`task check` will not catch them:

- a new app under `modules/apps/` needs a `recovery:<app>` task **and** an
  append to `recovery:all`, plus an `expectedPreservedDirs` entry
- a `version`/`tag`/`rev` edit needs `task hashes`
- `restartUnits` goes on the sops template, not the secret
- comments whose rationale your change invalidates — #644 listed the header
  section and the `let`-block comment explicitly

## No change needed

Verified and listed, so implementation doesn't re-derive it:

> - **Secrets.** `sops/hpp-1.yaml` already carries `valheim/{server_password,
>   discord_webhook,player_webhook}` — no `task secrets:*` run needed.
> - **Preservation/backups.** `preservation-server.nix` preserves
>   `/var/lib/containers` wholesale and restic paths derive from
>   `myContainerApp.<app>.stateDirs`, so no `expectedPreservedDirs` edit.
> - **Recovery.** `recovery:valheim` already takes `HOST`. (#644)

Say what you checked. "Nothing else needed" is not the same claim.

## What must not change

For anything touching a shared module or a prod host, state what has to stay
identical and how it will be proven. Prefer a build-time proof:

> The amos1 closure was built from `origin/main` and from this branch and
> diffed file-by-file. The only differences are the `self` flake source store
> path... No unit file, firewall rule, container environment variable or sops
> secret differs. (#647)

That diff is what surfaced the `BEPINEX="false"` hazard — always emitting the
var would have been behaviourally identical to the container but would rewrite
the unit and bounce it, rotating the join code out from under every player.

## Verification

A checklist, with the **load-bearing unknown marked first**:

> - [ ] **A LAN Steam client can actually join `192.168.10.10:2456`.** This is
>   the load-bearing unknown in the whole plan — everything above assumes
>   Steam-backend direct connect works with `SERVER_PUBLIC=false`. Test it
>   before closing anything else out. (#644)

Prefer absence checks that distinguish states: "joincode-notify is *absent* on
hpp-1, not present-and-failing".

For metrics work, state retention and the scrape interval, and confirm your
window fits — read both off `modules/system/victoriametrics.nix` at the time of
writing rather than quoting a figure from here. #636's "compare against two
weeks ago" was rejected at PR time because retention was then 15 days, putting
`offset 14d` on the edge where it silently evaluates to nothing. Retention is
45 days now, so that objection has expired — which is exactly why this says
check rather than naming a number.

## Rollback, not-doing, open questions

Rollback: the one-line revert and what survives on disk. Not-doing: scope you
are excluding and where it lives instead (#625 has an explicit section). Open
questions: each with a recommendation and reasoning, so the implementer can
accept or argue rather than guess.
