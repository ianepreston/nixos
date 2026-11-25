# Decluttarr - background queue cleaner for the *arr stack
# (https://github.com/ManiMatter/decluttarr). Polls Sonarr / Radarr at
# `general.timer` intervals and removes queue items matching configured
# patterns — most usefully `remove_failed_imports` with the default
# "Not a Custom Format upgrade for existing*" / "Not an upgrade for
# existing*" message filters, which catches releases that grabbed but
# can't import because they wouldn't score above the on-disk file.
#
# Container only (no nixpkgs module). Stateless — no /var/lib state,
# no preservation entry, no recovery task. Config.yaml is rendered in
# `podman-decluttarr.service`'s own preStart, which reads the
# sonarr/radarr/sabnzbd API keys with the readers those apps publish in
# `myRuntimeCredentials.readers` (the scripts homepage's widgets use),
# so we don't have to mint and rotate a separate sops secret for keys
# the arrs already manage themselves. Only the reader scripts are
# shared: decluttarr keeps its own render-on-every-start, fail-on-
# missing-key policy rather than the tolerant `consumers` oneshot (see
# the preStart below).
#
# Sonarr/Radarr/Sabnzbd are reached from inside the podman bridge at
# the container-side URL each publishes in `myServiceEndpoints`.
_: {
  flake.modules.nixos.decluttarr =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # Upstream app -> the runtime-credentials reader for its API key.
      # Listed in read order; the app name is also the label in the
      # failure message.
      upstreams = [
        {
          app = "sonarr";
          key = "SONARR_API_KEY";
        }
        {
          app = "radarr";
          key = "RADARR_API_KEY";
        }
        {
          app = "sabnzbd";
          key = "SABNZBD_API_KEY";
        }
      ];
      endpoint = app: config.myServiceEndpoints.${app} or null;
      reader = key: config.myRuntimeCredentials.readers.${key} or null;
      # The empty fallback leaves the diagnostic to the assertions below.
      containerUrl =
        app:
        let
          url = (endpoint app).containerUrl or null;
        in
        if url == null then "" else url;
      # Ready before reaching an app, and before reading its key.
      upstreamUnits = lib.unique (
        lib.concatMap (
          u:
          lib.optional (endpoint u.app != null) (endpoint u.app).unit
          ++ lib.optional (reader u.key != null) (reader u.key).sourceUnit
        ) upstreams
      );
      configDir = "/run/decluttarr";
      configFile = "${configDir}/config.yaml";
    in
    {
      assertions = lib.concatMap (u: [
        {
          assertion = containerUrl u.app != "";
          message = "modules/apps/decluttarr.nix runs in a container and needs myServiceEndpoints.${u.app}.containerUrl, published by modules/apps/${u.app}.nix.";
        }
        {
          assertion = reader u.key != null;
          message = "modules/apps/decluttarr.nix needs myRuntimeCredentials.readers.${u.key}, published by modules/apps/${u.app}.nix.";
        }
      ]) upstreams;

      myObservability.monitoredSystemdUnits = [ "podman-decluttarr" ];

      # Render config.yaml as part of podman-decluttarr's own start
      # cycle rather than via a separate oneshot — a previous split
      # design hit a race where /run/decluttarr got cleared between
      # deploys (RuntimeDirectoryPreserve didn't survive activation)
      # and podman would then statfs the missing bind-mount source
      # and fail. Inlining the render means every container start
      # re-reads the API keys; there's no window where the file is
      # stale or absent.
      systemd.services.podman-decluttarr = {
        # Need the arrs to have actually written their config.xml /
        # sabnzbd.ini before we read them. Same first-boot timing
        # concern as homepage-credentials — handled with a retry
        # loop in the script so a missing key blocks here rather
        # than letting decluttarr boot with a broken config.
        after = upstreamUnits;
        wants = upstreamUnits;
        path = with pkgs; [
          coreutils
          gnugrep
          gawk
        ];
        serviceConfig = {
          RuntimeDirectory = "decluttarr";
          RuntimeDirectoryPreserve = "yes";
          UMask = "0077";
        };
        # Unlike a `myRuntimeCredentials.consumers` oneshot, which skips
        # an empty key and starts once, this retries for 30s, fails the
        # start when any key stays empty, and re-reads every key on
        # every container start.
        preStart = ''
          set -euo pipefail

          ${lib.concatMapStrings (u: ''
            read_${u.app}_key() {
            ${(reader u.key).readScript or ""}
            }
          '') upstreams}
          read_key() {
            local label="$1"
            local val=""
            for _ in 1 2 3 4 5 6 7 8 9 10; do
              val="$("read_''${label}_key" 2>/dev/null | tr -d '\n\r' || true)"
              [ -n "$val" ] && { printf '%s' "$val"; return 0; }
              sleep 3
            done
            echo "decluttarr-config: failed to read $label after retries" >&2
            return 1
          }

          ${lib.concatMapStrings (u: ''
            ${u.app}_key="$(read_key ${u.app})"
          '') upstreams}

          tmp="${configFile}.tmp"
          cat > "$tmp" <<EOF
          general:
            log_level: INFO
            timer: 10
            test_run: false

          job_defaults:
            max_strikes: 3
            min_days_between_searches: 7
            max_concurrent_searches: 3

          jobs:
            remove_failed_imports:
              message_patterns:
                - "Not a Custom Format upgrade for existing*"
                - "Not an upgrade for existing*"
                - "*Found potentially dangerous file with extension*"
                - "Invalid video file*"
                - "No files found are eligible for import*"
                - "One or more episodes expected in this release were not imported or missing from the release"
            remove_failed_downloads:
            remove_stalled:
            remove_metadata_missing:
            remove_unmonitored:
            remove_orphans:
            remove_missing_files:

          instances:
            sonarr:
              - base_url: "${containerUrl "sonarr"}"
                api_key: "$sonarr_key"
            radarr:
              - base_url: "${containerUrl "radarr"}"
                api_key: "$radarr_key"

          download_clients:
            sabnzbd:
              - base_url: "${containerUrl "sabnzbd"}"
                api_key: "$sabnzbd_key"
                name: "SABnzbd"
          EOF
          chmod 0444 "$tmp"
          mv "$tmp" ${configFile}
        '';
      };

      # Not migrated to myContainerApp: decluttarr is stateless (no state
      # dirs, no user override), so myContainerApp's stateDirs/user plumbing
      # buys nothing — it keeps its own TZ instead.
      virtualisation.oci-containers.containers.decluttarr = {
        # renovate: datasource=docker depName=ghcr.io/manimatter/decluttarr
        image = "ghcr.io/manimatter/decluttarr:v2.2.0";
        volumes = [
          "${configFile}:/app/config/config.yaml:ro"
          # NOTE: /mnt/content is intentionally NOT bind-mounted, even
          # though doing so silences the `Job 'detect_deletions' does
          # not have access to '/mnt/content/{TV,Movies}'` warnings at
          # startup. With the mount in place, decluttarr's watchdog
          # Observer recursively walks the entire root folder tree
          # adding inotify watches — fine on hpp-1's small share, but
          # on amos1's real multi-TB Synology mount it hangs the main
          # coroutine before the job loop ever starts running. The
          # warnings are cosmetic; the cure was worse than the disease.
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };

    };
}
