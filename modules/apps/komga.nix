# Komga - comic + manga server
# Native services.komga from nixpkgs (Spring Boot service; user
# overridden to server-${env}:servers so reads against
# /mnt/content/{comics,books} land with the NFS UID the NAS expects).
# OIDC against authentik via Spring's relaxed-binding env vars
# (SPRING_SECURITY_OAUTH2_CLIENT_*).
#
# Komga doesn't have a sign-up toggle for OAuth — first OIDC login
# creates an account, but only if the email address matches an
# already-existing Komga user. To onboard new users, log in once as
# the Komga admin and pre-create their accounts (email-only is fine).
_: {
  flake.modules.nixos.komga =
    {
      config,
      hostSpec,
      ...
    }:
    let
      komgaHost = "komga.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      port = 25600;
    in
    {
      myAuthentik.oidcApps.komga = {
        blueprintsDir = ./komga-blueprints;
        appRestartUnit = "komga.service";
        clientIdVar = "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_ID";
        clientSecretVar = "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_SECRET";
        homepage = {
          group = "Consumption";
          icon = "komga";
          description = "Comics + manga";
        };
        homepageDisplayName = "Komga";
        homepageHref = "https://${komgaHost}";
      };

      services.komga = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
        settings.server.port = port;
      };

      systemd.services.komga = {
        environment = {
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_NAME = "Authentik";
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_SCOPE = "openid,profile,email";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_ISSUER_URI = "https://${authentikHost}/application/o/komga/";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_USER_NAME_ATTRIBUTE = "preferred_username";
        };
        serviceConfig.EnvironmentFile = [ config.sops.templates."komga.env".path ];
      };

      services.restic.backups.server.paths = [ "/var/lib/komga" ];

      myCaddy.apps.komga = {
        host = komgaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
