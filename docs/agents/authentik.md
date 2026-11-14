# Authentik (SSO)

Deployed via `nix-community/authentik-nix` (flake input `authentik-nix`), not
containers — see README "Authentik (SSO)" for rationale and the per-app
onboarding pattern. The `myAuthentik.{oidcApps,forwardAuthApps}` surface lives
in `modules/apps/authentik.nix` beside the IDP.

- **`bypassAuthPaths` for key-gated APIs.** When registering
  `myAuthentik.forwardAuthApps.<app>`, declare `bypassAuthPaths` for routes the
  app gates with its own API key (`/api/*`, healthchecks, feeds), with a
  rationale comment like `modules/apps/radarr.nix`. Never bypass routes that
  serve data unauthenticated (gatus, pinchflat feeds) — omit the option and
  leave everything gated. Verify by curling the bypassed routes without a key:
  an app whose auth endpoint hands out its API key when no UI password is set
  must NOT bypass `/api/*`. Path lists differ per app (sabnzbd is exactly
  `/api`; prowlarr has no `/feed`), so keep them per-module.
- **Don't use `pkgs.symlinkJoin` for `blueprints_dir`.** Authentik's
  `retrieve_file` rejects paths resolving outside `blueprints_dir`, and
  symlinkJoin's entries dereference to other store paths ("Invalid blueprint
  path"). Use `pkgs.runCommandLocal` + `cp -rL`, as `authentik.nix` does.
- **Domain placeholder substitution happens per contributor, not at merge.**
  OIDC blueprint dirs are pre-rendered by `renderedBlueprintDir`;
  `fwBlueprintDir` interpolates the domain directly; the merge step is a plain
  `cp -rL` (a merge-time `sed` mangled unrelated YAML, #154). A new way of
  contributing blueprints must substitute at the contribution site.
  `renderedBlueprintDir` substitutes whole-file, comments included, so never
  spell the placeholder in blueprint prose — write "per-host domain
  placeholder" instead (#743).
- **Blueprint secrets** (`password`, `client_secret`, token `key`) use
  `!Env VAR_NAME`. The var must be in the *worker's* `EnvironmentFile` (the
  worker applies blueprints); authentik-nix wires one `environmentFile` to all
  three units, so adding it to `sops.templates."authentik.env"` suffices.
- **Don't override `authentik-nix`'s `nixpkgs`** via `inputs.follows` — it
  breaks its pinned python deps.
- **Blueprint YAML uses custom tags** pyyaml can't safe-load.
  `modules/flake/git-hooks.nix` excludes `^modules/apps/authentik-blueprints/`
  from `check-yaml`; extend `excludes` for new blueprint dirs.
- **Database:** `services.authentik.createDatabase = true` (default) uses the
  shared postgres over the unix socket with peer auth. Don't add a
  `db_password` secret for it.
- **Migrating an app from `forwardAuthApps` to `oidcApps`** leaves a stale
  ProxyProvider that hijacks the new OIDC provider and clobbers its
  redirect URIs; remove it with a `state: absent` blueprint entry (#428).
- Reference:
  [model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
  [YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).
