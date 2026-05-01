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
      };

      sops.templates."mealie.env" = {
        content = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."mealie/db_password"}
        '';
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

      systemd.services.postgresql-setup.postStart = ''
        psql -tAc "ALTER USER mealie WITH PASSWORD '$(cat ${
          config.sops.secrets."mealie/db_password".path
        })'"
      '';

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
