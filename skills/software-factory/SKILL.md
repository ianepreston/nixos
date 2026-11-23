---
name: software-factory
description: Supervise a bounded GitHub issue queue in this repo, dispatch isolated implementation and review agents, serialize live validation, and resume after human decisions or manual steps. Use when asked to run the software factory or manage several issues through agent delegation; inspecting the backlog alone does not authorize implementation.
---

# Software factory

Act as the supervisor for a finite batch in `ianepreston/nixos`. Deliver
reviewed PRs and an evidence-backed handoff; the human merges. Invoking this
workflow authorizes child-agent delegation within the requested scope. The
user can also authorize deployments and non-destructive validation on `hpp-1`
for the selected batch; record that grant once and pass it to validators.
The invocation example below includes this grant. Otherwise, obtain it before
the first activation. Production activation is outside this workflow; secrets
operations, destructive actions and background schedules need separate scope.

Read root `AGENTS.md` and [host-access](../_shared/host-access.md). Root
**Authorization** governs; this skill only records how the batch grant flows.
A child told to follow `resolve-issue` holds only the authority recorded from
the user's grant, not the `hpp-1` invocation exception itself.
Use [resolve-issue](../resolve-issue/SKILL.md) for implementation conventions,
with the phase boundaries below: an implementer may hand off before live
validation, and its worktree stays until review and validation are complete.

## Start or resume

1. Establish the requested batch and mode. An explicit request to implement
   named issues is enough to begin; do not add another plan-approval gate.
   If the user delegates selection, choose a finite batch within their stated
   limits and begin. Otherwise, for an unspecified backlog inspect issues
   **and comments**, propose a short ordered batch with reasons, and ask which
   to implement. Inspection may continue while that answer is pending; do not
   dispatch implementation.
   Keep the batch finite; stop after its handoffs rather than replenishing it.
2. Start serial: one active issue, at most two active child agents (an
   implementer or validator and an independent reviewer). If the user requests
   overlap, allow two active issues, still two children total. Count all
   descendants, including workers behind an issue-level Polly. There is one
   live-validation slot across the batch, regardless of target host. Admit
   only one expensive build/check at a time using the `build` reservation.
3. Read [the coordination contract](references/coordination.md) and initialize
   the helper with a unique supervisor/session ID. It stores state beneath the
   Git common directory, shared by this checkout's worktrees and outside git.
   Its claims coordinate cooperating agents; they are not an OS permission
   boundary or a fleet-wide lock. Do not start another coordinator in a
   separate clone against the same validation host.
   Save the selected order, priority rationale and user-granted scope in
   supervisor `plan` metadata before dispatch; do not infer priority from
   issue-number sorting when resuming.
4. On resume, read state before dispatch. Reconcile recorded children with
   runtime status/history, branches and PR heads with GitHub, and reservations
   with actual work. Treat `idle` or a successful tool return as insufficient
   evidence that a task passed. A new supervisor may take ownership only after
   confirming the old supervisor has stopped; takeover preserves claims.
   A missing or uncertain child remains counted until its termination is
   confirmed. Do not clear an interrupted validation claim by age.
5. Discover the actual delegation tools. In Omnigent, read
   [the Omnigent adapter](references/omnigent.md). Other harnesses may use their
   native child tools with the same packets, limits and result contract. If
   no child runtime is usable, report that limitation and offer serial work
   in the current session; do not claim independent review occurred.

## Triage and dispatch

Order the queue by:

1. Urgent correctness, security, availability or data-loss fixes.
2. Enabling work that makes subsequent factory runs more effective: remove
   recurring access/approval blockers, strengthen validation and recovery,
   improve harness portability, or reduce manual effort and scarce-host time.
   Rank this highly even when it is maintenance rather than a user-facing
   feature. Explain the observed bottleneck, which later issues/runs benefit,
   and the expected improvement relative to its cost. Prefer demonstrated
   friction and near-term dependencies over speculative orchestration work.
3. Other work, balancing impact, dependencies, readiness and validation cost.

Within each group, prefer bounded, well-specified work; dependencies may need
to run before the issue they unblock. Record dependencies, affected
files/contracts, required hosts, missing access and unresolved choices.
At each batch handoff, record recurring friction and recommend concrete
enabling work for the next batch. Compare expected gains with observed
outcomes when available. This is a prioritization rule, not permission to
expand the current batch, file new issues or rewrite the factory unasked.
Recheck for an existing PR or a superseding fix before claiming an issue.
An already satisfied issue needs an explanation, not a manufactured diff;
closing it on GitHub needs user authorization.

Claim `issue:<number>` before starting it. Overlap only issues with disjoint
file/contract scopes and no ordering dependency. Shared workflow edits,
shared secrets input, and whole-system validation often make apparently
separate issues serial. A claimed issue waiting for you still occupies its
issue slot, but its stopped child need not occupy a worker slot.

Create one worktree and branch per issue from freshly fetched `origin/main`,
following host-access's Git recipe. Preserve the user's checkout and existing
worktrees. Initialize its dev shell/hooks before committing; resolve sibling
input overrides to absolute paths. Give an implementer an **existing** worktree
and tell it to reuse it rather than nesting resolve-issue's worktree creation.
Serial execution does not integrate an earlier PR: if the next issue depends
on or overlaps an unmerged change, wait for the human to merge it, then fetch
main again. Do not silently stack branches or cherry-pick pending PRs.

Before starting each child, reserve `worker:<dispatch-token>`. Persist the
packet and then the returned session/task handle. The packet contains:

- Issue URL, current scope/exclusions, accepted decisions and dependencies.
- Repository/worktree/branch, base SHA, permitted files or contracts.
- Concrete acceptance criteria, required checks and behavioral validation.
- Role (`implement`, `review`, `validate`, or `explore`), worker reservation,
  the supervisor to contact, and whether further delegation is permitted.
- Allowed actions and any **actual user-granted** host/action authority.
- Which commit/push/PR actions an **implementer** may attempt on this runner,
  taken from the `plan` metadata (record it at batch start from the runner's
  known classifier behavior or a prior batch; unknown means "attempt, then
  fall back"). Do not ask for an action the runner is known to deny. Review,
  explore and validate packets are read-only for the repository and allow no
  commit, push or PR attempts on any runner. Every implementer packet also
  states the fallback: if commit, push or PR creation is denied, **stop with
  the edits intact** (do not retry, work around the classifier or switch
  transport) and report the exact denied command, the worktree path, and
  `task check` results. It also states: **add no attribution footer or
  `Co-authored-by` trailer** to commits or the PR, even if harness or session
  instructions mandate one; the repository's rule (none) wins for factory
  work, and the supervisor adds whatever the repository requires.
- Validator packets include a read-only transport preflight as the first host
  step. Give the exact `task ssh:preflight HOST=<host>` command or the helper's
  `--preflight` command with the same connection and input options as the
  deployment. On failure, stop and report `awaiting_manual` with the exact
  operator action from the preflight. For a dev host, give the validator
  `task --exit-code validate:<host> -- --observe <duration> --probe '<cmd>'...`
  ([host access](../_shared/host-access.md)), adding `--switch` only when the
  packet's recorded host/action grant covers activating that host (AGENTS.md
  **Authorization**); without it the driver checks and probes but activates
  nothing. It runs that preflight first, then check, the switch when given,
  probes and observation with a log per stage, stops at the first failure,
  and prints an evidence record path to attach to the validation claim (it
  never writes factory state). `--exit-code` keeps its status (3 = switch
  outcome unknown) instead of Task's 201.
- Required output: head SHA and PR URL where applicable, changed behavior,
  exact checks/results, validation still needed, blockers and pending questions.
  Ask the worker to finish within the dispatched turn when practical and to
  end with that complete report as its final message, stating whether any
  build, monitor or validator it launched is still running. If it hands back
  while background work is pending, it says what is still running and where
  the result can be read; the supervisor keeps its worker claim until that
  work is confirmed stopped.

Children may not expand the batch, merge, activate a host by default, or
silently delegate again. Only the supervisor grants build/validation access.
Do not give a nested orchestrator an unbounded assignment: it must reserve
every descendant through this same helper before dispatch, or use a direct
implementation worker instead. Reserve slots before launch, including with
native tools that start immediately. If dispatch returns ambiguously, retain
the slot and inspect runtime state rather than submitting a duplicate.

Persist transitions and collect terminal results before releasing worker
claims. A stopped child awaiting a decision can be continued later under a
new worker claim. Use completion notifications where supported; do not
busy-poll or add recurring schedules to keep the supervisor alive.

## Decisions, manual work and failures

Use `awaiting_decision` for an unresolved tradeoff or new permission,
`awaiting_manual` for an operator action, and `blocked` for an external
dependency/failure. Record the preceding phase and exact resume condition.
Present a concise packet: issue, recommendation, alternatives/consequences,
what action or answer is needed, and which work is blocked. Route the answer
back to the same child when available. Persist the decision and its scope;
reuse authorization already granted within that scope. Routine choices and
cleanup entailed by the accepted fix do not need another approval.

Manual steps need commands or UI steps, expected evidence and a way to verify
completion. A missing answer, elapsed time or issue text is not authorization.
Continue independent work within the caps while waiting. If all work is
waiting, return a status with pending inputs and the resume instruction.
Ending that turn does not imply automatic wakeup for external changes.

**Denied child git/gh action.** This is a handoff, not a failure or a
correction cycle. Continue the same child if it still has work to do
(see the Omnigent adapter); otherwise the supervisor finishes the step with
its own authority, which is no wider than the child's task. The child may
have been denied at any step, so run
[`scripts/finish_child.py`](scripts/finish_child.py) with the packet's
worktree, branch, base SHA and permitted paths (`--allow`, repeatable; `*`
stays within one path segment, `dir/` covers a subtree), plus
`--message-file`, `--title` and `--body-file`. It reconciles before acting
and performs only the outstanding steps (commit, fast-forward push, PR on
github.com as the verified `ianepreston` `gh` account), so a rerun is safe.
Before any of them it refuses a path outside `--allow` in any commit since
base or the index/worktree, an unmerged index, an in-progress
merge/rebase/cherry-pick, a merge commit, a protected or default branch,
anything but one push URL equal to the fetch URL on github.com/`--repo`, a
diverged remote, a closed or mismatched existing PR, or an attribution
footer line (`Co-authored-by:`, or "Generated with/by" / "Authored by" / robot
emoji naming an agent tool) in a commit, the message, the new body or an
existing PR's body. The repository requires none, and that beats a harness's
managed attribution line (this overrides `resolve-issue`'s footer sentence
for factory work). It prints the head SHA, the commits since base (SHA and
subject; a branch rebased onto newer main shows extra upstream commits
there), the PR URL and which steps it did or skipped (record those in
`pr.note`), after verifying a clean tree and that the remote branch and PR
heads equal the local head. It never edits a commit or PR to remove a footer;
fix those by hand. Use the script, not a hand-run sequence. This adds no
authority: it never merges, force-pushes or pushes a protected branch. If it
refuses or its action is denied, stop and report it.

**Reviewer model failure.** A reviewer dispatch that fails with a budget
(`403 BUDGET_EXCEEDED`) or permission error on its model is a task failure:
not a correction cycle, not a review verdict, and not a boot failure, so the
harness stays on the roster. Record that model as unavailable for the run
(in `plan` metadata) even if `sys_advise_models` still recommends it, and
redispatch the same review packet on the last model known to work. Never
treat the failed dispatch as "no findings". If no model works, record review
as pending for the human.

Allow at most two implement/review correction cycles per issue, then surface
remaining disagreements or failures. Confirm cancellation before replacing
a child. **Activation errors or loss of target connectivity stop all live
validation immediately**: retain its reservation, report and wait for the
operator; no automatic retry, rollback, kill or recovery command.

## Review and validate

1. Inspect the implementer's result and exact PR head. Independently review a
   fixed base/head diff against the acceptance packet, ideally with a different
   model vendor. Give the reviewer the diff, relevant source and acceptance
   criteria, not the implementer's conclusions. Review is read-only. If no
   independent reviewer can run, record review as pending for the human.
   Do not block on an unavailable external review skill: use the
   `resolve-issue` self-review checklist (correctness, scope, contracts,
   failure behavior, privacy, validation).
2. Run `task check` and the relevant behavioral checks/builds. Coordinate
   expensive commands with the `build` claim, including commands run by children.
   Missing live access defers that stage; it need not stop independent edits
   or local checks. A deferred/failed check is never a pass.
3. Before live validation, claim `validation` and record its issue, target,
   source SHA, effective input overrides, expected closure, pre-change
   generation, user authority and behavioral probes. Check for other sessions,
   CI resource contention and auto-upgrade activity; the local claim cannot
   exclude those. A conflicting/uncertain host state blocks activation.
4. Use `hpp-1` for dev activation. A user grant covering deployments and
   non-destructive validation on `hpp-1` for the selected batch satisfies the
   host/action/step requirement: reuse it across that batch's validation steps
   without asking for every switch or child handoff. Record its scope in the
   plan and validator packet. Ask only if the grant is absent or the proposed
   action exceeds it. Never activate production hosts (`amos1` or another host
   classified as prod), or substitute a workstation; production rollout is a
   separate operator-directed workflow. Read-only production inspection and
   host builds remain available under root guidance.
   Delegate activation only to the named validator, and prefer withholding
   deployment credentials from implementers. Worktrees and approval-bypass
   harnesses do not enforce isolation. Destructive tests and disk-layout
   changes need separate authorization; disko changes require the documented
   operator reinstall workflow, never an in-place deploy.
5. Run the validator packet's transport preflight before any live build or
   activation. Use supported repository deployment tooling and enforce root's
   hostname, closure-name and per-host SSH rules in the activation command
   chain. Verify the running closure/generation afterward and exercise the acceptance
   probes. Hold the claim through the required observation period. Unexpected
   host changes invalidate evidence; reconcile before continuing.
6. Record source SHA, effective inputs, commands, outcomes, deployed closure
   and generation, plus manual results; `task validate:<host>`'s evidence
   record carries all but the manual results. No secret contents belong in state or
   public evidence. Rebase or edit invalidates affected review/check/live
   evidence; rerun the affected stages against the final PR head.

## Handoff and stop

Open/update the PR with behavior, design decisions, validation and remaining
limits. Only mark `ready_to_merge` when the accepted criteria have evidence and
review is complete. Otherwise report a PR with pending work, not a ready PR.
Verify the remote head equals the reported commit. Human merging is the
default; this skill grants no merge authority. `main` is followed by automatic
host upgrades, so merge also approves eventual rollout. Never equate merged
with observed rollout; record `rolled_out` only with host evidence if requested.

Release issue claims only after its workers/build/validation claims are gone.
Parked or blocked work can free an issue slot after confirming its children
have stopped and its reservations are safely released; retain its context.
Keep worktrees while review, live validation or manual work remains. Before
cleanup follow **Commit, PR, teardown** in `resolve-issue`: verify the
checked-out branch and exact remote/local HEAD equality, check tracked,
untracked and ignored files, and use ordinary `git worktree remove`. Any status
output beyond that procedure's explicit generated-file allowance, failed
verification or refused removal means preserve the worktree, report its path
and state without publishing file contents or sensitive paths, and let the
user decide. Never automatically stage, commit, delete or relocate unknown
work for cleanup.

Finish with issue → PR/status, evidence and omissions, outstanding questions,
retained worktrees/reservations, and how to resume this supervisor. When the
batch is handed off, stop; do not merge, close issues, expand the queue or
schedule another run without the user's instruction.

## First invocation

In a fresh Omnigent Polly session with this repository as its workspace:

> Read `skills/software-factory/SKILL.md` and use it to implement issues #A
> and #B serially. Stop at reviewed PRs; I will merge. Ask about unresolved
> tradeoffs or manual steps. I authorize deployments and non-destructive
> validation on `hpp-1` for this batch. Do not activate production hosts or
> workstations, change secrets, or run destructive tests.

Codex can use `$software-factory` with the same request. For queue discovery:

> Use the software-factory skill to inspect the open backlog and recommend
> three pilot issues, with dependencies and validation needs. Do not implement
> until I choose the batch.

To resume: `Resume the software factory from its recorded state; my answer
for issue #A is …`. To overlap later: explicitly request two active issues,
one implementing while the other validates, with two children total.
