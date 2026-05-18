# PostgreSQL - Simple Aspect
# Single shared native PostgreSQL instance for server apps.
#
# Two surfaces:
#   * The service itself — `services.postgresql` configured below.
#   * `myPostgresApp.<name> = { ... }` — the app-helper option, which
#     provisions a db + role via `ensureDatabases` / `ensureUsers`, a
#     sops secret for the role password, and a oneshot systemd unit
#     `<name>-db-password.service` that runs `ALTER USER … WITH
#     PASSWORD` on every secret rotation. `ensureUsers` only handles
#     unix-socket / peer auth; containerized apps connect over TCP
#     from the podman bridge and need password auth — that's why
#     every postgres-backed app needs this rotate-on-secret-change
#     oneshot, and doing it once here (instead of four times verbatim
#     across mealie/tandoor/paperless-ngx/etc.) is the point of the
#     helper.
#
# Apps that consume `myPostgresApp` still have to:
#   1. wire `POSTGRES_PASSWORD` (or whatever env var the upstream image
#      reads) into their own env file via the secret placeholder, and
#   2. point their consumer service at host.containers.internal:5432
#      with the matching role + dbName.
#
# Major version is pinned: upgrades are a manual operation
# (`nix-shell -p postgresql_<new>` + `upgrade-pg-cluster`) so we never
# get a silent dump/restore on rebuild.
_: {
  flake.modules.nixos.postgresql =
    {
      config,
      hostSpec,
      lib,
      pkgs,
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
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = ''
                    Systemd units that consume this role and must wait
                    for the password rotation oneshot to complete. The
                    oneshot is wired with `before` and `wantedBy` on
                    every listed unit, so no consumer ever starts with
                    a stale password. Pass every unit that opens a
                    connection (e.g. paperless-ngx with
                    paperless-{web,scheduler,task-queue,consumer})
                    rather than trusting transitive ordering through a
                    single representative unit.
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

      config = lib.mkMerge [
        {
          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_18;
            enableTCPIP = true;

            # Peer auth for native services on the Unix socket; scram for TCP.
            # Container apps connect from the default podman bridge (10.88.0.0/16).
            authentication = lib.mkOverride 10 ''
              local all all                peer
              host  all all 127.0.0.1/32   scram-sha-256
              host  all all ::1/128        scram-sha-256
              host  all all 10.88.0.0/16   scram-sha-256
            '';
          };
        }

        (lib.mkIf (apps != { }) {
          sops.secrets = lib.mapAttrs' (
            name: app:
            lib.nameValuePair app.secretName {
              inherit (hostSpec) sopsFile;
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
            let
              secretPath = config.sops.secrets.${app.secretName}.path;
            in
            lib.nameValuePair "${name}-db-password" {
              description = "Set ${name} postgres role password from sops secret";
              after = [
                "postgresql.service"
                "postgresql-setup.service"
                # Explicit ordering on the sops decryption unit
                # (sops.useSystemdActivation = true in modules/system/
                # sops.nix). Without this, the activation-script form of
                # sops races against an early-boot start of this unit:
                # the secret file may not exist yet when the script
                # below cats it. ConditionPathExists below still
                # belt-and-suspenders the case where sops *finishes* but
                # this particular secret failed to decrypt.
                "sops-install-secrets.service"
              ];
              requires = [ "postgresql.service" ];
              wants = [
                "postgresql-setup.service"
                "sops-install-secrets.service"
              ];
              wantedBy = app.consumerService;
              before = app.consumerService;
              # Skip the unit if sops hasn't decrypted *this specific*
              # secret yet (sops-install-secrets.service may report
              # success overall while a single entry failed — wrong age
              # key on file, blob shape changed upstream, etc.). Without
              # this guard the script below would cat a missing file,
              # send an empty password to ALTER USER, and silently lock
              # the app out of its DB. See #123 for the original
              # paperless-ngx near-miss that motivated the guard.
              unitConfig.ConditionPathExists = secretPath;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                User = "postgres";
                Group = "postgres";
              };
              script = ''
                set -euo pipefail
                if [ ! -s "${secretPath}" ]; then
                  echo "ERROR: sops secret ${secretPath} is empty — refusing to clear ${app.dbName} postgres password" >&2
                  exit 1
                fi
                ${config.services.postgresql.package}/bin/psql -tAc \
                  "ALTER USER ${app.dbName} WITH PASSWORD '$(cat ${secretPath})'"
              '';
            }
          ) apps;
        })
      ];
    };
}
