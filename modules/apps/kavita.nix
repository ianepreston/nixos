# Kavita - reading server (manga, comics, books)
# Native services.kavita from nixpkgs (.NET service running as the
# shared server-${env}:servers user so reads against /mnt/content/
# {Comics,books} keep their NFS UID alignment). OIDC against authentik
# is configured in Settings → Authentication → OpenID Connect in the
# kavita UI; this module only stages the authentik side.
#
# Token key (JWT signing secret) is generated locally by a one-shot
# the first time the unit comes up and persisted under the data dir.
# Kavita's preStart rewrites appsettings.json on every restart, so
# `services.kavita.settings` is the source of truth for everything
# inside that file (TokenKey gets templated in via @TOKEN@).
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
        displayName = "Kavita";
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

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/kavita";
          user = kavitaUser;
          group = "servers";
          mode = "0750";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/kavita" ];

      mySqliteQuiesce.apps.kavita.databases = [
        "/var/lib/kavita/config/kavita.db"
      ];

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

      myCaddy.apps.kavita = {
        host = kavitaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
