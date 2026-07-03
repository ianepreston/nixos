# Mealie - recipe manager
# Native services.mealie from nixpkgs (DynamicUser; ExecStartPre runs
# init_db; gunicorn binds the configured port). Mealie speaks OIDC
# natively; the provider/application/policy binding live in
# modules/apps/mealie-blueprints/ and are wired into authentik via the
# aggregator's blueprintsDir option.
#
# Postgres switches from container-style TCP+password to unix-socket
# peer auth: `database.createLocally = true` ensures the `mealie`
# role/db exist and DynamicUser=mealie causes peer auth to match the
# role name automatically — no password to plumb through sops. The
# myPostgresApp helper goes away here; the sops db_password secret
# becomes unused.
_: {
  flake.modules.nixos.mealie =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      mealieHost = "mealie.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      # 9000 is authentik's port (authentik-nix pins it). Mealie's
      # upstream default is also 9000, so leaving it default would
      # race authentik for the bind: whichever loses falls back to
      # HTTPS-only and Caddy's forward_auth + the authentik vhost
      # both end up pointing at the wrong upstream. 9925 is mealie's
      # common alt-port (used by some compose templates).
      port = 9925;
      uid = 892;
    in
    {
      myAuthentik.oidcApps.mealie = {
        blueprintsDir = ./mealie-blueprints;
        appRestartUnit = [ "mealie.service" ];
        homepage = {
          group = "Home";
          icon = "mealie";
          description = "Recipe manager";
        };
        displayName = "Mealie";
      };

      services.mealie = {
        enable = true;
        inherit port;
        listenAddress = "127.0.0.1";
        database.createLocally = true;
        credentialsFile = config.sops.templates."mealie.env".path;
        settings = {
          ALLOW_SIGNUP = "false";
          BASE_URL = "https://${mealieHost}";
          TZ = config.time.timeZone;

          # OIDC. Auto-redirect stays off so password login still works
          # if SSO breaks; users can hit the "Login with Authentik"
          # button on the regular login page. Append `?direct=1` to the
          # URL to force the password form when needed.
          OIDC_AUTH_ENABLED = "true";
          OIDC_PROVIDER_NAME = "Authentik";
          OIDC_CONFIGURATION_URL = "https://${authentikHost}/application/o/mealie/.well-known/openid-configuration";
          OIDC_USER_GROUP = "Users";
          OIDC_ADMIN_GROUP = "authentik Admins";
          OIDC_AUTO_REDIRECT = "false";
          OIDC_REMEMBER_ME = "true";
          OIDC_SIGNUP_ENABLED = "true";
        };
      };

      users.users.mealie = {
        inherit uid;
        group = "mealie";
        isSystemUser = true;
      };
      users.groups.mealie.gid = uid;

      # Override DynamicUser → static "mealie" (the role name postgres
      # peer-auth expects is unaffected — User="mealie" stays). Re-add
      # the hardening DynamicUser used to imply, since dropping the
      # flag also drops those implicit defaults.
      systemd.services.mealie.serviceConfig = {
        DynamicUser = lib.mkForce false;
        Group = "mealie";
        NoNewPrivileges = true;
        RemoveIPC = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
        RestrictSUIDSGID = true;
      };

      myAppState.mealie = {
        stateDir = "/var/lib/mealie";
        user = "mealie";
        group = "mealie";
      };

      myCaddy.apps.mealie = {
        host = mealieHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
