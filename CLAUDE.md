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
evaluation will see them.
