# Observability — metrics, logs, dashboards, alerting.
#
# Parent meta-module: collects the per-service modules so the server
# profile can `imports` a single observability target. Each leaf
# module is self-contained (sops secrets, systemd config, caddy
# routes, authentik wiring). Add new observability components by
# dropping a new module under modules/system/<component>.nix and
# adding it to the imports list below.
#
# Stack:
#   Prometheus     — scrapes node/postgres/mysqld/redis/caddy/cadvisor/
#                    itself; ephemeral on-disk TSDB with 15d retention.
#   Loki           — single-node, filesystem store; ~7d retention.
#   Promtail       — ships the systemd journal into Loki.
#   Grafana        — dashboards + provisioned datasources, OIDC against
#                    Authentik via myAuthentik.oidcApps.
#   Alertmanager   — Discord receiver + a Watchdog → healthchecks.io
#                    heartbeat receiver. Config rendered through
#                    envsubst so webhook URLs never hit /nix/store.
#
# Auth model. Every UI exposed by this stack is gated on Authentik
# group `Infrastructure`. Grafana speaks OIDC natively; Prometheus and
# Alertmanager don't do auth, so they sit behind the
# `authentik_forward_auth` Caddy snippet (embedded outpost, proxy
# providers in `forward_single` mode).
#
# Data is intentionally ephemeral per the issue thread — no
# postgresqlBackup-style hook for prometheus/loki state. If the host
# dies, dashboards and alerting recreate themselves declaratively from
# these modules on the new box; only the historical timeseries is lost.
{ inputs, ... }:
{
  flake.modules.nixos.observability = _: {
    imports = with inputs.self.modules.nixos; [
      alertmanager
      grafana
      loki
      prometheus
      promtail
    ];
  };
}
