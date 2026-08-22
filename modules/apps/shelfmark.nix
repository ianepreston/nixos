# Shelfmark - book + audiobook search / request hub (calibrain/shelfmark)
# Container; upstream ships no nixpkgs module. Auth is OIDC against
# authentik, configured entirely from env: shelfmark's settings resolver
# checks the environment before its own config files, so AUTH_METHOD and
# the OIDC_* vars below are authoritative and the matching fields render
# read-only in the UI. `DISABLE_LOCAL_AUTH` drops the "a local admin must
# exist before OIDC can be enabled" prerequisite, so there is no
# first-boot account registration and no UI bootstrap step — the first
# authentik login provisions the account.
#
# Admin rights come from authentik group membership rather than a
# database role: `OIDC_ADMIN_GROUP = Infrastructure` promotes anyone in
# that group (only ian) to shelfmark admin on each login, while the
# application's policy binding admits the whole Users group as
# non-admins. Non-admins see only their own downloads and submit
# requests for approval, which is the point of running it with real
# identities instead of forward-auth.
#
# Volumes. `/books` is the ebook destination and points at the shared
# ingest folder (bookorbit watches it, same as shelfarr's `/ebooks`);
# `/audiobooks` is the audiobookshelf library, selected per-user or
# globally as the audiobook destination in Settings -> Downloads.
# `/mnt/content/Downloads` is mounted at its *host* path deliberately:
# for torrent/usenet releases shelfmark has to open the exact path its
# download client reports, and sabnzbd runs natively on the host, so
# only an identical path avoids a Remote Path Mapping.
#
# Direct Download uses the bundled chromium to solve Cloudflare
# challenges, which is why this is the standard image and not
# `shelfmark-lite` — upstream calls out that an external resolver
# (our flaresolverr, reachable at host.containers.internal:8191 via
# USING_EXTERNAL_BYPASSER + EXT_BYPASSER_URL) is slower and less
# reliable. It wants ~2GB of headroom; swap to lite + flaresolverr if
# this ever lands on a host that can't spare it.
_: {
  flake.modules.nixos.shelfmark =
    {
      config,
      hostSpec,
      ...
    }:
    let
      shelfmarkHost = "shelfmark.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      # gatus already owns 127.0.0.1:8084 on the host, so publish on a
      # distinct host port and leave the container on the image default
      # (which is also what its built-in HEALTHCHECK probes).
      hostPort = 8085;
      containerPort = 8084;
    in
    {
      myAuthentik.oidcApps.shelfmark = {
        blueprintsDir = ./shelfmark-blueprints;
        appRestartUnit = [ "podman-shelfmark.service" ];
        displayName = "Shelfmark";
        homepage = {
          group = "Requests";
          icon = "shelfmark";
          description = "Book + audiobook search";
        };
      };

      myContainerApp.shelfmark = {
        port = hostPort;
        inherit containerPort;
        linuxServer = true;
        stateDirs = [
          "/var/lib/containers/shelfmark"
          "/var/lib/containers/shelfmark/config"
        ];
      };

      virtualisation.oci-containers.containers.shelfmark = {
        # renovate: datasource=docker depName=ghcr.io/calibrain/shelfmark
        image = "ghcr.io/calibrain/shelfmark:v1.3.11";
        volumes = [
          "/var/lib/containers/shelfmark/config:/config"
          "/mnt/content/books_intake:/books"
          "/mnt/content/audiobooks:/audiobooks"
          # Same path inside and out — see the volumes note above.
          "/mnt/content/Downloads:/mnt/content/Downloads"
        ];
        environment = {
          AUTH_METHOD = "oidc";
          # No local accounts exist, so the login page is the authentik
          # button alone. This is also what makes OIDC usable without
          # first registering a local admin.
          DISABLE_LOCAL_AUTH = "true";
          OIDC_DISCOVERY_URL = "https://${authentikHost}/application/o/shelfmark/.well-known/openid-configuration";
          OIDC_USE_ADMIN_GROUP = "true";
          OIDC_GROUP_CLAIM = "groups";
          OIDC_ADMIN_GROUP = "Infrastructure";
          OIDC_BUTTON_LABEL = "Sign in with authentik";
          # Caddy terminates TLS and shelfmark is never reachable over
          # plain HTTP, so the session cookie can be Secure-only.
          SESSION_COOKIE_SECURE = "true";
        };
        environmentFiles = [ config.sops.templates."shelfmark.env".path ];
      };

      # Shelfmark builds its OIDC callback URL from the incoming request,
      # so X-Forwarded-Proto / -Host have to survive the hop. Caddy sets
      # both on `reverse_proxy` by default; the redirect_uri in the
      # blueprint is pinned to the value they produce.
      myCaddy.apps.shelfmark = {
        host = shelfmarkHost;
        routeConfig = ''
          reverse_proxy localhost:${toString hostPort}
        '';
      };

      # users.db holds the accounts, per-user delivery preferences and
      # the request queue — the only sqlite in /config, everything else
      # there is JSON. Stage a consistent copy for the nightly restic
      # run rather than trusting a mid-write hot copy.
      mySqliteQuiesce.apps.shelfmark.databases = [
        "/var/lib/containers/shelfmark/config/users.db"
      ];
    };
}
