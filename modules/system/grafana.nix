# Grafana — dashboards + provisioned datasources, OIDC against
# Authentik via myAuthentik.oidcApps.
#
# Auth model. Per #65 comment, every UI exposed by the observability
# stack is gated on Authentik group `Infrastructure`. Grafana speaks
# OIDC natively; the Authentik blueprint (./grafana-blueprints/) pins
# the launcher tile to the Infrastructure group and Grafana itself
# accepts anyone who completes OIDC, then maps roles from the
# `groups` claim.
#
# OIDC plumbing is dogfooded through `myAuthentik.oidcApps.grafana`:
# sops secrets land at grafana/oidc_client_{id,secret} and the platform
# module renders both a per-app env file (consumed by grafana via
# EnvironmentFile + GF_AUTH_GENERIC_OAUTH_CLIENT_*) and a worker env
# entry (GRAFANA_OIDC_CLIENT_* — referenced by !Env in the blueprint).
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.grafana =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      grafanaHost = "grafana.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";

      grafanaPort = 3000;
      prometheusPort = 9090;
      alertmanagerPort = 9093;
      lokiPort = 3100;

      dashboardsDir = pkgs.runCommandLocal "grafana-dashboards" { } ''
        mkdir -p $out
        cp -r ${./_grafana-dashboards}/. $out/
      '';
    in
    {
      # OIDC client_id/_secret via the platform aggregator. The
      # platform module owns the sops.secrets.grafana/oidc_client_{id,
      # secret} entries; we wire the per-app env file onto
      # grafana.service below so the GF_AUTH_GENERIC_OAUTH_CLIENT_*
      # vars resolve at start-up. The worker side picks up
      # GRAFANA_OIDC_CLIENT_* automatically from the merged worker
      # env file the platform module stacks onto authentik.
      myAuthentik.oidcApps.grafana = {
        blueprintsDir = ./grafana-blueprints;
        clientCredsInAppEnv = true;
        appRestartUnit = [ "grafana.service" ];
        clientIdVar = "GF_AUTH_GENERIC_OAUTH_CLIENT_ID";
        clientSecretVar = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET";
        homepage = {
          group = "Infrastructure";
          icon = "grafana";
          description = "dashboards";
        };
        homepageDisplayName = "Grafana";
        homepageHref = "https://${grafanaHost}";
      };

      # Bootstrap password is separate from OIDC: it's the local admin
      # account password, read via $__file{} (no env). Owned by
      # grafana so the unit can read it.
      sops.secrets."grafana/bootstrap_password" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        owner = "grafana";
        restartUnits = [ "grafana.service" ];
      };

      # The platform module wires the per-app env file's path into
      # sops.templates."grafana.env"; stack it onto grafana.service so
      # GF_AUTH_GENERIC_OAUTH_CLIENT_{ID,SECRET} are in scope at start.
      systemd.services.grafana.serviceConfig.EnvironmentFile = [
        config.sops.templates."grafana.env".path
      ];

      services.grafana = {
        enable = true;
        settings = {
          server = {
            http_addr = "127.0.0.1";
            http_port = grafanaPort;
            domain = grafanaHost;
            root_url = "https://${grafanaHost}/";
          };
          analytics.reporting_enabled = false;
          security = {
            # `$__file{}` reads the secret out of the sops-decrypted
            # path at runtime, so the password never lands in the
            # rendered grafana.ini in /nix/store.
            admin_password = "$__file{${config.sops.secrets."grafana/bootstrap_password".path}}";
          };
          # OIDC against Authentik. `role_attribute_path` is JMESPath
          # over the id_token claims — `Infrastructure` group → Admin,
          # everyone else who somehow makes it past the Authentik app
          # binding → Viewer. client_id / client_secret come from the
          # platform-managed env file (GF_AUTH_GENERIC_OAUTH_CLIENT_*
          # — grafana auto-merges GF_-prefixed env vars into settings).
          "auth.generic_oauth" = {
            enabled = true;
            name = "Authentik";
            scopes = "openid email profile";
            auth_url = "https://${authentikHost}/application/o/authorize/";
            token_url = "https://${authentikHost}/application/o/token/";
            api_url = "https://${authentikHost}/application/o/userinfo/";
            login_attribute_path = "preferred_username";
            email_attribute_path = "email";
            name_attribute_path = "name";
            groups_attribute_path = "groups";
            role_attribute_path = "contains(groups[*], 'Infrastructure') && 'Admin' || 'Viewer'";
            allow_assign_grafana_admin = false;
            auto_login = false;
            # We restrict access at the Authentik app/policy binding,
            # not here, so users coming through OIDC are already
            # vetted; allow auto-signup so first login provisions the
            # local Grafana account.
            allow_sign_up = true;
            use_pkce = true;
          };
          users = {
            auto_assign_org = true;
            auto_assign_org_role = "Viewer";
          };
        };

        provision = {
          enable = true;
          # UIDs are pinned (rather than letting Grafana
          # auto-generate) so provisioned dashboards can reference
          # them by literal `"uid": "prometheus"` instead of
          # `${DS_PROMETHEUS}` placeholders that need import-time
          # resolution.
          datasources.settings.datasources = [
            {
              name = "Prometheus";
              uid = "prometheus";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString prometheusPort}";
              isDefault = true;
              # Tell Grafana the scrape interval so $__rate_interval
              # stays >= 4 * 30s = 2m (always wide enough for rate()).
              jsonData.timeInterval = "30s";
            }
            {
              name = "Loki";
              uid = "loki";
              type = "loki";
              access = "proxy";
              url = "http://127.0.0.1:${toString lokiPort}";
            }
            {
              name = "Alertmanager";
              uid = "alertmanager";
              type = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString alertmanagerPort}";
              jsonData.implementation = "prometheus";
            }
          ];
          dashboards.settings.providers = [
            {
              name = "homelab";
              type = "file";
              folder = "Homelab";
              updateIntervalSeconds = 30;
              allowUiUpdates = false;
              options.path = "${dashboardsDir}";
              options.foldersFromFilesStructure = true;
            }
          ];
        };
      };

      # ========== Caddy route ==========
      # Grafana speaks OIDC natively, so no forward_auth here. The
      # Authentik app binding (in ./grafana-blueprints/) still pins
      # the launcher tile to the Infrastructure group; this route is
      # the destination of the OIDC redirect.
      myCaddy.apps.grafana = {
        host = grafanaHost;
        routeConfig = ''
          reverse_proxy localhost:${toString grafanaPort}
        '';
      };
    };
}
