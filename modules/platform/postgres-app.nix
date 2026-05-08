# Postgres app helper (platform-tier).
# `myPostgresApp.<name> = { ... }` provisions:
#   * the postgres database + role (via services.postgresql.ensureDatabases / ensureUsers)
#   * a sops secret for the role password (sopsFile = host's yaml)
#   * a oneshot systemd unit `<name>-db-password.service` that runs
#     ALTER USER … WITH PASSWORD on every secret rotation
#
# `services.postgresql.ensureUsers` provisions unix-socket / peer auth
# only, but containerized apps connect over TCP from the podman bridge
# and need password auth — that's why every postgres-backed app needs
# this rotate-on-secret-change oneshot. Doing it once here, instead of
# four times verbatim across mealie/tandoor/paperless-ngx/etc., is the
# point of this module.
#
# Apps that consume this still have to:
#   1. wire `POSTGRES_PASSWORD` (or whatever env var the upstream image
#      reads) into their own env file via the secret placeholder, and
#   2. point their consumer service at host.containers.internal:5432
#      with the matching role + dbName.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.myPostgresApp =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      apps = config.myPostgresApp;
    in
    {
      options.myPostgresApp = lib.mkOption {
        default = { };
        description = ''
          Apps that consume the shared native postgres instance with a
          sops-managed password. The helper provisions the db + role +
          rotation oneshot; the app module is responsible for plumbing
          the password into its own env file and pointing the upstream
          service at host.containers.internal:5432.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                dbName = lib.mkOption {
                  type = lib.types.str;
                  default = lib.replaceStrings [ "-" ] [ "_" ] name;
                  description = ''
                    Postgres database (and role) name. Defaults to the
                    attribute name with hyphens replaced by underscores
                    (paperless-ngx → paperless_ngx) so the role name is
                    a valid SQL identifier.
                  '';
                };
                consumerService = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Systemd unit that consumes this role and must wait
                    for the password rotation oneshot to complete. The
                    oneshot is wired with `before` and `wantedBy` on
                    this unit, so the consumer never starts with a
                    stale password.
                  '';
                };
                secretName = lib.mkOption {
                  type = lib.types.str;
                  default = "${name}/db_password";
                  description = ''
                    sops secret name for the role's password. Defaults
                    to "<name>/db_password". Override only if the
                    secret already exists under a non-standard name.
                  '';
                };
              };
            }
          )
        );
      };

      config = lib.mkIf (apps != { }) {
        sops.secrets = lib.mapAttrs' (
          name: app:
          lib.nameValuePair app.secretName {
            sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
            owner = "postgres";
            restartUnits = [ "${name}-db-password.service" ];
          }
        ) apps;

        services.postgresql = {
          ensureDatabases = lib.mapAttrsToList (_: app: app.dbName) apps;
          ensureUsers = lib.mapAttrsToList (_: app: {
            name = app.dbName;
            ensureDBOwnership = true;
          }) apps;
        };

        systemd.services = lib.mapAttrs' (
          name: app:
          lib.nameValuePair "${name}-db-password" {
            description = "Set ${name} postgres role password from sops secret";
            after = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
            requires = [ "postgresql.service" ];
            wants = [ "postgresql-setup.service" ];
            wantedBy = [ app.consumerService ];
            before = [ app.consumerService ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              Group = "postgres";
            };
            script = ''
              ${config.services.postgresql.package}/bin/psql -tAc \
                "ALTER USER ${app.dbName} WITH PASSWORD '$(cat ${config.sops.secrets.${app.secretName}.path})'"
            '';
          }
        ) apps;
      };
    };
}
