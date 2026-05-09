# Kavita - reading server (manga, comics, books)
# Native services.kavita from nixpkgs (.NET service running as the
# shared server-${env}:servers user so reads against /mnt/content/
# {comics,books} keep their NFS UID alignment). OIDC against authentik
# is configured in Settings → Authentication → OpenID Connect in the
# kavita UI; this module only stages the authentik side.
#
# Token key (JWT signing secret) is generated locally by a one-shot
# the first time the unit comes up and persisted under the data dir.
# Kavita's preStart rewrites appsettings.json on every restart, so
# `services.kavita.settings` is the source of truth for everything
# inside that file (TokenKey gets templated in via @TOKEN@).
#
# Library paths after migration: the container exposed the shares at
# /comics and /books via bind-mounts; the native service runs in the
# host namespace, so update each library in the kavita UI to
# /mnt/content/comics and /mnt/content/books.
_: {
  flake.modules.nixos.kavita =
    {
      hostSpec,
      lib,
      ...
    }:
    let
      kavitaHost = "kavita.${hostSpec.serverDomain}";
      port = 5000;
      tokenKeyFile = "/var/lib/kavita/token-key";
      kavitaUser = "server-${hostSpec.serverEnvironment}";
    in
    {
      myAuthentik.oidcApps.kavita = {
        blueprintsDir = ./kavita-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Consumption";
          icon = "kavita";
          description = "Manga + books";
        };
        homepageDisplayName = "Kavita";
        homepageHref = "https://${kavitaHost}";
      };

      services.kavita = {
        enable = true;
        user = kavitaUser;
        inherit tokenKeyFile;
        settings = {
          Port = port;
          IpAddresses = "127.0.0.1";
        };
      };

      # Unlike jellyfin (whose nixpkgs module gates `users.users.${cfg
      # .user} = {...}` on `mkIf (cfg.user == "jellyfin")`), the kavita
      # module unconditionally writes `users.users.${cfg.user}.group =
      # cfg.user`. With cfg.user = server-${env}, that collides with
      # server-users.nix's `group = "servers"` on the same UID-pinned
      # user. Force the NAS-aligned `servers` group; the empty
      # `server-${env}` group kavita also creates is dangling but
      # harmless since user-perm checks always win when EUID matches
      # the file owner.
      users.users.${kavitaUser}.group = lib.mkForce "servers";

      services.restic.backups.server.paths = [ "/var/lib/kavita" ];

      systemd.services.kavita-token-init = {
        description = "Generate kavita JWT signing key on first boot";
        before = [ "kavita.service" ];
        wantedBy = [ "kavita.service" ];
        unitConfig.ConditionPathExists = "!${tokenKeyFile}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0750 -o ${kavitaUser} -g servers /var/lib/kavita
          umask 0177
          head -c 64 /dev/urandom | base64 --wrap=0 > ${tokenKeyFile}
          chown ${kavitaUser}:servers ${tokenKeyFile}
        '';
      };

      systemd.services.kavita-migrate-state = {
        description = "Migrate kavita state from container layout";
        before = [ "kavita.service" ];
        wantedBy = [ "kavita.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/kavita";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # Container had /var/lib/containers/kavita/config; native
        # expects /var/lib/kavita/config — same subdir name, different
        # parent. Move the whole tree, then drop the appsettings.json
        # that the container wrote (kavita's preStart will rewrite it
        # on next start, and the old TokenKey is now stale anyway).
        script = ''
          if [ ! -e /var/lib/kavita ] || [ -z "$(ls -A /var/lib/kavita 2>/dev/null)" ]; then
            rm -rf /var/lib/kavita
            mv /var/lib/containers/kavita /var/lib/kavita
            rm -f /var/lib/kavita/config/appsettings.json
          fi
        '';
      };

      myCaddy.apps.kavita = {
        host = kavitaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
