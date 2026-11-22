---
name: llm-eval
description: Evaluate a local-LLM candidate against the incumbent for one alias on one host — serve it as a temporary peer, run the tier-0 gates and tier-1 private fixtures, compare, post a sanitized verdict on its llm-candidate issue, then open the adopt/drop PR. Use when asked to evaluate/test/benchmark a candidate model ("evaluate #966", "is this GGUF better than text on terra", "/llm-eval 966").
---

# Evaluate an LLM candidate

Argument: an `llm-candidate` issue number (filed by the `model-radar` skill),
or an explicit host + alias + `<repo>:<tag>` when there's no issue yet. If an
issue covers several targets (#966 is terra `text` *and* `code`), evaluate
one target at a time: **the unit of decision is one alias on one host**, the
candidate is the challenger, and whatever serves the alias now is the
incumbent.

The skill sequences the work and holds the judgement calls. The scripts do
the measuring, scoring and rendering, so don't reimplement any of it here.
Before starting, read:

- `skills/_shared/host-access.md`: bounded SSH preflight, operator handoff,
  and the deploy recipe. `AGENTS.md` **Authorization** says what needs approval.
- The *Evaluation* section of `modules/system/_llama-cpp/README.md`: the
  privacy rule, the task reference and the candidate procedure this skill
  automates.
- The private fixtures checkout's `README.md` (see its location below):
  which features target which alias.

## The privacy rule, in one place

Keep source documents, request bodies, prompts, expected values and raw
responses from the private fixtures checkout out of this repo, its issues and
its PRs. **That includes the run directories under `results/` and the
plain `task llm:eval:compare` output.** Its failed-check labels
(`tags:must:<name>`) carry expected values. Allowed in public: fixture IDs
(`paperless-classify/energuide-report`), the fixtures commit hash, scores,
per-field rule-kind failures, speed, and the verdict.

Two mechanical guards exist, and anything GitHub-bound goes through both:

- `task llm:eval:compare … PUBLIC=true` renders the redacted comparison.
- `task llm:eval:audit FILE=<draft>` fails if the draft names any expected
  value, under any spelling the scorer would accept. Run it on the final
  comment or PR body, including any prose you wrote around the tables.
  Prose is exactly where `PUBLIC=true` can't help. In prose, refer to cases
  only by their full `<feature>/<case>` ID. A bare case name isn't masked,
  so it can trip the audit.

**From a worktree, pass `FIXTURES=<absolute path>` to `llm:eval` and
`llm:eval:audit`.** Their default `../nix-eval-fixtures` resolves against
the worktree and finds nothing. `llm:eval` then skips with a warning and
`llm:eval:audit` refuses to run. Neither of those results means the step
passed.

Gate output (`task llm:gate`) is synthetic and public as printed.

## Stages

Each stage is a separate tier with its own task. Run them in order. A
failing stage ends the evaluation, and its failure becomes the verdict.

| stage | tier | task | needs fixtures | status |
| --- | --- | --- | --- | --- |
| [Gates](#3-tier-0-gates) | 0 | `task llm:gate` | no | available |
| [Replay](#4-tier-1-replay) | 1 | `task llm:eval` + `llm:eval:compare` | yes | available |
| agentic coding | 2 | — | yes | not built: #613 |
| judged review | 3 | — | yes | not built: #614 |

Adding a tier means adding a row and a numbered section between *Replay* and
*Verdict*. Use the same shape: what it runs, how to tell a pass from a fail,
and what of its output is public. Sections 1, 2 and 5–7 stay tier-agnostic.

## 1. Read the candidate

```sh
gh issue view <N> --comments
```

Pull out:

- the exact router name (`<repo>:<tag>`)
- host and alias
- the radar disposition. `manual-review` means its fit is unproven, not
  that it was approved.
- any decision rule the issue states

The issue's own rule wins over the default in section 5. Also check whether
an earlier evaluation already posted a verdict on it, and whether the issue
asks for work this skill doesn't do. #966's residency sweep, `llama-bench`
throughput and KLD are examples. Say which parts are out of scope rather
than skipping them silently.

Then read the alias's target off the contract, which the gates enforce:

```sh
nix eval --json .#nixosConfigurations.<host>.config.myLlamaCpp.evalTargets
```

## 2. Preflight and serve

Check the requirements for live evaluation before serving the candidate:

- When running the gates or replay from another machine, use the bounded
  master and hostname checks in host-access for the evaluation host's SSH
  alias. Both tasks forward through that alias's existing master. On the
  evaluation host itself they connect to loopback. Both paths require
  operator access to the API key file via `sudo`.
- Resolve the fixtures checkout to an absolute path (usually
  `../nix-eval-fixtures` from the primary checkout). Verify it is present and
  clean with `git -C "$fixtures_path" status --short` and use that path for the
  fixtures commands below. Tier 1 skips when the checkout is absent.
- Find the cases for the alias with
  `grep -l 'alias = "<alias>"' "$fixtures_path"/*/*/meta.toml`.
  If there are no cases, tell the user during preflight that Tier 1 has no
  evidence for the alias and that a gates-only verdict has less evidence.

If host access is unavailable, continue independent preparation such as
inspecting the issue, target config and fixtures. Defer serving and live
measurements. Report the unmet prerequisite and the commands still needed
for the affected stages. Skipped or deferred stages supply no evidence for
a verdict.

**Serve the candidate as a temporary peer**, following the README's
*Evaluating a candidate* procedure. Work on a branch in a throwaway worktree
(the `resolve-issue` worktree rules apply). Add a `models."<repo>:<tag>"`
entry with its own alias, `<alias>-next`, and the context, KV types and
offload the *target* needs, not the candidate's maximum. Leave the
incumbent's alias where it is.

**Deploying it is ask-first on every host this targets.** terra is a
workstation and amos1 is prod (host-access), so under `AGENTS.md`
**Authorization** the user names the host and action each time; the `hpp-1`
workflow exception does not apply to this skill. Mention two side effects
when you ask:

- **Production traffic.** `--models-max 1` means loading the candidate
  unloads whatever the apps are using. On amos1 that is the production
  `text`/`vision` model, so the apps take a reload on their next request.
- **The overnight revert.** Both hosts run `system.autoUpgrade` from
  `main` at 04:40. A peer deployed from a branch is reverted overnight, so
  finish the eval the same day or plan to redeploy. This is also the safety
  net: an abandoned peer cleans itself up.

Run `task ssh:preflight HOST=<host>` for the standard deployment or the
matching helper preflight in host-access for custom options. Once it passes
and the user has authorized the host and action, use `task deploy:<host>`
for the standard deployment. It enforces the host and closure identity
assertions. Then:

```sh
task llm:models:fetch HOST=<host>
```

A tag that doesn't load at the deployed llama.cpp build stops the evaluation
here. The fix is a scoped llama-cpp bump in its own PR
(`docs/agents/fetch-hashes.md`). Record it on the issue and stop.

## 3. Tier 0: gates

Gate the challenger and the incumbent with the same command, so a host-side
regression isn't blamed on the candidate:

```sh
task llm:gate HOST=<host> ALIAS=<alias> MODEL=<alias>-next JSON=<scratch>/gate-next.json
task llm:gate HOST=<host> ALIAS=<alias> JSON=<scratch>/gate-incumbent.json
```

Both print a markdown table and exit non-zero on any failed gate.

- **Pass:** the challenger passes every gate. If the incumbent also fails a
  gate, report that as a separate finding and keep going.
- **Fail on `context` or `vram`:** this can be the serving config rather
  than the model. Tuning `nCpuMoeLayers` (or a smaller KV type the target
  allows) and re-gating is legitimate, but record every attempt for the
  verdict. Don't lower `ctxSize` below the target to make it fit: the gate
  measures against the target on purpose.
- **Any other failure** (tool-call, round trip, modalities, image) is a
  verdict, not something to tune. Go to section 5.

## 4. Tier 1: replay

Run both models in one session, back to back, with the same fixtures commit.
Don't reuse an older incumbent run: the llama.cpp build, fixtures and scorer
all move.

```sh
task llm:eval HOST=<host> MODEL=<alias>-next ALIAS=<alias> TRIALS=3 FIXTURES="$fixtures_path"
task llm:eval HOST=<host> MODEL=<alias> ALIAS=<alias> TRIALS=3 FIXTURES="$fixtures_path"
```

`ALIAS=` limits the replay to the cases whose `meta.toml` targets that
alias. Use the same filter for both runs: `compare` warns when the case sets
differ, because the totals then have different denominators. `TRIALS=3` is
the floor, since per-case spread is about ±3 checks out of 40. Each run
prints its run directory when it runs. If either replay is skipped or
deferred, report the missing evidence and resume the paired run when the
prerequisites are met. Then:

```sh
task llm:eval:compare RUNS="<next run dir> <incumbent run dir>"
task llm:eval:compare RUNS="<next run dir> <incumbent run dir>" PUBLIC=true
```

Read the private one to understand the failures, and only *quote* the public
one. Commit the run directories in the fixtures checkout at `$fixtures_path`
with a message naming the candidate issue. Pushing that private repo is the
user's call.

A trial that ends with `finish_reason=length` is a real failure, usually a
reasoning model that ran out of context. Don't re-run until it goes away.

## 5. Verdict

Weigh the evidence and recommend one of the four outcomes below. **The user
decides.** Wait for their answer before posting or changing anything.

| verdict | when (default rule; the issue's own rule wins) |
| --- | --- |
| **adopt** | Passes every gate, and its tier-1 total beats the incumbent's by more than trial noise. Or it ties on score but is clearly faster or frees VRAM the host needs. |
| **peer** | Passes the gates, and is better on some features and worse on others, or tied with a different trade-off worth keeping on hand. Keep it under its own alias. |
| **reject** | Fails a gate not caused by serving config, or scores below the incumbent. |
| **defer** | Blocked: needs a llama.cpp bump, or has no tier-1 cases for this alias and the gates alone can't decide. |

Treat a difference inside the ±3-checks-per-case spread as a tie. A tie
leaves the incumbent in place unless speed or residency makes the case.

## 6. Post the verdict

Draft the comment in the scratchpad. Use the shape below, and stick to the
facts the stages produced:

```markdown
## Evaluation: <host> `<alias>` — <verdict>

- Challenger `<alias>-next` = `<repo>:<tag>`; incumbent = `<resolved id>`
- llama.cpp <build>; fixtures `<commit>`; <date>

### Tier 0
<both gate tables, as printed>

### Tier 1
<the PUBLIC=true compare output>

### Verdict
<two to five sentences: the deciding numbers and the trade-off>
```

Then run `task llm:eval:audit FILE=<draft> FIXTURES="$fixtures_path"`. It has
to pass before you post.
If it fails, rewrite the prose instead of trying to get past the check.
Finally:

```sh
gh issue comment <N> --body-file <draft>
```

For an issue with several targets, post one comment per target. Leave the
issue open until the last one is decided.

## 7. Adopt or drop

Once the user has confirmed the verdict, open the config PR from the serving
worktree (the `resolve-issue` self-review, commit, push and PR conventions
apply, including its optional attribution footer rule):

- **adopt:** move `<alias>` onto the candidate's entry and drop `-next`. The
  old incumbent is deleted or kept as a named peer, whichever the user picks.
- **peer:** rename `-next` to a lasting alias the user picks (for example
  `text-nemotron`).
- **reject / defer:** no PR. Preserve the worktree and branch for the user's
  decision, and report its path and state using the shared **Commit, PR,
  teardown** preservation procedure in `resolve-issue`. Let autoUpgrade revert
  the host, or redeploy `main` if the user wants it gone now. Deploying is
  ask-first again.

For published adopt/peer work, follow **Commit, PR, teardown** in
`resolve-issue`: verify the checked-out branch and exact remote/local HEAD
equality, check tracked, untracked and ignored files, and use ordinary
`git worktree remove`. Any status output beyond that procedure's explicit
generated-file allowance, failed verification or refused removal means
preserve the worktree and report its path and state without publishing private
contents or sensitive paths. Never automatically stage, commit, delete or
relocate unknown work to clean up.

Put `Closes #<N>` in the PR when this is the last target, and run
`task llm:eval:audit FILE=<pr-body-file> FIXTURES="$fixtures_path"` on the PR
body as well. After the merge and deploy, show
`task llm:models:prune HOST=<host>` (a dry run) to the user. Only run
`APPLY=true` with their go-ahead, because it deletes weights on the host.

Report back with:

- the verdict and the comment URL
- the PR URL, if one was opened
- any checks the issue asked for that were out of scope, failed or were
  deferred, with any missing prerequisites and commands or steps still needed
- whether the fixtures commit still needs pushing
