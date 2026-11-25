# Fetch hashes are regenerated in CI

The procedure, the rationale (#625, #936) and the list of build-derived
markers live in the [fetch hashes runbook](../runbooks/fetch-hashes.md). The
rules an agent must follow:

- **Never hand-maintain a fixed-output hash.** A stale `hash` doesn't fail the
  build; nix finds the old path in a warm store and silently builds the old
  source. After editing any `version`/`tag`/`rev` pin, run `task hashes` (or
  `task hashes -- --check` to only report).
- **A new hash only a build can reveal** (`cargoHash`, `npmDepsHash`, vendored
  trees, coding-sandbox bundle sources) needs a `# regen-hash: <flake attr>`
  comment on the line directly above the `hash`, naming an attribute the
  script can build. Add it to the runbook's marker table.
- **Don't trust a host to notice.** Hosts substitute from hpp-1's store, so a
  stale hash never fails there either.
- **Leave the deliberately manual pins alone** (`fetchPypi`, and the
  `automerge: false` caddy and HA-component rules); the runbook says why.
