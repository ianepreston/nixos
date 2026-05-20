# Jellyfin - media server
# Native services.jellyfin from nixpkgs (system user `jellyfin`,
# /var/lib/jellyfin for state). Hardware transcoding is tracked as
# a follow-up.
#
# Auth: shared credentials with authentik via LDAP rather than OIDC.
# Most jellyfin clients are TVs / native apps that can't do an SSO
# redirect anyway, so OIDC's only benefit (the web-client redirect)
# wasn't worth depending on the archived 9p4/jellyfin-plugin-sso.
# `jellyfin/jellyfin-plugin-ldapauth` is officially maintained under
# the jellyfin org and binds against the authentik LDAP outpost
# (services.authentik-ldap on loopback :3389). This module requests
# the outpost via `myAuthentik.ldap.enable`; the blueprint creates
# everything including a pre-stamped outpost token so no UI steps are
# needed (see goauthentik/authentik#9711). Only manual one-time bit
# is installing the LDAP plugin DLL inside jellyfin and filling its
# config form — see the Jellyfin section of the README.
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
      myAuthentik.ldap.enable = true;

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
