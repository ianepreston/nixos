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
# Two sources: the local journal, and remote syslog from pfSense
# (behemoth). The pfSense side was dead until now — its `<syslog>`
# block had no `<enable>` tag and pointed at a decommissioned host, so
# firewall blocks, pfBlockerNG rejects and config changes only ever
# landed in the router's local logs. Those rotate by size (512 KB × 8),
# which leaves roughly 12 hours of firewall history on the box; that
# short window is the reason for shipping them, not the config-change
# log (which survives ~7 months locally).
#
# Both servers are registered as remote targets on pfSense, so each
# keeps its own independent copy — same duplication as the
# `snmp_pfsense` scrape job in victoriametrics.nix, and deliberate for
# the same reason: neither host depends on the other being up.
#
# The journal side is loopback-only. The syslog listener is the one
# externally-reachable surface in this module, and it is opened only to
# the router's own address (see the firewall block below). The vector
# unit runs as a systemd DynamicUser with `journaldAccess = true` (adds
# the `systemd-journal` supplementary group) — no static user/group to
# manage; the nixpkgs module already grants
# `AmbientCapabilities=CAP_NET_BIND_SERVICE`, which is what lets a
# DynamicUser bind the privileged 514. Cursor state lives at
# /var/lib/vector/ via StateDirectory, so reboots resume where the last
# poll left off.
_: {
  flake.modules.nixos.vector =
    { config, ... }:
    let
      victorialogsPort = 9428;

      # pfSense hardcodes 514 as the default remote-syslog port and the
      # GUI takes the target as `IP[:port]`, so the receiver meets it
      # there rather than the other way round.
      syslogPort = 514;
      # behemoth's "Default" (mgmt VLAN) interface address. pfSense is
      # configured with this as its syslog Source Address, so every
      # message provably arrives from exactly this IP — which is what
      # makes the single-source firewall rule below sufficient.
      pfsenseAddress = "192.168.10.1";
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

          # pfSense remote syslog. Bound on all interfaces because the
          # host's mgmt address differs per host (192.168.10.10 on
          # hpp-1, .11 on amos1) and is not carried in hostSpec; the
          # firewall rule below is the enforcement point, not the bind
          # address. pfSense is set to RFC 5424 (`<format>rfc5424`) —
          # vector's syslog source parses both that and RFC 3164, but
          # only 5424 carries a year and a timezone in the timestamp,
          # so the format setting is load-bearing for correct ordering.
          sources.pfsense = {
            type = "syslog";
            mode = "udp";
            address = "0.0.0.0:${toString syslogPort}";
          };

          transforms = {
            # cAdvisor floods the journal with one line per podman
            # container per housekeeping cycle (~33/min, ~47k/day on
            # hpp-1) trying to read podman's `containers.json` storage
            # metadata — the cgroup-level metrics it ships still work,
            # only the libpod label-enrichment lookup fails. Drop just
            # the matching message; keep everything else cadvisor logs
            # so genuine collector errors stay visible (closes #192).
            drop_cadvisor_libpod_noise = {
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
            journal_enrich = {
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

            # Normalize syslog into the same field shape the journal
            # pipeline produces, so both feed one sink and one set of
            # `_stream_fields`. Without this, pfSense events would carry
            # `appname`/`severity` while journal events carry
            # `unit`/`level`, and every query would need to know which
            # source it was reading. Raw syslog fields are left in place —
            # same "keep both" rationale as journal_enrich above.
            pfsense_enrich = {
              type = "remap";
              inputs = [ "pfsense" ];
              source = ''
                if exists(.hostname) {
                  .host = .hostname
                }
                if exists(.appname) {
                  .unit = .appname
                }
                if exists(.severity) {
                  .level = .severity
                }
              '';
            };
          };

          sinks.victorialogs = {
            type = "elasticsearch";
            inputs = [
              "journal_enrich"
              "pfsense_enrich"
            ];
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

      # Open 514/udp to the router only. Source-restricted rather than
      # opened globally, following the flaresolverr precedent in
      # modules/apps/flaresolverr.nix: the NixOS allowlist
      # (`allowedUDPPorts`) emits a rule with no `-i` and no `-s`, which
      # here would also answer on tailscale0 and to any host on the mgmt
      # VLAN. Restricting by source IP keeps this interface-name-agnostic
      # (the LAN NIC is enp1s0 on hpp-1, enp4s0 on amos1) and narrows the
      # sender to the one device that is actually configured to send.
      #
      # Note this is *not* what keeps the IoT VLAN out — vlan30 is
      # already gated ahead of every accept by the `-i iot` jump that
      # iot-network.nix inserts at the head of nixos-fw (#477). This rule
      # is narrow on its own merits.
      #
      # IPv4-only (iptables, not ip46tables): the mgmt VLAN is v4 and
      # pfSense's `<ipproto>` is set to ipv4.
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p udp -s ${pfsenseAddress} --dport ${toString syslogPort} -j nixos-fw-accept
      '';
      networking.firewall.extraStopCommands = ''
        iptables -D nixos-fw -p udp -s ${pfsenseAddress} --dport ${toString syslogPort} -j nixos-fw-accept || true
      '';

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
