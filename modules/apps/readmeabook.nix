# ReadMeABook - audiobook request + automation engine
# Container; OIDC against authentik gated to the Users group. The
# unified image (`ghcr.io/kikootwo/readmeabook`) bundles postgres +
# redis internally and uses gosu to drop from root to PUID:PGID at
# startup, so the container runs as root and we set PUID/PGID rather
# than `--user`. ReadMeABook stores OIDC settings in its own bundled
# postgres (configured via Settings → Authentication in the UI), so
# this module only stages the authentik side (provider/application/
# policy binding via the blueprint, plus the env-file for the worker
# so `!Env` substitutions resolve).
#
# On first boot, complete the local-admin setup wizard, then under
# Settings → Authentication enable OIDC with Issuer
# `https://authentik.dnix.ipreston.net/application/o/readmeabook/`,
# the client_id from `readmeabook/oidc_client_id` in sops, and the
# client_secret from `readmeabook/oidc_client_secret`. The first OIDC
# user to land becomes admin; subsequent users default to `user`.
#
# Audiobook library lives under `/mnt/content/audiobooks` to share
# with audiobookshelf. Downloads go to `/mnt/content/Downloads` so
# the *arr/sabnzbd containers see the same paths.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
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
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "readmeabook/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
        "readmeabook/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
      };

      sops.templates."readmeabook-authentik.env" = {
        content = ''
          READMEABOOK_OIDC_CLIENT_ID=${config.sops.placeholder."readmeabook/oidc_client_id"}
          READMEABOOK_OIDC_CLIENT_SECRET=${config.sops.placeholder."readmeabook/oidc_client_secret"}
        '';
        restartUnits = restartAuthentik;
      };

      myAuthentik.extraBlueprints = [ ./readmeabook-blueprints ];

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

        services = {
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."readmeabook-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."readmeabook-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."readmeabook-authentik.env".path
          ];
        };
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

      myHomepage.services.Consumption = [
        {
          ReadMeABook = {
            href = "https://${readmeabookHost}";
            icon = "audiobookshelf";
            description = "Audiobook requests";
          };
        }
      ];
    };
}
