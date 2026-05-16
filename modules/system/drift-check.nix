# Drift-check - Simple Aspect
# Weekly timer that detects when /run/current-system has diverged from
# what `main` would build for this host, and fires an Alertmanager alert
# via the existing Discord receiver.
#
# Why this exists. `task deploy:<host>` legitimately switches a host to
# an uncommitted closure (CLAUDE.md "fast iteration path"). Nothing then
# notices that the live closure no longer matches `main`, and the
# nightly `system.autoUpgrade` will silently overwrite the
# deployment-tested-but-not-committed change. This timer surfaces that
# divergence weekly so the operator either lands the change or accepts
# it'll get clobbered. See issue #156.
#
# Implementation. Mirrors auto-rebuild.nix in shape:
#   1. Build the host's toplevel out of `github:ianepreston/nixos#<host>`
#      with the same SSH/insteadOf shim auto-rebuild uses for the
#      private nix-secrets repo.
#   2. Compare the resulting store path to `realpath /run/current-system`.
#   3. If they differ, POST a single alert to the local Alertmanager
#      v2 alerts API. Alertmanager already routes by `alertname` to the
#      Discord receiver, so no new receiver config is needed.
#
# Alertmanager-only delivery. The alert is posted directly to
# `127.0.0.1:9093/api/v2/alerts` rather than as a Prometheus rule
# because the comparison is a one-shot build step, not a continuously
# scrapeable metric. An alert with `endsAt = now + 30m` means
# Alertmanager auto-resolves it if the next drift-check run (or a
# deploy) brings the host back into alignment.
_: {
  flake.modules.nixos.drift-check =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.myDriftCheck;
      flakeRef = "github:ianepreston/nixos#${hostSpec.hostName}";

      driftScript = pkgs.writeShellApplication {
        name = "drift-check";
        runtimeInputs = with pkgs; [
          coreutils
          curl
          jq
          nix
          nixos-rebuild
          git
          openssh
        ];
        text = ''
          set -euo pipefail

          host="${hostSpec.hostName}"
          flake_ref="${flakeRef}"
          alertmanager_url="${cfg.alertmanagerUrl}"

          echo "drift-check: building $flake_ref"

          # Build the toplevel from main without registering a GC root.
          # --print-out-paths gives us the resulting store path on stdout
          # which we can string-compare against /run/current-system.
          target=$(nix build \
            --no-link \
            --print-out-paths \
            --refresh \
            "$flake_ref.config.system.build.toplevel")

          current=$(realpath /run/current-system)

          echo "drift-check: target  = $target"
          echo "drift-check: current = $current"

          if [ "$target" = "$current" ]; then
            echo "drift-check: in sync with main"
            exit 0
          fi

          # Drift detected. Post a single alert to Alertmanager v2.
          # endsAt is now+30m so the alert auto-resolves on the next
          # successful check (or a deploy that re-aligns the host) —
          # repeated drift just re-asserts the same alert and resets
          # the TTL.
          now=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
          ends=$(date -u -d '+30 minutes' +"%Y-%m-%dT%H:%M:%S.000Z")

          payload=$(jq -n \
            --arg host "$host" \
            --arg target "$target" \
            --arg current "$current" \
            --arg now "$now" \
            --arg ends "$ends" \
            '[{
              labels: {
                alertname: "ClosureDrift",
                severity: "warning",
                instance: $host,
                job: "drift-check"
              },
              annotations: {
                summary: ("Host " + $host + " has drifted from main"),
                description: ("Running closure does not match what github:ianepreston/nixos#" + $host + " would build. current=" + $current + " target=" + $target)
              },
              startsAt: $now,
              endsAt: $ends
            }]')

          echo "drift-check: drift detected, posting to $alertmanager_url"
          curl -sS --fail-with-body \
            -H 'Content-Type: application/json' \
            -X POST \
            --data "$payload" \
            "$alertmanager_url/api/v2/alerts"
          echo
          exit 0
        '';
      };
    in
    {
      options.myDriftCheck = {
        enable = lib.mkEnableOption "weekly closure drift detection against main";
        alertmanagerUrl = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:9093";
          description = "Base URL of the local Alertmanager that drift alerts POST to.";
        };
        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "Mon 05:30";
          description = "systemd OnCalendar expression for the drift-check timer.";
        };
      };

      config = lib.mkIf cfg.enable {
        systemd.services.drift-check = {
          description = "Detect closure drift between running system and main";
          # Match the env shim auto-rebuild uses so the private
          # nix-secrets input fetches over SSH with the user's key
          # rather than blocking on missing GitHub HTTPS creds.
          environment = {
            GIT_SSH_COMMAND = "ssh -i ${hostSpec.home}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new";
            GIT_CONFIG_COUNT = "1";
            GIT_CONFIG_KEY_0 = "url.git@github.com:ianepreston/.insteadOf";
            GIT_CONFIG_VALUE_0 = "https://github.com/ianepreston/";
          };
          serviceConfig = {
            Type = "oneshot";
            # Build needs root for nix-daemon access on the install
            # closure path the same way nixos-upgrade.service does.
            User = "root";
            ExecStart = "${lib.getExe driftScript}";
          };
        };

        systemd.timers.drift-check = {
          description = "Weekly drift-check trigger";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.onCalendar;
            Persistent = true;
            RandomizedDelaySec = "30m";
          };
        };
      };
    };
}
