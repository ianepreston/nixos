# Working in this repo

## Taskfile.yaml is the entry point

Common operations are defined in `Taskfile.yaml` (with bootstrap /
recovery / secrets workflows split out into `taskfiles/*.yaml` and
exposed via `includes:`). Read them before running ad-hoc
`nixos-rebuild` / `nix build` commands — there is usually a task that
already wires up the right flags (private-input overrides, target
hosts, etc.).

Frequently used:

- `task deploy:<host>` — build locally, push the closure, and `switch` on a
  remote host. Use this to test uncommitted changes against a real host
  without pushing to GitHub. The `system.autoUpgrade` timer only catches up
  to `main` after a push, so deploy is the fast iteration path.
- `task rebuild` / `task rebuild:<host>` — local rebuild.
- `task check` — full pre-push gate (fmt, lint, `nix flake check`).
- `task bootstrap:new` / `task bootstrap:reinstall` — provision a new host
  end-to-end via nixos-anywhere.

When in doubt: `task --list`.

### Never `task deploy` disko-affecting changes

Disko-managed subvolumes/partitions only land at install time (when
nixos-anywhere actually runs disko). `task deploy:<host>` does an
in-place `nixos-rebuild switch`, which copies the closure including the
new `fileSystems.*` entries that disko generates — and then systemd
tries to mount paths that don't exist on the running disk. `local-fs.target`
fails, cascades through dependent units (sshd among them), and the
host goes dark with no way back in except console rollback. Even
console rollback doesn't always clear the runtime systemd job queue,
so a second deploy after rollback can re-trigger the cascade.

Rule: any change that touches `modules/hosts/_<host>-disks.nix`
**must** be applied via `task bootstrap:reinstall HOST=<host> DEST=<ip>`
(or `bootstrap:new` for a fresh host), with `IMPERMANENT=true` if
preservation is involved. Never `task deploy:<host>` it.

If you're impermanence-bound, also seed the SSH host key into
`/persist/etc/ssh/` at install time — that's what the `IMPERMANENT=true`
flag on `bootstrap:install` exists for. Without it sshd can't load its
host key after the first rollback (preservation bind-mounts an empty
file from `/persist`) and the host comes up unreachable.

### Local testing via `task vm:*`

For sandboxed iteration without a real host, use the `task vm:*` family
(`taskfiles/vm.yaml`). It drives a single quickemu VM at a time under
`~/vms/nixos-vm/`, with a persistent SSH host key (and matching age
identity) preserved across `vm:down`/`vm:up` cycles.

- `task vm:up` — boots the VM on the installer ISO (rebuilds
  `latest.iso` only if absent, or if `FORCE_ISO=true`).
- `task vm:sops-authorize TARGET=<host>` — one-time per real-host
  secret set. Authorizes the VM's persistent age key onto
  `<host>.yaml` + `shared.yaml`'s creation rules in
  `../nix-secrets/.sops.yaml`. Edit is uncommitted; commit + push via
  `task secrets:publish` to make sticky, or `git restore` in
  `../nix-secrets` to revoke.
- `task vm:install HOST=<flake-host>` — `bootstrap:reinstall` against
  the VM with the persistent key reused (no nix-secrets churn per
  install). HOST must be on the allow-list (`tests-server`,
  `tests-desktop`) — anything else has a real-hardware disk layout
  that won't boot under quickemu.
- `task vm:down` — kills quickemu, deletes the qcow2, preserves the
  SSH host key.
- `task vm:reset HOST=<flake-host>` — `down` → `up` → `install` in one
  shot for a fresh sandbox.

When adding a new VM-compatible flake host, register it in the
`case` allow-list in `taskfiles/vm.yaml`'s `install` task and have it
import `modules/hosts/_vm-disks.nix` (the shared impermanent vda
btrfs layout).

### `LOCAL_SECRETS` toggle

`task bootstrap:{install,reinstall,new,rebuild}` and `task vm:install`
take `LOCAL_SECRETS=true|false` (default `true`). True pre-builds /
on-target-switches with `--override-input nix-secrets path:../nix-secrets`,
picking up any uncommitted edits in the sibling checkout. False
resolves nix-secrets from `flake.lock`. Default-true is what you want
for almost all local iteration; flip to false only when explicitly
testing against published secrets.

## Module layout

- `modules/system/*.nix` — NixOS modules, registered as
  `flake.modules.nixos.<name>` and consumed via
  `inputs.self.modules.nixos.<name>`. Cross-cutting option surfaces
  (`myCaddy.apps` in `caddy.nix`, `myPostgresApp` in `postgresql.nix`,
  `myHomepage.tiles` in `homepage.nix`, `mySqliteQuiesce.apps` in
  `sqlite-quiesce.nix`) are declared inline next to the service that
  consumes them — no separate "platform tier" directory. The
  `my`-prefix marks options owned by this flake (vs upstream
  `services.*`).
- `modules/apps/*.nix` — server-app modules (jellyfin, mealie, miniflux,
  authentik, …). Each is self-contained: service (or container — see
  "App packaging" below), caddy route via `myCaddy.apps`, postgres
  via `myPostgresApp`, SSO via `myAuthentik.{oidcApps,forwardAuthApps}`.
  The `myAuthentik.*` option surface lives in `modules/apps/authentik.nix`
  — same file as the IDP itself.
- `modules/profiles/*.nix` — composed bundles. Two server-side profiles:
  `server` (core infra: `base`, `auto-rebuild`, `authentik`, `caddy`,
  `mariadb`, `nfsclient`, `nix-maintenance`, `observability`,
  `oci-containers`, `postgresql`, `server-backups`, `server-users`,
  `sops`, `ssh`, `tailscale`) and `server-apps` (the user-facing app
  bundle on top of `server`). Hosts that run apps import both.
- `modules/hosts/<host>.nix` — per-host `nixosConfiguration` wiring.
- `hostSpecs/<host>.nix` — declarative host metadata (hostname, environment,
  email). Schema lives in `hostSpecs/host-spec.nix`.

New modules need to be tracked by git (even just `git add -N`) before flake
evaluation will see them. This applies to non-`.nix` files referenced from
modules too (e.g. blueprint YAMLs under `modules/apps/authentik-blueprints/`)
— `nix eval` will error with "path … does not exist" until they're tracked.

## App packaging: prefer nixpkgs services over containers

Default to a native NixOS module (`services.<app>`) when one exists in
nixpkgs. Containers are the fallback, not the baseline — they add a
podman runtime layer, separate volume bookkeeping under
`/var/lib/containers/<app>`, and inter-app DNS that doesn't exist
between native services. Reach for a container only when one of the
exceptions below applies.

When evaluating a candidate, check the version in both `nixos-25.11`
and `nixos-unstable`:

```sh
nix eval --raw "github:NixOS/nixpkgs/nixos-25.11#<app>.version"
nix eval --raw "github:NixOS/nixpkgs/nixos-unstable#<app>.version"
```

Acceptable lag is a couple of minor versions on stable; a major-version
regression or a five-plus minor gap on both branches is a skip signal
(historical examples: sabnzbd 4.5 vs upstream 5.0, mealie 3.9 vs 3.17 —
both originally skipped, then taken anyway because the apps weren't in
production). If unstable is significantly closer than stable and you
need it, wire a per-package overlay rather than flipping the whole
flake to unstable.

Stay on the container path when:

- **No nixpkgs module.** (e.g. actualbudget, kapowarr, mylar3,
  readmeabook, shelfarr, tandoor, watchstate, grimmory.)
- **The container is a fork or variant the nix module doesn't track.**
  Seerr is the seerr-team fork at v3.x; nixpkgs ships jellyseerr.
  They share lineage but aren't drop-in.
- **Upstream image bakes in behaviour the nix package doesn't.**
  home-operations sabnzbd applies `SABNZBD__HOST_WHITELIST_ENTRIES` on
  every entrypoint run; the nix package doesn't, so the module fakes
  it with a oneshot — that worked, but if the missing behaviour is
  deeper than a sed-script, container is fine.
- **The app is upstream-hostile to native packaging.** Home Assistant
  is the canonical case — its add-on ecosystem and version churn
  don't fit the nixpkgs cadence.

When you do switch to a nix module, watch for these gotchas (all
encountered on the containerize-to-nixos-modules branch):

- **User/group override gating.** Jellyfin gates user creation behind
  `mkIf (cfg.user == "jellyfin")`, so overriding to `server-${env}`
  cleanly skips the module's user block. Kavita writes
  `users.users.${cfg.user}.group = cfg.user` unconditionally; with
  `cfg.user = "server-${env}"` that collides with `server-users.nix`
  setting `group = "servers"` on the same UID-pinned user. Resolve
  with `users.users.${kavitaUser}.group = lib.mkForce "servers";`.
  Read each module's `users.users` block before assuming the jellyfin
  pattern works.
- **Postgres connection style.** Mealie's
  `database.createLocally = true` + `DynamicUser=mealie` gets unix-socket
  peer auth for free (the dynamic username matches the role name); no
  password to plumb. Use this when the module's expected role name
  doesn't conflict with anything pre-existing. When it does (paperless's
  module wants role `paperless` but our existing role is `paperless_ngx`),
  keep `myPostgresApp` + TCP + sops password rather than triggering a
  destructive rename.
- **Multi-unit apps and OIDC env file restarts.** Apps that ship
  several systemd units consuming the same env file (paperless-{web,
  scheduler,task-queue,consumer}) need every unit listed in
  `myAuthentik.oidcApps.<app>.appRestartUnit` so all of them bounce on
  credential rotation. The option accepts a list.
- **Module-imposed `PrivateNetwork`.** Paperless's `database.createLocally`
  enables `PrivateNetwork=true` on scheduler/consumer. That's fine for
  workers (no OIDC traffic) but check what each unit actually does
  before relying on it.

## NFS UID alignment

Any service touching the NFS-mounted Synology share (`/mnt/content`,
`/mnt/backups`, …) must run as `server-${env}:servers` (UID 1029/1030,
GID 65536) — the NAS enforces UID-based access and a service running
under its own per-package user will silently see empty listings even
when the directory is mode 0777. This applies to native NixOS modules
too, not just containers: pin `services.<app>.user`/`.group` when the
module exposes them. After flipping ownership, `chown -R` any
pre-existing `/var/lib/<app>` state on the host once — the upstream
`tmpfiles` rules use type `d` and won't re-chown existing directories.
See `modules/apps/jellyfin.nix` for the pattern.

## Provisioning per-app secrets (`task secrets:*`)

Secrets live in the sibling repo at `../nix-secrets` (consumed as a
flake input). Run secret-management tasks from **this** repo — the
former `../nix-secrets/Taskfile.yaml` was rolled in as
`taskfiles/secrets.yaml` since the operator workflow always starts
from a nixos checkout. All tasks default to `HOST=hpp-1` (the homelab
server) and refuse to overwrite an existing key unless `FORCE=true`.

- `task secrets:oidc APP=<app>` — generates `client_id` (hex 16) and
  `client_secret` (hex 32) at `<app>.oidc_client_id` /
  `<app>.oidc_client_secret` in `sops/<host>.yaml`. Use whenever
  wiring `myAuthentik.oidcApps.<app>`.
- `task secrets:dbpw APP=<app>` — generates `<app>.db_password` (hex 16).
  Use for any app whose postgres role is provisioned via
  `myPostgresApp` with TCP + password (i.e. not unix-socket peer auth
  / `createLocally`).
- `task secrets:secret APP=<app> KEY=<key> [LEN=<bytes>]` — generic
  high-entropy hex at `<app>.<key>`. Use for app-specific tokens
  (session keys, signing secrets, API keys).
- `task secrets:edit:<host>` / `task secrets:view:<host>` — open or
  print a host's decrypted yaml. Use `edit` for non-random values
  (e.g. pasted-in API keys from a provider).
- `task secrets:rekey` — re-encrypts every file against current
  `.sops.yaml`; run after changing the key registry.
- `task secrets:publish MSG="..."` — commits + pushes pending changes
  in `../nix-secrets`, then runs `nix flake update nix-secrets` here.
  No-ops on a clean tree / already-pushed branch, so it's also safe
  to run defensively before a deploy.

Workflow when adding a new app that needs secrets:

1. Decide which secrets the app needs (OIDC creds, db password,
   app-specific tokens).
2. Run the matching task(s). Keys nest under the app name, so
   `sops.secrets."<app>/oidc_client_id"` /
   `sops.placeholder."<app>/db_password"` etc. in the nixos module
   resolve directly.
3. Run `task secrets:publish MSG="add <app> secrets for <host>"` to
   commit + push `nix-secrets` and bump the flake input here. After
   that the new secrets are usable in a deploy.

Don't invent ad-hoc key names — stick to `oidc_client_id`,
`oidc_client_secret`, `db_password` so existing app modules
(`tandoor.nix`, `paperless-ngx.nix`, etc.) remain a copy-paste
template. Reach for `task secrets:secret` only when the app genuinely
needs something beyond those three.

## Recovery tasks: keep the per-app list in sync

`taskfiles/recovery.yaml` has a dispatcher per server-app. When you
add a new app under `modules/apps/`, add a matching
`recovery:<app>` task in the same PR and append it to `recovery:all`'s
cmd list (the catastrophic-rebuild aggregate). Pick the template that
matches the app's shape:

| Shape (how the module is built) | Template | What to fill in |
|---|---|---|
| Container, no postgres | `_restore-volume` | `UNITS=podman-<app>.service`, `PATHS` = every persistent volume (typically `/var/lib/containers/<app>` plus any out-of-tree mount) |
| Container + `myPostgresApp.<app>` | `_restore-pg` | `UNITS=podman-<app>.service`, `DB=<app>` (or the `dbName` override — hyphens become underscores), `PATHS` = volumes outside `/var/backup/postgresql` |
| Native + `myPostgresApp.<app>` | `_restore-pg` | `UNITS` = every unit in `myPostgresApp.<app>.consumerService`, `DB=<role>`, `PATHS=/var/lib/<app>` (or `/var/lib/private/<app>` for DynamicUser modules) if the app has on-disk state |
| Native + `mySqliteQuiesce.apps.<app>` | `_restore-sqlite` | `UNITS=<app>.service`, `PATHS=/var/lib/<app> /var/backup/sqlite/<app>`, `SWAPS` = one triple `<staged>:<live>:<owner>` per file in `mySqliteQuiesce.apps.<app>.databases`. Use `@env@` as the owner sentinel when the app runs as `server-${env}` — the template substitutes the live username from `/etc/passwd` at execution time. |
| Native, no postgres or quiesce | `_restore-volume` | `UNITS=<app>.service`, `PATHS=/var/lib/<app>` |
| Timer-driven oneshot container (e.g. spierscraper) | `_restore-volume` | `UNITS=''` (nothing to stop), `PATHS` = its state dir |

For apps with an HTTP endpoint, append a `_health` task after the
restore so the dispatcher exits non-zero on a botched restore. See
`recovery:jellyfin` (60-retry, longer warm-up) or `recovery:miniflux`
(`/healthcheck`) for the two main patterns.

The `expectedPreservedDirs` list in
`modules/profiles/server-apps.nix` is the structural analogue —
forcing a manual edit when adding state to a native app. Recovery
dispatchers and that list should grow together.

### `restartUnits` goes on the template, not the secret

When an app declares its own `sops.templates."<app>.env"` (i.e. it's
not threaded through `myAuthentik.oidcApps`), put `restartUnits` on
the **template only** — not on the underlying `sops.secrets.<key>`,
not on both. The template is what the consumer reads via
`environmentFile` / `EnvironmentFile`, and sops-nix re-renders it
whenever any referenced placeholder's source changes — so a single
declaration on the template captures every rotation path. Putting
it on the secret is redundant; splitting it across both is a
"did I update both?" footgun the next time keys change.

Exceptions:
- Aggregators (`myPostgresApp`, `myAuthentik.oidcApps`) already attach
  `restartUnits` to the secrets they own — leave those alone. The rule
  applies to per-app env templates declared inline in the app module.
- When a secret is consumed directly (via `config.sops.secrets.<k>.path`
  in a oneshot or `ExecStart`) rather than through a template, the
  restart trigger has to go on the secret because there's no template
  to bind it to. `paperless-ngx.nix`'s `paperless-secret-key-init`
  oneshot is the example.

Existing modules that have it on both the secret and the template
(`readeck.nix`, `manyfold.nix`, `pinchflat.nix`, `valheim.nix`) are
not broken — converge them to template-only on drive-by edits rather
than a dedicated cleanup pass. Closes #142.

## Authentik notes

- Deployed via `nix-community/authentik-nix` (flake input `authentik-nix`),
  *not* containers — see README "Authentik (SSO)" for the rationale and
  the per-app onboarding pattern.
- **Don't use `pkgs.symlinkJoin` for `blueprints_dir`.** Authentik's
  `retrieve_file` resolves paths and rejects anything outside the
  configured `blueprints_dir`; symlinkJoin's top-level entries dereference
  back to upstream / source store paths and every blueprint apply fails
  with "Invalid blueprint path". `modules/apps/authentik.nix` uses
  `pkgs.runCommandLocal` + `cp -rL` to materialize real files.
- **`@serverDomain@` substitution is per-contributor, not at merge
  time.** OIDC blueprint dirs are pre-rendered by `renderedBlueprintDir`
  in `modules/apps/authentik.nix` before they hit `extraBlueprints`;
  `fwBlueprintDir` interpolates the domain into the Nix string directly.
  The merge step (also in `modules/apps/authentik.nix`) is a pure
  `cp -rL` stack with no `sed` pass — that pass mangled unrelated YAML
  values that happened to contain the literal string (closes #154). If
  you add a new way of contributing blueprints, do substitution at the
  contribution site if those files use the placeholder.
- Blueprint secrets (`password`, `client_secret`, token `key`) go through
  `!Env VAR_NAME`. The var must be present in the `EnvironmentFile`
  consumed by the *worker* (the worker is what applies blueprints, not
  just the server). The authentik-nix module already wires the same
  `environmentFile` to all three units, so adding to
  `sops.templates."authentik.env"` is sufficient.
- Don't override `authentik-nix`'s `nixpkgs` via `inputs.follows` — its
  README warns this breaks pinned python deps. Let it use its own
  locked nixpkgs.
- Authentik blueprints use custom YAML tags pyyaml can't safe-load.
  `modules/flake/git-hooks.nix` excludes `^modules/apps/authentik-blueprints/`
  from the `check-yaml` hook; extend the `excludes` list when adding new
  blueprint dirs.
- `services.authentik.createDatabase = true` (default) merges
  `authentik` into the shared postgres via `ensureDatabases` /
  `ensureUsers` and connects over the unix socket with peer auth — no
  password required for the role. Don't add a `db_password` sops secret
  for it.
- Reference: [model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
  [YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).
