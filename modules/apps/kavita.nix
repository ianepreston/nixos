# Kavita - reading server (manga, comics, books)
# Container; OIDC against authentik gated to the Users group. Kavita
# doesn't read OIDC settings from env vars — they live in the
# Settings → Authentication → OpenID Connect UI — so this module
# registers via myAuthentik.oidcApps with clientCredsInAppEnv = false.
# On first boot, complete owner setup, then enter Authority
# `https://authentik.dnix.ipreston.net/application/o/kavita/` plus the
# client_id / client_secret from `kavita/oidc_client_*` in sops; the
# blueprint already pins the redirect URIs to /signin-oidc and
# /signout-callback-oidc.
_: {
  flake.modules.nixos.kavita =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      kavitaHost = "kavita.${hostSpec.serverDomain}";
      port = 5000;
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

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/kavita 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/kavita/config 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.kavita = {
        # renovate: datasource=docker depName=jvmilazz0/kavita
        image = "jvmilazz0/kavita:0.9.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/kavita/config:/kavita/config"
          "/mnt/content/comics:/comics"
          "/mnt/content/books:/books"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };

      myCaddy.apps.kavita = {
        host = kavitaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
