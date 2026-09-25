# Working in this repo

## Agent guidance and repository workflows

`AGENTS.md` is the canonical repository guidance for every agent runner.
`CLAUDE.md` is a compatibility entry point that imports this file for Claude
Code; edit this file, never `CLAUDE.md`.

Canonical repository workflows live under `skills/`. They are agent-neutral
source-controlled content. Runner-specific discovery adapters may point at
them, but must not duplicate their bodies. Local runner state (settings,
caches, scheduled-task state, and worktrees) remains untracked.

The checked-in discovery adapters are deliberately thin: Claude Code imports
each workflow from `.claude/skills/`, while Codex discovers directory symlinks
under `.agents/skills/`. When adding a canonical workflow, add or update both
adapters; neither is a second source of workflow instructions.

## PII never goes in git or GitHub

This repo is public, and so are its issues, PRs, and commit history. Personal
data about anyone — third parties above all — must never land in a commit, a
commit message, an issue body, a PR description, or a review comment.

Treat as PII: email addresses, real names, phone numbers, street addresses,
and identifiers that resolve to a person's account outside this system (a
`tailscale whois` `User.Name`, an OIDC subject).

Not PII: app usernames and handles. They are already in config and in the app
databases, they are what the systems here actually key on, and a handle on its
own names nobody. Neither are the operator's own identifiers, which this flake
declares in the open — `ianepreston`, host names, `*.ipreston.net`, the
addresses in `hostSpecs/`.

Redact at the point of writing, not afterwards. Evidence gathered off a live
host routinely carries third-party identity alongside the handle; when writing
it up, keep the handle and the technical facts the argument rests on —
timestamps, tailnet IPs, device models, versions — and drop the person behind
them. "`Cozy room TV` is user `dubelder`" is the right level of detail; the
same line with the account's email address is not.

Cleanup after the fact is expensive and incomplete: a public issue is already
fetchable and indexed, GitHub keeps the pre-edit revision in the issue's edit
history (deletable only by hand in the web UI), and a committed value needs a
history rewrite plus a force-push. Assume anything published stays published.

## Taskfile.yaml is the entry point

Common operations are defined in `Taskfile.yaml` (with bootstrap / recovery /
secrets workflows split out into `taskfiles/*.yaml` and exposed via
`includes:`). Read them before running ad-hoc `nixos-rebuild` / `nix build`
commands — there is usually a task that already wires up the right flags
(private-input overrides, target hosts, etc.).

Frequently used:

- `task deploy:<host>` — build locally, push the closure, and `switch` on a
  remote host. Use this to test uncommitted changes against a real host without
  pushing to GitHub. The `system.autoUpgrade` timer only catches up to `main`
  after a push, so deploy is the fast iteration path.
- `task rebuild` / `task rebuild:<host>` — local rebuild.
- `task check` — full pre-push gate (fmt, lint, `nix flake check`).
- `task bootstrap:new` / `task bootstrap:reinstall` — provision a new host
  end-to-end via nixos-anywhere.

When in doubt: `task --list`.

### Never `task deploy` disko-affecting changes

Disko-managed subvolumes/partitions only land at install time (when
nixos-anywhere actually runs disko). `task deploy:<host>` does an in-place
`nixos-rebuild switch`, which copies the closure including the new
`fileSystems.*` entries that disko generates — and then systemd tries to mount
paths that don't exist on the running disk. `local-fs.target` fails, cascades
through dependent units (sshd among them), and the host goes dark with no way
back in except console rollback. Even console rollback doesn't always clear the
runtime systemd job queue, so a second deploy after rollback can re-trigger the
cascade.

Rule: any change that touches `modules/hosts/_<host>-disks.nix` **must** be
applied via `task bootstrap:reinstall HOST=<host> DEST=<ip>` (or `bootstrap:new`
for a fresh host), with `IMPERMANENT=true` if preservation is involved. Never
`task deploy:<host>` it.

If you're impermanence-bound, also seed the SSH host key into
`/persist/etc/ssh/` at install time — that's what the `IMPERMANENT=true` flag on
`bootstrap:install` exists for. Without it sshd can't load its host key after
the first rollback (preservation bind-mounts an empty file from `/persist`) and
the host comes up unreachable.

### Local testing via `task vm:*`

For sandboxed iteration without a real host, use the `task vm:*` family
(`taskfiles/vm.yaml`). It drives a single quickemu VM at a time under
`~/vms/nixos-vm/`, with a persistent SSH host key (and matching age identity)
preserved across `vm:down`/`vm:up` cycles.

- `task vm:up` — boots the VM on the installer ISO (rebuilds `latest.iso` only
  if absent, or if `FORCE_ISO=true`).
- `task vm:sops-authorize TARGET=<host>` — one-time per real-host secret set.
  Authorizes the VM's persistent age key onto `<host>.yaml` + `shared.yaml`'s
  creation rules in `../nix-secrets/.sops.yaml`. Edit is uncommitted; commit +
  push via `task secrets:publish` to make sticky, or `git restore` in
  `../nix-secrets` to revoke.
- `task vm:install HOST=<flake-host>` — `bootstrap:reinstall` against the VM
  with the persistent key reused (no nix-secrets churn per install). HOST must
  be on the allow-list (`tests-server`, `tests-desktop`) — anything else has a
  real-hardware disk layout that won't boot under quickemu.
- `task vm:down` — kills quickemu, deletes the qcow2, preserves the SSH host
  key.
- `task vm:reset HOST=<flake-host>` — `down` → `up` → `install` in one shot for
  a fresh sandbox.

When adding a new VM-compatible flake host, register it in the `case` allow-list
in `taskfiles/vm.yaml`'s `install` task and have it import
`modules/hosts/_vm-disks.nix` (the shared impermanent vda btrfs layout).

### `LOCAL_SECRETS` toggle

`task bootstrap:{install,reinstall,new,rebuild}` and `task vm:install` take
`LOCAL_SECRETS=true|false` (default `true`). True pre-builds /
on-target-switches with `--override-input nix-secrets path:../nix-secrets`,
picking up any uncommitted edits in the sibling checkout. False resolves
nix-secrets from `flake.lock`. Default-true is what you want for almost all
local iteration; flip to false only when explicitly testing against published
secrets.

## Module layout

- `modules/system/*.nix` — NixOS modules, registered as
  `flake.modules.nixos.<name>` and consumed via
  `inputs.self.modules.nixos.<name>`. Cross-cutting option surfaces
  (`myCaddy.apps` in `caddy.nix`, `myPostgresApp` in `postgresql.nix`,
  `myHomepage.tiles` in `homepage.nix`, `mySqliteQuiesce.apps` in
  `sqlite-quiesce.nix`, `myRuntimeCredentials` in `runtime-credentials.nix`)
  are declared inline next to the service that consumes them — no separate
  "platform tier" directory. The `my`-prefix marks options owned by this flake
  (vs upstream `services.*`).

  `myRuntimeCredentials` is the odd one out in shape: an app that generates
  its own API key (the *arrs, sabnzbd, jellyfin) declares
  `myRuntimeCredentials.readers.<VAR>` next to the service that writes it, and
  any service that needs those keys at runtime declares
  `myRuntimeCredentials.consumers.<name> = { vars; units; }` and reads
  `.envFile`. Keys like these can't live in sops — nothing chose them — so
  they're read off disk at boot into a tmpfs env file rather than baked into
  /nix/store. Two consumers today: homepage (widget keys, `HOMEPAGE_VAR_`
  prefix) and shelfmark (prowlarr + sabnzbd).
- `modules/apps/*.nix` — server-app modules (jellyfin, mealie, miniflux,
  authentik, …). Each is self-contained: service (or container — see "App
  packaging" below), caddy route via `myCaddy.apps`, postgres via
  `myPostgresApp`, SSO via `myAuthentik.{oidcApps,forwardAuthApps}`. The
  `myAuthentik.*` option surface lives in `modules/apps/authentik.nix` — same
  file as the IDP itself.
- `modules/profiles/*.nix` — composed bundles. Two server-side profiles:
  `server` (core infra: `base`, `auto-rebuild`, `authentik`, `caddy`, `mariadb`,
  `nfsclient`, `nix-maintenance`, `observability`, `oci-containers`,
  `postgresql`, `server-backups`, `server-users`, `sops`, `ssh`, `tailscale`)
  and `server-apps` (the user-facing app bundle on top of `server`). Hosts that
  run apps import both.
- `modules/hosts/<host>.nix` — per-host `nixosConfiguration` wiring.
- `hostSpecs/<host>.nix` — declarative host metadata (hostname, environment,
  email). Schema lives in `hostSpecs/_host-spec.nix`.

New modules need to be tracked by git (even just `git add -N`) before flake
evaluation will see them. This applies to non-`.nix` files referenced from
modules too (e.g. blueprint YAMLs under `modules/apps/authentik-blueprints/`) —
`nix eval` will error with "path … does not exist" until they're tracked.

### Module placement: `modules/programs/` vs `modules/system/`

- `modules/programs/*.nix` — home-manager modules for user-facing programs
  (ghostty, neovim, browser, comms, …). Each registers
  `flake.modules.homeManager.<name>` **only** — no `flake.modules.nixos.*`.
- `modules/system/*.nix` — NixOS system modules, plus "multi-context aspects"
  that pair a NixOS module with a co-located HM module in one file. `ssh.nix`
  registers both `nixos.ssh` and `homeManager.ssh`; `sops.nix` registers both
  `nixos.sops` and `homeManager.sops`; `hm-core.nix` registers
  `homeManager.core` (bootstrap HM coupled to system setup). Co-locate the HM
  half here when it is tightly coupled to a system service — SSH client config
  paired with sshd, sops age-key bootstrap paired with sops-nix activation, and
  the like — so the two halves stay in lockstep. A standalone HM module with no
  such coupling belongs in `modules/programs/`.
- **Known anomaly:** `modules/programs/printing.nix` registers
  `flake.modules.nixos.printing` (a NixOS-only module) and really belongs at
  `modules/system/printing.nix`; movable on a drive-by edit.

## App packaging: prefer nixpkgs services over containers

Default to a native NixOS module (`services.<app>`) when one exists in nixpkgs.
Containers are the fallback, not the baseline — they add a podman runtime layer,
separate volume bookkeeping under `/var/lib/containers/<app>`, and inter-app DNS
that doesn't exist between native services. Reach for a container only when one
of the exceptions below applies.

When evaluating a candidate, check the version in both the stable channel the
flake tracks (the `nixpkgs` input in `flake.nix`) and `nixos-unstable`. Derive
the stable ref from `flake.nix` rather than hardcoding it here, so this doesn't
drift when the channel bumps:

```sh
# stable channel is whatever flake.nix tracks — don't hardcode it
stable=$(grep -oE 'nixos-[0-9]+\.[0-9]+' flake.nix | head -1)
nix eval --raw "github:NixOS/nixpkgs/$stable#<app>.version"
nix eval --raw "github:NixOS/nixpkgs/nixos-unstable#<app>.version"
```

Acceptable lag is a couple of minor versions on stable; a major-version
regression or a five-plus minor gap on both branches is a skip signal
(historical examples: sabnzbd 4.5 vs upstream 5.0, mealie 3.9 vs 3.17 — both
originally skipped, then taken anyway because the apps weren't in production).
If unstable is significantly closer than stable and you need it, wire a
per-package overlay rather than flipping the whole flake to unstable.

Before falling through to a container, check whether **upstream publishes its
own flake with a NixOS module**. That is a third path, not a variant of the
container one, and it is the right call when the app will never be in nixpkgs —
sparkyfitness is source-available under a non-commercial licence, so there is no
"wait for nixpkgs" to wait for (#655). It buys a real systemd unit, normal
`services.<app>` options and no podman layer, at these costs:

- **A flake input on someone else's nixpkgs.** Don't `inputs.follows` ours onto
  it — same call as `authentik-nix`. Expect a second closure.
- **Source builds** on every version bump, and a fat closure if upstream doesn't
  prune (sparkyfitness's backend is a 765 MB `node_modules` tree).
- **No renovate tracking.** `renovate.json` sets `"nix": {"enabled": false}`, so
  the input is bumped by hand: move the pinned ref (a path segment for a
  `github:` input — `github:owner/repo/v1.7.1`) *and* run
  `nix flake update <input>`, because evaluation reads `flake.lock`, not the URL
  — the same "the pin moved but the build didn't" class as #606/#625.
- **Upstream may not test the nix path at all.** SparkyFitness says so outright
  and has no CI job that builds the packages. Tolerable because the failure is a
  loud build error at deploy time; if a release breaks it twice running, take
  the container.

Two traps this repo hit on that path, both worth checking in any upstream module
before importing it:

- **Plain assignments where you'd expect `mkDefault`.** SparkyFitness's
  `database.createLocally` branch sets `services.postgresql.package` outright,
  which is an eval conflict against our `postgresql_18` pin (and a cluster
  downgrade if it won). Turn that branch off and use `myPostgresApp`, then
  re-add by hand whatever the module's own init did — for sparkyfitness that was
  `CREATEROLE` on the owner role and `ALTER SCHEMA public OWNER TO`.
- **Prefer the bare module over a `packages.${pkgs.system}` convenience
  wrapper.** `pkgs.system` is deprecated, so importing the wrapper prints a
  rename warning on every eval of every host that imports it. Import
  `nixosModules.default` and set the package options yourself off
  `pkgs.stdenv.hostPlatform.system`.

Stay on the container path when:

- **No nixpkgs module.** (e.g. actualbudget, mylar3, readmeabook,
  shelfmark, bindery, grimmory.) Re-check before taking this branch — tandoor
  sat on this list while `services.tandoor-recipes` existed all along (#441).
- **The container is a fork or variant the nix module doesn't track.** Seerr is
  the seerr-team fork at v3.x; nixpkgs ships jellyseerr. They share lineage but
  aren't drop-in.
- **Upstream image bakes in behaviour the nix package doesn't.** home-operations
  sabnzbd applies `SABNZBD__HOST_WHITELIST_ENTRIES` on every entrypoint run; the
  nix package doesn't, so the module fakes it with a oneshot — that worked, but
  if the missing behaviour is deeper than a sed-script, container is fine.
- **The app's plugin/add-on ecosystem assumes a container runtime you'd have to
  reproduce.** Home Assistant was the canonical case cited here — but it moved
  native anyway (see the HA note in the gotchas below). The stated reason
  ("python deps don't fit the nixpkgs cadence") was wrong; the real cost turned
  out to be integration-declaration friction, which is acceptable for a stable
  install. Keep this category for an app that genuinely can't be expressed, but
  don't assume "big/churny" means "must containerize" — verify.

When you do switch to a nix module, watch for these gotchas (all encountered on
the containerize-to-nixos-modules branch):

- **User/group override gating.** Jellyfin gates user creation behind
  `mkIf (cfg.user == "jellyfin")`, so overriding to `server-${env}` cleanly
  skips the module's user block. Kavita writes
  `users.users.${cfg.user}.group = cfg.user` unconditionally; with
  `cfg.user = "server-${env}"` that collides with `server-users.nix` setting
  `group = "servers"` on the same UID-pinned user. Resolve with
  `users.users.${kavitaUser}.group = lib.mkForce "servers";`. Read each module's
  `users.users` block before assuming the jellyfin pattern works.
- **Postgres connection style.** Mealie's `database.createLocally = true` +
  `DynamicUser=mealie` gets unix-socket peer auth for free (the dynamic username
  matches the role name); no password to plumb. Use this when the module's
  expected role name doesn't conflict with anything pre-existing. When it does
  (paperless's module wants role `paperless` but our existing role is
  `paperless_ngx`), keep `myPostgresApp` + TCP + sops password rather than
  triggering a destructive rename.
- **Multi-unit apps and OIDC env file restarts.** Apps that ship several systemd
  units consuming the same env file (paperless-{web,
  scheduler,task-queue,consumer}) need every unit listed in
  `myAuthentik.oidcApps.<app>.appRestartUnit` so all of them bounce on
  credential rotation. The option accepts a list.
- **Module-imposed `PrivateNetwork`.** Paperless's `database.createLocally`
  enables `PrivateNetwork=true` on scheduler/consumer. That's fine for workers
  (no OIDC traffic) but check what each unit actually does before relying on it.
- **A per-package unstable pin may also need the unstable *module*.** Pinning
  `services.<app>.package` to `nixpkgs-unstable` only works while the stable
  module can still drive the newer package. Paperless 3.x moved both in lockstep
  (Whoosh → Tantivy index with its own tmpfiles dir and a
  `reindex --if-needed` migration, a `paperless-secret-key.service` shim,
  `passthru.dependencies` in place of `propagatedBuildInputs`), so
  `modules/apps/paperless-ngx.nix` carries
  `disabledModules = [ "services/misc/paperless.nix" ]` plus an import of the
  unstable module file alongside the package pin (#526). Diff the two module
  files before assuming a `package =` override is enough. Pinning the module
  also inherits upstream's in-flight bugs — check the newest `nixos-unstable`
  and bump the input before writing a local workaround.
- **Home Assistant: integration breadth is the real native cost, not python
  isolation.** HA runs native (`modules/apps/homeassistant.nix`) on an
  `nixpkgs-unstable` per-package overlay — stable freezes HA at a yearly
  snapshot while HA ships ~monthly and its integrations track fast-moving APIs.
  The friction the container hid: native ships python deps only for *declared*
  components. Adding a device is therefore a config change, not just a UI click
  — each integration must be in `services.home-assistant.extraComponents` (core)
  or packaged as a `customComponents` entry via `buildHomeAssistantComponent`
  (HACS-only: bambu_lab, hoymiles_wifi, ha_blueair), else the UI config flow
  fails "Invalid handler specified". This taxes experimentation, not steady
  state, so it fits a stable device set and the declarative/reproducible payoff.
  Custom-component versions are renovate-tracked (the `github-releases` `tag`
  and `github-tags` rev-pin custom managers in `renovate.json`, kept manual);
  each manager's match spans `version` through `tag`/`rev`, so renovate rewrites
  both halves of the number in one edit, and CI regenerates the fetch hash
  beside them (see "Fetch hashes are regenerated in CI" below). Their unpackaged
  python libs are pinned to each manifest's `requirements` and bumped in
  lockstep by hand. OIDC creds reach HA
  via `!secret` from a sops-rendered `secrets.yaml` (not env), and UI-authored
  automations/scripts/scenes are file-based `!include` targets seeded by the
  service `preStart`. Stateful config (`/var/lib/hass/.storage`) does not merge
  between instances — do device pairing directly on the target host; only the
  `automations.yaml`/`scripts.yaml`/`scenes.yaml` files port cleanly.

## Fetch hashes are regenerated in CI

Renovate rewrites a `version`/`tag`/`rev` and nothing else. The `hash` beside it
is a fixed-output derivation's *declared* content address, so a stale one is not
a build failure — nix addresses the FOD by that hash, finds the old path already
in the store, and skips the fetch entirely. #606 merged a ha_blueair bump with
the previous hash still in place, all checks green, and two hosts ran the old
code for two months; the `check` jobs run on hpp-1, whose warm store is exactly
the store that can't notice (#625).

So don't hand-maintain them: `.github/workflows/renovate-hashes.yml` runs
`scripts/regen-fetch-hashes.sh` on every `renovate/**` branch and pushes a fixup
commit. Run the same script by hand (`task hashes`, or `task hashes -- --check`
to only report) after editing a pin yourself. Two paths, both automatic:

- **`fetchFromGitHub` blocks** are found structurally — no annotation needed.
  The hash is the NAR hash of the unpacked `archive/<ref>.tar.gz`, which
  `nix-prefetch-url --unpack` reproduces, so there's nothing to build.
- **Hashes only a build can reveal** (vendored dependency trees — today
  `pkgs.caddy.withPlugins` in `modules/system/caddy.nix`) need a
  `# regen-hash: <flake attr>` comment on the line directly above the `hash`.
  The script swaps in `lib.fakeHash`, builds that attribute, and reads the real
  hash off the mismatch error; the marker exists because nothing in the file
  says where the derivation is reachable in the flake. A new `cargoHash` /
  `npmDepsHash` / vendor pin is covered by adding that one comment line.

Two things stay deliberately manual: `fetchPypi` pins (blueair-api's version is
an `==` constraint from the component's own `manifest.json`, enforced loudly at
build time by `manifestRequirementsCheckHook`) and the `automerge: false` on the
caddy / HA-component package rules.

## NFS UID alignment

Any service touching the NFS-mounted Synology share (`/mnt/content`,
`/mnt/backups`, …) must run as `server-${env}:servers` (UID 1029/1030,
GID 65536) — the NAS enforces UID-based access and a service running under its
own per-package user will silently see empty listings even when the directory is
mode 0777. This applies to native NixOS modules too, not just containers: pin
`services.<app>.user`/`.group` when the module exposes them. After flipping
ownership, `chown -R` any pre-existing `/var/lib/<app>` state on the host once —
the upstream `tmpfiles` rules use type `d` and won't re-chown existing
directories. See `modules/apps/jellyfin.nix` for the pattern.

## Provisioning per-app secrets (`task secrets:*`)

Secrets live in the sibling repo at `../nix-secrets` (consumed as a flake
input). Run secret-management tasks from **this** repo — the former
`../nix-secrets/Taskfile.yaml` was rolled in as `taskfiles/secrets.yaml` since
the operator workflow always starts from a nixos checkout. All tasks default to
`HOST=hpp-1` (the homelab server) and refuse to overwrite an existing key unless
`FORCE=true`.

- `task secrets:oidc APP=<app>` — generates `client_id` (hex 16) and
  `client_secret` (hex 32) at `<app>.oidc_client_id` /
  `<app>.oidc_client_secret` in `sops/<host>.yaml`. Use whenever wiring
  `myAuthentik.oidcApps.<app>`.
- `task secrets:dbpw APP=<app>` — generates `<app>.db_password` (hex 16). Use
  for any app whose postgres role is provisioned via `myPostgresApp` with TCP +
  password (i.e. not unix-socket peer auth / `createLocally`).
- `task secrets:secret APP=<app> KEY=<key> [LEN=<bytes>]` — generic high-entropy
  hex at `<app>.<key>`. Use for app-specific tokens (session keys, signing
  secrets, API keys).
- `task secrets:edit:<host>` / `task secrets:view:<host>` — open or print a
  host's decrypted yaml. Use `edit` for non-random values (e.g. pasted-in API
  keys from a provider).
- `task secrets:rekey` — re-encrypts every file against current `.sops.yaml`;
  run after changing the key registry.
- `task secrets:publish MSG="..."` — commits + pushes pending changes in
  `../nix-secrets`, then runs `nix flake update nix-secrets` here. No-ops on a
  clean tree / already-pushed branch, so it's also safe to run defensively
  before a deploy.

Workflow when adding a new app that needs secrets:

1. Decide which secrets the app needs (OIDC creds, db password, app-specific
   tokens).
2. Run the matching task(s). Keys nest under the app name, so
   `sops.secrets."<app>/oidc_client_id"` /
   `sops.placeholder."<app>/db_password"` etc. in the nixos module resolve
   directly.
3. Run `task secrets:publish MSG="add <app> secrets for <host>"` to commit +
   push `nix-secrets` and bump the flake input here. After that the new secrets
   are usable in a deploy.

Don't invent ad-hoc key names — stick to `oidc_client_id`, `oidc_client_secret`,
`db_password` so existing app modules (`tandoor.nix`, `paperless-ngx.nix`, etc.)
remain a copy-paste template. Reach for `task secrets:secret` only when the app
genuinely needs something beyond those three.

## Recovery metadata: declare it beside the app

`taskfiles/recovery.yaml` keeps the generic restore templates, while app
modules contribute `myRecovery.apps.<app>` metadata. `task recovery:app
APP=<app> HOST=<host>` evaluates that generated manifest, and `recovery:all`
sorts its enabled entries by the app-owned `order`. When you add an app with
restorable state, add its recovery metadata beside its service/state
declaration; do not add a Taskfile registry entry or hand-maintain an aggregate
list. Pick the metadata shape that matches the app:

| Shape (how the module is built)                    | `kind`       | Metadata to declare                                                                                                                                                                                                                              |
| -------------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Container, no postgres                             | `"volume"`   | `units = [ "podman-<app>.service" ]; paths = [ ... ];`                                                                                                                                                                                         |
| Container + `myPostgresApp.<app>`                  | `"postgres"` | Container unit, database name (respecting any override), and paths outside `/var/backup/postgresql`                                                                                                                                           |
| Native + `myPostgresApp.<app>`                     | `"postgres"` | Every consumer service, database role/name, and any on-disk state path                                                                                                                                                                        |
| Native + `mySqliteQuiesce.apps.<app>`              | `"sqlite"`   | Unit and state path. The manifest derives `/var/backup/sqlite/<app>` and every staged-to-live swap from `mySqliteQuiesce.apps.<app>.databases`; use `sqliteOwner = "@env@"` (the default) for `server-${env}`. |
| Native, no postgres or quiesce                     | `"volume"`   | Unit and state path                                                                                                                                                                                                                             |
| Timer-driven oneshot container (e.g. spierscraper) | `"volume"`   | Empty `units` and its state path                                                                                                                                                                                                                |

For apps with an HTTP endpoint, set `health.url` (and only override its default
200/30-retry/2-second values when needed) so the dispatcher exits non-zero on a
botched restore. Jellyfin is the 60-retry, longer-warm-up example.

`myAppState.<app>` in the owning module is the structural analogue: it renders
the preservation entry, the restic path (unless `backup = false`), and the
`expectedPreservedDirs` guard in `modules/profiles/server-apps.nix` from one
declaration, so there is no profile edit to forget. Recovery metadata remains
an intentional app-level declaration: an app whose state is preserved and
backed up but has no `myRecovery.apps.<app>` entry is restorable only by hand.

### `restartUnits` goes on the template, not the secret

When an app declares its own `sops.templates."<app>.env"` (i.e. it's not
threaded through `myAuthentik.oidcApps`), put `restartUnits` on the **template
only** — not on the underlying `sops.secrets.<key>`, not on both. The template
is what the consumer reads via `environmentFile` / `EnvironmentFile`, and
sops-nix re-renders it whenever any referenced placeholder's source changes — so
a single declaration on the template captures every rotation path. Putting it on
the secret is redundant; splitting it across both is a "did I update both?"
footgun the next time keys change.

Exceptions:

- Aggregators (`myPostgresApp`, `myAuthentik.oidcApps`) already attach
  `restartUnits` to the secrets they own — leave those alone. The rule applies
  to per-app env templates declared inline in the app module.
- When a secret is consumed directly (via `config.sops.secrets.<k>.path` in a
  oneshot, an `ExecStart`, or a config-file reference) rather than through a
  template, the restart trigger has to go on the secret because there's no
  template to bind it to. `grafana.nix`'s `grafana/bootstrap_password` (read
  via `$__file{}` from grafana.ini) is the example.

Existing modules that have it on both the secret and the template
(`manyfold.nix`, `pinchflat.nix`) are not broken — converge them
to template-only on drive-by edits rather than a dedicated cleanup pass. Closes
#142. (`valheim.nix` had the inverse defect — `restartUnits` on the secret only,
not the template — fixed to template-only per #336.)

## Authentik notes

- Deployed via `nix-community/authentik-nix` (flake input `authentik-nix`),
  _not_ containers — see README "Authentik (SSO)" for the rationale and the
  per-app onboarding pattern.
- **`bypassAuthPaths` for key-gated APIs.** When registering
  `myAuthentik.forwardAuthApps.<app>`, declare `bypassAuthPaths` for the routes
  the app gates with its own API key (`/api/*`, healthchecks, feeds) so
  non-browser clients can use the native key instead of an authentik session
  cookie — with a rationale comment, following `modules/apps/radarr.nix`. Never
  bypass routes that serve data unauthenticated (gatus, pinchflat feeds, …);
  for those apps omit the option entirely and leave everything gated. Verify
  the "key-gated" claim by actually curling the bypassed routes without a key:
  an app whose auth endpoint hands out its API key unauthenticated when no UI
  password is set must NOT bypass `/api/*` despite having an API key scheme,
  because doing so would let any LAN client mint full API access. Keep path
  lists per-module — they genuinely differ per app (sabnzbd is the single exact
  path `/api`, prowlarr has no `/feed`).
- **Don't use `pkgs.symlinkJoin` for `blueprints_dir`.** Authentik's
  `retrieve_file` resolves paths and rejects anything outside the configured
  `blueprints_dir`; symlinkJoin's top-level entries dereference back to upstream
  / source store paths and every blueprint apply fails with "Invalid blueprint
  path". `modules/apps/authentik.nix` uses `pkgs.runCommandLocal` + `cp -rL` to
  materialize real files.
- **`@serverDomain@` substitution is per-contributor, not at merge time.** OIDC
  blueprint dirs are pre-rendered by `renderedBlueprintDir` in
  `modules/apps/authentik.nix` before they hit `extraBlueprints`;
  `fwBlueprintDir` interpolates the domain into the Nix string directly. The
  merge step (also in `modules/apps/authentik.nix`) is a pure `cp -rL` stack
  with no `sed` pass — that pass mangled unrelated YAML values that happened to
  contain the literal string (closes #154). If you add a new way of contributing
  blueprints, do substitution at the contribution site if those files use the
  placeholder. `renderedBlueprintDir`'s own substitution is whole-file, comments
  included, so don't spell the placeholder in blueprint prose — a comment saying
  a URI "carries no `@serverDomain@`" renders as "carries no dnix.ipreston.net"
  (bookorbit's native redirect URI, #743). Say "per-host domain placeholder"
  instead.
- Blueprint secrets (`password`, `client_secret`, token `key`) go through
  `!Env VAR_NAME`. The var must be present in the `EnvironmentFile` consumed by
  the _worker_ (the worker is what applies blueprints, not just the server). The
  authentik-nix module already wires the same `environmentFile` to all three
  units, so adding to `sops.templates."authentik.env"` is sufficient.
- Don't override `authentik-nix`'s `nixpkgs` via `inputs.follows` — its README
  warns this breaks pinned python deps. Let it use its own locked nixpkgs.
- Authentik blueprints use custom YAML tags pyyaml can't safe-load.
  `modules/flake/git-hooks.nix` excludes `^modules/apps/authentik-blueprints/`
  from the `check-yaml` hook; extend the `excludes` list when adding new
  blueprint dirs.
- `services.authentik.createDatabase = true` (default) merges `authentik` into
  the shared postgres via `ensureDatabases` / `ensureUsers` and connects over
  the unix socket with peer auth — no password required for the role. Don't add
  a `db_password` sops secret for it.
- Reference:
  [model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
  [YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).
