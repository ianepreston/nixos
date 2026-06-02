# Seerr - media request + discovery manager (Overseerr/Jellyseerr successor)
# Container; OIDC against authentik gated to the Users group. Seerr
# doesn't read OIDC settings from env vars — they live in its own
# settings.json — so this module registers via myAuthentik.oidcApps
# with clientCredsInAppEnv = false. On first boot, complete owner
# setup, then add an OIDC provider in the Seerr UI under Settings →
# Users → OpenID Connect using the client_id / client_secret from
# `seerr/oidc_client_*` in sops; the blueprint already pins the
# redirect URIs to /login and /profile/settings/linked-accounts.
_: {
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
    in
    {
      myAuthentik.oidcApps.seerr = {
        blueprintsDir = ./seerr-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Requests";
          icon = "jellyseerr";
          description = "Media requests";
          widget = {
            type = "jellyseerr";
            url = "http://localhost:${toString port}";
            key = "{{HOMEPAGE_VAR_SEERR_API_KEY}}";
          };
        };
        displayName = "Seerr";
      };

      # Seerr API key lives in main.apiKey of its settings.json (the
      # container's /app/config is bind-mounted at /var/lib/containers/seerr).
      # Must use jq + explicit path — settings.json has additional
      # `apiKey` fields under per-arr-server configs that a regex match
      # would also pick up. The file is generated on first boot, so the
      # homepage-credentials retry loop covers the case where seerr has
      # just started but hasn't written it yet.
      myHomepage.credentials.SEERR_API_KEY = {
        sourceUnit = "podman-seerr.service";
        readScript = ''
          jq -r '.main.apiKey // empty' /var/lib/containers/seerr/settings.json
        '';
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/seerr 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.seerr = {
        # renovate: datasource=docker depName=ghcr.io/seerr-team/seerr
        image = "ghcr.io/seerr-team/seerr:v3.3.0";
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
    };
}
