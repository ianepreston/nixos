# BookOrbit - self-hosted ebook / audiobook / comic library + reader
# Container; not in nixpkgs (NestJS + Vue, semver git tags but only a
# rolling `latest` / per-commit `sha-*` on ghcr) — the "container is the
# fallback" rule applies. The upstream image runs as root, repairs
# ownership of /data, then drops to PUID:PGID, so we pin those to
# server-${env}:servers for NFS UID alignment (the library lives on the
# Synology share at /mnt/content/books, same path komga/kavita read).
#
# Postgres via myPostgresApp (TCP + sops `bookorbit/db_password`). The
# app needs the `uuid-ossp`, `pg_trgm`, and `vector` (pgvector)
# extensions present in its database. pg_trgm / uuid-ossp ship with the
# base postgresql package; vector comes from the pgvector plugin wired
# into services.postgresql.extensions below. None of the three are
# "trusted" extensions, so `CREATE EXTENSION` needs superuser — the
# bookorbit-db-extensions oneshot pre-creates them as the postgres
# superuser before the container starts (the app's own migrations then
# `CREATE EXTENSION IF NOT EXISTS` as no-ops).
#
# OIDC is configured in the app UI (Settings -> OIDC / SSO) and stored
# in bookorbit's own postgres, not via env — so this registers via
# myAuthentik.oidcApps with clientCredsInAppEnv = false (audiobookshelf /
# kavita / readmeabook pattern). After first boot, complete the local
# admin setup (the SETUP_BOOTSTRAP_TOKEN is sent as the x-setup-token
# header by the setup wizard), then under Settings -> OIDC / SSO add a
# provider with:
#   Issuer:        https://authentik.<serverDomain>/application/o/bookorbit/
#   Client ID:     bookorbit/oidc_client_id     (in sops)
#   Client secret: bookorbit/oidc_client_secret (in sops)
# The redirect URI bookorbit uses is https://bookorbit.<serverDomain>/oauth2-callback
# (matched strictly by the blueprint provider).
#
# The image runs read-only with a dropped cap set (see the compose
# upstream ships); we replicate that hardening via extraOptions.
_: {
  flake.modules.nixos.bookorbit =
    {
      config,
      hostSpec,
      ...
    }:
    let
      bookorbitHost = "bookorbit.${hostSpec.serverDomain}";
      # 3000 is grafana's on the server hosts; pick a free port and let
      # the container's PORT match it (publish + caddy + app all agree).
      port = 3017;
    in
    {
      myPostgresApp.bookorbit.consumerService = [ "podman-bookorbit.service" ];

      myAuthentik.oidcApps.bookorbit = {
        blueprintsDir = ./bookorbit-blueprints;
        # OIDC creds are entered in the app UI and persisted in bookorbit's
        # own postgres, so no client_id/secret in the app env.
        clientCredsInAppEnv = false;
        homepage = {
          group = "Consumption";
          icon = "bookorbit";
          description = "Ebook + audiobook library";
        };
        displayName = "BookOrbit";
      };

      sops = {
        # JWT_SECRET signs login tokens; SETUP_BOOTSTRAP_TOKEN gates the
        # one-time /auth/setup endpoint. Declared here so the env
        # template's placeholders resolve; restartUnits lives on the
        # template only.
        secrets."bookorbit/jwt_secret".sopsFile = hostSpec.sopsFile;
        secrets."bookorbit/setup_bootstrap_token".sopsFile = hostSpec.sopsFile;

        # DATABASE_URL embeds the role password, so it (and the two app
        # secrets) come through sops.templates rather than plain env.
        templates."bookorbit.env" = {
          content = ''
            DATABASE_URL=postgres://bookorbit:${
              config.sops.placeholder."bookorbit/db_password"
            }@host.containers.internal:5432/bookorbit
            JWT_SECRET=${config.sops.placeholder."bookorbit/jwt_secret"}
            SETUP_BOOTSTRAP_TOKEN=${config.sops.placeholder."bookorbit/setup_bootstrap_token"}
          '';
          restartUnits = [ "podman-bookorbit.service" ];
        };
      };

      # Make the pgvector .so available to the shared cluster. uuid-ossp
      # and pg_trgm are bundled with the base postgresql package.
      services.postgresql.extensions = ps: [ ps.pgvector ];

      # Pre-create the three extensions in bookorbit's db as the postgres
      # superuser (none are trusted, so the unprivileged role can't).
      systemd.services.bookorbit-db-extensions = {
        description = "Create required postgres extensions in the bookorbit database";
        after = [
          "postgresql.service"
          "postgresql-setup.service"
          "bookorbit-db-password.service"
        ];
        requires = [ "postgresql.service" ];
        wants = [ "postgresql-setup.service" ];
        wantedBy = [ "podman-bookorbit.service" ];
        before = [ "podman-bookorbit.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          set -euo pipefail
          ${config.services.postgresql.package}/bin/psql -d bookorbit -v ON_ERROR_STOP=1 <<'SQL'
          CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          CREATE EXTENSION IF NOT EXISTS vector;
          SQL
        '';
      };

      myContainerApp.bookorbit = {
        inherit port;
        linuxServer = true;
        stateDirs = [
          "/var/lib/containers/bookorbit"
          "/var/lib/containers/bookorbit/data"
        ];
      };

      virtualisation.oci-containers.containers.bookorbit = {
        # Upstream publishes semver git releases but only a rolling
        # `latest` (and per-commit `sha-*`) to ghcr — no semver image
        # tags — so we pin `latest` to its digest for reproducibility;
        # renovate tracks `latest` and bumps the digest on its own.
        # renovate: datasource=docker depName=ghcr.io/bookorbit/bookorbit
        image = "ghcr.io/bookorbit/bookorbit:latest@sha256:c2b01e655562dd95d785b515890c4c8c31325d90671efd1ae7db5b9f378a80ce";
        # The image starts as root (caps below), repairs /data ownership,
        # then drops to PUID:PGID. Don't set `user` — it short-circuits
        # the entrypoint's permission fix.
        volumes = [
          "/var/lib/containers/bookorbit/data:/data"
          "/mnt/content/books:/books"
          "/mnt/content/books_intake:/data/book-dock"
        ];
        environment = {
          NODE_ENV = "production";
          PORT = toString port;
          APP_URL = "https://${bookorbitHost}";
          # authentik.<serverDomain> resolves to a private/LAN address on
          # this network; bookorbit rejects local issuer/discovery URLs
          # unless this is set. Trusted self-hosted IdP, so allow it.
          OIDC_ALLOW_LOCAL_ISSUERS = "true";
        };
        environmentFiles = [ config.sops.templates."bookorbit.env".path ];
        # Mirror the upstream compose hardening: read-only rootfs with a
        # tmpfs for /tmp and a minimal cap set (the entrypoint needs
        # CHOWN/DAC_OVERRIDE/FOWNER/SET[UG]ID to fix /data perms and drop
        # privileges).
        extraOptions = [
          "--init"
          "--read-only"
          "--tmpfs=/tmp"
          "--cap-drop=ALL"
          "--cap-add=CHOWN"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--cap-add=SETGID"
          "--cap-add=SETUID"
          "--security-opt=no-new-privileges"
        ];
      };

      myCaddy.apps.bookorbit = {
        host = bookorbitHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
