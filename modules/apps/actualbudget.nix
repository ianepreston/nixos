# Actual Budget - personal finance + budgeting
# Container; OIDC against authentik gated to the Home group. Actual
# reads OIDC config straight from env vars (ACTUAL_OPENID_*) so the
# whole flow is wired here — first OIDC user to log in becomes the
# server owner.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.actualbudget =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      actualHost = "actualbudget.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      port = 5006;
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "actualbudget/client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-actualbudget.service" ];
        };
        "actualbudget/client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "podman-actualbudget.service" ];
        };
      };

      sops.templates = {
        "actualbudget-authentik.env" = {
          content = ''
            ACTUALBUDGET_OIDC_CLIENT_ID=${config.sops.placeholder."actualbudget/client_id"}
            ACTUALBUDGET_OIDC_CLIENT_SECRET=${config.sops.placeholder."actualbudget/client_secret"}
          '';
          restartUnits = restartAuthentik;
        };
        "actualbudget.env" = {
          content = ''
            ACTUAL_OPENID_CLIENT_ID=${config.sops.placeholder."actualbudget/client_id"}
            ACTUAL_OPENID_CLIENT_SECRET=${config.sops.placeholder."actualbudget/client_secret"}
          '';
          restartUnits = [ "podman-actualbudget.service" ];
        };
      };

      myAuthentik.extraBlueprints = [ ./actualbudget-blueprints ];

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/actualbudget 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services = {
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."actualbudget-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."actualbudget-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."actualbudget-authentik.env".path
          ];
        };
      };

      virtualisation.oci-containers.containers.actualbudget = {
        # renovate: datasource=docker depName=actualbudget/actual-server
        image = "actualbudget/actual-server:26.5.0";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/actualbudget:/data"
        ];
        environment = {
          TZ = config.time.timeZone;
          ACTUAL_LOGIN_METHOD = "openid";
          ACTUAL_ALLOWED_LOGIN_METHODS = "password,openid";
          ACTUAL_OPENID_AUTH_METHOD = "openid";
          ACTUAL_OPENID_DISCOVERY_URL = "https://${authentikHost}/application/o/actualbudget/.well-known/openid-configuration";
          ACTUAL_OPENID_SERVER_HOSTNAME = "https://${actualHost}";
          ACTUAL_TRUSTED_PROXIES = "10.88.0.0/16,127.0.0.1/32";
        };
        environmentFiles = [ config.sops.templates."actualbudget.env".path ];
      };

      myCaddy.apps.actualbudget = {
        host = actualHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };

      myHomepage.services.Infrastructure = [
        {
          "Actual Budget" = {
            href = "https://${actualHost}";
            icon = "actual";
            description = "Personal finance";
          };
        }
      ];
    };
}
