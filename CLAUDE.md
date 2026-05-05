# Working in this repo

## Taskfile.yaml is the entry point

Common operations are defined in `Taskfile.yaml`. Read it before running ad-hoc
`nixos-rebuild` / `nix build` commands — there is usually a task that already
wires up the right flags (private-input overrides, target hosts, etc.).

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

## Module layout

- `modules/system/*.nix` — NixOS modules, registered as
  `flake.modules.nixos.<name>` and consumed via
  `inputs.self.modules.nixos.<name>`.
- `modules/profiles/*.nix` — composed bundles (e.g. `server.nix` imports
  `base`, `auto-rebuild`, `server-users`, `oci-containers`, `sops`, `ssh`).
- `modules/hosts/<host>.nix` — per-host `nixosConfiguration` wiring.
- `hostSpecs/<host>.nix` — declarative host metadata (hostname, environment,
  email). Schema lives in `hostSpecs/host-spec.nix`.

New modules need to be tracked by git (even just `git add -N`) before flake
evaluation will see them. This applies to non-`.nix` files referenced from
modules too (e.g. blueprint YAMLs under `modules/apps/authentik-blueprints/`)
— `nix eval` will error with "path … does not exist" until they're tracked.

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
