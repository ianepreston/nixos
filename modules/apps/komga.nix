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
      pkgs,
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
        user = hostSpec.serverUser;
        group = hostSpec.serverGroup;
        settings.server.port = port;
        # The jar (unlike the bundled Docker/desktop distros) doesn't ship
        # kepubify, so point Komga at the nixpkgs binary. Required for
        # on-the-fly EPUB->KEPUB conversion when syncing to a Kobo.
        settings.komga.kobo.kepubify-path = "${pkgs.kepubify}/bin/kepubify";
      };

      systemd.services.komga = {
        environment = {
          KOMGA_OAUTH2ACCOUNTCREATION = "true";
          # Whole-book downloads (OPDS clients like Apex Comics fetch the entire
          # CBZ via getBookFileInternal) stream async through Tomcat. On a slow
          # mobile connection a single socket write can block past Tomcat's ~20s
          # default write timeout, so Komga aborts mid-download with a
          # SocketTimeoutException and the reader stalls. Raise the connection
          # timeout and disable the async request timeout so large files finish
          # over flaky Wi-Fi. Spring relaxed-binding env vars.
          SERVER_TOMCAT_CONNECTION_TIMEOUT = "300000";
          SPRING_MVC_ASYNC_REQUEST_TIMEOUT = "-1";
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_NAME = "Authentik";
          SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_SCOPE = "openid,profile,email";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_ISSUER_URI = "https://${authentikHost}/application/o/komga/";
          SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_USER_NAME_ATTRIBUTE = "preferred_username";
        };
        serviceConfig.EnvironmentFile = [ config.sops.templates."komga.env".path ];
      };

      myAppState.komga = {
        stateDir = "/var/lib/komga";
        user = hostSpec.serverUser;
      };

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
