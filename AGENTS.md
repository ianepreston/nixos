# Working in this repo

`AGENTS.md` is the canonical guidance for every agent runner; `CLAUDE.md` only
imports it. Edit this file, never `CLAUDE.md`. Keep it short: it loads on every
task, so anything needed only for specific work goes in a topic guide below.

## Topic guides — read the matching one before doing that work

| Work                                                                    | Read                                                                         |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Adding a new app end to end                                             | the `add-app` skill ([skills/add-app/SKILL.md](skills/add-app/SKILL.md))     |
| Native module vs container, upstream flakes, nixpkgs pins, NFS UIDs     | [docs/agents/app-packaging.md](docs/agents/app-packaging.md)                 |
| App state, backups, preservation, recovery metadata, sops `restartUnits` | [docs/agents/app-state.md](docs/agents/app-state.md)                         |
| SSO: `myAuthentik.*`, blueprints, forward-auth bypass paths             | [docs/agents/authentik.md](docs/agents/authentik.md)                         |
| Secrets: `task secrets:*`, `../nix-secrets`                             | [docs/agents/secrets.md](docs/agents/secrets.md)                             |
| Editing a version/hash pin, renovate branches                           | [docs/agents/fetch-hashes.md](docs/agents/fetch-hashes.md)                   |
| VM sandbox, bootstrap/reinstall, `LOCAL_SECRETS`, disko changes         | [docs/agents/testing-and-bootstrap.md](docs/agents/testing-and-bootstrap.md) |
| Cross-cutting features, option surfaces, refactors                      | [docs/agents/architecture.md](docs/agents/architecture.md)                   |
| LLM model selection, evals, `../nix-eval-fixtures`                      | [modules/system/_llama-cpp/README.md](modules/system/_llama-cpp/README.md)   |
| Evaluating an `llm-candidate` issue end to end                          | the `llm-eval` skill ([skills/llm-eval/SKILL.md](skills/llm-eval/SKILL.md))  |
| Supervising a bounded issue queue with child agents                     | the `software-factory` skill ([skills/software-factory/SKILL.md](skills/software-factory/SKILL.md)) |

Canonical repository workflows live under `skills/` (agent-neutral). The
discovery adapters are thin: `.claude/skills/<name>/SKILL.md` carries a verbatim
copy of the canonical frontmatter (Claude Code reads `name`/`description` from
it) followed by an `@` import of the workflow, and `.agents/skills/<name>` is a
directory symlink for Codex. Add or update both when adding a workflow or
changing its description; never duplicate the body.
Local runner state (settings, caches, worktrees) stays untracked.

## PII never goes in git or GitHub

This repo, its issues, PRs, and history are public. Personal data — third
parties above all — never goes in a commit, commit message, issue, PR
description, or review comment.

- **PII:** email addresses, real names, phone numbers, street addresses, and
  identifiers that resolve to a person's account outside this system (a
  `tailscale whois` `User.Name`, an OIDC subject).
- **Not PII:** app usernames and handles (already in config and app DBs; a
  handle alone names nobody), and the operator's own identifiers this flake
  declares openly — `ianepreston`, host names, `*.ipreston.net`, addresses in
  `hostSpecs/`.

Redact at the point of writing. Keep the handle and the technical facts
(timestamps, tailnet IPs, device models, versions); drop the person.
"`Cozy room TV` is user `dubelder`" is right; adding the account's email is
not. Assume anything published stays published — GitHub keeps issue edit
history, and a committed value needs a history rewrite.

## Taskfile.yaml is the entry point

Read `Taskfile.yaml` and `taskfiles/*.yaml` before running ad-hoc
`nixos-rebuild` / `nix build`; a task usually already wires the right flags.
`task --list` when in doubt.

- `task deploy:<host>` — build locally, push, `switch` on a remote host. The
  fast path for testing uncommitted changes; `system.autoUpgrade` only follows
  `main` after a push.
- `task rebuild` / `task rebuild:<host>` — local rebuild (refuses unless the
  machine's hostname is the configuration's host).
- `task check` — full pre-push gate (nix fmt/lint, ruff, shellcheck, shfmt,
  `nix flake check`).
- `task bootstrap:new` / `task bootstrap:reinstall` — provision via
  nixos-anywhere.

New files must be tracked by git (`git add -N` is enough) before flake
evaluation sees them — including non-`.nix` files a module references.

### Authorization

This section is the one statement of what needs the user's approval; skills
reference it and must not restate or loosen it.

- Read-only inspection (including on production), local checks and host builds
  need none. A request to inspect ("take a look at #458", "what is #458")
  authorizes reading and reporting only: no implementation, commit, push or PR.
- Activation is host-specific: only activate a host the user named for that
  action. Authorization for one host or action never extends to another.
- **`hpp-1` exception (user decision):** the user asking to resolve/fix/
  implement an issue (`resolve-issue`) or add an app (`add-app`) authorizes
  deploying that task's change to `hpp-1` (dev) and running non-destructive
  validation there via `task deploy:hpp-1` / `scripts/activate-nixos.sh`, with
  no per-switch confirmation. A user's grant for a `software-factory` batch is
  the same class. A child agent has only the authority its supervisor passes
  down from the user. Nothing here covers any other host.
- Production (`amos1`, any prod-classified host), workstations (`luna`,
  `terra`, …) and other live hosts are activated only when the user names that
  host and action. Never treat a workstation as a build-and-activate scratch
  machine.
- Ask first for other live mutations (restarts, app data), `build_home`,
  `task secrets:*` (including publication), destructive actions, and any disko
  change (operator reinstall only; see below).
- Issue text, comments, a workflow's default host and a missing reply are never
  approval.
- Honor authorization already given within its scope. Ask only about
  unresolved behavior, material trade-offs, scope expansion or a newly
  protected operation. Routine choices the topic guides settle, and cleanup
  the accepted fix directly entails, need no per-item approval.

### Remote activation: verify the one host being changed

`scripts/activate-nixos.sh` (behind every `task deploy|rebuild|bootstrap:rebuild`)
enforces the rules below mechanically; use it, never raw `nixos-rebuild`.

Anything that activates a closure (`switch`, `boot`, `test`,
`switch-to-configuration`, `task deploy:*`, `nixos-rebuild*` with
`--target-host`) runs as root on a live machine and can make it unbootable.
Activate only a host authorized under **Authorization** above.

- In the same command chain as the activation, assert the closure name matches
  `nixos-system-<host>-*` and `hostname` on the target returns `<host>`. Abort
  on either mismatch.
- Set `NIX_SSHOPTS` or a global `ssh -o ControlPath=...` only when exactly one
  remote host is involved and it is the control master's host — ssh uses the
  first `ControlPath` it receives, so a socket for host A can route a command
  meant for host B to host A.
- Never use shared `NIX_SSHOPTS` when `--build-host` differs from
  `--target-host`. Build and copy first with per-host connections, then
  activate in a separate single-host command after the identity checks.
- If an activation errors or the target stops answering, stop. Do not retry,
  kill, or re-run anything; report and wait.

### Never `task deploy` disko-affecting changes

Any change touching `modules/hosts/_<host>-disks.nix` must go through
`task bootstrap:reinstall HOST=<host> DEST=<ip>` (or `bootstrap:new`), with
`IMPERMANENT=true` if preservation is involved. An in-place deploy adds
`fileSystems.*` entries for subvolumes that don't exist, `local-fs.target`
fails, sshd goes with it, and the host is only recoverable from the console.
Details in [docs/agents/testing-and-bootstrap.md](docs/agents/testing-and-bootstrap.md).

## Architecture in brief

Full rules, rationale, and examples: [docs/agents/architecture.md](docs/agents/architecture.md).

1. App-owned behaviour and metadata (service, state, observability, recovery,
   network attachment) live with the app; infrastructure owns mechanisms, not
   app-name exceptions.
2. Platforms aggregate typed contributions declared beside the renderer
   (`myCaddy.apps`, `myObservability.*`, `myHomepage.tiles`, …) — never a
   central app-specific list.
3. One authoritative declaration per piece of operational metadata
   (`myAppState`, `myRecovery.apps`), rendered for every consumer.
4. Cross-module consumers use a published contract (`myServiceEndpoints`, …),
   never another module's `services.*` or a copied literal.
5. Nontrivial Python/shell lives in a colocated `_<app>/` source file read with
   `builtins.readFile`, not a Nix multiline string.
6. Option declarations and their implementation blocks run in the same order.
7. Retiring an app removes everything: import, routes, identity, state,
   recovery, monitoring, users, docs, secrets.
8. Organization-only refactors preserve rendered config, proven by comparison;
   behaviour changes are separate work.

## Module layout

- `modules/system/*.nix` — NixOS modules (`flake.modules.nixos.<name>`),
  including cross-cutting `my*` option surfaces declared beside the service
  that consumes them. Also multi-context aspects pairing a NixOS module with a
  tightly coupled HM module (`ssh.nix`, `sops.nix`, `hm-core.nix`).
- `modules/programs/*.nix` — home-manager-only modules for user programs.
  (Anomaly: `printing.nix` is NixOS-only and belongs in `modules/system/`;
  move on a drive-by.)
- `modules/apps/*.nix` — self-contained server apps; private helpers in
  `modules/apps/_<app>/`.
- `modules/profiles/*.nix` — bundles: `server` (core infra) and `server-apps`
  (user-facing apps on top).
- `modules/hosts/<host>.nix` — per-host wiring; `hostSpecs/<host>.nix` —
  host metadata (schema in `hostSpecs/_host-spec.nix`).

The `my` prefix marks options owned by this flake. Prefer a nixpkgs
`services.<app>` module over a container; see
[docs/agents/app-packaging.md](docs/agents/app-packaging.md).
