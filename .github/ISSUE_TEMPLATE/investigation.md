---
name: Investigation
about: Something was observed that isn't understood yet — no fix proposed
title: "<area>: <the observation>"
labels: ''
assignees: ''
---

<!--
Use this when you have evidence but not a diagnosis. Closing this as
"explained, not a defect" is a success, not a failure — the write-up is the
deliverable. See skills/create-issue.
-->

## Summary

<!-- What was observed, on which host, over what period, and how it came to
light (an alert, a user report, reading logs). -->

## Evidence

<!-- Quantified and timestamped, as for a defect. Group into episodes if it
recurred. -->

## What the ordering tells us

<!-- OPTIONAL but usually the point. Where several symptoms co-occur, establish
which precedes which, and say plainly what that rules in or out — a symptom
that appears after the first failure is an amplifier, not a trigger. -->

## Ruled out

<!-- Each with the observation that eliminates it, including anything that
lands in the window by coincidence. -->

## Open questions

<!-- What you genuinely don't know, phrased so an answer is decidable. -->

## What would confirm or refute this

<!-- The observation that would settle it, and where it would have to be made
from — often outside the process that is lying. -->

## Suggested next step

<!-- Usually instrumentation rather than a fix: export the signal so the next
occurrence is observed rather than reconstructed. Say what already exists that
could carry it. -->
