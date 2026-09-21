---
name: Enhancement
about: New behaviour, or a change to how something works
title: "<area>: <the change, stated as an outcome>"
labels: enhancement
assignees: ''
---

<!--
Sections marked OPTIONAL can be dropped when they don't apply. The rest exist
to stop the implementing session re-deriving ground you already covered — see
skills/create-issue.
-->

## Summary

<!-- What should change and what it enables, in a few sentences. If this was
deliberately left out of an earlier PR, say so and link it. -->

## Why now / why this way

<!-- The constraint that makes this the right change. Where an existing signal
or mechanism is inadequate, show it: which sources you can't use, and the
measurement that disqualifies each. -->

## Proposed approach

<!-- Concrete enough to implement. For an option surface, show the shape:

```nix
myThing = {
  enable = true;
  someToggle = false;
};
```

Where more than one design is viable, list them with a recommendation and the
trade-off, not a bare menu. Say which parts change the option surface — that is
a different question from how the behaviour is wired. -->

## Work

<!-- Checklist, one line per edit, naming the file. Include the obligations
this repo attaches to the shape you're building: a recovery:<app> task and
expectedPreservedDirs for a new app, a task hashes run after a pin edit,
restartUnits placement, comments that need rewriting because their rationale
changed. -->

- [ ]

## No change needed

<!-- Verified-and-listed, so it isn't re-derived during implementation. Secrets,
preservation/backups, recovery tasks, alert rules — whichever you checked. Say
what you checked, not just "nothing else". -->

## What must not change

<!-- OPTIONAL but strongly preferred for anything touching a shared module or a
prod host: what has to stay byte-identical, and how that will be proven. A
closure diff against origin/main beats a smoke test. -->

## Verification

<!-- Checklist. Mark the load-bearing unknown — the assumption the whole plan
rests on, to be tested first — and name any step needing a human or physical
access. For anything querying metrics, state the retention and scrape interval
and confirm your window fits inside them. -->

- [ ]

## Rollback

<!-- OPTIONAL. How to back this out, and what survives on disk if you do. -->

## Explicitly not doing

<!-- OPTIONAL. Scope this issue excludes, and where it lives instead. -->

## Open questions

<!-- Each with a recommendation and reasoning, so the implementer can accept or
argue rather than guess. -->
