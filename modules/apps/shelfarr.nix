# Shelfarr - book/audiobook request system for the *arr ecosystem
# Container; OIDC against authentik gated to the Users group. Shelfarr
# stores OIDC settings in its own database (configured via Admin →
# Settings → OIDC/SSO Authentication in the UI), so this module
# registers via myAuthentik.oidcApps with clientCredsInAppEnv = false.
#
# On first boot, register the initial admin account, then under
# Admin → Settings → OIDC/SSO Authentication enable OIDC with:
#   Issuer        https://authentik.<serverDomain>/application/o/shelfarr/
#   Client ID     from sops `shelfarr/oidc_client_id`
#   Client Secret from sops `shelfarr/oidc_client_secret`
# The blueprint pins the redirect URI to /auth/oidc/callback.
#
# Libraries live alongside the rest of the book stack:
#   /mnt/content/audiobooks  shared with audiobookshelf / readmeabook
#   /mnt/content/books       shared with kavita / komga (ebooks)
#   /mnt/content/Downloads   shared with sabnzbd / *arr containers
# Rails state (db, auto-generated master key) persists under
# /var/lib/containers/shelfarr/data.
_: {
  flake.modules.nixos.shelfarr =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      shelfarrHost = "shelfarr.${hostSpec.serverDomain}";
      port = 5056;
    in
    {
      myAuthentik.oidcApps.shelfarr = {
        blueprintsDir = ./shelfarr-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Requests";
          icon = "shelfarr";
          description = "Book + audiobook requests";
        };
        homepageDisplayName = "Shelfarr";
        homepageHref = "https://${shelfarrHost}";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/shelfarr 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/shelfarr/data 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.shelfarr = {
        # Upstream only publishes `latest`, `main`, `dev`, and per-commit
        # short-SHA tags to ghcr.io despite tagging GitHub releases
        # (0.18.x at module-write time). Pin to the digest of `latest`
        # for reproducibility; renovate tracks `latest` and bumps the
        # digest on its own (see renovate.json's digest manager).
        # renovate: datasource=docker depName=ghcr.io/pedro-revez-silva/shelfarr
        image = "ghcr.io/pedro-revez-silva/shelfarr:latest@sha256:6e9207bc7ec1ac2aca8b426907af5af42b4b66d07865981802e4194e4506e17f";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/shelfarr/data:/rails/storage"
          "/mnt/content/audiobooks:/audiobooks"
          "/mnt/content/books:/ebooks"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          TZ = config.time.timeZone;
          PUID = toString serverUid;
          PGID = toString serverGid;
          HTTP_PORT = toString port;
          SOLID_QUEUE_IN_PUMA = "1";
        };
      };

      myCaddy.apps.shelfarr = {
        host = shelfarrHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
