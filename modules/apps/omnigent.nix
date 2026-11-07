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
# needed.
#
# First-account bootstrap. The first account registered becomes the
# administrator, and the omnigent-nix flake exposes no way to pre-seed an admin
# or close sign-up. So the route is closed until a human has
# claimed that account from a trusted client:
#   1. `myOmnigent.enable = true`, leave `bootstrapped = false`, and set
#      `myOmnigent.bootstrapClients` to the address(es) of the machine you will
#      register from. While `bootstrapped` is false Caddy proxies only those
#      clients and answers 403 to everyone else (an empty list closes the route
#      entirely).
#   2. Deploy, open the public URL from that machine and create the admin
#      account.
#   3. Set `myOmnigent.bootstrapped = true` (and drop `bootstrapClients`) and
#      deploy: the route is then open to every client, as for other apps here.
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

      options.myOmnigent = {
        enable = lib.mkEnableOption ''
          the Omnigent server. Off by default; see the header of
          modules/apps/omnigent.nix for what turning it on does'';

        bootstrapped = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether the first (administrator) account has been created. While
            false, the Caddy route only serves `bootstrapClients`, because the
            first registrant becomes the administrator. Set true after
            creating that account; see the header of this module.
          '';
        };

        bootstrapClients = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "192.168.10.50" ];
          description = ''
            Client addresses or CIDRs (Caddy `remote_ip`) allowed to reach the
            route while `bootstrapped` is false. Empty closes the route to
            everyone. Ignored once `bootstrapped` is true.
          '';
        };
      };

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
          database = server.postgresql.name;
          paths = [ server.stateDir ];
          health.url = "${server.listenUrl}${server.healthPath}";
        };

        myCaddy.apps.omnigent = {
          host = omnigentHost;
          # Unbuffered so the UI's long-lived streaming connections work.
          routeConfig =
            let
              proxy = ''
                reverse_proxy ${server.listenUrl} {
                  flush_interval -1
                }
              '';
            in
            if cfg.bootstrapped then
              proxy
            else
              ''
                # Not bootstrapped: only the listed clients may reach the app,
                # so a stranger cannot register the administrator account.
                @bootstrap remote_ip ${
                  if cfg.bootstrapClients == [ ] then "127.0.0.1" else lib.concatStringsSep " " cfg.bootstrapClients
                }
                handle @bootstrap {
                  ${proxy}
                }
                handle {
                  respond "Omnigent is not open yet" 403
                }
              '';
        };
      };
    };
}
