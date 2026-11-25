# Documentation index

Each kind of documentation has one home. Before writing something down, find
its kind below and put it there; link to it from anywhere else instead of
restating it.

| Kind | Home | Holds |
| ---- | ---- | ----- |
| Onboarding | [`README.md`](../README.md) | what this repo is, hosts, layout, the module and server-app patterns, the Task entry points, links onward |
| Extension guidance | [`docs/server-apps.md`](server-apps.md) | conventions an app module follows (runtime, networking, NFS UIDs, volumes, secrets) |
| Option contracts | [`docs/reference/options.md`](reference/options.md) | **generated** reference for the public `my*` options: type, default, description, declaring file |
| Operations | [`docs/runbooks/`](runbooks/) | operator procedures: restore, upgrades, bootstrap, activation, per-subsystem setup and their rationale |
| Agent constraints | [`docs/agents/`](agents/), indexed from [`AGENTS.md`](../AGENTS.md) | rules agents must follow; short, imperative, linking to runbooks for procedure |
| Agent workflows | [`skills/`](../skills/) | canonical multi-step workflows (`add-app`, `resolve-issue`, …); adapters under `.claude/` and `.agents/` only point at them |
| App history | `modules/<tier>/_<app>/README.md` beside the module | one app's incident history and operational narrative (e.g. [`_valheim`](../modules/apps/_valheim/README.md), [`_llama-cpp`](../modules/system/_llama-cpp/README.md)) |

## Ownership rules

- **One authoritative location per procedure.** A runbook owns its commands.
  README, agent guides and skills link to the runbook section instead of
  copying the steps, so a change is made once.
- **Option facts come from declarations.** An option's type, default and
  description live in its `mkOption` beside the code that renders it. The
  option reference is generated from those declarations by
  `task docs:options`; do not edit it by hand, and do not copy field
  definitions into prose. Prose explains *when* and *why* to use an option and
  links to the reference for *what* it accepts.
- **Agent guides state constraints, not tutorials.** Keep `AGENTS.md` short;
  put topic rules in `docs/agents/` and leave procedures to the runbooks.
  `CLAUDE.md` stays a one-line import of `AGENTS.md`.
- **App-specific history stays with the app.** An incident that explains one
  module's odd wiring goes in that module's `_<app>/README.md`, not in a
  runbook and not atop the `.nix` file.

## Runbooks

| Runbook | Covers |
| ------- | ------ |
| [Backups and restore](runbooks/backup-restore.md) | backup layout, catastrophic rebuild, per-app restore recipes, cross-host recovery testing |
| [PostgreSQL major-version upgrades](runbooks/postgresql-upgrade.md) | `pg_upgrade` procedure and rollback |
| [Activating a host](runbooks/activation.md) | what `scripts/activate-nixos.sh` asserts, preflight probes, SSH multiplexing |
| [Bootstrapping a new host](runbooks/bootstrap.md) | nixos-anywhere install, secrets setup, reinstall, VM testing |
| [Recovering from a sops decryption failure](runbooks/sops-recovery.md) | re-running decryption and role-password units |
| [Fetch hashes](runbooks/fetch-hashes.md) | why CI regenerates fixed-output hashes |
| [Authentik (SSO)](runbooks/authentik-sso.md) | blueprints, adding an OIDC app, forward-auth |
| [Jellyfin](runbooks/jellyfin.md) | LDAP authentication via authentik, hardware transcoding |
| [Home Assistant](runbooks/home-assistant.md) | native deployment, adding devices, declarative vs stateful config |
| [Local LLM inference](runbooks/local-llm.md) | llama.cpp hosts, sizing, routing, coding agents |
| [Coding sandboxes](coding-sandbox.md) | the sandboxed coding-agent runtime |

## Checks

`task check` (via `nix flake check`) keeps this layout honest:

- the `doc-links` pre-commit hook fails on a relative Markdown link whose file
  or `#heading` does not exist, so moving a section breaks the build until its
  inbound links follow it;
- the `options-reference` flake check fails when
  `docs/reference/options.md` differs from what the declarations generate.
  Regenerate with `task docs:options` and commit the result.
