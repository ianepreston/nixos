# Server app conventions

How a server app module under `modules/apps/` is put together. The README's
[Server App Pattern](../README.md#server-app-pattern) introduces the shape;
the option types and defaults each bullet relies on are in the generated
[option reference](reference/options.md); the end-to-end procedure for a new
app is the [`add-app` workflow](../skills/add-app/SKILL.md), and agent-specific
packaging rules are in [app-packaging.md](agents/app-packaging.md).

## Conventions

- **Registration:** `flake.modules.nixos.<appname>`, then add the name to the
  `imports` list in `modules/profiles/server-apps.nix`.
- **Container runtime:** `virtualisation.oci-containers` with the podman backend
  (rootful — see `modules/system/oci-containers.nix`). Containers drop
  privileges via `user = "${serverUid}:${serverGid}"` so files on NFS-mounted
  volumes line up with the Synology UID/GID (1029/1030 + 65536).
- **NFS UID alignment (containers AND native services):** anything that reads or
  writes the NFS-mounted Synology share (under `/mnt/content`, `/mnt/backups`,
  etc.) must run as `server-${env}:servers` (1029/1030 + 65536). The NAS
  enforces UID-based access — a service running as its own per-package system
  user (e.g. the upstream jellyfin module's default `jellyfin:jellyfin`) will
  silently see an empty directory listing on the NFS mount. For native modules
  that expose `user`/`group` options (jellyfin, etc.), pin them to
  `server-${hostSpec.serverEnvironment}` and `servers`. Existing
  `/var/lib/<app>` state created with the wrong owner needs a one-time
  `sudo chown -R server-<env>:servers` on first deploy — `tmpfiles` rules with
  type `d` won't re-chown an existing directory.
- **Networking:** bind container ports to `127.0.0.1` only — Caddy fronts
  everything externally. Containers reach host services (e.g. postgres) via
  `host.containers.internal`, which resolves to the podman bridge gateway; the
  bridge is in `networking.firewall.trustedInterfaces`.
- **Reverse proxy:** add a `myCaddy.apps.<name>` entry inside the same module —
  `host` defaults to `<name>.${hostSpec.serverDomain}` and `routeConfig` is the
  body of the `handle` block (typically a `reverse_proxy localhost:<port>`
  directive). The wildcard vhost in `modules/system/caddy.nix` folds these into
  one matcher per app, so one wildcard cert (DNS-01 via Cloudflare) covers them
  all.
- **Image versions:** pin the tag in the module and put a renovate annotation
  above it so updates are automated:
  ```nix
  # renovate: datasource=docker depName=ghcr.io/bookorbit/bookorbit
  image = "ghcr.io/bookorbit/bookorbit:3.9.0";
  ```
- **Volumes:** state lives under `/var/lib/containers/<appname>`. Declare its
  directories in `myContainerApp.<name>.stateDirs`; the helper creates the
  tmpfiles rules and contributes those paths to backup. Bind-mount them into
  the container. Container-wide preservation is separate (see
  [backups and restore](runbooks/backup-restore.md)).
- **Postgres:** declare
  `myPostgresApp.<name>.consumerService = [ "podman-<app>.service" ];` (list
  every unit that consumes the role). The helper in
  `modules/system/postgresql.nix` handles the database/role via `ensureDatabases`/`ensureUsers`, the sops secret, and
  the rotate-on-secret-change oneshot wired `before` the consumer unit. The app
  is responsible for plumbing `${config.sops.placeholder."<app>/db_password"}`
  into its own env file (e.g. as `POSTGRES_PASSWORD`) and pointing the upstream
  container at `host.containers.internal:5432` with the matching role and
  database name; native services can use `127.0.0.1:5432`.
- **UI-stored config can silently beat the module.** Several apps keep a
  settings row in their own database and prefer it over the environment —
  paperless-ngx's AI configuration page is `app_config.X or settings.X` for
  every field, and Home Assistant's `.storage` behaves the same way. Where an
  app has both surfaces, configure it from the module and leave the UI page
  empty; a value saved there wins over the declarative one and does not show up
  in a diff.
- **Secrets:** declare per-app entries under `sops.secrets."<app>/..."` with
  `sopsFile = hostSpec.sopsFile;`. For env vars the container needs, render a `sops.templates."<app>.env"` and pass it via
  `environmentFiles`; set `restartUnits = [ "podman-<app>.service" ]` so the
  container picks up rotated secrets.

## Operating containers

The systemd services that run containers (e.g. `podman-bookorbit.service`) are
root-owned, so use `sudo podman ps`, `sudo podman logs <name>`, etc. for
inspection. Rootless podman as your user works for ad-hoc containers you start
yourself, but it can't see the system-managed ones.
