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
# Bookorbit owns the library; bindery stops after the grab. This is the
# "External mode with the Book Dock" topology, recipe 2 in upstream's
# docs/BookOrbit-Integration-Wiki.md. With Settings -> General -> File Naming
# set to Import Mode = External, drop folder = /books_intake, layout Flat,
# placement Copy, bindery copies each
# finished download into bookorbit's book-dock under a clean name and marks
# the download handed off. Bookorbit's dock auto-finalize files it into
# /mnt/content/books under its own naming, and bindery's next library scan
# finds it there and flips the book to Imported. Those settings live in
# bindery's database, not here — this module only points the library dirs at
# where bookorbit files things.
#
# Ebooks and audiobooks share one bookorbit library (author/series/book, both
# formats in the book folder), so both library dirs are /books and both
# formats leave through the one dock (audiobook import mode left at "Same as
# ebooks"). The scan reads the author from the first folder under the library
# root, which bookorbit's default naming satisfies — changing bookorbit's
# library pattern to anything not author-first silently breaks reconciliation.
#
# The library is mounted read-only: in External mode bindery only ever reads
# it during a scan, and Reorganize would otherwise offer to rename every
# bookorbit-filed book to bindery's scheme (it now asks for confirmation; the
# :ro mount makes confirming it harmless).
#
# Placement is Copy, not Hardlink: bindery and bookorbit bind-mount different
# subdirectories of /mnt/content, and the kernel refuses links across bind
# mounts. Usenet has nothing to seed anyway. The cost is that finished
# downloads are never removed — tracked in #1001.
#
# Failure is silent on bindery's side: a drop bookorbit can't match confidently
# (score below its 85 threshold) parks in the dock awaiting a click, and the
# book just stays Wanted. Check bookorbit's Book Dock when something expected
# hasn't shown up.
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
      myObservability.monitoredSystemdUnits = [ "podman-bindery" ];

      myRecovery.apps.bindery = {
        kind = "sqlite";
        order = 40;
        units = [ "podman-bindery.service" ];
        paths = [ "/var/lib/containers/bindery" ];
        health.url = "http://127.0.0.1:8787/";
      };

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
          group = "Requests";
          icon = "https://raw.githubusercontent.com/vavallee/bindery/main/web/public/favicon.png";
          # Bindery is the front door for books: monitor it here and it
          # arrives on its own. Shelfmark's tile points back the other way.
          description = "Series and Author book and audiobook subscriptions";
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

      # Bindery initialises its OIDC provider exactly once, at process start,
      # and latches the result: a failed discovery leaves the provider in
      # `state: "failed"` forever, and the only cure is a restart. On a rebuild
      # that restarts both stacks, podman-bindery can start while authentik's
      # Django worker is still coming up — caddy then answers the discovery URL
      # with 502 and SSO is dead until the container is bounced by hand
      # (observed on amos1: bindery up at 04:46:27, authentik.service at
      # 04:46:36). authentik-ready.service is the real HTTP readiness gate, so
      # order against it.
      #
      # `myAuthentik.oidcApps` normally injects this ordering, but only onto
      # `appRestartUnit`, which is empty here because bindery keeps its OIDC
      # config in its own database rather than in an env file. UI-configured
      # doesn't mean race-immune — bindery still probes discovery at boot.
      # `wants` (not `requires`) so a wedged authentik degrades bindery to
      # local auth rather than keeping the container down.
      systemd.services.podman-bindery = {
        after = [ "authentik-ready.service" ];
        wants = [ "authentik-ready.service" ];
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
        image = "ghcr.io/vavallee/bindery:v1.52.0";
        volumes = [
          "/var/lib/containers/bindery/config:/config"
          # Bookorbit's library: the reconcile target, read-only — see the
          # header note.
          "/mnt/content/books:/books:ro"
          # Bookorbit's book-dock: the External-mode drop folder.
          "/mnt/content/books_intake:/books_intake"
          # Same path inside and out — see the paths note above.
          "/mnt/content/Downloads:/mnt/content/Downloads"
        ];
        environment = {
          BINDERY_PORT = toString port;
          # Where bookorbit files both formats; bindery only scans it.
          BINDERY_LIBRARY_DIR = "/books";
          BINDERY_AUDIOBOOK_DIR = "/books";
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
          # The app itself is open to the whole Users group (see the policy
          # binding in the blueprint), so this is the only thing keeping the
          # household out of indexer/download-client config — ian is the sole
          # member of Infrastructure on both hosts.
          BINDERY_OIDC_ADMIN_GROUP = "Infrastructure";
          # BINDERY_ENFORCE_TENANCY deliberately left off (its default): every
          # authenticated user shares one catalogue and one set of monitored
          # authors, because everything lands in the same bookorbit and
          # audiobookshelf libraries anyway. Admin-only config gating applies
          # regardless of this flag.

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
