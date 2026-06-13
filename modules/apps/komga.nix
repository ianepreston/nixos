# Komga - comic + manga server
# Native services.komga from nixpkgs (Spring Boot service; user
# overridden to server-${env}:servers so reads against
# /mnt/content/{Comics,books} land with the NFS UID the NAS expects).
# OIDC against authentik via Spring's relaxed-binding env vars
# (SPRING_SECURITY_OAUTH2_CLIENT_*).
#
# KOMGA_OAUTH2ACCOUNTCREATION=true lets a first OIDC login auto-create
# a Komga user when no account matches the email (random password the
# user can later set from Account Settings for OPDS/Mihon). Komga warns
# to enable this only with providers you control — authentik qualifies.
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
        appRestartUnit = [ "komga.service" ];
        clientIdVar = "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_ID";
        clientSecretVar = "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_SECRET";
        homepage = {
          group = "Consumption";
          icon = "komga";
          description = "Comics + manga";
        };
        displayName = "Komga";
      };

      services.komga = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
        settings.server.port = port;
      };

      systemd.services.komga = {
        environment = {
          KOMGA_OAUTH2ACCOUNTCREATION = "true";
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_NAME = "Authentik";
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_SCOPE = "openid,profile,email";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_ISSUER_URI = "https://${authentikHost}/application/o/komga/";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_USER_NAME_ATTRIBUTE = "preferred_username";
        };
        serviceConfig.EnvironmentFile = [ config.sops.templates."komga.env".path ];
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/komga";
          user = "server-${hostSpec.serverEnvironment}";
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/komga" ];

      mySqliteQuiesce.apps.komga.databases = [
        "/var/lib/komga/database.sqlite"
        "/var/lib/komga/tasks.sqlite"
      ];

      myCaddy.apps.komga = {
        host = komgaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
