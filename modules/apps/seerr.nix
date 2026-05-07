# Seerr - media request + discovery manager (Overseerr/Jellyseerr successor)
# Container; OIDC against authentik gated to the Users group. Seerr
# doesn't read OIDC settings from env vars — they live in its own
# settings.json — so this module only stages the authentik side
# (provider/application/policy binding via the blueprint, plus the
# env-file for the worker so `!Env` substitutions resolve). On first
# boot, complete owner setup, then add an OIDC provider in the Seerr
# UI under Settings → Users → OpenID Connect using the client_id /
# client_secret from `seerr/oidc_client_*` in sops; the blueprint
# already pins the redirect URIs to /login and
# /profile/settings/linked-accounts.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.seerr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      seerrHost = "seerr.${hostSpec.serverDomain}";
      port = 5055;
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "seerr/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
        "seerr/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
      };

      sops.templates."seerr-authentik.env" = {
        content = ''
          SEERR_OIDC_CLIENT_ID=${config.sops.placeholder."seerr/oidc_client_id"}
          SEERR_OIDC_CLIENT_SECRET=${config.sops.placeholder."seerr/oidc_client_secret"}
        '';
        restartUnits = restartAuthentik;
      };

      myAuthentik.extraBlueprints = [ ./seerr-blueprints ];

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/seerr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      systemd.services = {
        authentik.serviceConfig.EnvironmentFile = [
          config.sops.templates."seerr-authentik.env".path
        ];
        authentik-worker.serviceConfig.EnvironmentFile = [
          config.sops.templates."seerr-authentik.env".path
        ];
        authentik-migrate.serviceConfig.EnvironmentFile = [
          config.sops.templates."seerr-authentik.env".path
        ];
      };

      virtualisation.oci-containers.containers.seerr = {
        # renovate: datasource=docker depName=ghcr.io/seerr-team/seerr
        image = "ghcr.io/seerr-team/seerr:v3.0.1";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/seerr:/app/config"
        ];
        environment = {
          TZ = config.time.timeZone;
          PORT = toString port;
        };
      };

      myCaddy.apps.seerr = {
        host = seerrHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };

      myHomepage.services.Acquisition = [
        {
          Seerr = {
            href = "https://${seerrHost}";
            icon = "jellyseerr";
            description = "Media requests";
          };
        }
      ];
    };
}
