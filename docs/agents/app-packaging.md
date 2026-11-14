# App packaging: prefer nixpkgs services over containers

Default to a native NixOS module (`services.<app>`) when nixpkgs has one.
Containers are the fallback, not the baseline: they add a podman layer, separate volume
bookkeeping under `/var/lib/containers/<app>`, and inter-app DNS that native
services don't need. Either way, [architecture.md](architecture.md) governs the
module's shape.

## Checking the nixpkgs version

Check both the stable channel the flake tracks and `nixos-unstable` (derive the
stable ref from `flake.nix`; don't hardcode it):

```sh
stable=$(grep -oE 'nixos-[0-9]+\.[0-9]+' flake.nix | head -1)
nix eval --raw "github:NixOS/nixpkgs/$stable#<app>.version"
nix eval --raw "github:NixOS/nixpkgs/nixos-unstable#<app>.version"
```

A couple of minor versions behind on stable is fine. A major-version regression
or a five-plus minor gap on both branches is a skip signal, though it's
acceptable for an app not yet in production. If unstable is much closer and you
need it, wire a per-package overlay rather than flipping the whole flake to unstable.

## Upstream flake with a NixOS module

Before falling back to a container, check whether upstream publishes a flake
with a NixOS module — the right call when the app will never be in nixpkgs
(sparkyfitness: non-commercial licence). You get a real systemd unit and normal
`services.<app>` options, at these costs:

- **A flake input on someone else's nixpkgs.** Don't `inputs.follows` ours onto
  it (same as `authentik-nix`). Expect a second closure.
- **Source builds** on every bump, possibly a fat closure (sparkyfitness ships
  a 765 MB `node_modules`).
- **No renovate tracking** (`renovate.json` disables nix). Bump by hand: move
  the pinned ref (`github:owner/repo/v1.7.1`) *and* run
  `nix flake update <input>` — evaluation reads `flake.lock`, not the URL.
- **Upstream may not test the nix path.** Tolerable because failure is a loud
  build error; if a release breaks it twice running, take the container.

Check any upstream module for:

- **Plain assignments where you'd expect `mkDefault`.** SparkyFitness's
  `database.createLocally` sets `services.postgresql.package` outright, which
  conflicts with our `postgresql_18` pin. Turn that branch off, use
  `myPostgresApp`, and re-add what the module's init did (`CREATEROLE` on the
  owner role, `ALTER SCHEMA public OWNER TO`).
- **`packages.${pkgs.system}` convenience wrappers.** `pkgs.system` is
  deprecated and warns on every eval. Import `nixosModules.default` and set the
  package options off `pkgs.stdenv.hostPlatform.system`.

## When a container is right

- **No nixpkgs module** (actualbudget, mylar3, readmeabook, shelfmark,
  bindery, grimmory). Re-check first — tandoor sat here while
  `services.tandoor-recipes` existed (#441).
- **The container is a fork the nix module doesn't track** (Seerr is the
  seerr-team fork; nixpkgs ships jellyseerr).
- **The image bakes in behaviour the nix package lacks** and it's deeper than a
  small oneshot can fake (home-operations sabnzbd applies
  `SABNZBD__HOST_WHITELIST_ENTRIES` on each start; our native module fakes it).
- **A plugin ecosystem assumes a container runtime you can't reproduce.**
  Verify rather than assume — Home Assistant moved native successfully.

## Native-module gotchas

- **User/group overrides.** Jellyfin gates user creation behind
  `mkIf (cfg.user == "jellyfin")`, so overriding to `server-${env}` cleanly
  skips it. Kavita sets `users.users.${cfg.user}.group = cfg.user`
  unconditionally, colliding with `server-users.nix`; fix with
  `users.users.${kavitaUser}.group = lib.mkForce "servers";`. Read each
  module's `users.users` block first.
- **Postgres connection style.** `database.createLocally = true` +
  `DynamicUser` (mealie) gets unix-socket peer auth for free when the role name
  doesn't collide. When it does (paperless wants `paperless`, ours is
  `paperless_ngx`), keep `myPostgresApp` + TCP + sops password instead of a
  destructive rename.
- **Multi-unit apps.** Every unit consuming the same OIDC env file
  (paperless-{web,scheduler,task-queue,consumer}) goes in
  `myAuthentik.oidcApps.<app>.appRestartUnit` (accepts a list).
- **Module-imposed `PrivateNetwork`.** Paperless's `createLocally` sets
  `PrivateNetwork=true` on scheduler/consumer — fine for workers; check what
  each unit does before relying on it.
- **A per-package unstable pin may also need the unstable module.** Paperless 3.x
  changed module and package together, so `paperless-ngx.nix` carries
  `disabledModules = [ "services/misc/paperless.nix" ]` plus the unstable
  module import (#526). Diff the two module files before assuming
  `package =` suffices, and bump `nixos-unstable` before writing a local
  workaround for an upstream bug.

## NFS UID alignment

Any service touching the Synology NFS shares (`/mnt/content`, `/mnt/backups`,
…) must run as `server-${env}:servers` (UID 1029/1030, GID 65536). The NAS
enforces UID-based access; a service under its own user silently sees empty
listings even on mode 0777. Pin `services.<app>.user`/`.group` on native
modules too. After changing ownership, `chown -R` existing `/var/lib/<app>`
once — upstream tmpfiles `d` rules don't re-chown. Pattern:
`modules/apps/jellyfin.nix`.

## Home Assistant

HA runs native (`modules/apps/homeassistant.nix`) on a `nixpkgs-unstable`
per-package overlay — stable freezes it for a year while HA ships monthly.

- Native only ships python deps for *declared* components, so adding a device
  is a config change: add it to `services.home-assistant.extraComponents`, or
  package a HACS-only integration as a `customComponents` entry via
  `buildHomeAssistantComponent` (bambu_lab, hoymiles_wifi, ha_blueair).
  Otherwise the UI config flow fails "Invalid handler specified".
- Custom-component versions are renovate-tracked (custom managers in
  `renovate.json`, automerge off); CI regenerates their hashes (see
  [fetch-hashes.md](fetch-hashes.md)). Their unpackaged python libs are pinned
  to each manifest's `requirements` and bumped by hand in lockstep.
- OIDC creds reach HA via `!secret` from a sops-rendered `secrets.yaml`.
  UI-authored automations/scripts/scenes are `!include` files seeded by
  `preStart`.
- `/var/lib/hass/.storage` doesn't merge between instances — pair devices on
  the target host; only `automations.yaml`/`scripts.yaml`/`scenes.yaml` port.
