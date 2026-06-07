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
# `podman-decluttarr.service`'s own preStart, which scrapes the
# sonarr/radarr/sabnzbd API keys out of their respective config files
# (same approach the homepage credentials reader uses), so we don't
# have to mint and rotate a separate sops secret for keys the arrs
# already manage themselves.
#
# Sonarr/Radarr/Sabnzbd are reachable from inside the podman bridge
# at `host.containers.internal:<port>` — same trick as watchstate /
# grimmory.
_: {
  flake.modules.nixos.decluttarr =
    {
      config,
      pkgs,
      ...
    }:
    let
      configDir = "/run/decluttarr";
      configFile = "${configDir}/config.yaml";
    in
    {
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
        after = [
          "sonarr.service"
          "radarr.service"
          "sabnzbd.service"
        ];
        wants = [
          "sonarr.service"
          "radarr.service"
          "sabnzbd.service"
        ];
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
        preStart = ''
          set -euo pipefail

          read_key() {
            local label="$1" reader="$2"
            local val=""
            for _ in 1 2 3 4 5 6 7 8 9 10; do
              val="$(eval "$reader" 2>/dev/null | tr -d '\n\r' || true)"
              [ -n "$val" ] && { printf '%s' "$val"; return 0; }
              sleep 3
            done
            echo "decluttarr-config: failed to read $label after retries" >&2
            return 1
          }

          sonarr_key="$(read_key sonarr "grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/sonarr/.config/NzbDrone/config.xml")"
          radarr_key="$(read_key radarr "grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/radarr/.config/Radarr/config.xml")"
          sabnzbd_key="$(read_key sabnzbd "awk -F= '/^[[:space:]]*api_key[[:space:]]*=/ { gsub(/^[[:space:]]+|[[:space:]]+\$/,\"\",\$2); print \$2; exit }' /var/lib/sabnzbd/sabnzbd.ini")"

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

          instances:
            sonarr:
              - base_url: "http://host.containers.internal:8989"
                api_key: "$sonarr_key"
            radarr:
              - base_url: "http://host.containers.internal:7878"
                api_key: "$radarr_key"

          download_clients:
            sabnzbd:
              - base_url: "http://host.containers.internal:18080"
                api_key: "$sabnzbd_key"
                name: "SABnzbd"
          EOF
          chmod 0444 "$tmp"
          mv "$tmp" ${configFile}
        '';
      };

      virtualisation.oci-containers.containers.decluttarr = {
        # renovate: datasource=docker depName=ghcr.io/manimatter/decluttarr
        image = "ghcr.io/manimatter/decluttarr:v2.1.0";
        volumes = [
          "${configFile}:/app/config/config.yaml:ro"
          # Mounted so decluttarr's `detect_deletions` watcher can resolve
          # the Sonarr/Radarr root folder paths (`/mnt/content/TV`,
          # `/mnt/content/Movies`, …) — those paths come straight from
          # the *arrs' root-folder API and need to exist at the same path
          # inside the container or the watcher logs WARNING at every
          # start. The job runs unconditionally upstream regardless of
          # YAML config (`if settings.jobs.detect_deletions:` in main.py
          # is a truthy check on the JobParams object, not its `.enabled`
          # flag), so mounting is the only knob we have. Read-only because
          # the watcher only inotify-watches; it triggers refreshes via
          # the arr APIs, not via filesystem writes.
          "/mnt/content:/mnt/content:ro"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };

    };
}
