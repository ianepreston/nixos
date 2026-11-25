# Fetch Hashes Are Regenerated in CI

Renovate rewrites a `version`, `tag` or `rev` and nothing else. The `hash` next
to it is a fixed-output derivation's _declared_ content address, and a stale one
does not fail: nix addresses the FOD by that hash, finds the path already in the
store, and skips the fetch — building the old source under the new label. That
is not a hole in the checks. It is structural, and it happened: a ha_blueair
bump merged with the previous hash in place, six checks green, and two hosts ran
the old code for two months. The `check` jobs run on hpp-1, whose warm
`/nix/store` is precisely the store that cannot notice; only a store that has
never built the component fails, with `hash mismatch in fixed-output
derivation`.

`.github/workflows/renovate-hashes.yml` closes it from the other side: on every
`renovate/**` branch it recomputes the hashes in the files that branch touched
and pushes a fixup commit, so the hash is right by construction rather than
merely loud. `scripts/regen-fetch-hashes.sh` does the work and is also the local
entry point (`task hashes`, or `task hashes -- --check` to report without
rewriting). It covers two shapes:

- **`fetchFromGitHub`** blocks are found structurally, no annotation needed.
  The hash is the NAR hash of the unpacked `archive/<ref>.tar.gz`, which
  `nix-prefetch-url --unpack` reproduces exactly — one download, no build.
- **Hashes only a build can reveal** — vendored dependency trees, today just
  the `pkgs.caddy.withPlugins` plugin closure — carry a
  `# regen-hash: <flake attr>` comment directly above the `hash`. There is no
  URL to prefetch, so the script swaps in `lib.fakeHash`, builds that attribute,
  and takes the `got:` line out of the mismatch error. The marker names the
  attribute because nothing else in the file says where that derivation is
  reachable in the flake; a future `cargoHash` or `npmDepsHash` pin joins in by
  adding that one line.

Two supporting details in `renovate.json`. The custom managers' matches span
from the `# renovate:` comment through the `tag`/`rev` line, which lets
`autoReplaceGlobalMatch` (on by default) rewrite the version everywhere it
appears inside that span — the component's `version` attribute and its tag —
while deliberately stopping short of `hash`. And `gitIgnoredAuthors` lists the
identity the workflow commits as, because Renovate treats a branch carrying a
commit it didn't write as human-edited and stops updating it.

Still manual on purpose: `fetchPypi` pins (blueair-api's version is an `==`
constraint from the component's own `manifest.json`, which
`manifestRequirementsCheckHook` enforces at build time — loudly, which is the
property everything else here is trying to buy) and merging the caddy and
HA-component PRs.
