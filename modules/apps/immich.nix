# Immich - self-hosted photo and video backup
# Native services.immich from nixpkgs. Multiple systemd units:
#   * immich-server.service           - REST API + web UI
#   * immich-machine-learning.service - face/object/CLIP search (ML)
#
# The ML model is bundled with the nixpkgs `services.immich` module
# (machine-learning.enable defaults to true), so we do NOT need a
# separate container for it — closes the "ML container" deferral the
# issue called out as a potential gap.
#
# Storage:
#   * State (config, generated thumbnails, transcoded video cache,
#     ML model cache) → /var/lib/immich (local disk).
#   * Media (originals) → /mnt/content/photos (NFS-mounted Synology).
#
# NFS UID alignment: media on /mnt/content is enforced by the NAS via
# UID, so immich runs as the shared `server-${env}:servers` user
# instead of the module's default `immich:immich`. The module's user
# creation is gated behind `mkIf (cfg.user == "immich")` (same
# pattern as jellyfin), so overriding cleanly skips it.
#
# Postgres: immich needs postgres extensions (vector / vchord / cube
# / pg_trgm / earthdistance / unaccent / uuid-ossp), which the
# upstream module wires into `services.postgresql` when
# `database.enable = true`. We keep that on (the module is the
# authoritative source for which extensions / shared_preload_libraries
# / post-start CREATE EXTENSION lines are needed) and just point it
# at TCP+password — peer auth would require the system user to match
# the postgres role name, but our system user is server-${env}, not
# immich. The DB role itself is still `immich` (default), provisioned
# by the upstream module via ensureDatabases / ensureUsers; the
# myPostgresApp helper takes responsibility for setting that role's
# password from sops on every rotation.
#
# Redis: the upstream module always creates a per-app instance
# (`services.redis.servers.immich`) when `cfg.redis.enable = true` so
# we automatically get isolation from authentik's unnamed redis on
# 6379. We override to TCP on 6381 (rather than the module-default
# unix socket) per the issue spec — keeps the wire format consistent
# with what other apps on the host might want to look at later.
#
# OIDC: immich configures OAuth via its admin UI (Settings → OAuth),
# not via env vars — the values are stored in the immich database
# once entered. So this module only stages the authentik side
# (provider + application + policy binding via blueprint) and the
# admin enters client_id / client_secret in the immich UI on first
# login. Same pattern as audiobookshelf / kavita / seerr.
_: {
  flake.modules.nixos.immich =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      immichHost = "immich.${hostSpec.serverDomain}";
      port = 2283;
      redisPort = 6381;
      immichUser = "server-${hostSpec.serverEnvironment}";
    in
    {
      myPostgresApp.immich.consumerService = "immich-server.service";

      myAuthentik.oidcApps.immich = {
        blueprintsDir = ./immich-blueprints;
        # immich reads OAuth client_id/secret from its own database
        # (admin UI), not env vars. The per-app env file still gets
        # generated (we use it for DB_PASSWORD via extraEnvLines), but
        # the OIDC creds don't go through it.
        clientCredsInAppEnv = false;
        appRestartUnit = "immich-server.service";
        extraEnvLines = ''
          DB_PASSWORD=${config.sops.placeholder."immich/db_password"}
        '';
        homepage = {
          group = "Home";
          icon = "immich";
          description = "Photo backup";
        };
        homepageDisplayName = "Immich";
        homepageHref = "https://${immichHost}";
      };

      services.immich = {
        enable = true;
        host = "127.0.0.1";
        inherit port;
        user = immichUser;
        group = "servers";
        mediaLocation = "/mnt/content/photos";

        # Keep the upstream module's DB extension wiring (vchord +
        # search_path + post-start CREATE EXTENSION) but turn off its
        # role/db provisioning. We've already got an `immich` entry
        # in ensureUsers from myPostgresApp (which also rotates the
        # password from sops) — letting the upstream module add a
        # second ensureUsers entry with login=true causes
        # postgresql-setup to try to apply two non-identical role
        # definitions in sequence on each start. Forced onto TCP +
        # password since the system user (server-${env}) doesn't
        # match the postgres role name (immich), so peer auth is off
        # the table.
        database = {
          enable = true;
          createDB = false;
          host = "127.0.0.1";
          port = 5432;
          name = "immich";
          user = "immich";
        };

        # Per-app redis instance on TCP/6381. The module creates
        # services.redis.servers.immich automatically when
        # `cfg.redis.enable = true`; setting `redis.port` non-zero
        # flips it to TCP, and `redis.host = "127.0.0.1"` makes it
        # bind to loopback.
        redis = {
          enable = true;
          host = "127.0.0.1";
          port = redisPort;
        };

        # Re-use the per-app env file myAuthentik already builds for
        # us (contains DB_PASSWORD via extraEnvLines above). Setting
        # `secretsFile` is mandatory whenever the postgres connection
        # isn't a unix socket (the module asserts this).
        secretsFile = config.sops.templates."immich.env".path;

        # `settings = null` keeps immich fully UI-configurable
        # (matching the audiobookshelf / kavita pattern). OAuth gets
        # set up via the admin UI on first run.
        settings = null;
      };

      # The upstream module sets a tmpfiles `e` rule on mediaLocation
      # forcing mode 0700 + user/group ownership. On an NFS-mounted
      # share with NAS-defined perms that chmod call would either
      # fail or fight the NAS. Drop the immich tmpfiles entry; the
      # mount point already exists with appropriate UIDs from the
      # NAS side. State dir under /var/lib/immich is still created
      # via systemd's StateDirectory regardless.
      systemd.tmpfiles.settings.immich = lib.mkForce { };

      # Preservation defaults to root:root mode 0755, but immich
      # writes its state dir at startup under the configured user
      # and StateDirectory mode 0700. Match the service user/group
      # so the bind-mount root is owned correctly.
      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/immich";
          user = immichUser;
          group = "servers";
          mode = "0700";
        }
      ];

      # Photos themselves live on the NAS (separate backup story);
      # restic only needs the local state dir (thumbnails, config,
      # ML model cache — small).
      services.restic.backups.server.paths = [ "/var/lib/immich" ];

      myCaddy.apps.immich = {
        host = immichHost;
        routeConfig = ''
          # Immich's mobile clients upload originals through the same
          # endpoint; bump the request body limit so multi-hundred-MB
          # videos / RAWs don't get rejected.
          request_body {
            max_size 50000MB
          }
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
