# Grimmory - self-hosted digital library (community fork of Booklore)
# Container; OIDC against authentik gated to the Users group. Grimmory
# is a Spring Boot app that stores OIDC settings in its own MariaDB
# database (configured once via Settings → OIDC in the UI), so this
# module registers via myAuthentik.oidcApps with clientCredsInAppEnv
# = false. Grimmory only supports public OIDC clients with PKCE — set
# `publicClient = true` so no client_secret is provisioned.
#
# Grimmory requires MariaDB (the JDBC URL in the upstream image is
# pinned to `jdbc:mariadb://...`). It connects to the shared native
# MariaDB instance from modules/system/mariadb.nix over the podman
# bridge via host.containers.internal:3306.
#
# On first boot, complete the admin setup, then in Settings → OIDC
# enter Provider name `Authentik`, Issuer URI
# `https://authentik.<serverDomain>/application/o/grimmory/`,
# Client ID from `grimmory/oidc_client_id` in sops, and JWKS URL
# `https://authentik.<serverDomain>/application/o/grimmory/jwks/`.
_: {
  flake.modules.nixos.grimmory =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      grimmoryHost = "grimmory.${hostSpec.serverDomain}";
      port = 6060;
    in
    {
      myAuthentik.oidcApps.grimmory = {
        blueprintsDir = ./grimmory-blueprints;
        appRestartUnit = "podman-grimmory.service";
        publicClient = true;
        clientCredsInAppEnv = false;
        displayName = "Grimmory";
        extraEnvLines = ''
          DATABASE_PASSWORD=${config.sops.placeholder."grimmory/db_password"}
        '';
        extraSecrets = {
          "grimmory/db_password" = {
            sopsFile = hostSpec.sopsFile;
            owner = "mysql";
            restartUnits = [
              "grimmory-db-password.service"
              "podman-grimmory.service"
            ];
          };
        };
        homepage = {
          group = "Consumption";
          icon = "booklore";
          description = "Digital library";
        };
      };

      services.mysql = {
        ensureDatabases = [ "grimmory" ];
      };

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/grimmory 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/grimmory/data 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/grimmory/bookdrop 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services = {
          # Sets up the grimmory mariadb role with a sops-managed password
          # and grants on the grimmory database. ensureUsers can't help
          # here because it provisions unix_socket auth only, but the
          # container connects over TCP from the podman bridge and needs
          # password auth. Runs as the `mysql` OS user so the unix_socket
          # plugin maps it to the bootstrap mysql superuser.
          grimmory-db-password = {
            description = "Provision grimmory mariadb role";
            after = [ "mysql.service" ];
            requires = [ "mysql.service" ];
            wantedBy = [ "podman-grimmory.service" ];
            before = [ "podman-grimmory.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "mysql";
              Group = "mysql";
            };
            script = ''
              pw=$(cat ${config.sops.secrets."grimmory/db_password".path})
              pw_sql=''${pw//\'/\'\'}
              ${config.services.mysql.package}/bin/mysql -u mysql <<EOF
              CREATE USER IF NOT EXISTS 'grimmory'@'%' IDENTIFIED BY '$pw_sql';
              ALTER USER 'grimmory'@'%' IDENTIFIED BY '$pw_sql';
              GRANT ALL PRIVILEGES ON \`grimmory\`.* TO 'grimmory'@'%';
              FLUSH PRIVILEGES;
              EOF
            '';
          };
        };
      };

      virtualisation.oci-containers.containers.grimmory = {
        # renovate: datasource=docker depName=grimmory/grimmory
        image = "grimmory/grimmory:v3.1.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/grimmory/data:/app/data"
          "/mnt/content/books:/books"
          "/var/lib/containers/grimmory/bookdrop:/bookdrop"
        ];
        environment = {
          TZ = config.time.timeZone;
          USER_ID = toString serverUid;
          GROUP_ID = toString serverGid;
          DATABASE_URL = "jdbc:mariadb://host.containers.internal:3306/grimmory";
          DATABASE_USERNAME = "grimmory";
          SWAGGER_ENABLED = "false";
          FORCE_DISABLE_OIDC = "false";
        };
        environmentFiles = [ config.sops.templates."grimmory.env".path ];
      };

      myCaddy.apps.grimmory = {
        host = grimmoryHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
