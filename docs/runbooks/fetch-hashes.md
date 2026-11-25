# Fetch Hashes Are Regenerated in CI

This is the authoritative procedure for fixed-output hashes. The agent rules
in [docs/agents/fetch-hashes.md](../agents/fetch-hashes.md) only point here.

## Why a stale hash is silent

Renovate rewrites a `version`, `tag` or `rev` and nothing else. The `hash` next
to it is a fixed-output derivation's _declared_ content address, and a stale one
does not fail: nix addresses the FOD by that hash, finds the path already in the
store, and skips the fetch — building the old source under the new label. That
is not a hole in the checks. It is structural, and it happened: a ha_blueair
bump merged with the previous hash in place, six checks green, and two hosts ran
the old code for two months (#625). The `check` jobs run on hpp-1, whose warm
`/nix/store` is precisely the store that cannot notice; only a store that has
never built the component fails, with `hash mismatch in fixed-output
derivation`.

**Hosts don't catch a stale hash either.** amos1, terra and luna substitute
from hpp-1's store (`modules/system/nix-cache.nix`, #936), and that's the store
CI just built into. A host that doesn't already hold the stale path (newly
enabled app, GC'd store) used to fail loudly fetching a mismatched source. Now
it pulls hpp-1's validly signed copy of the old content. The regen workflow and
`task hashes -- --check` are the only guard, so don't count on a host-side
mismatch to notice.

## How they are regenerated

`.github/workflows/renovate-hashes.yml` closes it from the other side: on every
`renovate/**` branch and the weekly `automated/flake-update` branch it
recomputes the hashes in the files that branch touched and pushes a fixup
commit, so the hash is right by construction rather than merely loud. A
`flake.lock` change rescans every file with a build-derived `regen-hash:`
marker, since nixpkgs can move those sources without touching their `.nix`
files. `scripts/regen-fetch-hashes.sh` does the work and is also the local
entry point: after editing a pin by hand, run `task hashes`, or
`task hashes -- --check` to report without rewriting. It covers two shapes:

- **`fetchFromGitHub`** blocks are found structurally, no annotation needed.
  The hash is the NAR hash of the unpacked `archive/<ref>.tar.gz`, which
  `nix-prefetch-url --unpack` reproduces exactly — one download, no build.
- **Hashes only a build can reveal** — vendored dependency trees and other
  derived sources — carry a `# regen-hash: <flake attr>` comment on the line
  directly above the `hash`. There is no URL to prefetch, so the script swaps
  in `lib.fakeHash`, builds that attribute, and takes the `got:` line out of
  the mismatch error. The marker names the attribute because nothing else in
  the file says where that derivation is reachable in the flake. Add that one
  line for any new `cargoHash` / `npmDepsHash` / vendor pin.

Build-derived markers in use (`rg -n '#\s*regen-hash:' modules` lists them):

| File | Pin | Marker attribute |
| ---- | --- | ---------------- |
| `modules/system/caddy.nix` | `pkgs.caddy.withPlugins` plugin closure | `nixosConfigurations.hpp-1.config.services.caddy.package.src` |
| `modules/apps/_acb/package.nix` | ACB wasm, `canada-acb` and web builds | `packages.x86_64-linux.acb-wasm`, `.acb-canada-acb`, `.acb-web` |
| `modules/apps/_valheim/bepinex-plugins.nix` | BetterNetworking10 and FiresGhettoNetworking sources | `nixosConfigurations.hpp-1.config.myValheim.availablePlugins.<plugin>.src` |
| `modules/programs/_coding-sandbox/bundles/databricks-cli.nix` | per-platform CLI archives | `legacyPackages.x86_64-linux.coding-sandbox-bundle-sources.databricks-cli.<system>` |

Coding-sandbox bundles aren't flake attributes, so a bundle returns its pinned
sources in `sources` and the marker names
`legacyPackages.x86_64-linux.coding-sandbox-bundle-sources.<bundle>.<key>`. A
fixed-output path depends only on its name and hash, so the x86_64 runner
regenerates other systems' hashes too (see `databricks-cli.nix`).

## Renovate details

Two supporting details in `renovate.json`. The custom managers' matches span
from the `# renovate:` comment through the `tag`/`rev` line, which lets
`autoReplaceGlobalMatch` (on by default) rewrite the version everywhere it
appears inside that span — the component's `version` attribute and its tag —
while deliberately stopping short of `hash`. And `gitIgnoredAuthors` lists the
identity the workflow commits as, because Renovate treats a branch carrying a
commit it didn't write as human-edited and stops updating it.

## Deliberately manual

`fetchPypi` pins (blueair-api's version is an `==` constraint from the
component's own `manifest.json`, which `manifestRequirementsCheckHook` enforces
at build time — loudly, which is the property everything else here is trying
to buy), and merging the caddy and HA-component PRs (`automerge: false` on
their renovate rules).
