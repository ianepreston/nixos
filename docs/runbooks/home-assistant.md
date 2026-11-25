# Home Assistant

Home Assistant runs as the **native** `services.home-assistant`
(`modules/apps/homeassistant.nix`), not a container. That reverses the usual
"big, churny apps stay containerized" instinct, so the reasoning is worth
recording.

## Why native, and the real tradeoff

The original objection was that HA's python dependencies wouldn't fit the
nixpkgs cadence. That turned out to be wrong — Nix isolates HA's closure
cleanly. The genuine tradeoff is different:

- **Version currency.** HA ships ~monthly and its integrations track fast-moving
  cloud APIs; the stable channel freezes HA at a yearly snapshot. So the HA
  package (and its custom components) are pinned to `nixpkgs-unstable` via a
  per-package overlay (the `rgb.nix` pattern), while the rest of the system
  stays on stable. HA updates are therefore `nixos-rebuild`s, not Renovate
  image-tag bumps.
- **Integration declaration.** The container image bundles every integration's
  python deps, so "discover device → click Add" always worked. Native ships deps
  only for **declared** components. This is the one real recurring cost, and it
  lands on _experimentation_, not steady state — which suits a stable device set
  and buys a git-tracked, reproducible, reviewable integration inventory in
  exchange.

What native gives back: declarative OIDC (no HACS), the recorder on the shared
native postgres over a peer-auth socket, the DHCP/discovery integrations working
without container capability hacks, and custom integrations captured in git
instead of installed imperatively through HACS into a stateful volume.

## Adding a device — the recurring workflow

Auto-discovery still finds devices, but if the integration's python dep isn't
shipped the UI config flow fails
**`Config flow could not be loaded: Invalid handler specified`**. Two cases:

1. **Core integration** (in nixpkgs) — add its domain to
   `services.home-assistant.extraComponents` and deploy. Confirm the name is
   real first:

   ```sh
   nix eval --json "github:NixOS/nixpkgs/nixos-unstable#home-assistant.availableComponents" \
     --apply 'cs: builtins.elem "<domain>" cs'
   ```

2. **HACS-only integration** (no core module) — package it as a
   `customComponents` entry with `buildHomeAssistantComponent` (the `auth_oidc`
   / `bambu_lab` / `hoymiles_wifi` / `ha_blueair` pattern in the module). Any
   python lib nixpkgs lacks gets its own `buildPythonPackage`, pinned to the
   version the component's `manifest.json` `requirements` demands — the
   `manifestRequirementsCheckHook` fails the build otherwise.

Custom-component versions are Renovate-tracked via the `github-releases` `tag`
and `github-tags` rev-pin custom managers in `renovate.json`, kept **manual**
(grouped as "home-assistant custom components"). Each manager's match spans the
component's `version` line through its `tag`/`rev`, so Renovate rewrites the
same number in both places at once; CI then regenerates the `fetchFromGitHub`
hash (see [Fetch hashes](fetch-hashes.md)). What's left for
a human is the paired python lib: if the new manifest pins a different version,
bump the `buildPythonPackage` in the same PR. The libs themselves are
deliberately _not_ Renovate-tracked — they must move in lockstep with the
component, and the build fails loudly until they do.

## Config: declarative vs. stateful

`configuration.yaml` is Nix-managed and immutable (`default_config`,
`http.trusted_proxies`, `recorder.db_url`, `auth_oidc`). OIDC creds reach it
through HA's `!secret` tag from a sops-rendered `secrets.yaml` symlinked into
the config dir. UI-authored automations/scripts/scenes are file-based `!include`
targets, seeded empty by the service `preStart` (race-free, never clobbered) so
UI edits persist.

Everything with an **"Add" button** in the UI — paired devices, integrations —
is stateful and lives in `/var/lib/hass/.storage`, keyed by internal UUIDs. That
state does **not** merge between instances: do device pairing directly on the
target host rather than trying to sync a dev instance into prod. The only
cleanly portable Tier-2 artifacts are the `automations.yaml` / `scripts.yaml` /
`scenes.yaml` files (plain YAML; each automation needs a unique `id` and
entity_ids that exist on the target).
