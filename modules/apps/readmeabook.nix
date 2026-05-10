# ReadMeABook - audiobook request + automation engine
# Container; OIDC against authentik gated to the Users group. The
# unified image (`ghcr.io/kikootwo/readmeabook`) bundles postgres +
# redis internally and uses gosu to drop from root to PUID:PGID at
# startup, so the container runs as root and we set PUID/PGID rather
# than `--user`. ReadMeABook stores OIDC settings in its own bundled
# postgres (configured via Settings → Authentication in the UI), so
# this module registers via myAuthentik.oidcApps with
# clientCredsInAppEnv = false.
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
    in
    {
      myAuthentik.oidcApps.readmeabook = {
        blueprintsDir = ./readmeabook-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Requests";
          icon = "audiobookshelf";
          description = "Audiobook requests";
        };
        homepageDisplayName = "ReadMeABook";
        homepageHref = "https://${readmeabookHost}";
      };

      systemd = {
        # Container runs as root and uses gosu to drop to PUID/PGID
        # for node + redis, while leaving postgres at UID 103. Leave
        # the parent dirs root-owned and let the entrypoint chown
        # children on first start.
        tmpfiles.rules = [
          "d /var/lib/containers/readmeabook 0750 root root -"
          "d /var/lib/containers/readmeabook/config 0750 root root -"
          "d /var/lib/containers/readmeabook/cache 0750 root root -"
          "d /var/lib/containers/readmeabook/pgdata 0750 root root -"
          "d /var/lib/containers/readmeabook/redis 0750 root root -"
        ];
      };

      virtualisation.oci-containers.containers.readmeabook = {
        # Upstream only publishes `latest` and per-commit `sha-*` tags
        # to ghcr.io (no semver tags despite their GitHub releases), so
        # we pin to the digest of `latest` at module-update time for
        # reproducibility. Bump the digest manually when upgrading.
        # renovate: datasource=docker depName=ghcr.io/kikootwo/readmeabook
        image = "ghcr.io/kikootwo/readmeabook@sha256:dbab6658743053955f1397216337cfe5eef412cbee4bb6e9ab7fbe8a3b5cb09a";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/readmeabook/config:/app/config"
          "/var/lib/containers/readmeabook/cache:/app/cache"
          "/var/lib/containers/readmeabook/pgdata:/var/lib/postgresql/data"
          "/var/lib/containers/readmeabook/redis:/var/lib/redis"
          "/mnt/content/Downloads:/downloads"
          "/mnt/content/audiobooks:/media"
        ];
        environment = {
          TZ = config.time.timeZone;
          PUID = toString serverUid;
          PGID = toString serverGid;
          PUBLIC_URL = "https://${readmeabookHost}";
        };
      };

      myCaddy.apps.readmeabook = {
        host = readmeabookHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
