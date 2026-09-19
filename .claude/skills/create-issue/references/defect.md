# Filling the defect template

Skeleton: `.github/ISSUE_TEMPLATE/bug.md`. Label `bug`. Exemplars worth reading
in full before writing your first one: **#661** (silent wrong answer), **#649**
(guard that fell through), **#650** (two-paragraph defect done right).

## Summary

State the fault, its user-visible consequence, and when it was observed. If it
was split out of another investigation, say so in the same breath.

> `valheim-joincode-notify` keys off the wrong log line and announced a join
> code that had already been superseded. On 2026-09-18 Discord advertised
> **496995** while the live PlayFab session was **555295**; a remote player
> using the announced code got "unable to resolve join code" while players
> holding the real code connected fine. (#661)

When the failure is silent, say that explicitly and say what the system
reported instead — it is usually the worst part of the bug:

> The watcher reported success the whole time — unit `active (running)`, no
> errors, a cheerful `join code 496995 already announced, skipping`.

## Evidence

Counted, over a stated window, on a named host. Then the excerpt that shows the
mechanism, with timestamps, trimmed to the lines that matter. Annotate the
lines that carry the argument:

```
16:56:39  Session "amos1-g2-valheim" registered with join code 496995
16:56:40  Created new join code 555295 for session "amos1-g2-valheim"
16:56:43  Session ... with join code 555295 ... is active   <- what the relay serves
```

Where the same fault recurred, group into episodes with durations (#662's two
PlayFab episodes, ~1 min and ~6 min). Where ordering matters, make it a section
of its own and state the conclusion — a symptom that appears *after* the first
failure is an amplifier, not a trigger.

## Root cause

Name the file and line. Explain why the code is wrong in principle, not just in
this instance — "that line reports what the server *offered* at
re-registration, not what PlayFab issued back" is the sentence that makes the
fix obvious.

If a constant is load-bearing, read the source that defines it and cite it.
#649's budget came from a repo comment and was wrong by 30 seconds, which
changed the fix's sizing at PR time.

## Ruled out

One line each, with the observation that eliminates it. Include near-misses:

> Not correlated with upsmon. An upsmon poll failure against the same
> 192.168.10.1 lands at 16:52:24, inside the window, but upsmon flaps many
> times a day independent of any Valheim event, so this is coincidence. (#662)

## Why it hasn't bitten before

Write this whenever the code has been wrong all along — it tells the reader
whether they are looking at a regression or a latent fault, which changes
urgency and changes whether a bisect is worth anything.

> `Created new join code` has fired exactly twice in the container's entire
> log, both at 16:56:40 today. Until now every re-registration returned the
> same code it offered, so the pattern happened to be correct. It was never
> *right* — just coincidentally not wrong. (#661)

## Impact

Optional, and the honest version is the useful one:

> Not yet pinned down, and worth stating plainly: I have **not** confirmed a
> user-visible audio fault. What's established is that Steam's device
> enumeration path fails every time it runs. Worth fixing on its own merits
> regardless. (#650)

## Proposed fix

Direction plus the traps. Three things belong here that are routinely missed:

- **The cascade.** Everything downstream that names the mechanism being
  replaced. Changing a `grep` filter to `sed` also moves `--line-buffered` to
  `-u`, orphans a gnugrep helper var, and invalidates any comment explaining
  the old exit-code behaviour (#661 → #663).
- **Alternatives rejected, with the reason.** #661 recommended *against* also
  matching `Created new join code`, naming the specific candidate code
  (809934) that would have been announced wrongly. That saved the implementer
  from re-deriving it.
- **What to keep.** Guards that look vestigial but are load-bearing for a
  different reason — #661 called out the `|| true` guards as #640's fix,
  unrelated to this bug, keep them.

For a package addition, say what else the package brings and why it is inert
(#651: the `pulseaudio` package's own systemd units land on pipewire-pulse's
socket path, harmless only because upstream ships `Conflicts=`).

## Verification

Prove it from outside whatever lied. A watcher that reports success while
publishing a dead code cannot be verified by reading its own logs:

> An announcement is only trustworthy if it matches what the relay serves, so
> verify against a join rather than against the log alone. (#661)

Name any step needing a human or a client you don't have. Saying it here beats
discovering it in the PR's "not validated" section.
