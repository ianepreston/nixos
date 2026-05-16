# Jellyfin - media server
# Native services.jellyfin from nixpkgs (system user `jellyfin`,
# /var/lib/jellyfin for state). Hardware transcoding and OIDC are
# tracked as follow-ups; v1 is just the bare service + caddy + backups.
#
# Backups: /var/lib/jellyfin contains both XML config and the library
# SQLite databases. Restic snapshots the whole tree, but live SQLite
# files can be torn mid-write — the DB gets an extra consistent copy
# via `sqlite3 .backup` into /var/backup/sqlite/jellyfin/ before each
# restic run (mySqliteQuiesce helper). On restore, prefer the staged
# copy under /var/backup/sqlite/jellyfin/ over the live one under
# /var/lib/jellyfin/data/.
_: {
  flake.modules.nixos.jellyfin =
    { hostSpec, ... }:
    let
      jellyfinHost = "jellyfin.${hostSpec.serverDomain}";
      jellyfinPort = 8096;
    in
    {
      services.jellyfin = {
        enable = true;
        # Run as the shared server-env user so jellyfin can read media
        # off the NFS-mounted Synology share at /mnt/content. UIDs are
        # pinned to match the NAS (server-dev=1029, server-prod=1030,
        # group servers=65536) so NFS doesn't have to translate.
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      # Preservation defaults to root:root, but jellyfin runs as
      # server-${env}:servers and needs to mkdir under its own dir
      # (the bind-mount root). Match the service user/group.
      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/jellyfin";
          user = "server-${hostSpec.serverEnvironment}";
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/jellyfin" ];

      mySqliteQuiesce.apps.jellyfin.databases = [
        "/var/lib/jellyfin/data/jellyfin.db"
      ];

      myCaddy.apps.jellyfin = {
        host = jellyfinHost;
        routeConfig = ''
          reverse_proxy localhost:${toString jellyfinPort}
        '';
      };

      myHomepage.tiles.Jellyfin = {
        group = "Consumption";
        href = "https://${jellyfinHost}";
        icon = "jellyfin";
        description = "Media server";
      };
    };
}
