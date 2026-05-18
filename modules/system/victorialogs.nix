# VictoriaLogs — single-binary log store, replaces Loki (#126).
#
# Listens on loopback only; Grafana queries via the VictoriaLogs
# datasource provisioned in ./grafana.nix (plugin
# `victoriametrics-logs-datasource`). Vector ingests through VL's
# native elasticsearch-bulk endpoint at `/insert/elasticsearch/_bulk`
# (see ./vector.nix) — swapped in via #127 so every journal field
# stays queryable instead of being collapsed into the Loki-push
# label/body shape promtail forced.
#
# Data is intentionally ephemeral per #65 / #126 — no backup hook.
# If the host dies, only historical logs are lost; the runtime config
# and vector wire-up recreate themselves declaratively.
_: {
  flake.modules.nixos.victorialogs =
    {
      hostSpec,
      ...
    }:
    let
      vlHost = "victorialogs.${hostSpec.serverDomain}";
      vlPort = 9428;
    in
    {
      services.victorialogs = {
        enable = true;
        # Loopback-only — Caddy proxies the UI for human access;
        # ingestion is local-only from vector.
        listenAddress = "127.0.0.1:${toString vlPort}";
        # 30d matches the retention we had on Loki (bumped from 7d
        # per #157). VL stores significantly more efficiently than
        # Loki for the same window, so this is comfortably within
        # the host's free space.
        extraOptions = [ "-retentionPeriod=30d" ];
      };

      # Forward-auth via the embedded authentik outpost — VictoriaLogs'
      # UI has no built-in auth so it sits behind the
      # `authentik_forward_auth` Caddy snippet (see
      # modules/apps/authentik.nix for the aggregator that owns
      # the outpost's providers list).
      myAuthentik.forwardAuthApps.victorialogs = {
        host = vlHost;
        port = vlPort;
        displayName = "VictoriaLogs";
        homepage = {
          group = "Infrastructure";
          icon = "loki";
          description = "logs";
        };
      };
    };
}
