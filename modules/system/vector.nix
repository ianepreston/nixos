# Vector — ships the systemd journal into VictoriaLogs via VL's
# native ingest path (#127, replaces promtail).
#
# Why vector instead of promtail: promtail's Loki-push model is
# label-first, which forces the producer to pre-decide which fields
# get promoted to labels (we had only `unit` and `level`) and stuffs
# the rest into the log line body. VL's native ingest treats every
# field as a first-class indexed column, so we can ship the journal
# verbatim and query on fields we hadn't pre-decided to care about
# (`_PID`, `_BOOT_ID`, `MESSAGE_ID`, `SYSLOG_IDENTIFIER`, `_TRANSPORT`,
# …). Promtail was also deprecated by Grafana in late 2024 in favor
# of Alloy — keeping it just to talk to a non-Loki backend through a
# compat shim was two layers of "fine for now" stacked together.
#
# Why the elasticsearch sink and not the http+jsonline sink: VL's
# `/insert/elasticsearch/_bulk` endpoint is one of its three native
# paths (alongside `/insert/jsonline` and `/insert/loki/api/v1/push`),
# and it is the form VL's own docs recommend for Vector — vector ships
# a mature `elasticsearch` sink with bulk batching, gzip, and retry
# handling that the generic `http` sink would otherwise reimplement.
# `jsonline` is fine too; pick whichever has cleaner sink support.
#
# Loopback-only; no external exposure. The vector unit runs as a
# systemd DynamicUser with `journaldAccess = true` (adds the
# `systemd-journal` supplementary group) — no static user/group to
# manage. Cursor state lives at /var/lib/vector/ via StateDirectory,
# so reboots resume where the last poll left off.
_: {
  flake.modules.nixos.vector =
    { config, ... }:
    let
      victorialogsPort = 9428;
    in
    {
      services.vector = {
        enable = true;
        journaldAccess = true;

        settings = {
          sources.journald = {
            type = "journald";
            # Default reads all units the systemd-journal group can see.
            # No `current_boot_only` — we want history across reboots
            # since vector persists the cursor.
          };

          # cAdvisor floods the journal with one line per podman
          # container per housekeeping cycle (~33/min, ~47k/day on
          # hpp-1) trying to read podman's `containers.json` storage
          # metadata — the cgroup-level metrics it ships still work,
          # only the libpod label-enrichment lookup fails. Drop just
          # the matching message; keep everything else cadvisor logs
          # so genuine collector errors stay visible (closes #192).
          transforms.drop_cadvisor_libpod_noise = {
            type = "filter";
            inputs = [ "journald" ];
            condition = {
              type = "vrl";
              source = ''
                unit = to_string(._SYSTEMD_UNIT) ?? ""
                msg = to_string(.message) ?? ""
                !(unit == "cadvisor.service" && contains(msg, "Failed to create existing container"))
              '';
            };
          };

          # Add query-friendly aliases (`unit`, `level`) without
          # deleting the raw underscored journal fields — keeping both
          # means existing dashboards/alerts that key off `unit` and
          # `level` (matching the prior promtail labels) keep working,
          # while ad-hoc queries can still reach `_PID`, `_BOOT_ID`,
          # etc. directly. That dual access is the whole point of
          # this swap.
          transforms.journal_enrich = {
            type = "remap";
            inputs = [ "drop_cadvisor_libpod_noise" ];
            source = ''
              if exists(._SYSTEMD_UNIT) {
                .unit = ._SYSTEMD_UNIT
              }
              if exists(.PRIORITY) {
                severity = to_int(.PRIORITY) ?? 6
                .level = to_syslog_level(severity) ?? "info"
              }
            '';
          };

          sinks.victorialogs = {
            type = "elasticsearch";
            inputs = [ "journal_enrich" ];
            endpoints = [
              "http://127.0.0.1:${toString victorialogsPort}/insert/elasticsearch/"
            ];
            mode = "bulk";
            api_version = "v8";
            compression = "gzip";
            # VL's bulk endpoint doesn't implement the ES `/` healthcheck
            # vector probes by default; disabling it avoids a noisy
            # boot-time warning. Real liveness is the steady stream of
            # accepted events in vector's own logs.
            healthcheck.enabled = false;
            # VL ingest query params — define which field carries the
            # log body, which carries the timestamp, and which fields
            # form the stream key (low-cardinality identifier per log
            # stream). `host` + `unit` matches the prior promtail
            # label set and keeps stream count bounded; per-PID or
            # per-boot streams would explode cardinality and aren't
            # what stream fields are for.
            query = {
              _msg_field = "message";
              _time_field = "timestamp";
              _stream_fields = "host,unit";
            };
          };
        };
      };

      # Best-effort assertion that VL is in the same module set —
      # vector has no purpose here without a destination, and pointing
      # at loopback:9428 only makes sense when VL is on the host.
      assertions = [
        {
          assertion = config.services.victorialogs.enable;
          message = "modules.nixos.vector expects victorialogs to be enabled on the same host (loopback ingest at 127.0.0.1:9428).";
        }
      ];
    };
}
