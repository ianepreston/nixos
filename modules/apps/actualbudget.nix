# Actual Budget - personal finance + budgeting
# Container; OIDC against authentik gated to the Home group. Actual
# reads OIDC config straight from env vars (ACTUAL_OPENID_*) so the
# whole flow is wired here — first OIDC user to log in becomes the
# server owner.
_: {
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
    in
    {
      myAuthentik.oidcApps.actualbudget = {
        blueprintsDir = ./actualbudget-blueprints;
        appRestartUnit = [ "podman-actualbudget.service" ];
        clientIdVar = "ACTUAL_OPENID_CLIENT_ID";
        clientSecretVar = "ACTUAL_OPENID_CLIENT_SECRET";
        homepage = {
          group = "Home";
          icon = "actual-budget";
          description = "Personal finance";
        };
        displayName = "Actual Budget";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/actualbudget 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.actualbudget = {
        # renovate: datasource=docker depName=actualbudget/actual-server
        image = "actualbudget/actual-server:26.5.2";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/actualbudget:/data"
        ];
        environment = {
          TZ = config.time.timeZone;
          ACTUAL_LOGIN_METHOD = "openid";
          ACTUAL_ALLOWED_LOGIN_METHODS = "password,openid";
          ACTUAL_USER_CREATION_MODE = "login";
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
    };
}
