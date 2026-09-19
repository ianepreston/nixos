# Filling the investigation template

Skeleton: `.github/ISSUE_TEMPLATE/investigation.md`. No label. Exemplar:
**#662** — filed on live evidence, closed about an hour later as *"explained, not
a defect"*, and cited by #663 for the event taxonomy it recorded.

Use this when you have evidence and no diagnosis, or when the right next step
is instrumentation rather than a fix. The write-up is the deliverable; closing
it with an explanation is a success.

## Summary

Observation, host, period, and how it surfaced. Be explicit that this is not
(yet) a defect report, and link whatever it was split out of:

> Surfaced while diagnosing #661; filed separately because the join-code fix
> does not touch it. (#662)

## Evidence

Same bar as a defect: counted, timestamped, grouped into episodes with
durations. Include the full sequence for at least one episode — a reader
reconstructing causality needs the gaps between lines, not just the lines.

## What the ordering tells us

Usually the analytical core. Establish which symptom precedes which, then state
what that rules in or out:

> 1. **The relay drop comes first.** `PlayFab network error ... code '63'` at
>    16:50:41 precedes any DNS failure. So DNS is not the trigger.
> 2. **DNS then fails during recovery**, which is what prolongs it... So the DNS
>    failures are a secondary amplifier, not the root cause — but they are the
>    difference between a momentary blip and six minutes off the relay. (#662)

Getting this backwards is the expensive failure mode. #662's own framing was
later corrected in its closing comment — with the WAN absent, both symptoms
were consequences of the same cause, and "DNS prolonged recovery" had the
causality backwards.

## Ruled out

Each with its eliminating observation, and name the coincidences so nobody else
chases them. State where you looked and found nothing: "No other host-level
warnings in the 16:40-17:00 window that line up."

## Open questions

Phrased so an answer would be decidable, and say what would make you believe
each one:

> - **Time-of-day clustering.** Both episodes fall in a ~16:41-16:56 window on
>   consecutive days. Suspicious enough to want a third data point before
>   theorising.
> - **Is the resolver actually failing, or is the container's curl failing to
>   reach it?** Distinguishing those needs resolution attempts logged from
>   outside the container. (#662)

Ask whether this is a better-instrumented instance of an existing issue rather
than a new fault, and link the candidate.

## Suggested next step

Usually instrumentation, not a fix — and name what already exists that could
carry it, so the next issue is small:

> There is no monitoring on this today — the six-minute outage was found by
> reading logs after a player complained. Before chasing a root cause, export
> the relay state so the next episode is observed rather than reconstructed:
> `valheim-metrics` already runs on a 2m timer and could publish a counter of
> `PlayFab host fast recovery` occurrences. That also tells us whether the
> time-of-day clustering is real. (#662)

Resist proposing an alert on the raw event. On #662's data, an alert on relay
drops would have fired three times for planned maintenance and zero times for
the real defect (#661) — noise that trains the reader to ignore it. The signal
worth having is usually a *state* comparison, evaluated once things settle,
rather than an *event* count.

## Closing one

When it resolves without code, close with a comment that explains it and keeps
the taxonomy findable — that comment is why the issue was worth filing. If part
of the remediation is manual or off-repo (a pfSense package, a cron job), write
the runbook into a comment rather than leaving it in a branch, as #643 did.
