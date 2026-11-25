# Architecture and authored-source boundaries

These rules decide where behaviour, metadata, contracts, and executable source
belong when adding or changing a cross-cutting feature. They came out of the
#687–#700 audit; follow them so a later change doesn't recreate the coupling
that audit removed.

They don't ban the deliberate co-locations already in place — the
multi-context NixOS/HM aspects in `ssh.nix` / `sops.nix`, the `myAuthentik.*`
surface hosted beside the IDP. A *new* exception needs a stated reason.

1. **App-owned behaviour and metadata live with the app.** An app module owns
   its service, state declaration, app-specific observability contribution,
   recovery metadata, and app-specific network attachment. Profiles compose
   apps; generic infrastructure owns mechanisms, not app-name exceptions (e.g.
   Bambuddy's Virtual Printer wiring lives in its own module, not a host
   schema).
2. **Platforms aggregate additive, typed contributions.** When several apps
   feed one platform — alerts and monitored units into observability
   (`myObservability.metricRuleGroups` / `logRuleGroups` /
   `monitoredSystemdUnits`), routes into caddy, tiles into homepage — the
   platform declares a narrow typed option beside the code that renders it and
   each app fills it in. Never add a central app-specific list or regex.
3. **One authoritative declaration.** State, backup, preservation, recovery,
   and similar metadata are declared once beside the service and rendered for
   every consumer. `myAppState` renders the preservation entry, restic path,
   and `expectedPreservedDirs` guard; `myRecovery.apps` generates the recovery
   dispatcher manifest. No parallel Taskfile or profile inventory.
4. **Cross-module consumers use a published contract, not a private read.** A
   producer publishes only what a consumer needs — `myServiceEndpoints` for a
   URL + readiness unit, `myObservability.nodeExporterTextfileDirectory` for
   the textfile drop directory. No consumer reads another module's
   `services.*` / container attrset, and no shared literal is copied between
   producer and consumer; the contract owner does duplicate/conflict checking.
5. **Keep executable source inspectable.** Nix owns dependencies, environment,
   and unit wiring; a nontrivial, independently understandable Python or shell
   program goes in a colocated tracked file read with `builtins.readFile`
   (`modules/<tier>/_<app>/<script>.py`). Split a large module by concern into
   a private `_<app>/` directory behind a stable public file, as `valheim.nix`
   was. Incident history goes in a nearby `README.md`, not atop the module.
   Judge by boundary and responsibility, not line count.
6. **Keep an option surface navigable.** Public option declarations and the
   implementation blocks consuming them run in the same order, unless a local
   comment explains a stronger dependency ordering.
7. **Retire an integration completely.** Removing an app removes its profile
   import, routes and identity, state / recovery / monitoring metadata, static
   users, docs and examples, and now-unused secrets. A half-removed app is
   worse than none.
8. **Separate organization from behaviour.** A boundary or extraction refactor
   preserves rendered configuration and is proved by a generated-config or
   closure comparison; behaviour changes are separate work unless inseparable
   for correctness.

Before introducing or changing a cross-cutting feature, be able to name:

- the **owner** — the single module the behaviour and metadata live in;
- the **public contract** — the typed option or published endpoint others use;
- the **single source of truth** — the one declaration everything downstream
  is generated from;
- every **generated downstream consumer** — profile guards, manifests, alerts,
  routes; and
- the **rendered configuration** that proves an organization-only change moved
  no behaviour.

## Cross-cutting option surfaces

Declared inline next to the service that consumes them (no separate platform
directory). This table is a map of owners; each option's type, default and
description are in the generated [option reference](../reference/options.md)
(`task docs:options`), which covers every top-level `my*` surface on
tests-server — classify a new one in `modules/flake/options-reference.nix`:

| Option                   | File                                   | Purpose                                 |
| ------------------------ | -------------------------------------- | --------------------------------------- |
| `myCaddy.apps`           | `modules/system/caddy.nix`             | reverse-proxy routes                    |
| `myPostgresApp`          | `modules/system/postgresql.nix`        | role + DB + sops password               |
| `myHomepage.tiles`       | `modules/system/homepage.nix`          | dashboard tiles                         |
| `mySqliteQuiesce.apps`   | `modules/system/sqlite-quiesce.nix`    | consistent sqlite snapshots for backup  |
| `myRuntimeCredentials`   | `modules/system/runtime-credentials.nix` | app-generated API keys at runtime     |
| `myAuthentik.*`          | `modules/apps/authentik.nix`           | OIDC / forward-auth                     |
| `myAppState`, `myRecovery.apps` | see [app-state.md](app-state.md) | state, backup, recovery            |

`myRuntimeCredentials` differs in shape: an app that generates its own API key
(the *arrs, sabnzbd, jellyfin) declares `myRuntimeCredentials.readers.<VAR>`
beside the service that writes it; a consumer declares
`myRuntimeCredentials.consumers.<name> = { vars; units; }` and reads
`.envFile`. Nothing chose these keys, so they can't live in sops — they're read
off disk at boot into a tmpfs env file instead of the store. Consumers today:
homepage (`HOMEPAGE_VAR_` prefix) and shelfmark (prowlarr + sabnzbd).
