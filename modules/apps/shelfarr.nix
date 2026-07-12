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
# /var/lib/containers/shelfarr/data. /rails/tmp is also bind-mounted
# so it's UID-aligned to server-${env} from first boot — otherwise the
# image's entrypoint touches a startup-check sentinel as the rails
# user (whose UID gets rewritten to PUID via usermod), fails because
# the image's /rails/tmp is still owned by the build-time UID 1000,
# and emits a "Permission denied" warning every boot before chown'ing
# it. Pre-aligning the bind mount avoids the noise. Closes #196.
_: {
  flake.modules.nixos.shelfarr =
    {
      hostSpec,
      ...
    }:
    let
      shelfarrHost = "shelfarr.${hostSpec.serverDomain}";
      port = 5056;
    in
    {
      myAuthentik.oidcApps.shelfarr = {
        blueprintsDir = ./shelfarr-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Requests";
          icon = "bookstack";
          description = "Book + audiobook requests";
        };
        displayName = "Shelfarr";
      };

      myContainerApp.shelfarr = {
        inherit port;
        linuxServer = true;
        stateDirs = [
          "/var/lib/containers/shelfarr"
          "/var/lib/containers/shelfarr/data"
          "/var/lib/containers/shelfarr/tmp"
        ];
      };

      virtualisation.oci-containers.containers.shelfarr = {
        # Upstream only publishes `latest`, `main`, `dev`, and per-commit
        # short-SHA tags to ghcr.io despite tagging GitHub releases
        # (0.18.x at module-write time). Pin to the digest of `latest`
        # for reproducibility; renovate tracks `latest` and bumps the
        # digest on its own (see renovate.json's digest manager).
        # renovate: datasource=docker depName=ghcr.io/pedro-revez-silva/shelfarr
        image = "ghcr.io/pedro-revez-silva/shelfarr:latest@sha256:70eab761e3ededd82ef994593fab2755149546141377299dffd075596ea54b8e";
        volumes = [
          "/var/lib/containers/shelfarr/data:/rails/storage"
          "/var/lib/containers/shelfarr/tmp:/rails/tmp"
          "/mnt/content/audiobooks:/audiobooks"
          "/mnt/content/books_intake:/ebooks"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
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
