# Fetch hashes are regenerated in CI

Renovate rewrites a `version`/`tag`/`rev` and nothing else. A stale `hash`
beside it doesn't fail the build: nix addresses the fixed-output derivation by
the declared hash, finds the old path already in the store, and silently builds
the old source (#625). The CI runner's warm store is exactly the store that
can't notice.

So don't hand-maintain them. `.github/workflows/renovate-hashes.yml` runs
`scripts/regen-fetch-hashes.sh` on every `renovate/**` branch and the weekly
`automated/flake-update` branch, then pushes a fixup commit. A `flake.lock`
change rescans every build-derived `regen-hash:` marker, since nixpkgs can
move those sources without touching their `.nix` files. After editing a pin by
hand, run `task hashes` (or `task hashes -- --check` to only report).

- **`fetchFromGitHub` blocks** are found structurally; no annotation needed
  (`nix-prefetch-url --unpack` reproduces the hash without a build).
- **Hashes only a build can reveal** (vendored dependency trees, e.g.
  `pkgs.caddy.withPlugins` in `modules/system/caddy.nix`) need a
  `# regen-hash: <flake attr>` comment on the line directly above the `hash`.
  The script swaps in `lib.fakeHash`, builds that attribute, and reads the real
  hash off the mismatch. Add that one line for any new `cargoHash` /
  `npmDepsHash` / vendor pin. Coding-sandbox bundles aren't flake attributes,
  so a bundle returns its pinned sources in `sources` and the marker names
  `legacyPackages.x86_64-linux.coding-sandbox-bundle-sources.<bundle>.<key>`.
  A fixed-output path depends only on its name and hash, so the x86_64 runner
  regenerates other systems' hashes too (see `databricks-cli.nix`).

Deliberately manual: `fetchPypi` pins (blueair-api's version comes from the
component's `manifest.json` and is enforced at build time by
`manifestRequirementsCheckHook`), and `automerge: false` on the caddy and
HA-component renovate rules.

**Hosts don't catch a stale hash either.** amos1, terra and luna substitute
from hpp-1's store (`modules/system/nix-cache.nix`, #936), and that's the store
CI just built into. A host that doesn't already hold the stale path (newly
enabled app, GC'd store) used to fail loudly fetching a mismatched source.
Now it pulls hpp-1's validly signed copy of the old content. The regen workflow and `task hashes -- --check` are the only
guard, so don't count on a host-side mismatch to notice.
