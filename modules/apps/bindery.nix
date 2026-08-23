# Bindery - monitored book/audiobook acquisition (the Readarr successor)
# Container; upstream ships no nixpkgs module. This is the automation half of
# the book stack: shelfmark is a manual search front end that deliberately
# refuses to monitor anything ("if a book isn't available now, Shelfmark won't
# watch for it" — its README lists that as a non-goal), so an upcoming title you
# want the day it drops has nowhere to live. Bindery is the *arr shape for that:
# monitor an author or a single book, keep it `wanted`, sweep every 12h plus an
# immediate search on add, grab when an indexer finally carries it.
#
# The two are complementary rather than competing. Bindery only searches
# Newznab/Torznab indexers — shadow libraries are an explicit non-goal upstream
# for legal and API-stability reasons — so anything prowlarr can't see still
# needs shelfmark's Direct Download path.
#
# Ebooks and audiobooks are independent slots on the same title, with separate
# search/grab/import pipelines, so both destinations are wired here: ebooks to
# the komga/bookorbit library, audiobooks to the audiobookshelf library. The
# audiobook side moves multi-part m4b/mp3 folders as one unit.
#
# Paths. `/mnt/content/Downloads` is mounted at its *host* path so the paths
# sabnzbd reports over its API resolve unchanged inside the container — sabnzbd
# runs natively, and BINDERY_DOWNLOAD_DIR is explicitly not a watch folder
# (per-job import paths come from the client's API), so identical paths are what
# keeps imports working without a remap. The `books`/`audiobooks` sabnzbd
# categories already exist on the host and sort under complete_dir.
#
# Indexers, download clients, quality profiles and the OIDC provider are all
# runtime-tunable in bindery's own Settings UI rather than env; only the
# bootstrap knobs below are declarative. See the README section on onboarding
# for the one-time setup.
_: {
  flake.modules.nixos.bindery =
    {
      config,
      hostSpec,
      ...
    }:
    let
      binderyHost = "bindery.${hostSpec.serverDomain}";
      port = 8787;
      inherit (hostSpec) serverUid serverGid;
      # sabnzbd's complete_dir, plus the per-category subdir the audiobook
      # grabs land in. Same path inside the container as on the host.
      completeDir = "/mnt/content/Downloads/complete";
    in
    {
      myAuthentik.oidcApps.bindery = {
        blueprintsDir = ./bindery-blueprints;
        # Bindery keeps OIDC provider config (issuer, client id/secret, scopes)
        # in its own database, entered under Settings -> Security -> OIDC
        # Providers. Nothing to put in the app's env, so no restart units
        # either — the creds still land in sops for the blueprint's `!Env`
        # refs and for the operator to paste in once.
        clientCredsInAppEnv = false;
        displayName = "Bindery";
        homepage = {
          group = "Acquisition";
          icon = "https://raw.githubusercontent.com/vavallee/bindery/main/web/public/favicon.png";
          # Bindery is the front door for books: monitor it here and it
          # arrives on its own. Shelfmark's tile points back the other way.
          description = "Books + audiobooks — start here";
        };
      };

      # Seeds bindery's own API key on first launch; afterwards the value lives
      # in its database and is regenerated from the UI, so this is a bootstrap
      # value rather than a rotating one. restartUnits lives on the template.
      sops.secrets."bindery/api_key".sopsFile = hostSpec.sopsFile;

      sops.templates."bindery.env" = {
        content = ''
          BINDERY_API_KEY=${config.sops.placeholder."bindery/api_key"}
        '';
        restartUnits = [ "podman-bindery.service" ];
      };

      myContainerApp.bindery = {
        inherit port;
        stateDirs = [
          "/var/lib/containers/bindery"
          "/var/lib/containers/bindery/config"
        ];
      };

      virtualisation.oci-containers.containers.bindery = {
        # renovate: datasource=docker depName=ghcr.io/vavallee/bindery
        image = "ghcr.io/vavallee/bindery:v1.32.1";
        volumes = [
          "/var/lib/containers/bindery/config:/config"
          "/mnt/content/books:/books"
          "/mnt/content/audiobooks:/audiobooks"
          # Optional hand-off target for bookorbit's book-dock; see the
          # bookorbit note in the README.
          "/mnt/content/books_intake:/books_intake"
          # Same path inside and out — see the paths note above.
          "/mnt/content/Downloads:/mnt/content/Downloads"
        ];
        environment = {
          BINDERY_PORT = toString port;
          BINDERY_LIBRARY_DIR = "/books";
          BINDERY_AUDIOBOOK_DIR = "/audiobooks";
          BINDERY_DOWNLOAD_DIR = completeDir;
          BINDERY_AUDIOBOOK_DOWNLOAD_DIR = "${completeDir}/audiobooks";

          # Caddy terminates TLS on the host and reaches the container over the
          # podman bridge, so the proxy's source address is the bridge gateway.
          # Without this every X-Forwarded-* header is stripped, which would
          # silently downgrade the OIDC redirect_uri and the OPDS feed links to
          # http:// — upstream calls it out as required even when proxy auth
          # isn't in use.
          BINDERY_TRUSTED_PROXY = "10.88.0.0/16";
          BINDERY_COOKIE_SECURE = "always";
          BINDERY_OIDC_REDIRECT_BASE_URL = "https://${binderyHost}";
          # authentik.<serverDomain> resolves to a LAN address here, and
          # bindery's discovery probe refuses private-range issuers unless this
          # is set. Trusted self-hosted IdP — same call bookorbit's
          # OIDC_ALLOW_LOCAL_ISSUERS makes.
          BINDERY_ALLOW_LAN_OIDC = "true";
          BINDERY_OIDC_GROUP_CLAIM = "groups";
          # Makes authentik authoritative for the admin role on every login:
          # promoted when Infrastructure is in the claim, demoted when it isn't.
          BINDERY_OIDC_ADMIN_GROUP = "Infrastructure";
          # NOTE: BINDERY_LOCAL_AUTH_ENABLED is deliberately left at its `true`
          # default. Bindery's OIDC provider is created in its UI, so disabling
          # password login before that exists locks everyone out ("Contact your
          # administrator for access"). Flip it to false once SSO logs in
          # cleanly — that's the last step of onboarding, not the first.

          # Notification webhooks are how a `wanted` book announces itself when
          # it finally lands. apprise runs natively on the host (RFC1918 from
          # the container's point of view) and the default SSRF policy blocks
          # private targets outright.
          BINDERY_NOTIFICATIONS_ALLOW_PRIVATE = "1";

          # OpenLibrary rate-limits per User-Agent, and bindery's default UA is
          # the shared project URL — every install in the fleet counts as one
          # client and author searches start returning 403. A per-instance
          # contact is what upstream asks for.
          BINDERY_CONTACT = "mailto:${hostSpec.email.personal}";

          # Sanity assertions: bindery checks these against the uid/gid it is
          # actually running as (set by myContainerApp) and fails loudly on a
          # mismatch, rather than half-importing files the NAS won't accept.
          BINDERY_PUID = toString serverUid;
          BINDERY_PGID = toString serverGid;
        };
        environmentFiles = [ config.sops.templates."bindery.env".path ];
      };

      myCaddy.apps.bindery = {
        host = binderyHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };

      # Single SQLite database in WAL mode holding the catalogue, monitored
      # state, queue and history — the whole point of the app is state that
      # accumulates, so stage a consistent copy for the nightly restic run.
      mySqliteQuiesce.apps.bindery.databases = [
        "/var/lib/containers/bindery/config/bindery.db"
      ];
    };
}
