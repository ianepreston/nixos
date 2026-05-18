# ReadMeABook - audiobook request + automation engine
# Container; OIDC against authentik gated to the Users group. The
# unified image (`ghcr.io/kikootwo/readmeabook`) bundles postgres +
# redis + node under supervisord and uses gosu to drop from root to
# PUID:PGID, so the container runs as root and we set PUID/PGID rather
# than `--user`.
#
# We *don't* run the bundled postgres / redis — they're a packaging
# convenience for compose users, not an isolation requirement. The
# entrypoint detects `DATABASE_URL` / `REDIS_URL` in the env and exports
# `USE_EXTERNAL_POSTGRES=true` / `USE_EXTERNAL_REDIS=true`, which makes
# the supervisord `postgres-start.sh` / `redis-start.sh` children
# `exec sleep infinity` instead of starting their service. That gives
# us the shared postgres role + a native NixOS redis under journald,
# both backed up by the same machinery as every other app on this host
# — and avoids the original gosu/UID-mapping issues that were causing
# pg_filenode.map permission failures and redis MISCONF errors when the
# bundled services tried to coexist inside one container.
#
# Postgres via myPostgresApp (TCP + sops `readmeabook/db_password`).
# Redis via per-app `services.redis.servers.readmeabook` on 6381
# (authentik = 6379, manyfold = 6380); same loopback + bridge trust
# model as manyfold's redis.
#
# ReadMeABook stores OIDC settings in its own postgres (configured
# via Settings → Authentication in the UI), so this module registers
# via myAuthentik.oidcApps with clientCredsInAppEnv = false.
#
# On first boot, complete the local-admin setup wizard, then under
# Settings → Authentication enable OIDC with Issuer
# `https://authentik.<serverDomain>/application/o/readmeabook/`,
# the client_id from `readmeabook/oidc_client_id` in sops, and the
# client_secret from `readmeabook/oidc_client_secret`. The first OIDC
# user to land becomes admin; subsequent users default to `user`.
#
# Audiobook library lives under `/mnt/content/audiobooks` to share
# with audiobookshelf. Downloads go to `/mnt/content/Downloads` so
# the *arr/sabnzbd containers see the same paths.
_: {
  flake.modules.nixos.readmeabook =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      readmeabookHost = "readmeabook.${hostSpec.serverDomain}";
      port = 3030;
      redisPort = 6381;
    in
    {
      myPostgresApp.readmeabook.consumerService = [ "podman-readmeabook.service" ];

      myAuthentik.oidcApps.readmeabook = {
        blueprintsDir = ./readmeabook-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Requests";
          icon = "audiobookshelf";
          description = "Audiobook requests";
        };
        displayName = "ReadMeABook";
      };

      # DATABASE_URL embeds the role password, so it has to come through
      # sops.templates rather than the plain `environment` attrset.
      sops.templates."readmeabook.env" = {
        content = ''
          DATABASE_URL=postgresql://readmeabook:${
            config.sops.placeholder."readmeabook/db_password"
          }@host.containers.internal:5432/readmeabook
          REDIS_URL=redis://host.containers.internal:${toString redisPort}/0
        '';
        restartUnits = [ "podman-readmeabook.service" ];
      };

      # Per-app redis on 6381 (loopback + podman bridge). Same trust
      # model as manyfold: host firewall blocks the port on external
      # NICs and podman0 is in trustedInterfaces, so practical surface
      # is loopback + the bridge. `protected-mode = no` is required
      # when bind != 127.0.0.1 with no password.
      services.redis.servers.readmeabook = {
        enable = true;
        port = redisPort;
        bind = "0.0.0.0";
        settings.protected-mode = "no";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/readmeabook 0750 root root -"
        "d /var/lib/containers/readmeabook/config 0750 root root -"
        "d /var/lib/containers/readmeabook/cache 0750 root root -"
      ];

      virtualisation.oci-containers.containers.readmeabook = {
        # Upstream only publishes `latest` and per-commit `sha-*` tags
        # to ghcr.io (no semver tags despite their GitHub releases), so
        # we pin to the digest of `latest` for reproducibility; renovate
        # tracks `latest` and bumps the digest on its own (see
        # renovate.json's digest manager).
        # renovate: datasource=docker depName=ghcr.io/kikootwo/readmeabook
        image = "ghcr.io/kikootwo/readmeabook:latest@sha256:7e061bea2611bf5314758b33ee86882a92b887e06fdc527964f54b643e0fdff0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/readmeabook/config:/app/config"
          "/var/lib/containers/readmeabook/cache:/app/cache"
          "/mnt/content/Downloads:/downloads"
          "/mnt/content/audiobooks:/media"
        ];
        environment = {
          TZ = config.time.timeZone;
          PUID = toString serverUid;
          PGID = toString serverGid;
          PUBLIC_URL = "https://${readmeabookHost}";
        };
        environmentFiles = [ config.sops.templates."readmeabook.env".path ];
      };

      myCaddy.apps.readmeabook = {
        host = readmeabookHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
