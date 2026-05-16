# PostgreSQL - Simple Aspect
# Single shared native PostgreSQL instance for server apps. App modules
# extend ensureDatabases / ensureUsers and set scram-sha-256 passwords
# from sops; the boilerplate for the password-rotation oneshot is
# handled by myPostgresApp (modules/platform/postgres-app.nix), which
# this module pulls in so the option surface is available wherever
# postgres is enabled.
#
# Major version is pinned: upgrades are a manual operation
# (`nix-shell -p postgresql_<new>` + `upgrade-pg-cluster`) so we never
# get a silent dump/restore on rebuild.
{ inputs, ... }:
{
  flake.modules.nixos.postgresql =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ inputs.self.modules.nixos.myPostgresApp ];

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
    };
}
