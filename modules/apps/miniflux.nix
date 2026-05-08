# Miniflux - RSS reader
# Native NixOS module (services.miniflux), not a container — miniflux
# is a single Go binary so the upstream module is a better fit than
# wrapping it in podman.
#
# Postgres: createDatabaseLocally provisions the miniflux DB/role and
# connects over the unix socket via peer auth (DynamicUser=miniflux).
# No password to manage. Restic snapshots /var/backup/postgresql, so
# `services.postgresqlBackup` covers miniflux state automatically; the
# DynamicUser RuntimeDirectory has no persistent state to back up.
#
# OIDC against Authentik. CREATE_ADMIN=false because OAUTH2_USER_CREATION
# auto-provisions accounts on first login; admin user/password isn't
# needed. OAuth2 client creds go through sops as MINIFLUX_OAUTH2_* on
# the authentik worker side and OAUTH2_CLIENT_ID/SECRET on the miniflux
# side, mirroring the mealie pattern.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.miniflux =
    {
      config,
      hostSpec,
      ...
    }:
    let
      minifluxHost = "miniflux.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "miniflux/client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "miniflux.service" ];
        };
        "miniflux/client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik ++ [ "miniflux.service" ];
        };
      };

      sops.templates = {
        "miniflux.env" = {
          content = ''
            OAUTH2_CLIENT_ID=${config.sops.placeholder."miniflux/client_id"}
            OAUTH2_CLIENT_SECRET=${config.sops.placeholder."miniflux/client_secret"}
          '';
          restartUnits = [ "miniflux.service" ];
        };
        # Same secret values exposed under MINIFLUX_OAUTH2_* names so
        # the authentik worker can substitute them into the blueprint.
        "miniflux-authentik.env" = {
          content = ''
            MINIFLUX_OAUTH2_CLIENT_ID=${config.sops.placeholder."miniflux/client_id"}
            MINIFLUX_OAUTH2_CLIENT_SECRET=${config.sops.placeholder."miniflux/client_secret"}
          '';
          restartUnits = restartAuthentik;
        };
      };

      services.miniflux = {
        enable = true;
        config = {
          LISTEN_ADDR = "127.0.0.1:8089";
          BASE_URL = "https://${minifluxHost}";
          CREATE_ADMIN = false;
          OAUTH2_PROVIDER = "oidc";
          OAUTH2_OIDC_DISCOVERY_ENDPOINT = "https://${authentikHost}/application/o/miniflux/";
          OAUTH2_OIDC_PROVIDER_NAME = "Authentik";
          OAUTH2_REDIRECT_URL = "https://${minifluxHost}/oauth2/oidc/callback";
          OAUTH2_USER_CREATION = 1;
          DISABLE_LOCAL_AUTH = 1;
        };
      };

      systemd.services = {
        miniflux.serviceConfig.EnvironmentFile = [
          config.sops.templates."miniflux.env".path
        ];

        # Stack the miniflux-authentik env file onto authentik so the
        # worker has MINIFLUX_OAUTH2_* in scope when applying blueprints.
        authentik.serviceConfig.EnvironmentFile = [
          config.sops.templates."miniflux-authentik.env".path
        ];
        authentik-worker.serviceConfig.EnvironmentFile = [
          config.sops.templates."miniflux-authentik.env".path
        ];
        authentik-migrate.serviceConfig.EnvironmentFile = [
          config.sops.templates."miniflux-authentik.env".path
        ];
      };

      myAuthentik.extraBlueprints = [ ./miniflux-blueprints ];

      myCaddy.apps.miniflux = {
        host = minifluxHost;
        routeConfig = ''
          reverse_proxy localhost:8089
        '';
      };

      myHomepage.tiles.Miniflux = {
        group = "Consumption";
        href = "https://${minifluxHost}";
        icon = "miniflux";
        description = "RSS reader";
      };
    };
}
