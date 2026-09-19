# SparkyFitness - self-hosted nutrition / fitness diary (food, exercise,
# water, sleep, mood, fasting, measurements, goals, reports).
#
# Native, but not from nixpkgs: the licence is a custom non-commercial
# source-available grant, so nixpkgs will never carry it. Upstream ships
# its own flake with a `services.sparkyfitness` module instead, which is
# what this imports. The container path was the alternative and lost:
# the compose shape is *two*
# containers (nginx-serving-SPA in front of the node backend) plus
# inter-container plumbing, which is a worse trade than one flake input
# against CLAUDE.md's "containers are the fallback, not the baseline".
#
# Upstream calls the nix integration community-provided and untested,
# and no CI job builds the packages — so a release can ship with the nix
# build broken. That failure is loud (a build error at deploy time), not
# silent, which is the tolerable kind. If it happens twice running,
# revisit the container path.
#
# Three things this module has to do on top of the upstream module:
#
#   1. `database.createLocally = false`, always. That branch assigns
#      `services.postgresql.package = cfg.database.package` (default
#      postgresql_16) as a plain assignment, not mkDefault — on a server
#      already pinning postgresql_18 in modules/system/postgresql.nix
#      that is an eval conflict, and winning it would be a cluster
#      downgrade. The shared cluster is reached through myPostgresApp
#      over TCP instead; `host all all 127.0.0.1/32 scram-sha-256` is
#      already in our pg_hba, so there is no authentication block to add.
#   2. Grant the owner role CREATEROLE, and hand it schema `public`.
#      myPostgresApp provisions role + database ownership only. The
#      backend creates its own limited application role at startup (that
#      role, not the owner, is what Row Level Security is enforced
#      against), and PostgreSQL 15+ leaves `public` owned by the
#      bootstrap superuser even after the database owner changes, which
#      breaks migrations that `COMMENT ON SCHEMA public`. Both are done
#      by the sparkyfitness-db-grants oneshot below — the same shape as
#      bookorbit-db-extensions, and the same two statements upstream's
#      own `sparkyfitness-db-init` runs on the createLocally path we
#      just turned off.
#   3. `nginx.enable = false` and rebuild the five routes in caddy. See
#      the myCaddy block for the two non-obvious ones.
#
# Secrets and their rotation hazards:
#
#   * BETTER_AUTH_SECRET encrypts TOTP data. Rotating it after anyone
#     has enabled 2FA locks every 2FA user out permanently. The usual
#     "regenerate and let sops restart the unit" reflex is wrong for
#     this one key.
#   * SPARKY_FITNESS_API_ENCRYPTION_KEY must be exactly 64 hex chars
#     (or 44 base64) or the server throws at import time — hence
#     `task secrets:secret ... LEN=32`.
#   * SPARKY_FITNESS_DB_PASSWORD is the owner role's password. Upstream
#     warns against changing it, but that warning is aimed at compose
#     users who would change the env without touching the database;
#     our sparkyfitness-db-password.service ALTER USERs it on every
#     sops rotation, so the two stay in sync and rotation is safe.
#
# Login / account model. OIDC is configured entirely from the
# environment — the backend upserts the provider into its own DB on
# every boot (SparkyFitnessServer/utils/oidcEnvConfig.ts) — so unlike
# audiobookshelf/bookorbit there is no UI step and no
# clientCredsInAppEnv = false. Two traps:
#
#   * The provider slug is load-bearing. Changing
#     SPARKY_FITNESS_OIDC_PROVIDER_SLUG deletes the old env-configured
#     provider and creates a new one, taking every existing SSO account
#     link with it. Treat `authentik` as permanent.
#   * Do NOT set SPARKY_FITNESS_DISABLE_SIGNUP=true. It reads like the
#     obvious hardening flag, but it is a master toggle in Better
#     Auth's `user.create.before` hook that fires *before* the SSO
#     auto-register check (SparkyFitnessServer/auth.ts) — with it set,
#     no user can ever be created, OIDC included. Self-provisioning
#     family members via SSO is wanted here, so it stays unset and
#     signup stays open.
#
# SPARKY_FITNESS_FORCE_EMAIL_LOGIN stays true: it is the documented
# escape hatch from an OIDC misconfiguration lockout, and this instance
# is reachable only from the LAN/tailnet. Flip it off (and optionally
# set SPARKY_FITNESS_DISABLE_EMAIL_LOGIN=true) if that stops being
# wanted.
#
# Admin assignment is the part with a trap in it, so: there are three
# routes to `role = 'admin'`, and the obvious one is the weakest.
#
#   1. A live BEFORE INSERT trigger on "user"
#      (20260206132000_ensure_first_user_is_admin.sql) grants admin to
#      whoever creates the *first row*, on any address. It is a
#      trigger, not a one-time backfill, so it is armed on every fresh
#      database — every new host. Since the blueprint binds this app to
#      the Users group, that is a race among every member of it, plus
#      anyone on the LAN who registers locally.
#   2. SPARKY_FITNESS_ADMIN_EMAIL, an exact findUserByEmail lookup run
#      on every startup. Note *what the IDP asserts* — see the
#      hardcoded value below for why reading hostSpec.email.personal
#      here matched nothing.
#   3. oidcGroupSync, which promotes members of
#      SPARKY_FITNESS_OIDC_ADMIN_GROUP and revokes admin from
#      non-members on every login.
#
# (3) is what actually holds, because it is the only one that takes
# admin *away*: whoever wins the trigger race in (1) is demoted at
# their next login, rather than holding admin permanently until someone
# edits the role by hand in postgres. It costs nothing in reach —
# revocation governs the `role` column only, so self-registration and
# SSO auto-register stay fully open.
#
# What it does not do is make the race harmless in the moment: a
# trigger-granted admin holds the admin panel until they log in again.
# Log in on a freshly-provisioned host promptly.
#
# Beyond admin, an ordinary account is RLS-scoped to its own rows.
#
# What open signup does leave, neither of which is escalation: anyone
# who can reach the vhost can create an account (and consume uploads
# storage, and any *global* AI provider an admin configures — a
# per-user one can't reach private URLs, since ALLOW_PRIVATE_NETWORK_AI
# is unset), and the password form is unthrottled. Upstream's docker
# nginx rate-limits `^~ /api/auth/`; the nix module's nginx doesn't,
# and neither does the caddy rebuild below, because caddy has no
# built-in limiter — it would mean adding caddy-ratelimit to
# `caddy.withPlugins` in modules/system/caddy.nix and regenerating that
# vendored hash. Only reachable from the LAN/tailnet, so not taken.
#
# Not wired here, deliberately: the Garmin sidecar (garmin.enable, one
# flag plus a myAppState entry and a recovery path), and the SparkyAI /
# Tandoor food-provider integrations, which are per-user UI settings
# with no nix surface. The homepage tile is a plain link: homepage
# 1.12.3 does ship a `sparkyfitness` widget, but it wants a key the app
# mints in its own UI and stores in postgres — which is neither sops
# nor myRuntimeCredentials — and a calorie readout on an unauthenticated
# dashboard is not wanted anyway.
{ inputs, ... }:
{
  flake.modules.nixos.sparkyfitness =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      sparkyPkgs = inputs.sparkyfitness.packages.${pkgs.stdenv.hostPlatform.system};
      sparkyHost = "sparkyfitness.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";

      port = 3010;
      stateDir = "/var/lib/sparkyfitness";
      unit = "sparkyfitness.service";
      grantsUnit = "sparkyfitness-db-grants.service";

      # Static uid/gid, same reason as gatus/readeck/prowlarr: the state
      # dir is preserved and restic-backed, and restic restores numeric
      # ownership. An auto-allocated system uid is stable on a running
      # host only because /var/lib/nixos is itself preserved — a
      # bootstrap:reinstall + `task recovery:all` reallocates from
      # scratch, and the restored uploads/ and backup/ trees would come
      # back owned by a uid this service no longer has. 895 is the next
      # free value after gatus at 894.
      uid = 895;

      # myPostgresApp's defaults: role and database both named after the
      # attribute. The backend creates `appUser` itself at startup.
      dbName = "sparkyfitness";
      appDbUser = "sparkyfitness_app";

      # Permanent — see the header. Also the last path segment of the
      # Better Auth SSO callback the blueprint pins.
      oidcSlug = "authentik";
    in
    {
      # `nixosModules.default` (the bare module) rather than
      # `nixosModules.sparkyfitness` (the convenience wrapper). The two
      # differ only in that the wrapper defaults the package options
      # from the same flake — which it does via `pkgs.system`, and that
      # attribute is deprecated, so importing it printed a rename
      # warning on every eval of every server. Wiring the same three
      # packages here off `stdenv.hostPlatform.system` is the identical
      # result without the noise.
      imports = [ inputs.sparkyfitness.nixosModules.default ];

      # The upstream module declares both (gated on the default names,
      # which we keep), so this only adds the numeric pins.
      users.users.sparkyfitness = { inherit uid; };
      users.groups.sparkyfitness.gid = uid;

      myPostgresApp.sparkyfitness.consumerService = [
        unit
        grantsUnit
      ];

      # Three things myPostgresApp doesn't provision, all idempotent so
      # the unit is safe to re-run on every boot and every rotation:
      #
      #   * CREATEROLE on the owner role, so the backend can create its
      #     limited application role;
      #   * schema `public` ownership, which PostgreSQL 15+ leaves with
      #     the bootstrap superuser even after the database owner
      #     changes (upstream's own db-init does the same);
      #   * the application role's password, when that role already
      #     exists. This one is the non-obvious half: the backend
      #     provisions the role with a bare `CREATE ROLE ... PASSWORD`
      #     and never ALTERs an existing one
      #     (SparkyFitnessServer/utils/dbMigrations.ts), so rotating
      #     `sparkyfitness/app_db_password` would re-render the env
      #     file and bounce the app onto a password postgres has never
      #     been told about — authentication failure on every query,
      #     until someone ALTERs the role by hand. Doing it here gives
      #     the app role the same rotate-on-change safety
      #     myPostgresApp's oneshot gives the owner role.
      systemd.services.sparkyfitness-db-grants =
        let
          appPwPath = config.sops.secrets."sparkyfitness/app_db_password".path;
          psql = "${config.services.postgresql.package}/bin/psql";
        in
        {
          description = "Provision sparkyfitness's postgres roles beyond myPostgresApp's defaults";
          after = [
            "postgresql.service"
            "postgresql-setup.service"
            "sparkyfitness-db-password.service"
            # Same explicit ordering (and the ConditionPathExists guard
            # below) as myPostgresApp's oneshot: the activation-script
            # form of sops otherwise races an early-boot start and the
            # script reads a secret that isn't there yet.
            "sops-install-secrets.service"
          ];
          requires = [ "postgresql.service" ];
          wants = [
            "postgresql-setup.service"
            "sops-install-secrets.service"
          ];
          wantedBy = [ unit ];
          before = [ unit ];
          unitConfig.ConditionPathExists = appPwPath;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "postgres";
            Group = "postgres";
          };
          script = ''
            set -euo pipefail

            ${psql} -d ${dbName} -v ON_ERROR_STOP=1 <<'SQL'
            ALTER ROLE ${dbName} WITH CREATEROLE;
            ALTER SCHEMA public OWNER TO ${dbName};
            SQL

            if [ ! -s "${appPwPath}" ]; then
              echo "ERROR: sops secret ${appPwPath} is empty — refusing to clear the ${appDbUser} postgres password" >&2
              exit 1
            fi

            # Only on an existing role: on first boot the backend
            # creates it, from the same secret, a moment later.
            if ${psql} -tAc "SELECT 1 FROM pg_roles WHERE rolname='${appDbUser}'" | grep -q 1; then
              # Passed as a psql variable and referenced as a quoted SQL
              # literal so the value is escaped rather than interpolated
              # into the statement text.
              printf '%s\n' "ALTER ROLE \"${appDbUser}\" WITH PASSWORD :'passwd';" \
                | ${psql} -v ON_ERROR_STOP=1 -v passwd="$(cat ${appPwPath})"
            fi
          '';
        };

      myAuthentik.oidcApps.sparkyfitness = {
        blueprintsDir = ./sparkyfitness-blueprints;
        appRestartUnit = [ unit ];
        clientIdVar = "SPARKY_FITNESS_OIDC_CLIENT_ID";
        clientSecretVar = "SPARKY_FITNESS_OIDC_CLIENT_SECRET";
        displayName = "SparkyFitness";

        # Everything the app reads from disk rather than the store. The
        # aggregator owns the env template (and its restartUnits), so
        # these are declared as extraSecrets rather than bare
        # sops.secrets.
        extraSecrets = {
          # app_db_password is the one secret consumed twice: through
          # the env file the app reads, and directly off disk by the
          # grants oneshot above. The template carries the app's own
          # restart, but the oneshot has no template to bind to, so its
          # rotation trigger has to live on the secret — the documented
          # exception to CLAUDE.md's template-only rule.
          "sparkyfitness/app_db_password" = {
            inherit (hostSpec) sopsFile;
            owner = "postgres";
            restartUnits = [ grantsUnit ];
          };
          "sparkyfitness/api_encryption_key".sopsFile = hostSpec.sopsFile;
          "sparkyfitness/better_auth_secret".sopsFile = hostSpec.sopsFile;
        };

        # The issuer is normalized (trailing slash stripped) and the
        # discovery URL derived as issuer + /.well-known/openid-configuration,
        # so authentik's per-provider issuer works verbatim.
        extraEnvLines = ''
          SPARKY_FITNESS_DB_PASSWORD=${config.sops.placeholder."sparkyfitness/db_password"}
          SPARKY_FITNESS_APP_DB_PASSWORD=${config.sops.placeholder."sparkyfitness/app_db_password"}
          SPARKY_FITNESS_API_ENCRYPTION_KEY=${config.sops.placeholder."sparkyfitness/api_encryption_key"}
          BETTER_AUTH_SECRET=${config.sops.placeholder."sparkyfitness/better_auth_secret"}
          SPARKY_FITNESS_OIDC_AUTH_ENABLED=true
          SPARKY_FITNESS_OIDC_ISSUER_URL=https://${authentikHost}/application/o/sparkyfitness/
          SPARKY_FITNESS_OIDC_PROVIDER_SLUG=${oidcSlug}
          SPARKY_FITNESS_OIDC_PROVIDER_NAME=Authentik
          SPARKY_FITNESS_OIDC_AUTO_REGISTER=true
        '';

        homepage = {
          group = "Home";
          icon = "https://raw.githubusercontent.com/CodeWithCJ/SparkyFitness/main/SparkyFitnessFrontend/public/images/icons/icon-192x192.png";
          description = "Nutrition + fitness diary";
        };
      };

      services.sparkyfitness = {
        enable = true;
        inherit port;
        backendPackage = sparkyPkgs.sparkyfitness-server;
        frontendPackage = sparkyPkgs.sparkyfitness-frontend;
        # Declared but not enabled, so nothing references it and it
        # stays out of the closure — this just keeps `garmin.enable =
        # true` a one-line change rather than an undefined-option error.
        garmin.package = sparkyPkgs.sparkyfitness-garmin;
        frontendUrl = "https://${sparkyHost}";
        environmentFile = config.sops.templates."sparkyfitness.env".path;

        # We run caddy, not nginx; the routes are rebuilt below.
        nginx.enable = false;

        database = {
          createLocally = false;
          host = "127.0.0.1";
          port = 5432;
          name = dbName;
          user = dbName;
          appUser = appDbUser;
        };

        extraEnvironment = {
          # Admin is group-driven: oidcGroupSync promotes members of
          # this group and *revokes* admin from everyone else, on every
          # login (the `session.create.after` hook in auth.ts). That
          # revocation is the point — see the header for what it
          # defends against. The group name is matched as an exact
          # string against the `groups` claim, which authentik's
          # default `profile` scope mapping already emits, so no
          # blueprint change is needed to supply it.
          SPARKY_FITNESS_OIDC_ADMIN_GROUP = "authentik Admins";

          # Backstop for the case where the groups claim stops arriving
          # (a changed scope mapping, say): with no groups in the token
          # the sync would demote every admin, and this re-promotes on
          # the next service restart.
          #
          # Hardcoded rather than read from hostSpec.email.personal,
          # which is what this used to be and was silently inert: that
          # is the real mail address, and the address authentik asserts
          # for this account is the @example.com placeholder on the
          # authentik user. The promotion is an exact findUserByEmail
          # lookup against what the IDP sent, so it has to be the
          # latter. Same on every host, so it is not a hostSpec read.
          SPARKY_FITNESS_ADMIN_EMAIL = "ian@example.com";

          SPARKY_FITNESS_FORCE_EMAIL_LOGIN = "true";
        };
      };

      # The upstream module leaves StateDirectoryMode at systemd's 0755
      # default, so /var/lib/sparkyfitness lands world-readable — and it
      # holds uploads, the app's own backups and temp_uploads. Every
      # other native app here preserves 0700; nothing outside the
      # service reads this tree (caddy serves /uploads by proxying the
      # backend, not from disk), so match the fleet. Keeping this in
      # step with myAppState's 0700 default also stops the preserved
      # copy under /persist and the live directory disagreeing.
      systemd.services.sparkyfitness.serviceConfig.StateDirectoryMode = "0700";

      myAppState.sparkyfitness = {
        inherit stateDir;
        user = "sparkyfitness";
        group = "sparkyfitness";
      };

      # The five routes the module's nginx vhost would have served,
      # rebuilt in caddy. Two are not obvious:
      #
      #   * /health-data is a path rewrite. The mobile apps post to the
      #     unprefixed path and the backend serves it under /api, which
      #     nginx expressed as `proxy_pass .../api/health-data` on a
      #     prefix location — so the whole matched path gets /api
      #     prepended, not just the exact route.
      #   * /mcp answers with text/event-stream (JSON-RPC over
      #     StreamableHTTP). nginx needed `proxy_buffering off`; caddy
      #     needs `flush_interval -1`, or replies sit in the proxy
      #     buffer and every MCP client hangs.
      #
      # Prefix matchers rather than exact ones throughout, to keep
      # nginx's location semantics.
      myCaddy.apps.sparkyfitness = {
        host = sparkyHost;
        routeConfig = ''
          request_body {
            max_size 10MB
          }

          # The nginx vhost this replaces turned on
          # `recommendedGzipSettings`, and no other app in this caddy
          # config serves static files, so there is no site-wide
          # `encode` to inherit — without this the whole vite bundle
          # goes out uncompressed.
          encode zstd gzip

          handle /mcp* {
            reverse_proxy 127.0.0.1:${toString port} {
              flush_interval -1
            }
          }

          handle /health-data* {
            rewrite * /api{uri}
            reverse_proxy 127.0.0.1:${toString port}
          }

          handle /api/* {
            reverse_proxy 127.0.0.1:${toString port}
          }

          handle /uploads/* {
            reverse_proxy 127.0.0.1:${toString port}
          }

          handle /assets/* {
            header Cache-Control "public, no-transform, immutable, max-age=31536000"
            root * ${config.services.sparkyfitness.frontendPackage}
            file_server
          }

          handle {
            header Cache-Control "no-cache, no-store, must-revalidate"
            root * ${config.services.sparkyfitness.frontendPackage}
            try_files {path} {path}/ /index.html
            file_server
          }
        '';
      };
    };
}
