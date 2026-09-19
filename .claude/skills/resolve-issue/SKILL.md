---
name: resolve-issue
description: Take a GitHub issue number in ianepreston/nixos from read through merged-ready PR — preflight the systems the fix needs, work in a throwaway worktree off origin/main, implement, sweep for ancillary changes the fix obsoletes, validate, self-review, open the PR, tear the worktree down. Use when asked to resolve/fix/implement/work an issue by number ("resolve #631", "take a look at 458", "/resolve-issue 512").
---

# Resolve an issue

Argument: one issue number (`631`, `#631`, or a full issue URL). If none was
given, ask for it — do not guess from recent activity.

Work the phases in order. Phase 5 has the permission boundary; read it before
running anything that leaves this machine.

## 1. Read the issue

```sh
gh issue view <N> --comments
```

Read the comments too — the design gets renegotiated there. Note explicitly:

- What it asks for, and anything it rules *out* (issues here often say "no
  vmalert rule, that's #458's call"). Out-of-scope statements are binding.
- Options the issue leaves open. Those are Phase 3 questions for the user, not
  choices to make silently.
- Linked issues/PRs. Skim them; they usually carry the constraint that made the
  issue necessary.

Restate the scope in one or two sentences before moving on. If the issue is
stale — the code already does this, or a later change made it moot — say so and
stop rather than manufacturing a diff.

## 2. Preflight

Work out which systems the change will need to *validate* against, then prove
you can reach them before writing code. A server-app / module / blueprint change
validates on `hpp-1` (dev). Workstation-only changes (`modules/programs/*`,
`luna`/`terra` config) validate by build, not by switch.

```sh
gh auth status                       # PR + issue access
ssh -O check -o ControlPath="$HOME/.ssh/master-ipreston@hpp-1:22" ipreston@hpp-1
```

The ssh master matters: ssh auth uses a FIDO2 key that needs a touch/PIN, and
nothing in this session can answer that prompt. `ssh hpp-1` appears to work
because it silently reuses the master. If `-O check` fails, ask the user to open
one (`! ssh hpp-1` in the session) **now**, before starting — finding out at
deploy time wastes the whole build.

If the issue needs secrets that don't exist yet, note it here and raise it in
Phase 3 — `task secrets:*` is an ask-first action (Phase 5).

## 3. Worktree

Always a worktree, even when the main checkout looks idle — the user routinely
runs concurrent sessions against this repo and `git switch` in the shared
checkout yanks the tree out from under them.

`git fetch` over ssh hangs here (same FIDO2 cause), so refresh `origin/main`
anonymously over https first:

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git fetch https://github.com/ianepreston/nixos +refs/heads/main:refs/remotes/origin/main
```

Then `EnterWorktree` with a name derived from the branch you intend
(`fix/valheim-joincode-stale` → `fix-valheim-joincode-stale`). It branches from
`origin/<default>` by default; confirm with `git log --oneline -1` that HEAD is
the commit you just fetched. Branch prefix follows the repo: `fix/` for a
defect, `feat/` for new behaviour, `chore/` for maintenance.

Two worktree gotchas:

- No `.pre-commit-config.yaml` (git-hooks.nix generates it in the devshell), so
  commits need `PRE_COMMIT_ALLOW_NO_CONFIG=1`. No lint coverage is lost —
  `task check` runs the same nixfmt/statix/deadnix through `nix flake check`.
- `task deploy:*` / `task rebuild` hardcode
  `--override-input nix-secrets path:../nix-secrets`, which from
  `.claude/worktrees/<name>/` resolves to nothing. Use the absolute path
  (Phase 5).

## 4. Implement

`CLAUDE.md` is the authority on how this repo is built — module layout, native
service vs container, NFS UID alignment, sops/`restartUnits` placement, the
recovery-task and `expectedPreservedDirs` obligations for a new app. Read the
section that covers what you're touching before writing it; most of it exists
because something broke once.

**Ask, don't guess.** Stop and ask the user whenever a choice is a trade-off
rather than a detail:

- Architecture: native module vs container, new option surface vs hardcode,
  where a module lives.
- Semantics the issue left open (absent-vs-zero, failure direction, defaults).
- Anything that would change the shape of an existing cross-cutting option
  (`myCaddy.apps`, `myPostgresApp`, `myAuthentik.*`, `myRuntimeCredentials`).
- Anything that touches disko (`modules/hosts/_<host>-disks.nix`) — those can
  never be deployed, only reinstalled, so the user needs to know up front.

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

**Allowed without asking:**

| Action | Command |
| --- | --- |
| Lint + eval gate | `task check` |
| Build a host closure | `task build:<host>` / `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` |
| Deploy to **hpp-1** (dev) | the `nixos-rebuild` invocation below |

**Ask first, every time:**

- Anything against **amos1** (prod) or any other live host.
- `task rebuild` / `build_home` / anything that switches *this workstation's*
  own configuration.
- `task secrets:*` and `task secrets:publish` — it pushes to `../nix-secrets`.
- `task deploy` of a disko-affecting change — that one is never allowed; it
  needs `bootstrap:reinstall` and is the user's call to run.
- Destructive host-side commands (service data, `/var/lib/<app>`, database
  drops) even on hpp-1.

Deploy to hpp-1 directly rather than through `task deploy:hpp-1`:
`nixos-rebuild-ng` appends its own `ControlPath` and re-authenticates against
the FIDO2 key, which hangs forever with no tty. User opts win because ssh takes
the first value for each option:

```sh
NIX_SSHOPTS="-o ControlPath=$HOME/.ssh/master-ipreston@hpp-1:22 -o ControlMaster=no" \
  nixos-rebuild switch --flake .#hpp-1 --target-host ipreston@hpp-1 --sudo \
    --override-input nix-secrets path:/home/ipreston/src/nix-secrets
```

Don't pipe that into `tail`/`head` — it hides the exit status and a failed
deploy reads as success. Check `PIPESTATUS` or don't pipe.

Then actually exercise the change on the target (`systemctl status`,
`journalctl -u`, `curl` the endpoint, read the metric) rather than treating a
green switch as proof. Record what you ran — it becomes the PR's validation
section.

## 6. Ancillary sweep

A fix usually orphans something elsewhere: a comment describing the bug as
open, a workaround now dead, a `CLAUDE.md` gotcha that no longer applies, a
recovery task or `expectedPreservedDirs` entry that should move with it, a
sibling module that copy-pasted the same mistake.

```sh
rg -n '#<N>\b' --glob '!flake.lock'      # explicit references to this issue
rg -n -i 'workaround|FIXME|TODO|for now|until <thing>' <touched modules>
```

Present what you find as a short list, with a recommendation per item. Default
is to fold it into this PR when it's directly entailed by the fix — but the user
decides per item, so wait for the answer. Anything they split off gets a
follow-up issue, linked from the PR.

## 7. Self-review

Run the `code-review` skill on the diff and address what it finds. Push back on
findings that are wrong rather than churning the code to satisfy them; say which
you rejected and why.

## 8. Commit, PR, teardown

Commit in the worktree with `PRE_COMMIT_ALLOW_NO_CONFIG=1`, subject in the house
style (`<area>: <imperative>`, e.g. `valheim: publish a player-count gauge from
the notifier roster`), and the session's attribution footer.

`git push` over ssh hangs, and pushing the https URL doesn't dodge it — a global
`insteadOf` rewrite sends it back to ssh. Suppress the global config and let
`gh` answer the credential prompt:

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper='!gh auth git-credential' \
      -c user.name="Ian Preston" -c user.email="ian.e.preston@gmail.com" \
      push https://github.com/ianepreston/nixos HEAD:refs/heads/<branch>
```

Then `gh pr create`. PR bodies here are substantial — match the repo's existing
ones (`gh pr list --state merged --limit 3 --json body` if you need a model):

- `Closes #<N>.` on the first line.
- `## What` — the change, with the concrete output/behaviour where it helps.
- The design calls, each with the alternative you rejected and why. This is the
  part the user actually reads; a decision the issue left open belongs here even
  if they chose it in Phase 3.
- `## What it does not do` — scope the issue explicitly excluded.
- Drive-by / ancillary changes from Phase 6.
- `## Validation` — what you ran and what it showed. A table of state → result
  beats prose. Name anything you couldn't validate.

Pushing the branch and opening the PR need no confirmation. After the PR is
open, **verify it landed** before tearing anything down:

```sh
gh pr view <PR#> --json url,headRefName,state
gh api repos/ianepreston/nixos/branches/<branch> --jq .commit.sha
```

The local tracking ref is stale (nothing was fetched), so the push looks absent
to git — trust the `gh api` answer, not `git branch -vv`.

Only once that confirms the remote branch is at your HEAD, tear down:
`ExitWorktree` with `action: "remove"`. It will refuse because the branch
carries commits that aren't on `main` — that's expected, and
`discard_changes: true` is safe *at this point specifically*, because the
commits are on the remote. Never pass it before the push is confirmed.

Report back with the PR URL, the design calls the user made, anything left
unvalidated, and any follow-up issues filed.
