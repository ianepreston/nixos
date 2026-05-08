# Kavita - reading server (manga, comics, books)
# Container; OIDC against authentik gated to the Users group. Kavita
# doesn't read OIDC settings from env vars — they live in the
# Settings → Authentication → OpenID Connect UI — so this module only
# stages the authentik side (provider/application/policy binding via
# the blueprint, plus the env-file for the worker so `!Env`
# substitutions resolve). On first boot, complete owner setup, then
# enter Authority `https://authentik.dnix.ipreston.net/application/o/kavita/`
# plus the client_id / client_secret from `kavita/oidc_client_*` in
# sops; the blueprint already pins the redirect URIs to /signin-oidc
# and /signout-callback-oidc.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
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
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "kavita/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
        "kavita/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
      };

      sops.templates."kavita-authentik.env" = {
        content = ''
          KAVITA_OIDC_CLIENT_ID=${config.sops.placeholder."kavita/oidc_client_id"}
          KAVITA_OIDC_CLIENT_SECRET=${config.sops.placeholder."kavita/oidc_client_secret"}
        '';
        restartUnits = restartAuthentik;
      };

      myAuthentik.extraBlueprints = [ ./kavita-blueprints ];

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/kavita 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/kavita/config 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services = {
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."kavita-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."kavita-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."kavita-authentik.env".path
          ];
        };
      };

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

      myHomepage.tiles.Kavita = {
        group = "Consumption";
        href = "https://${kavitaHost}";
        icon = "kavita";
        description = "Manga + books";
      };
    };
}
