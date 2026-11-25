# Authentik (SSO)

`modules/apps/authentik.nix` deploys Authentik as native systemd units via the
[`nix-community/authentik-nix`](https://github.com/nix-community/authentik-nix)
flake input — _not_ containers. The module's `services.authentik` runs three
units (`authentik`, `authentik-worker`, `authentik-migrate`) under
`DynamicUser=true`, talks to the shared postgres over the unix socket via peer
auth (so no role password is needed), and uses the unnamed NixOS
`services.redis.servers.""` instance on `localhost:6379`. Caddy fronts it at
`authentik.${hostSpec.serverDomain}`.

## Declarative configuration via blueprints

Groups, users, applications, OAuth/proxy providers, and group bindings are all
managed as Authentik **blueprints** (YAML, applied idempotently by the worker on
a periodic Celery task and on startup). No terraform, no UI clicks. Two starter
blueprints live under `modules/apps/authentik-blueprints/`:

- `groups.yaml` — homelab groups (Home, Infrastructure, Users).
- `users.yaml` — the `ian` admin user (in `authentik Admins`, Home,
  Infrastructure, Users) plus a few "Pattern A" onboarding users that have no
  `password` attr yet and authenticate after running through the recovery flow.
  `ian`'s password reads from `!Env IAN_PASSWORD`, which is rendered into the
  systemd `EnvironmentFile` from sops.
- `hardening.yaml` / `recovery.yaml` — bundled hardening and recovery flow
  tweaks.

The module merges its blueprints with the upstream-bundled set into a single
`blueprints_dir` via `pkgs.runCommandLocal` + `cp -rL`. **Do not use
`pkgs.symlinkJoin`** here: authentik's `retrieve_file` calls
`Path(...).resolve()` and rejects anything that resolves outside
`blueprints_dir`, so symlink-joined entries (which dereference back to their
original store paths) all fail with "Invalid blueprint path". Real files via
`cp -L` are required.

## Adding an OIDC app to Authentik

Apps that speak OIDC natively register via the `myAuthentik.oidcApps` aggregator
from `modules/apps/authentik.nix`. The aggregator generates the sops secret
pair, contributes the per-app blueprint dir, and stacks one merged worker-side
env file onto authentik so blueprint `!Env` placeholders resolve.

Miniflux, Komga, and Actual Budget use the aggregator's generated client-ID and
client-secret env vars. Tandoor and Paperless-ngx instead set
`clientCredsInAppEnv = false` and supply OIDC credentials in JSON settings
through `extraEnvLines`; they still consume the rendered per-app env file.
Tandoor remains a native env-file OIDC example. Apps that configure OIDC in
their own DB/UI (BookOrbit, Audiobookshelf, Seerr) also set
`clientCredsInAppEnv = false`, with no OIDC env file consumed by the app.
BookOrbit has a separate env template for its non-OIDC secrets.

Blueprint secrets must reference `!Env <APP>_OIDC_CLIENT_ID` /
`<APP>_OIDC_CLIENT_SECRET` (uppercased app name with hyphens → underscores) so
they never land in `/nix/store`.

Abridged aggregator wiring from
[`modules/apps/bookorbit.nix`](../../modules/apps/bookorbit.nix). The full module
also declares the container, database extensions, and a separate sops env
template for `DATABASE_URL`, `JWT_SECRET`, and `SETUP_BOOTSTRAP_TOKEN`.
BookOrbit's OIDC credentials are entered in Settings → OIDC / SSO, as described
in the module header; they do not go in the container env file.

```nix
# Excerpt from modules/apps/bookorbit.nix
_: {
  flake.modules.nixos.bookorbit = { ... }: {
    myPostgresApp.bookorbit.consumerService = [ "podman-bookorbit.service" ];

    myAuthentik.oidcApps.bookorbit = {
      blueprintsDir = ./bookorbit-blueprints;
      clientCredsInAppEnv = false;
      homepage = {
        group = "Consumption";
        icon = "bookorbit";
        description = "Ebook + audiobook library";
      };
      displayName = "BookOrbit";
    };

    myCaddy.apps.bookorbit = {
      # host defaults to "bookorbit.${hostSpec.serverDomain}"
      routeConfig = "reverse_proxy localhost:3017";
    };
  };
}
```

Abridged blueprint from
[`bookorbit.yaml`](../../modules/apps/bookorbit-blueprints/bookorbit.yaml):

```yaml
# modules/apps/bookorbit-blueprints/bookorbit.yaml
version: 1
metadata: { name: bookorbit }
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: prov-bookorbit
    identifiers: { name: bookorbit }
    attrs:
      client_type: confidential
      client_id: !Env BOOKORBIT_OIDC_CLIENT_ID
      client_secret: !Env BOOKORBIT_OIDC_CLIENT_SECRET
      grant_types: [authorization_code, refresh_token] # see note below — required on 2026.x
      authentication_flow:
        !Find [authentik_flows.flow, [slug, default-authentication-flow]]
      authorization_flow:
        !Find [
          authentik_flows.flow,
          [slug, default-provider-authorization-implicit-consent],
        ]
      invalidation_flow:
        !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      # ... property_mappings, redirect_uris, etc.
  - model: authentik_core.application
    id: app-bookorbit
    identifiers: { slug: bookorbit }
    attrs: { name: BookOrbit, provider: !KeyOf prov-bookorbit }
  - model: authentik_policies.policybinding
    identifiers: { target: !KeyOf app-bookorbit, order: 0 }
    attrs:
      group: !Find [authentik_core.group, [name, Users]]
      enabled: true
```

**Always set `grant_types` explicitly.** authentik 2026.x added
`OAuth2Provider.grant_types` (defaults to an empty list) and the authorize view
now rejects any flow whose grant isn't listed (`Invalid grant_type for provider`
→ the app sees a malformed-request error and bounces back to its login page).
Providers created under an older authentik were back-filled by the migration, so
the omission is invisible until a provider is created **fresh** on 2026.x — a
new app, a new host, or a `recovery:all` / `bootstrap:reinstall` rebuild (which
recreates every provider at once and would otherwise break all SSO
simultaneously). `[authorization_code, refresh_token]` is authentik's own UI
default and the right value for every app here, including `public`/PKCE clients
(grimmory). This bit komga on amos1 — see the blueprint comments for the full
trace.

Reference:
[model fields](https://docs.goauthentik.io/customize/blueprints/v1/models),
[YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags).

## Forward-auth via Caddy

For apps that don't speak OIDC themselves (AlertManager, Prometheus,
Longhorn-style admin UIs), gate them via Authentik's embedded outpost + Caddy's
`forward_auth`. Register the app via `myAuthentik.forwardAuthApps.<name>` — the
aggregator emits the proxy provider + application + policy binding into a single
merged blueprint per host (so two forward-auth apps don't clobber the embedded
outpost's global `providers` list) **and** wires a Caddy route that imports the
reusable `(authentik_forward_auth)` snippet:

```nix
myAuthentik.forwardAuthApps.alertmanager = {
  port = 9093;
  displayName = "Alertmanager";
  authentikGroup = "Infrastructure";   # default
  homepage = {                          # optional
    group = "Infrastructure";
    icon = "alertmanager";
    description = "Alert routing";
  };
};
```

The snippet (defined in `modules/apps/authentik.nix`) handles both the
`forward_auth` directive (auth check on every request) and the
`handle /outpost.goauthentik.io/*` block (callback routes).

## YAML lint exclusion

Authentik's custom YAML tags (`!Env`, `!Find`, `!KeyOf`) aren't accepted by
pyyaml's safe loader, so `modules/apps/authentik-blueprints/` is excluded from
the `check-yaml` pre-commit hook in `modules/flake/git-hooks.nix`. Add new
blueprint paths under that prefix or extend the excludes list.
