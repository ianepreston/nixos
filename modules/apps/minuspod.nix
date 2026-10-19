# MinusPod - podcast ad stripper (ttlequals0/MinusPod)
# Subscribes to podcast feeds, transcribes each episode with Whisper,
# has an LLM find the ad reads, cuts them with ffmpeg, and republishes a
# re-cut RSS feed per show (#654). Container; there is no nixpkgs package
# and faster-whisper isn't packaged either.
#
# Upstream: "intended for personal use only … only with podcasts you have
# permission to modify or where such modification is permitted under
# applicable laws."
#
# Transcription runs on the CPU image. GPU Whisper wants 5-6 GB of VRAM
# and amos1's 8 GB card is already fully allocated between llama-server
# and Jellyfin's NVENC path (#517). `small` rather than the CPU image's
# `tiny` default: sponsor names and promo codes are exactly what tiny
# mangles, and wall-clock per episode on the host's cores is the number
# #654 asks to measure before choosing a home for this.
#
# Ad detection goes to amos1's llama-server `text` alias over its
# llm.<domain> route, the same endpoint wherever this container runs.
# The `/v1/*` bypass on that route only applies when an Authorization
# header is present (see modules/apps/llm-terra.nix), so OPENAI_API_KEY
# carries the real shared key rather than upstream's `not-needed`
# default — without it the request gets an authentik login redirect,
# which MinusPod reports as a JSON parse failure and otherwise ignores.
# Parse failures are silent in general: the episode processes "normally"
# with gaps in detection, so judge quality by listening, not by the run
# log. Every run holds `text` resident, so with `--models-max 1` it
# evicts `vision` and the next Tandoor/paperless image call cold-loads.
# TypeSafe's Jev (a hosted "System One" model) is the alternative upstream
# supports natively for detection and verification (#827).
#
# Most settings below are *env-backed seeds*: MinusPod copies the env
# value into its database on every boot until the matching control is
# edited in the UI, after which the database wins and the env var is
# ignored. A UI edit is therefore sticky across rebuilds. That matters
# for one of them in particular, below.
#
# Auth. MinusPod has a single app password and no OIDC or proxy-header
# login, so the UI sits behind authentik forward-auth. Podcast clients
# (Apple Podcasts on a phone, Audiobookshelf) can't do a forward-auth
# login, so the feed surface bypasses it and is gated by MinusPod's own
# feed key instead: `?key=` on every feed, audio, caption, chapter and
# cover URL, 401 without it (`require_feed_key` in
# src/main_app/feed_auth.py). FEED_AUTH_ENABLED seeds that gate on and
# mints the key at boot (copy it from Settings > Security). The bypass
# below is only safe while that gate is on: switching feed auth off in the
# UI flips the stored setting, survives every rebuild, and leaves the
# feeds and audio open to anyone who can reach the host.
#
# State. DATA_DIR holds podcast.db (subscriptions, corrections, learned
# sponsor patterns: the authored state), `backups/` (upstream's
# pre-migration snapshots), and `podcasts/<slug>/` per feed. Restic skips
# the parts that re-derive on demand: each feed's processed audio, the
# Whisper model cache, and archive-import staging. Leave MinusPod's own
# scheduled backups off; they land on disk as unencrypted SQLite holding
# provider keys and password hashes, and restic already covers the db.
# Local (uploaded) feeds keep their only copy of the audio in that same
# `episodes/` tree, so using them means revisiting the exclude first.
{ inputs, ... }:
{
  flake.modules.nixos.minuspod =
    {
      config,
      hostSpec,
      ...
    }:
    let
      sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
      minuspodHost = "minuspod.${hostSpec.serverDomain}";
      stateDir = "/var/lib/containers/minuspod";
      # Not in dashboard-icons, so both tiles take upstream's own.
      iconUrl = "https://raw.githubusercontent.com/ttlequals0/MinusPod/main/frontend/public/apple-touch-icon.png";
      # 8000 is the image's listen port and a common container default
      # (apprise and bambuddy listen there too), so publish on a distinct
      # host port rather than claim it on the host.
      port = 8011;
      containerPort = 8000;
    in
    {
      myObservability.monitoredSystemdUnits = [ "podman-minuspod" ];

      myRecovery.apps.minuspod = {
        kind = "sqlite";
        order = 145;
        units = [ "podman-minuspod.service" ];
        # Enumerated rather than `stateDir`, for the reason spelled out in
        # jellyfin.nix: `_restore-sqlite` restores with `--delete`, and the
        # restic excludes below keep every feed's episodes/ out of the
        # snapshot, so including the parent would wipe the live audio on
        # any restore. podcast.db itself comes back through the quiesce
        # swap; its WAL pair is listed so the db is restored alongside the
        # same files a parent-path app (bindery, shelfmark) gets back. Not
        # restored, all re-derived on start or on the next feed refresh:
        # podcasts/<slug>/ (cached RSS + artwork), logs/, and the lock and
        # status files.
        paths = [
          "${stateDir}/backups"
          "${stateDir}/podcast.db-wal"
          "${stateDir}/podcast.db-shm"
        ];
        health.url = "http://127.0.0.1:${toString port}/api/v1/health";
      };

      myAuthentik.forwardAuthApps.minuspod = {
        inherit port;
        displayName = "MinusPod";
        inherit iconUrl;
        # Feed surface only; everything else (/, /ui/*, /api/*) stays
        # behind forward-auth *and* MinusPod's own password. All of these
        # 401 without the feed key while feed auth is on; see the header.
        #
        #   /*?*        the re-cut RSS feed at /<slug>. Caddy treats a
        #               pattern whose only `*` is trailing as a plain
        #               prefix, so `/*` would bypass every path; two stars
        #               send it to path.Match, where `*` stops at `/` and
        #               `?` needs a character. Net effect: exactly one
        #               non-empty top-level segment. That also catches
        #               /health and the favicons (public anyway) and
        #               bare `/ui` and `/api`, which only 308 to /ui/ or
        #               answer MinusPod's own 401.
        #   /episodes/* audio, captions, chapters, episode artwork
        #   /*/cover-minuspod*.jpg  per-feed cover art
        #
        # `/*?*` leans on upstream keeping every other top-level route
        # under /ui or /api (true as of 2.100.18: the only one-segment
        # routes in src/main_app/routes.py are `/`, the feed, /health and
        # the favicons). Re-check that on a major-version bump.
        bypassAuthPaths = [
          "/*?*"
          "/episodes/*"
          "/*/cover-minuspod*.jpg"
        ];
        homepage = {
          group = "Acquisition";
          icon = iconUrl;
          description = "Podcast ad stripper";
        };
      };

      sops = {
        secrets."minuspod/master_passphrase".sopsFile = hostSpec.sopsFile;
        # Same key every llm route accepts; see paperless-ngx.nix.
        secrets."llama-cpp/api_key".sopsFile = "${sopsFolder}/shared.yaml";

        templates."minuspod.env" = {
          content = ''
            MINUSPOD_MASTER_PASSPHRASE=${config.sops.placeholder."minuspod/master_passphrase"}
            OPENAI_API_KEY=${config.sops.placeholder."llama-cpp/api_key"}
          '';
          restartUnits = [ "podman-minuspod.service" ];
        };
      };

      myContainerApp.minuspod = {
        inherit port containerPort;
        stateDirs = [ stateDir ];
        # The entrypoint starts as root, remaps its `minuspod` user to
        # APP_UID/APP_GID, chowns DATA_DIR, then drops privileges.
        manageUser = false;
      };

      virtualisation.oci-containers.containers.minuspod = {
        # renovate: datasource=docker depName=ttlequals0/minuspod
        image = "ttlequals0/minuspod:2.100.18-cpu";
        volumes = [ "${stateDir}:/app/data" ];
        # faster-whisper takes every core it can see for the length of an
        # episode. A relative weight rather than a cap: it costs nothing
        # when the host is idle, and under contention the CI runner and the
        # other apps win (1024 is the default share).
        extraOptions = [ "--cpu-shares=256" ];
        environment = {
          APP_UID = toString hostSpec.serverUid;
          APP_GID = toString hostSpec.serverGid;

          BASE_URL = "https://${minuspodHost}";
          # Caddy is the one proxy hop; without this the login lockout and
          # rate limiter key on caddy's address instead of the client's.
          MINUSPOD_TRUSTED_PROXY_COUNT = "1";
          MINUSPOD_REQUIRE_AUTH = "true";
          # An unauthenticated feed hit must not be able to start a run.
          MINUSPOD_ALLOW_PUBLIC_PROCESSING = "false";
          SESSION_COOKIE_SECURE = "true";
          FEED_AUTH_ENABLED = "true";

          LLM_PROVIDER = "openai-compatible";
          OPENAI_BASE_URL = "https://llm.amos.ipreston.net/v1";
          OPENAI_MODEL = "text";

          WHISPER_BACKEND = "local";
          WHISPER_DEVICE = "cpu";
          WHISPER_MODEL = "small";
        };
        environmentFiles = [ config.sops.templates."minuspod.env".path ];
      };

      services.restic.backups.server.exclude = [
        "${stateDir}/podcasts/*/episodes"
        "${stateDir}/.cache"
        "${stateDir}/import-staging"
      ];

      mySqliteQuiesce.apps.minuspod.databases = [ "${stateDir}/podcast.db" ];
    };
}
