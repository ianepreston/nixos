# Omnigent server - control plane (API, web UI, session persistence).
# Native module from the omnigent-nix flake (`inputs.omnigent`), not a
# container. The flake's core module owns the hardened systemd unit and
# publishes `listenUrl` / `publicUrl` / `healthPath` / `stateDir`; this module
# translates that contract into the repo's typed surfaces (myCaddy, myAppState,
# myRecovery, myObservability) instead of importing the flake's caddy adapter.
#
# Off by default: `myOmnigent.enable = true` in a host file turns it on. The
# server never executes agent work and the machine must not be registered as a
# host.
#
# Postgres: the flake's `postgresql` adapter creates the `omnigent` database and
# role and connects over the unix socket with peer auth (fixed user `omnigent`),
# so there is no db_password to manage. Restic snapshots /var/backup/postgresql.
#
# Auth: the built-in `accounts` provider, so the app's own login is required for
# every request. Caddy deliberately does NOT add authentik forward-auth: hosts
# and the desktop talk to the API with non-browser clients that cannot follow an
# authentik redirect. The cookie secret is generated into the state directory on
# first start (preserved and backed up via myAppState); no sops secret is
# needed. The first account created becomes the administrator, so create it
# right after enabling.
{ inputs, ... }:
{
  flake.modules.nixos.omnigent =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      cfg = config.myOmnigent;
      server = config.services.omnigent;
      omnigentHost = "omnigent.${hostSpec.serverDomain}";
    in
    {
      imports = [
        inputs.omnigent.nixosModules.omnigent
        inputs.omnigent.nixosModules.postgresql
      ];

      options.myOmnigent.enable = lib.mkEnableOption ''
        the Omnigent server. Off by default; see the header of
        modules/apps/omnigent.nix for what turning it on does'';

      config = lib.mkIf cfg.enable {
        services.omnigent = {
          enable = true;
          listen.port = 8094;
          publicUrl = "https://${omnigentHost}";
          auth.provider = "accounts";
          postgresql.createLocally = true;
        };

        myObservability.monitoredSystemdUnits = [ "omnigent" ];

        # The adapter pins the service to the fixed `omnigent` user/group (peer
        # auth needs a role-named user), so state is owned by that user.
        myAppState.omnigent = {
          inherit (server) stateDir user group;
        };

        myRecovery.apps.omnigent = {
          kind = "postgres";
          order = 295;
          units = [ "omnigent.service" ];
          database = "omnigent";
          paths = [ server.stateDir ];
          health.url = "${server.listenUrl}${server.healthPath}";
        };

        myCaddy.apps.omnigent = {
          host = omnigentHost;
          # Unbuffered so the UI's long-lived streaming connections work.
          routeConfig = ''
            reverse_proxy ${server.listenUrl} {
              flush_interval -1
            }
          '';
        };
      };
    };
}
