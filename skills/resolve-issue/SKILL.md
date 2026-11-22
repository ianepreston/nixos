---
name: resolve-issue
description: Take a GitHub issue number in ianepreston/nixos from read through merged-ready PR — preflight the systems the fix needs, work in a throwaway worktree off origin/main, implement, sweep for ancillary changes the fix obsoletes, validate, self-review, open the PR, tear the worktree down. Use only on an explicit request to resolve/fix/implement/work an issue by number ("resolve #631", "fix 458", "/resolve-issue 512"); a request to inspect one ("take a look at 458", "what is #458") is read-and-report, not this workflow.
---

# Resolve an issue

Argument: one issue number (`631`, `#631`, or a full issue URL). If none was
given, ask for it — do not guess from recent activity.

**Read `skills/_shared/host-access.md` first.** It covers the fleet roles,
bounded SSH probes, and Git transport fallbacks. What needs approval is set
only by the **Authorization** section of `AGENTS.md`.

Run this workflow only on an explicit request to resolve, fix, implement or
work the issue. That request authorizes the whole workflow: worktree, commit,
push, PR, and (per `AGENTS.md`) deploying this change to `hpp-1` with
non-destructive validation there. An agent dispatched by a supervisor holds
only the authority its packet passes down from the user. A request only to
inspect an issue gets Phase 1 and a report, then stops: no implementation,
commit, push or PR.

## 1. Read the issue

```sh
gh issue view <N> --comments
```

Read the comments too — the design gets renegotiated there. Note explicitly:

- What it asks for, and anything it rules *out* (issues here often say "no
  vmalert rule, that's #458's call"). Out-of-scope statements are binding.
- Options the issue leaves open. Those the topic guides don't settle are
  Phase 4 questions for the user, not choices to make silently.
- Linked issues/PRs. Skim them; they usually carry the constraint that made the
  issue necessary.

Restate the scope in one or two sentences before moving on. If the issue is
stale — the code already does this, or a later change made it moot — say so and
stop rather than manufacturing a diff.

## 2. Preflight

Identify which validation can run locally and which needs a live host.
Server-app, module, and blueprint changes normally need live validation on
`hpp-1` (dev). Workstation-only changes (`modules/programs/*` and
`luna`/`terra` config) validate by build.

Activating `hpp-1` for this change and running non-destructive checks there
is already authorized by the invocation; do not ask again per switch. Any
other host, or a destructive or otherwise protected step, needs the user to
authorize that host and action. Ask now; a missing reply leaves that step and
the checks that depend on it deferred. Continue independent work meanwhile.

Check `gh auth status --hostname github.com` for GitHub work. For each
required live stage, use the relevant bounded SSH or transport preflight from
host-access. This can surface missing access before a dependent build. If the
runner lacks access, record the unmet prerequisite and defer the dependent
stages. Continue inspection, implementation, and local checks that the runner
can support. Ask for operator action only for work that depends on it.

If the issue needs secrets that don't exist yet, note it here and raise it in
Phase 4: `task secrets:*` is ask-first.

## 3. Worktree

Always a worktree, even when the main checkout looks idle — the user routinely
runs concurrent sessions against this repo and `git switch` in the shared
checkout yanks the tree out from under them.

Refresh `origin/main` using the available Git transport (see host-access),
then create a Git worktree on a temporary or runner-configured path with a name
derived from the intended branch (`fix/valheim-joincode-stale` →
`fix-valheim-joincode-stale`). Use `git worktree add -b <branch>
<worktree-path> origin/<default>`; do not assume a runner-owned directory.
`git worktree list --porcelain` is the authority for locating and cleaning up
the worktree. Confirm with `git log --oneline -1` that HEAD is the commit you
just fetched. Branch prefix follows the repo: `fix/` for a defect, `feat/` for
new behaviour, `chore/` for maintenance.

Two worktree gotchas:

- A fresh worktree lacks the ignored `.pre-commit-config.yaml` that
  `git-hooks.nix` generates. Before its first commit, run `nix develop -c true`
  (or enter `nix develop`) in the worktree. On Darwin this materializes the
  config for the managed global hook; on Linux it installs the project hook.
  Commit normally once that succeeds. Do **not** set
  `PRE_COMMIT_ALLOW_NO_CONFIG=1`: it papers over the missing config and can
  make the local hook a no-op. `task check` remains the full pre-push gate.
- `task deploy:*` / `task rebuild` resolve `nix-secrets` from `flake.lock`, so
  no sibling checkout is needed. For unpublished secrets work,
  `LOCAL_SECRETS=true` enables the helper's local checkout lookup. See
  host-access for worktree resolution and `NIX_SECRETS_PATH`.

## 4. Implement

`AGENTS.md` and the topic guides it indexes under `docs/agents/` are the
authority on how this repo is built — module layout, native service vs
container, NFS UID alignment, sops/`restartUnits` placement, the recovery and
`myAppState` obligations for a new app. Read the guide that covers what you're
touching before writing it; most of it exists because something broke once.

**Ask, don't guess — but don't ask what the guides decide.** Where the issue,
`AGENTS.md` or a topic guide settles a choice (the packaging order in
`app-packaging.md`, module placement and option surfaces in
`architecture.md`), follow it and note the call in the PR. Stop and ask only
when a choice is a material trade-off they leave open:

- Architecture the guides don't settle, or a departure from what they say.
- Semantics the issue left open (absent-vs-zero, failure direction, defaults).
- Anything that would change the shape of an existing cross-cutting option
  (`myCaddy.apps`, `myPostgresApp`, `myAuthentik.*`, `myRuntimeCredentials`).
- Scope beyond the issue, or a newly protected operation (`AGENTS.md`
  **Authorization**).
- Anything touching disko — those can never be deployed, only reinstalled, so
  the user needs to know up front.

Naming, comment wording, which helper to reuse, test placement: decide those
yourself.

Repo rules that bite most often:

- New files must be git-tracked (`git add -N`) before `nix eval` can see them —
  including non-`.nix` files like blueprint YAMLs.
- After editing any `version`/`tag`/`rev` pin, run `task hashes` (or
  `task hashes -- --check`). A stale hash is *not* a build failure; it silently
  runs the old code.
- `flake.lock` moves only the input this change needs — usually `nix-secrets`,
  and only after a secrets publish. Never a blanket `nix flake update`.

## 5. Validate

Run `task check` and the applicable local builds or tests. This can proceed
while live validation is deferred, subject to each check's own prerequisites.

For live validation, run the host-access preflight. Once access is
established, deploy to `hpp-1` (authorized by the invocation; other hosts per
`AGENTS.md` **Authorization**) with `scripts/activate-nixos.sh` or
`task deploy:hpp-1`. The helper asserts the target hostname and closure
identity in the activation chain. See host-access for `--dry-run`,
`--action check` and per-host SSH options. Don't pipe the activation. If it errors or the target stops answering, stop and report without
retrying.

Exercise the change on the target after a successful activation. Check the
unit status, journal, endpoint, or metric the issue requires. Record each
check's command and outcome. For each deferred check, record the prerequisite
and what the user still needs to run, including the expected evidence.
Only checks that ran successfully count as passes.

## 6. Ancillary sweep

A fix usually orphans something elsewhere: a comment describing the bug as
open, a workaround now dead, an `AGENTS.md` or `docs/agents/` gotcha that no longer applies, a
recovery task or `expectedPreservedDirs` entry that should move with it, a
sibling module that copy-pasted the same mistake.

```sh
rg -n '#<N>\b' --glob '!flake.lock'      # explicit references to this issue
rg -n -i 'workaround|FIXME|TODO|for now|until <thing>' <touched modules>
```

Fold in every item the fix directly entails (a stale comment, dead
workaround, obsolete gotcha) without asking, and list each in the PR. Ask only
about items that are optional, widen scope or are genuine trade-offs, with a
recommendation per item; continue the rest while waiting. Anything the user
splits off gets a follow-up issue, linked from the PR.

## 7. Self-review

Self-review is mandatory and needs nothing outside this repo. Read the whole
diff against the base (`git diff origin/<default>...HEAD` plus any uncommitted
changes) and work through this checklist, noting a finding or "clear" for each:

1. **Correctness** — it does what the issue asks, including edge cases (absent
   vs zero, empty input, first run, restart). Where it matters, check the
   rendered config or output, not just the source.
2. **Scope** — nothing the issue ruled out, no unrelated churn, and every
   ancillary change is entailed by the fix or was approved in Phase 6.
3. **Existing contracts** — published option surfaces and contracts keep their
   shape (or the change is called out), the `AGENTS.md` architecture rules
   hold, and docs or skills describing the touched behaviour still match it.
4. **Failure behavior** — when a dependency, secret, host or network is
   missing, it fails in the intended direction and visibly; nothing is
   silently skipped or reported as success.
5. **Privacy** — no PII (see `AGENTS.md`) or secret material in the diff,
   commit messages, PR body, or logs quoted in them.
6. **Validation** — every claim the PR makes is backed by a check that ran and
   fits the change; failed, skipped and deferred checks are named.

A review facility the runner provides (a harness review skill or command) may
augment the checklist: run it as well and fold in its findings, but it neither
replaces nor changes the checklist. If none is available, the checklist alone
completes this step; do not block on or go looking for one. Use a separate
reviewer agent only when the session permits spawning one; give it the diff
and acceptance criteria rather than your conclusions.

Address what the review finds. Push back on findings that are wrong rather
than churning the code to satisfy them; say which you rejected and why. Carry
the outcome into the PR and the final report: which review sources ran, the
unresolved risks, and the limits of the validation. "Review passed" alone is
not a result.

## 8. Commit, PR, teardown

Commit in the worktree normally, after the dev-shell setup above, with a subject
in the house style (`<area>: <imperative>`, e.g. `valheim: publish a player-count
gauge from the notifier roster`).

The repo requires no attribution footer. If the session or runner instructions
define one, append its exact lines to commits and the PR body as instructed.
Otherwise omit it; a missing convention never blocks the commit. Never invent
a co-author identity, reuse another harness's footer, or add a trailer that
exposes a personal email or account identifier. The commit author is the
checkout's configured Git identity; this step doesn't change it.

Push the task branch with a working Git transport. See host-access for scoped
fallbacks if the configured transport is unavailable. Then `gh pr create`.
PR bodies here are substantial — match the repo's existing ones (`gh pr list
--state merged --limit 3 --json body` if you need a model):

- `Closes #<N>.` on the first line.
- `## What` — the change, with the concrete output/behaviour where it helps.
- The design calls, each with the alternative you rejected and why. This is the
  part the user actually reads; a decision the issue left open belongs here even
  if they chose it in Phase 4.
- `## What it does not do` — scope the issue explicitly excluded.
- Drive-by / ancillary changes from Phase 6.
- `## Validation` — commands and outcomes, including failed, skipped, and
  deferred checks. For each incomplete check, name the reason, the steps
  still to run, and the evidence that would complete validation.

Pushing the branch and opening the PR need no confirmation. After the PR is
open, **verify it landed** before tearing anything down — the local tracking ref
is stale, so trust `gh api`, not `git branch -vv`:

```sh
gh pr view <PR#> --json url,headRefName,state
git -C "<worktree-path>" symbolic-ref --short HEAD
git -C "<worktree-path>" rev-parse HEAD
gh api repos/ianepreston/nixos/branches/<branch> --jq .commit.sha
```

Require the symbolic-ref query to succeed and return exactly `<branch>`.
A detached HEAD or another checked-out branch means publication is unverified,
even if the SHAs match: preserve the worktree and report that state.
Require both SHA queries to succeed and return exactly the same nonempty SHA.
A missing branch, failed query or mismatch means publication is unverified:
preserve the worktree and report that state. A matching remote HEAD proves
only that the commits were pushed; it says nothing about uncommitted files.

Before removal, check the worktree for tracked, untracked and ignored files:

```sh
git -C "<worktree-path>" status --porcelain --untracked-files=all --ignored
```

If the status check fails, preserve the worktree. Any output other than this
explicit allowance means preserve: `!! .pre-commit-config.yaml`, only after
confirming it is the unchanged, regenerable generated symlink created by the
dev-shell setup above. An unverified file or replacement symlink at that path
gets no allowance; neither do other ignored files or directories.

Only after publication is verified and the status check succeeds with no
output beyond that allowance, run ordinary
`git worktree remove "<worktree-path>"` from outside that worktree. If removal
refuses, preserve it; never retry with force or delete files to make removal
succeed.

For any preserved worktree, report its path, the verification/removal failure
or remaining tracked, untracked and ignored state, without publishing file
contents or sensitive paths. Let the user decide how to handle it. Never
automatically stage, commit, delete or relocate unknown work for cleanup.

Report back with the PR URL, the design calls the user made, and any
follow-up issues filed. State which checks failed, were skipped, or were
deferred, why, and what the user still needs to run.
