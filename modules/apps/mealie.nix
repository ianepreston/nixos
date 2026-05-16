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
    in
    {
      myAuthentik.oidcApps.mealie = {
        blueprintsDir = ./mealie-blueprints;
        appRestartUnit = "mealie.service";
        homepage = {
          group = "Home";
          icon = "mealie";
          description = "Recipe manager";
        };
        homepageDisplayName = "Mealie";
        homepageHref = "https://${mealieHost}";
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

      # DynamicUser: real state lives at /var/lib/private/mealie;
      # /var/lib/mealie is just the symlink systemd recreates each boot.
      # Restic doesn't follow symlinks, so backing up /var/lib/mealie
      # captures only the link, not the data.
      preservation.preserveAt."/persist".directories = [ "/var/lib/private/mealie" ];

      services.restic.backups.server.paths = [ "/var/lib/private/mealie" ];

      myCaddy.apps.mealie = {
        host = mealieHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
