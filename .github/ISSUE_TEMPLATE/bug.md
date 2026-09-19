---
name: Defect
about: Something is behaving wrongly, and there is evidence of it
title: "<area>: <what is wrong, stated as the fault not the symptom>"
labels: bug
assignees: ''
---

<!--
Sections marked OPTIONAL can be dropped when they don't apply. The rest carry
their weight on almost every defect here — see .claude/skills/create-issue for
what belongs in each and why.
-->

## Summary

<!-- The fault in 2-4 sentences: what misbehaves, the user-visible consequence,
and when it was observed. If this was split out of another issue, say so and
link it. -->

## Evidence

<!-- Quantified. "N occurrences in the last 7 days", not "this happens a lot".
Log excerpts in a fence with timestamps, trimmed to the lines that matter.
State the window and host you measured over. -->

## Root cause

<!-- The mechanism, located in the repo: modules/<path>.nix:<line>. If a
constant, timeout or budget is load-bearing here, verify it against source
rather than quoting a comment, and cite what you read. -->

## Ruled out

<!-- What this is NOT, each with the observation that eliminates it. Also note
anything that lands inside the window but is coincidence, and why. -->

## Why it hasn't bitten before

<!-- OPTIONAL, but write it whenever the code was wrong all along. It changes
how urgent the fix is: "coincidentally not wrong" is different from "regressed
last week". -->

## Impact

<!-- OPTIONAL. Be honest about what is confirmed vs. suspected. "I have not
confirmed a user-visible fault" is a legitimate and useful thing to write. -->

## Proposed fix

<!-- The direction, not necessarily the patch. Include:
  - anything downstream that names the mechanism you're replacing — buffering
    flags, helper vars, comments, runbooks — since those cascade;
  - for a package addition, what else the package brings (units, PATH entries)
    and why it's inert;
  - alternatives you considered and rejected, with the reason. -->

## Verification

<!-- How to prove the fix works from outside the thing that lied. Name any step
that needs a human, a game/desktop client, or physical access — flag those up
front rather than discovering them at PR time. -->

## Context

<!-- OPTIONAL. Host, versions, hardware, upstream issue links. -->
