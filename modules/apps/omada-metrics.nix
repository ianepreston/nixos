# omada-metrics - Omada controller device state into the textfile collector
#
# Closes the gap #586 names: the Omada controller had container liveness
# (`podman-omada` is in the systemd unit-include regex in
# ../system/victoriametrics.nix), UI reachability (a gatus probe, via
# `myAuthentik.forwardAuthApps.omada`) and its application log in
# VictoriaLogs — but not one metric about the switches and APs it
# manages. #584 was a firmware upgrade failing nightly for four days
# with nothing anywhere to notice.
#
# Shape follows ./llm-metrics.nix, with valheim/mylar3/sabnzbd as the
# simpler precedents: a timer-driven oneshot that polls and writes a
# `.prom` into node_exporter's textfileDir. There is no `omada-exporter`
# in nixpkgs (checked 25.11 and unstable), and a poller is how this repo
# already does the same job for four other apps.
#
# ## prod-only
#
# Imported through `prodOnlyApps` in ../profiles/server-apps.nix, not
# `commonApps`, so it lands on amos1 and not hpp-1 — as does omada.nix
# itself, which joined it there once hpp-1's controller had gone months
# without adopting anything. There is one network and amos1 manages it,
# so both the controller and this exporter have their subject only on
# prod; the Open API client below also has to be minted by hand in each
# controller's UI, and a second hand-provisioned credential to publish
# an empty device list was never worth having.
#
# ## Open API, not the session API or the embedded mongo
#
# Three ways in, all verified against the live controller on amos1
# (6.3.0.44-openj9):
#
#   * The Open API (`/openapi/v1/...`, bearer token from
#     `/openapi/authorize/token`) is what this uses. Versioned,
#     documented, and the controller serves its own OpenAPI 3.0.1 spec
#     at `/v3/api-docs` — 1894 paths, and the source for every field
#     name and enum quoted below. Note that path answers *without*
#     authentication, unlike `/openapi/*`; it discloses the API surface
#     but no data. 8043 is reachable from loopback, the infra VLAN and
#     the trusted LAN (see the firewall block in ./omada.nix — the LAN
#     was added in #673 so the APs could fetch firmware); the iot VLAN
#     and the internet-facing side are still out. So the surface is
#     disclosed to hosts that already reach the login page, which is why
#     it is noted rather than treated as a finding.
#   * The embedded mongo on 127.0.0.1:27217 answers with no credentials
#     at all and carries firmware currency (`modelfw`, keyed on the
#     version a device is currently on). Rejected: it is a vendor-
#     private schema a controller bump can rename silently, and it has
#     no usable liveness field — `device.last_seen` read 19 hours stale
#     on both switches while both were up, so it records adoption, not
#     a heartbeat.
#   * The UI's own session API needs the controller's local admin
#     password in sops, which the Open API's scoped Viewer client
#     avoids.
#
# ## Credentials
#
# `client_id` / `client_secret` are minted by the controller, not by us,
# so `task secrets:secret` (which generates random hex) is the wrong
# tool — they are pasted in via `task secrets:edit:amos1` under
# `omada.openapi_client_id` / `omada.openapi_client_secret`. Create the
# client in the UI under Global View -> Settings -> Platform
# Integration -> Open API, in Client Credentials mode with the Viewer
# role.
#
# Viewer is enough for everything read here, but not for everything:
# `/grid/devices/upgradeable` answers -1007 "does not have permissions"
# under it. That endpoint is not needed — per-device
# `latest-firmware-info` carries the same signal and Viewer can read it.
#
# Both secrets are read straight off disk by the oneshot rather than
# through an `sops.templates` env file: there is no unit to restart on
# rotation, because the next timer firing picks up the new value on its
# own. Same reasoning as the api-key handling in ./llm-metrics.nix.
#
# Tokens are fetched fresh on every run and never cached. Verified
# affordable rather than assumed: 25 back-to-back token requests all
# returned errorCode 0, and the first token was still valid after the
# other 24 were issued, so the controller neither rate-limits nor
# invalidates on re-issue at this cadence. That keeps the exporter
# stateless — no token file, no expiry bookkeeping, no 401-retry path.
#
# ## What is deliberately not derived from a metric
#
# A *failed* firmware upgrade stays a log-derived alert
# (`OmadaFirmwareUpgradeFailed` in ../system/log-alerts.nix, #610).
# Nothing in the Open API reports a failed attempt — a device that
# failed to upgrade simply reads as still upgradeable — so the two
# detectors are complementary: the log rule catches the attempt as it
# fails, `OmadaFirmwareUpgradeAvailable` catches the state it leaves
# behind.
_: {
  flake.modules.nixos.omada-metrics =
    {
      config,
      pkgs,
      hostSpec,
      ...
    }:
    let
      # Set in ../system/victoriametrics.nix; kept in sync by hand, as
      # in llm-metrics.nix, mylar3.nix and valheim.nix.
      textfileDir = "/var/lib/node-exporter-textfile-collector";

      hasController = config.myServiceEndpoints ? omada;
      # The empty fallback keeps the assertion below responsible for the
      # diagnostic when this module is imported without its producer. The
      # service remains unconditional, as it was before this contract, so
      # endpoint presence is not used while the module system is finding its
      # configuration fixpoint.
      controller =
        config.myServiceEndpoints.omada or {
          url = "";
          unit = "";
        };

      exporter = pkgs.writers.writePython3 "omada-metrics" {
        flakeIgnore = [
          "E501"
          "W391"
        ];
      } (builtins.readFile ./_omada-metrics/exporter.py);
    in
    {
      assertions = [
        {
          # This module is only meaningful next to the controller it polls.
          # The public endpoint contract is the guard instead of an
          # implementation-specific read of the Omada container config.
          assertion = hasController;
          message = ''
            modules/apps/omada-metrics.nix requires
            myServiceEndpoints.omada. Import modules/apps/omada.nix alongside
            it, or drop omada-metrics from prodOnlyApps in
            modules/profiles/server-apps.nix.
          '';
        }
      ];
      myObservability.metricRuleGroups.omada.groups = [
        {
          name = "omada";
          rules = [
            {
              alert = "OmadaDeviceDown";
              expr = "omada_device_up == 0";
              for = "5m";
              labels.severity = "critical";
              annotations = {
                summary = "Omada device {{ $labels.name }} is not connected";
                description = "The Omada controller on {{ $labels.instance }} has not had {{ $labels.name }} ({{ $labels.model }}, {{ $labels.mac }}) in the Connected state for 5m. Check omada_device_status for which state it is in — 2 Pending, 3 Heartbeat Missed, 4 Isolated — and omada_device_detail_status for the cause.";
              };
            }
            {
              alert = "OmadaFirmwareUpgradeAvailable";
              expr = "omada_device_firmware_upgrade_available == 1";
              for = "48h";
              labels.severity = "warning";
              annotations = {
                summary = "Omada device {{ $labels.name }} has a pending firmware upgrade";
                description = "{{ $labels.name }} ({{ $labels.model }}, {{ $labels.mac }}) has had a newer firmware build available for 48h, which is two missed runs of the controller's daily auto-upgrade. omada_device_firmware_info carries the running and available versions. Adopted devices fetch images from the controller on 8043, so start there — see the firewall block in modules/apps/omada.nix, and check OmadaFirmwareUpgradeFailed.";
              };
            }
            {
              alert = "OmadaScrapeFailing";
              expr = "omada_scrape_error == 1";
              for = "15m";
              labels.severity = "warning";
              annotations = {
                summary = "Omada exporter cannot read {{ $labels.endpoint }} on {{ $labels.instance }}";
                description = "omada-metrics.service has been failing to read the {{ $labels.endpoint }} Open API endpoint for 15m, so the metrics it feeds are missing rather than stale. If endpoint is \"token\", the Open API client has been revoked or rotated — remint it under Global View → Settings → Platform Integration and update sops. Otherwise check `journalctl -u omada-metrics` for the errorCode; -1007 is a role change. See modules/apps/omada-metrics.nix.";
              };
            }
            {
              alert = "OmadaMetricsStale";
              expr = ''time() - node_textfile_mtime_seconds{file="${textfileDir}/omada.prom"} > 900'';
              for = "10m";
              labels.severity = "warning";
              annotations = {
                summary = "Omada metrics are stale on {{ $labels.instance }}";
                description = "omada.prom has not been rewritten for {{ $value | humanizeDuration }} on {{ $labels.instance }}, so OmadaDeviceDown and OmadaFirmwareUpgradeAvailable are evaluating frozen data. Check omada-metrics.service and its timer.";
              };
            }
          ];
        }
      ];

      sops.secrets = {
        "omada/openapi_client_id".sopsFile = hostSpec.sopsFile;
        "omada/openapi_client_secret".sopsFile = hostSpec.sopsFile;
      };

      systemd.services.omada-metrics = {
        description = "publish Omada controller device state to node_exporter textfile collector";
        # The controller is a JVM that takes minutes to answer after a
        # boot; without this the first run after every reboot fails on a
        # connection refused and publishes controller_up=0 for one cycle.
        after = [ controller.unit ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = exporter;
          Environment = [
            "OMADA_URL=${controller.url}"
            "TEXTFILE_OUT=${textfileDir}/omada.prom"
            "CLIENT_ID_FILE=${config.sops.secrets."omada/openapi_client_id".path}"
            "CLIENT_SECRET_FILE=${config.sops.secrets."omada/openapi_client_secret".path}"
          ];
        };
      };

      systemd.timers.omada-metrics = {
        description = "Periodic Omada controller device state refresh";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # The controller needs to be up and past its JVM warm-up before
          # the first run is worth anything.
          OnBootSec = "5m";
          # Every alert on these metrics has a `for:` of 5m or more, so a
          # faster poll buys nothing and every run costs the controller a
          # token plus a client-table walk.
          OnUnitActiveSec = "2m";
          AccuracySec = "10s";
          Unit = "omada-metrics.service";
        };
      };

    };
}
