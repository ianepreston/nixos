# Omnigent server - control plane (API, web UI, session persistence).
# Native module from the omnigent-nix flake (`inputs.omnigent`), not a
# container. The flake's core module owns the hardened systemd unit and
# publishes `listenUrl` / `publicUrl` / `healthPath` / `stateDir`; this module
# translates that contract into the repo's typed surfaces (myCaddy, myAppState,
# myRecovery, myObservability) instead of importing the flake's caddy adapter.
#
# Off by default: `myOmnigent.enable = true` in a host file turns it on. The
# server never executes agent work and the machine must not be registered as a
# host; an assertion below fails the eval if any home-manager user here enables
# `programs.omnigent.host`. Hosts are workstations (terra) pointed at a server.
#
# Postgres: the flake's `postgresql` adapter creates the `omnigent` database and
# role and connects over the unix socket with peer auth (fixed user `omnigent`),
# so there is no db_password to manage. Restic snapshots /var/backup/postgresql.
#
# Auth: native OIDC against authentik (`auth.provider = "oidc"`), registered
# through `myAuthentik.oidcApps.omnigent` with the blueprint in
# ./omnigent-blueprints. Not `myAuthentik.forwardAuthApps`: the CLI, the
# omnigent-host/runner WebSocket tunnels under /v1/* and the desktop's native
# login under /auth/* are non-browser clients that cannot follow an authentik
# redirect, so Caddy is a plain reverse proxy and Omnigent does the login.
#
# Who gets in: the authentik application is bound to the Infrastructure group
# (admin tools), and Omnigent auto-provisions every user the IdP lets through,
# identified by the verified `email` claim. No domain allowlist is set, so the
# authentik binding is the only gate. There is no first-user-is-admin rule in
# OIDC mode: admins come only from Omnigent's `admins` setting
# (`services.omnigent.settings.admins`) or its admin-list file. The admin is
# the sops secret `omnigent/admin_email`, rendered at runtime into the
# `omnigent-admins` template (one identity per line) and named by
# OMNIGENT_ADMIN_LIST_PATH. It must equal the email of the `ian` user in the
# nix-secrets authentik blueprint, because that is what the IdP asserts. It is
# a secret rather than a literal because that address is not declared in this
# public repo, and it is not `hostSpec.email.*`, which is a different address
# (see sparkyfitness.nix). Promotion is additive: a listed email is made admin
# at login, and removing it later never demotes anyone.
#
# Secrets: the OIDC client id/secret and the session cookie secret come from
# sops and reach the service through the per-app `omnigent.env` template that
# `myAuthentik.oidcApps` renders. omnigent-nix loads it with `LoadCredential=`
# and accepts only its allowlisted names (`OMNIGENT_OIDC_*` covers all three).
# The template carries `restartUnits`, so rotating any of them bounces the
# service. Issuer and redirect URI are not secret and go in the unit
# environment, where they are inspectable.
{ inputs, ... }:
{
  flake.modules.nixos.omnigent =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      cfg = config.myOmnigent;
      server = config.services.omnigent;
      omnigentHost = "omnigent.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
    in
    {
      imports = [
        inputs.omnigent.nixosModules.omnigent
        inputs.omnigent.nixosModules.postgresql
      ];

      options.myOmnigent = {
        enable = lib.mkEnableOption ''
          the Omnigent server. Off by default; see the header of
          modules/apps/omnigent.nix for what turning it on does'';
      };

      config = lib.mkIf cfg.enable {
        # Server is never a host (see header). `or false` covers users that
        # don't import the omnigent-nix HM module.
        assertions = lib.mapAttrsToList (name: hm: {
          assertion = !(hm.programs.omnigent.host.enable or false);
          message = ''
            myOmnigent: this machine runs the Omnigent server, so home-manager
            user `${name}` must not enable programs.omnigent.host. Run the host
            on a workstation and point it at this server instead.
          '';
        }) (config.home-manager.users or { });

        services.omnigent = {
          enable = true;
          listen.port = 8094;
          publicUrl = "https://${omnigentHost}";
          auth.provider = "oidc";
          postgresql.createLocally = true;
          environmentFile = config.sops.templates."omnigent.env".path;
          environment = {
            OMNIGENT_OIDC_ISSUER = "https://${authentikHost}/application/o/omnigent/";
            OMNIGENT_OIDC_REDIRECT_URI = "https://${omnigentHost}/auth/callback";
            # A path, not a secret: the roster itself is the sops template below.
            OMNIGENT_ADMIN_LIST_PATH = config.sops.templates."omnigent-admins".path;
          };
        };

        # Admin roster (see header). The service reads it directly, so the
        # template is owned by the service's fixed user. restartUnits sits on
        # the template only, per AGENTS.md.
        sops = {
          secrets."omnigent/admin_email".sopsFile = hostSpec.sopsFile;
          templates."omnigent-admins" = {
            content = ''
              ${config.sops.placeholder."omnigent/admin_email"}
            '';
            owner = server.user;
            inherit (server) group;
            mode = "0400";
            restartUnits = [ "omnigent.service" ];
          };
        };

        myAuthentik.oidcApps.omnigent = {
          blueprintsDir = ./omnigent-blueprints;
          displayName = "Omnigent";
          appRestartUnit = [ "omnigent.service" ];
          clientIdVar = "OMNIGENT_OIDC_CLIENT_ID";
          clientSecretVar = "OMNIGENT_OIDC_CLIENT_SECRET";
          # 32 random bytes (64 hex chars), Omnigent's minimum for the HS256
          # session-cookie key.
          extraSecrets."omnigent/oidc_cookie_secret".sopsFile = hostSpec.sopsFile;
          extraEnvLines = ''
            OMNIGENT_OIDC_COOKIE_SECRET=${config.sops.placeholder."omnigent/oidc_cookie_secret"}
          '';
        };

        myObservability.monitoredSystemdUnits = [ "omnigent" ];

        # The adapter pins the service to the fixed `omnigent` user/group (peer
        # auth needs a role-named user), so state is owned by that user.
        myAppState.omnigent = {
          inherit (server) stateDir user group;
        };

        myRecovery.apps.omnigent = {
          kind = "postgres";
          order = 295;
          units = [ "omnigent.service" ];
          database = server.postgresql.name;
          paths = [ server.stateDir ];
          health.url = "${server.listenUrl}${server.healthPath}";
        };

        myCaddy.apps.omnigent = {
          host = omnigentHost;
          # Unbuffered so the UI's long-lived streaming (SSE) responses and the
          # /v1/* WebSocket tunnels are not held back. Caddy upgrades WebSockets
          # on its own.
          routeConfig = ''
            reverse_proxy ${server.listenUrl} {
              flush_interval -1
            }
          '';
        };
      };
    };
}
