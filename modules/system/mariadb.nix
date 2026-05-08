# MariaDB - Simple Aspect
# Single shared native MariaDB instance for server apps. App modules
# extend ensureDatabases and run a per-app oneshot that creates an
# '<app>'@'%' role with a sops-managed password and grants on the
# app's database.
#
# Why not ensureUsers for app roles? `ensureUsers` provisions accounts
# with the unix_socket auth plugin only, which works for native services
# but not for container apps that connect over TCP from the podman
# bridge — they need password auth. So apps drive their own role/grant
# script (see modules/apps/grimmory.nix for the canonical example).
#
# Major version is pinned: upgrades are a manual operation
# (mariadb-upgrade after switching the package) so we never get a
# silent on-disk format change on rebuild.
_: {
  flake.modules.nixos.mariadb =
    {
      pkgs,
      ...
    }:
    {
      services.mysql = {
        enable = true;
        package = pkgs.mariadb_114;

        settings.mysqld = {
          # Listen on all interfaces so containers on the podman bridge
          # (10.88.0.0/16) can reach 3306 via host.containers.internal.
          # The host firewall blocks 3306 on the external NIC; podman0
          # is in trustedInterfaces (see oci-containers.nix), so this
          # surface is only loopback + the bridge in practice.
          bind-address = "0.0.0.0";
        };
      };
    };
}
