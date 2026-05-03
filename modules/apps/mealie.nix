# Mealie - recipe manager
# Composes the OCI container, its caddy virtualHost, and a postgres
# database/user with a sops-managed password. First app on the
# server-app pattern; future apps follow the same shape.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.mealie =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
    in
    {
      sops.secrets."mealie/db_password" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        owner = "postgres";
        # Re-apply the password to postgres whenever the secret changes.
        restartUnits = [ "mealie-db-password.service" ];
      };

      sops.templates."mealie.env" = {
        content = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."mealie/db_password"}
        '';
        # Re-render env + restart container when the secret changes.
        restartUnits = [ "podman-mealie.service" ];
      };

      services.postgresql = {
        ensureDatabases = [ "mealie" ];
        ensureUsers = [
          {
            name = "mealie";
            ensureDBOwnership = true;
          }
        ];
      };

      # Sets mealie's postgres password from the sops secret. Runs after the
      # role exists (postgresql-setup creates it via ensureUsers) and before
      # the container starts, so mealie never tries to connect with a
      # password that doesn't match what postgres has on file. Splitting this
      # out of postgresql-setup.postStart avoids the failure mode where the
      # secret hasn't been decrypted yet and postgres clears the password.
      systemd.services.mealie-db-password = {
        description = "Set mealie postgres role password from sops secret";
        after = [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        requires = [ "postgresql.service" ];
        wants = [ "postgresql-setup.service" ];
        wantedBy = [ "podman-mealie.service" ];
        before = [ "podman-mealie.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          ${config.services.postgresql.package}/bin/psql -tAc \
            "ALTER USER mealie WITH PASSWORD '$(cat ${config.sops.secrets."mealie/db_password".path})'"
        '';
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/mealie 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.mealie = {
        # renovate: datasource=docker depName=ghcr.io/mealie-recipes/mealie
        image = "ghcr.io/mealie-recipes/mealie:v3.16.0";
        ports = [ "127.0.0.1:9925:9000" ];
        volumes = [ "/var/lib/mealie:/app/data" ];
        user = "${toString serverUid}:${toString serverGid}";
        environment = {
          ALLOW_SIGNUP = "false";
          BASE_URL = "http://mealie.dnix.ipreston.net";
          DB_ENGINE = "postgres";
          POSTGRES_USER = "mealie";
          POSTGRES_SERVER = "host.containers.internal";
          POSTGRES_PORT = "5432";
          POSTGRES_DB = "mealie";
          TZ = config.time.timeZone;
        };
        environmentFiles = [ config.sops.templates."mealie.env".path ];
      };

      services.caddy.virtualHosts."http://mealie.dnix.ipreston.net".extraConfig = ''
        reverse_proxy localhost:9925
      '';
    };
}
