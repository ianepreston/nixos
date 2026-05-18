# Observability — metrics, logs, dashboards, alerting.
#
# Parent meta-module: collects the per-service modules so the server
# profile can `imports` a single observability target. Each leaf
# module is self-contained (sops secrets, systemd config, caddy
# routes, authentik wiring). Add new observability components by
# dropping a new module under modules/system/<component>.nix and
# adding it to the imports list below.
#
# Stack (migrated to the Victoria single-binary stack in #126; the
# Prometheus/Loki monoliths-in-microservice-clothing were paying
# distributed-systems complexity without using any of the benefit):
#   VictoriaMetrics — scrapes node/postgres/mysqld/redis/caddy/cadvisor/
#                     itself; ephemeral on-disk, 15d retention.
#   vmalert         — evaluates the rule YAML against VM; emits to
#                     alertmanager. PromQL-superset, so the existing
#                     rule expressions move over unchanged.
#   VictoriaLogs    — single-binary log store, 30d retention.
#   Vector          — ships the systemd journal into VictoriaLogs via
#                     VL's native elasticsearch-bulk ingest endpoint
#                     (`/insert/elasticsearch/_bulk`); replaced promtail
#                     in #127 so every journal field stays queryable
#                     instead of being collapsed into label/body shape.
#   Grafana         — dashboards + provisioned datasources, OIDC
#                     against Authentik via myAuthentik.oidcApps.
#                     The Prometheus datasource (uid="prometheus")
#                     just points at VM's :8428; logs use the
#                     `victoriametrics-logs-datasource` plugin.
#   Alertmanager    — Discord receiver + a Watchdog → healthchecks.io
#                     heartbeat receiver. Config rendered through
#                     envsubst so webhook URLs never hit /nix/store.
#                     Lives under `services.prometheus.alertmanager`
#                     in nixpkgs (no top-level alias) but the runtime
#                     unit is independent of any prometheus storage.
#
# Auth model. Every UI exposed by this stack is gated on Authentik
# group `Infrastructure`. Grafana speaks OIDC natively; VictoriaMetrics,
# vmalert, VictoriaLogs, and Alertmanager don't do auth, so they sit
# behind the `authentik_forward_auth` Caddy snippet (embedded outpost,
# proxy providers in `forward_single` mode).
#
# Data is intentionally ephemeral per the issue thread — no
# postgresqlBackup-style hook for VM/VL state. If the host dies,
# dashboards and alerting recreate themselves declaratively from
# these modules on the new box; only the historical timeseries is lost.
{ inputs, ... }:
{
  flake.modules.nixos.observability = _: {
    imports = with inputs.self.modules.nixos; [
      alertmanager
      grafana
      vector
      victorialogs
      victoriametrics
    ];
  };
}
