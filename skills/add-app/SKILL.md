---
name: add-app
description: Add a new self-hosted server app to ianepreston/nixos end to end — choose native module vs upstream flake vs container, write modules/apps/<app>.nix, wire caddy, postgres, SSO, secrets, state/backup, recovery, observability and homepage, then validate on hpp-1. Use when asked to add, deploy, set up, or try out a new app/service ("add mealie", "let's try out bookorbit", "/add-app <name>").
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

1. `task check`.
2. Deploy to hpp-1 with the identity checks from `AGENTS.md` (from an agent
   session see [skills/_shared/host-access.md](../_shared/host-access.md)).
3. On the host: unit active, caddy route answers, SSO login works, the
   `myAppState` directory exists with the right owner. Check the recovery
   entry with a read-only eval —
   `nix eval --json .#nixosConfigurations.hpp-1.config.myRecovery.manifest | jq .<app>`.
   Never run `task recovery:app` to test it; that performs a real restore.
4. Note anything that needed manual first-run setup (admin bootstrap, library
   creation) in the module header — it'll be needed again on amos1.

## 6. Hand off

Report what was wired, what was validated, and any manual steps outstanding.
Commit / PR only when asked.
