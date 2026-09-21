# Recovery manifest - app-owned metadata for the operator recovery dispatcher.
#
# The taskfile still owns the restore mechanics: stopping units, restic,
# postgres replay, SQLite replacement, and health polling.  App modules own
# the facts those mechanics need.  Keeping this beside the service declaration
# prevents a second, manually synchronized inventory from drifting.
_: {
  flake.modules.nixos.recovery =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (config.myRecovery) apps;
      sqliteApps = config.mySqliteQuiesce.apps;
      sqliteRoot = "/var/backup/sqlite";
      orders = map (app: app.order) (lib.attrValues apps);

      manifest = lib.mapAttrs (name: app: {
        inherit (app)
          database
          health
          kind
          order
          units
          ;
        paths = app.paths ++ lib.optional (app.kind == "sqlite") "${sqliteRoot}/${name}";
        swaps =
          if app.kind == "sqlite" then
            map (live: {
              staged = "${sqliteRoot}/${name}/${builtins.baseNameOf live}";
              inherit live;
              owner = app.sqliteOwner;
            }) (sqliteApps.${name}.databases or [ ])
          else
            [ ];
      }) apps;
    in
    {
      options.myRecovery = {
        apps = lib.mkOption {
          default = { };
          description = ''
            Recovery metadata contributed by server-app modules. `task
            recovery:app APP=<name>` evaluates the generated manifest and
            passes these values to the existing restore templates.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                kind = lib.mkOption {
                  type = lib.types.enum [
                    "volume"
                    "postgres"
                    "sqlite"
                  ];
                  description = "Existing recovery template this app uses.";
                };
                order = lib.mkOption {
                  type = lib.types.int;
                  description = ''
                    Explicit catastrophic-restore ordering. Leave gaps between
                    values so a new dependency can be inserted without
                    renumbering unrelated apps.
                  '';
                };
                units = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Systemd units stopped and started around the restore.";
                };
                paths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Non-Postgres paths restored with the app.";
                };
                database = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Postgres database replayed by the postgres template.";
                };
                sqliteOwner = lib.mkOption {
                  type = lib.types.str;
                  default = "@env@";
                  description = ''
                    Owner passed to the SQLite swap template. The default is
                    the target host's server-environment user; services with
                    their own static user override it.
                  '';
                };
                health = lib.mkOption {
                  default = null;
                  description = "Optional loopback HTTP health probe after restoration.";
                  type = lib.types.nullOr (
                    lib.types.submodule {
                      options = {
                        url = lib.mkOption { type = lib.types.str; };
                        expect = lib.mkOption {
                          type = lib.types.str;
                          default = "200";
                        };
                        retries = lib.mkOption {
                          type = lib.types.int;
                          default = 30;
                        };
                        sleep = lib.mkOption {
                          type = lib.types.int;
                          default = 2;
                        };
                      };
                    }
                  );
                };
              };
            }
          );
        };

        manifest = lib.mkOption {
          readOnly = true;
          type = lib.types.attrsOf lib.types.anything;
          description = ''
            Machine-readable recovery metadata generated from `apps` and the
            existing SQLite-quiesce declarations. It contains no secrets and
            is intended for `nix eval --json` by taskfiles/recovery.yaml.
          '';
        };
      };

      config = {
        myRecovery.manifest = manifest;

        assertions =
          lib.mapAttrsToList (name: app: {
            assertion =
              (app.kind == "postgres") == (app.database != null)
              && (app.kind != "sqlite" || builtins.hasAttr name sqliteApps);
            message = ''
              myRecovery.apps.${name}: postgres entries require `database` and
              only postgres entries may set it; sqlite entries require a
              matching mySqliteQuiesce.apps.${name} declaration.
            '';
          }) apps
          ++ [
            {
              assertion = builtins.length orders == builtins.length (lib.unique orders);
              message = "myRecovery.apps: every app must have a unique catastrophic-restore order.";
            }
          ];
      };
    };
}
