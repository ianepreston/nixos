---
name: add-app
description: Add a new self-hosted server app to ianepreston/nixos end to end — choose native module vs upstream flake vs container, write modules/apps/<app>.nix, wire caddy, postgres, SSO, secrets, state/backup, recovery, observability and homepage, then validate on hpp-1. Use when asked to add, deploy, set up, or try out a new app/service ("add miniflux", "let's try out bookorbit", "/add-app <name>").
---

# Add an app

Argument: the app name (and optionally an upstream URL). Validate on **hpp-1**
(dev) before anything reaches amos1 (prod).

## 1. Choose the packaging

Read [docs/agents/app-packaging.md](../../docs/agents/app-packaging.md) and
decide, in order: nixpkgs `services.<app>` → upstream flake NixOS module →
container. Check stable and unstable versions with the commands there. This is
a trade-off — **tell the user what you found and ask** before committing to a
container or a new flake input.

## 2. Plan the integration

List what the app needs, then copy the closest existing module as a template:

| Need                        | Surface                                    | Template                         |
| --------------------------- | ------------------------------------------ | -------------------------------- |
| Native + postgres + OIDC    | `myPostgresApp`, `myAuthentik.oidcApps`    | `modules/apps/tandoor.nix`       |
| Multi-unit native app       | list every unit in `appRestartUnit`        | `modules/apps/paperless-ngx.nix` |
| App with its own API key    | `myAuthentik.forwardAuthApps` + `bypassAuthPaths` | `modules/apps/radarr.nix`  |
| NFS media access            | run as `server-${env}:servers`             | `modules/apps/jellyfin.nix`      |
| Upstream flake module       | flake input, `myPostgresApp`               | `modules/apps/sparkyfitness.nix` |

Read the surfaces' docs as you touch them:
[authentik.md](../../docs/agents/authentik.md),
[app-state.md](../../docs/agents/app-state.md),
[architecture.md](../../docs/agents/architecture.md).

## 3. Secrets

Per [docs/agents/secrets.md](../../docs/agents/secrets.md): `task secrets:oidc`,
`task secrets:dbpw`, `task secrets:secret` as needed, with the standard key
names. Publish with `task secrets:publish` before a deploy that needs them.

## 4. Write `modules/apps/<app>.nix`

Everything the app owns lives in this one file (or a private
`modules/apps/_<app>/` for nontrivial scripts). Checklist:

- [ ] Service / container, with any sops env via
      `sops.templates."<app>.env"` — `restartUnits` on the template only
- [ ] `myCaddy.apps.<app>` route
- [ ] `myPostgresApp.<app>` (or peer-auth `createLocally` when the role name
      is free), with every DB consumer in `consumerService`
- [ ] `myAuthentik.oidcApps.<app>` + `<app>-blueprints/` dir, or
      `forwardAuthApps` with verified `bypassAuthPaths`; homepage tile via the
      `homepage` attr (or `myHomepage.tiles`)
- [ ] `myAppState.<app>` (preservation + backup)
- [ ] `myRecovery.apps.<app>` with the right `kind`, `order`, and `health.url`
- [ ] `myObservability.monitoredSystemdUnits`
- [ ] sops ordering edge on any unit that reads a sops file but isn't in an
      aggregator list
- [ ] Header comment explaining non-obvious departures from module defaults
- [ ] Import in `modules/profiles/server-apps.nix`
- [ ] `git add -N` new files (module, blueprints, scripts) before eval

## 5. Validate

1. Run `task check` and verify the app's recovery entry with a read-only eval.
   Replace `<app>` with its name in
   `nix eval --json .#nixosConfigurations.hpp-1.config.myRecovery.manifest | jq -e --arg app '<app>' '.[$app]'`.
   Never run `task recovery:app` to test it. That performs a real restore.
2. Use `task ssh:preflight HOST=hpp-1` for the standard deployment, or the
   helper with matching custom options. See
   [host-access](../_shared/host-access.md) for bounded access checks and operator
   handoff. With host-specific authorization and working transport, deploy
   with `task deploy:hpp-1`, which enforces the identity checks in `AGENTS.md`.
3. Check that the unit is active, the Caddy route answers, SSO login works,
   and the `myAppState` directory exists with the right owner.
4. Note anything that needed manual first-run setup (admin bootstrap, library
   creation) in the module header for later use on `amos1`.

If access is unavailable, continue independent implementation and local
checks. Defer the deploy and on-host checks until their prerequisites are
met, and keep them required before production rollout.

## 6. Hand off

Report what was wired, which checks passed, and any failed or deferred
checks. For each deferral, include the unmet prerequisite and the commands or
manual steps still needed. Commit / PR only when asked.
