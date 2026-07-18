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
# needed. OAuth2 client creds are wired through myAuthentik.oidcApps,
# which generates the per-app env file with OAUTH2_CLIENT_ID/SECRET and
# stacks the worker-side MINIFLUX_OAUTH2_* vars onto authentik.
_: {
  flake.modules.nixos.miniflux =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      minifluxHost = "miniflux.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
    in
    {
      myAuthentik.oidcApps.miniflux = {
        blueprintsDir = ./miniflux-blueprints;
        appRestartUnit = [ "miniflux.service" ];
        clientIdVar = "OAUTH2_CLIENT_ID";
        clientSecretVar = "OAUTH2_CLIENT_SECRET";
        homepage = {
          group = "Consumption";
          icon = "miniflux";
          description = "RSS reader";
        };
        displayName = "Miniflux";
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
          # Override the default User-Agent. Miniflux's default
          # ("Mozilla/5.0 (compatible; Miniflux/x.y.z; +https://miniflux.app)")
          # trips CDN bot protection on some publishers — CBC (Akamai) rejects
          # it with an HTTP/2 INTERNAL_ERROR / HTTP/1.1 hang, so those feeds
          # never fetch. Dropping the "+https://…" bot-signal wrapper (bare
          # "Miniflux/x.y.z") clears it while still honestly identifying the
          # client. Matches upstream guidance in miniflux/v2#3236.
          HTTP_CLIENT_USER_AGENT = "Miniflux/${pkgs.miniflux.version}";
          # Raise the parsing-error limit above the default (3). Once a feed
          # hits the limit miniflux stops auto-refreshing it until someone
          # refreshes it manually — so a short run of transient upstream errors
          # silently benches a feed for good. This bit all 14 kill-the-newsletter
          # feeds: a spell of 502 Bad Gateway responses from KTN in late June /
          # July pushed each of them to 3 errors and froze them, and they never
          # recovered on their own even after KTN came back up. 10 gives real
          # outages room to resolve themselves while still surfacing feeds that
          # are genuinely, persistently dead.
          POLLING_PARSING_ERROR_LIMIT = 10;
        };
      };

      systemd.services.miniflux.serviceConfig.EnvironmentFile = [
        config.sops.templates."miniflux.env".path
      ];

      myCaddy.apps.miniflux = {
        host = minifluxHost;
        routeConfig = ''
          reverse_proxy localhost:8089
        '';
      };
    };
}
