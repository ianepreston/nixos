# Manyfold - 3D model library manager (Rails + sidekiq + postgres + redis)
# Container; not in nixpkgs and a Rails app — exactly the case the
# "container is the fallback" rule covers. Single-image setup: the
# upstream image runs the web app and both sidekiq workers under s6,
# so no separate worker container is needed (see the upstream
# Procfile: rails / default_worker / performance_worker).
#
# Auth via myAuthentik.forwardAuthApps to start. Upstream does
# document native OIDC envs (OIDC_CLIENT_ID/_SECRET/_ISSUER/_NAME
# since v0.83.0) — once basic deployment is verified, this can
# migrate to myAuthentik.oidcApps with a blueprint (mealie pattern).
#
# Postgres via myPostgresApp (TCP + sops password — Rails apps read
# DATABASE_PASSWORD from env, no peer-auth path). Redis is a per-app
# named NixOS instance on 6380 — authentik already owns the unnamed
# instance on 6379, and sidekiq is heavy enough on redis that a
# shared logical DB is worse isolation than just running a second
# server. Binds 0.0.0.0 so the container can reach it via
# host.containers.internal -> 10.88.0.1; same pattern as
# mariadb/postgres in this repo. Host firewall blocks 6380 on
# external NICs and podman0 is in trustedInterfaces (see
# oci-containers.nix), so the practical surface is loopback + the
# bridge.
#
# Model library lives on the NFS share at /mnt/content/3d-models and
# the container PUID/PGID are pinned to server-${env}:servers so NFS
# UID checks pass. Container state (uploaded thumbnails, indices) is
# under /var/lib/containers/manyfold and rides the standard restic
# preservation; the NFS share itself is backed up by the NAS.
_: {
  flake.modules.nixos.manyfold =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      manyfoldHost = "manyfold.${hostSpec.serverDomain}";
      port = 3214;
      redisPort = 6380;
    in
    {
      myPostgresApp.manyfold.consumerService = [ "podman-manyfold.service" ];

      myAuthentik.forwardAuthApps.manyfold = {
        inherit port;
        displayName = "Manyfold";
        authentikGroup = "Users";
        # No upstream icon in dashboard-icons; fall back to the repo
        # favicon (same approach as kapowarr).
        iconUrl = "https://raw.githubusercontent.com/manyfold3d/manyfold/main/app/assets/images/logo.svg";
        homepage = {
          group = "Home";
          icon = "https://raw.githubusercontent.com/manyfold3d/manyfold/main/app/assets/images/logo.svg";
          description = "3D model library";
        };
      };

      # SECRET_KEY_BASE signs browser cookies; the upstream docs ask
      # for a 128-char random hex string. Lives alongside the DB
      # password in the host's sops yaml.
      sops.secrets."manyfold/secret_key_base" = {
        inherit (hostSpec) sopsFile;
        restartUnits = [ "podman-manyfold.service" ];
      };

      sops.templates."manyfold.env" = {
        content = ''
          DATABASE_PASSWORD=${config.sops.placeholder."manyfold/db_password"}
          SECRET_KEY_BASE=${config.sops.placeholder."manyfold/secret_key_base"}
        '';
        restartUnits = [ "podman-manyfold.service" ];
      };

      # Per-app redis on 6380 (loopback only). Sidekiq is busy enough
      # that giving it its own instance avoids both noisy-neighbour
      # latency on authentik's redis and the "did you migrate the
      # logical-db number?" footgun on upgrades.
      services.redis.servers.manyfold = {
        enable = true;
        port = redisPort;
        bind = "0.0.0.0";
        # Disable protected-mode: redis refuses non-loopback connections
        # when bind != 127.0.0.1 and no password is set. We rely on the
        # host firewall + podman0 trustedInterfaces instead — same trust
        # model the postgres/mariadb instances use on this host.
        settings.protected-mode = "no";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/manyfold 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/manyfold/config 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.manyfold = {
        # renovate: datasource=docker depName=ghcr.io/manyfold3d/manyfold
        image = "ghcr.io/manyfold3d/manyfold:0.143.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        # The image runs an s6 supervisor as root and gosus down to
        # PUID:PGID for the rails + sidekiq processes. Don't set
        # `user` here — it would short-circuit the entrypoint.
        volumes = [
          "/var/lib/containers/manyfold/config:/config"
          "/mnt/content/3d-models:/models"
        ];
        environment = {
          TZ = config.time.timeZone;
          PUID = toString serverUid;
          PGID = toString serverGid;

          DATABASE_ADAPTER = "postgresql";
          DATABASE_HOST = "host.containers.internal";
          DATABASE_PORT = "5432";
          DATABASE_USER = "manyfold";
          DATABASE_NAME = "manyfold";

          REDIS_URL = "redis://host.containers.internal:${toString redisPort}/0";

          MULTIUSER = "enabled";
          HTTPS_ONLY = "enabled";
          PUBLIC_HOSTNAME = manyfoldHost;
          PUBLIC_PORT = "443";
        };
        environmentFiles = [ config.sops.templates."manyfold.env".path ];
      };
    };
}
