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
# Firewall events arrive as pfSense's positional filterlog CSV, which is
# split into `fw_*` fields at ingest so alerts and dashboards can filter
# on action / interface / addresses / ports instead of substring-matching
# a blob. See the pfsense_filterlog transform for the format notes.
#
# Operational hazard, learned the hard way, and since mitigated: if this
# listener was down while pfSense was sending, the kernel answered each
# datagram with an ICMP port-unreachable — the firewall rule below
# accepts the packet, so it reached a closed port rather than being
# dropped. FreeBSD syslogd takes the resulting ECONNREFUSED as fatal for
# that target, logs `sendto: Connection refused`, and then stops sending
# to it *for good* — it never retries and never logs again. Recovery
# meant restarting syslogd on the router (`pfSsh.php playback svc restart
# syslogd`; a SIGHUP kills it rather than reloading it), so a vector
# bounce did not merely pause ingest, it silently detached the router
# until someone intervened on the box. Every `nixos-rebuild switch` that
# restarted vector opened that window, not just reboots.
#
# The ICMP was self-inflicted: without our accept rule the datagram would
# fall through to `nixos-fw-refuse`, which DROPs, and the router would
# never learn a thing. The firewall block below therefore also drops
# outbound ICMP port-unreachable toward the router, which restores that
# drop-on-the-floor behaviour and makes a vector outage cost nothing more
# than the datagrams sent during it. See the comment there.
#
# The absence alerting stays regardless: a stalled feed is still
# invisible in the log data itself, since an empty feed looks exactly
# like a quiet network. Any alerting built on this data should alert on
# *absence* of pfSense events, not only on their content — a quiet feed
# is the failure mode, not a calm network.
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

      # Vector's own telemetry, exported for VictoriaMetrics to scrape.
      # Paired with the `vector` scrape job in victoriametrics.nix, which
      # repeats this port number (same local-literal convention as
      # caddyMetricsPort / cadvisorPort / gatusPort there).
      metricsPort = 9598;

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
          sources = {
            journald = {
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
            pfsense = {
              type = "syslog";
              mode = "udp";
              address = "0.0.0.0:${toString syslogPort}";
            };

            # Vector's own event counters. These exist to make *absence*
            # detectable: per the hazard noted above, a stalled pfSense feed
            # is invisible from the log data itself — the feed simply goes
            # quiet, which is indistinguishable from a calm network. Counting
            # events per source turns that into a metric that can be alerted
            # on when its rate hits zero. Also covers the plain case of
            # vector being up but a source being broken.
            internal_metrics = {
              type = "internal_metrics";
            };
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

            # pfSense's filterlog ships one positional CSV row per
            # firewall event, which is queryable only by substring until
            # it is split into fields — `fw_action:block AND
            # fw_dst_port:22` is the shape alerts and dashboards need.
            #
            # The layout is NOT fixed-width: the first ten fields are
            # common, then the IP header differs by version, and the
            # tail differs by protocol. Observed on the live feed:
            # v4/tcp is 29 fields, v4/udp and v4/icmp are 23, v4/igmp
            # and v4/gre are 21 (their tail is a bare `datalength=N`,
            # not ports). So every read past the common prefix is
            # length-guarded rather than assumed present.
            #
            #   common   0 rule, 3 tracker, 4 interface, 6 action,
            #            7 direction, 8 IP version
            #   IPv4     16 proto name, 17 length, 18 src, 19 dst
            #   IPv6     12 proto name, 13 proto id, 14 length,
            #            15 src, 16 dst
            #
            # Note IPv6 orders the protocol *name* before its number
            # while IPv4 does the reverse, which is why the two branches
            # cannot share offsets. IPv6 also spells the name upper-case
            # ("TCP", "ICMPv6"), so it is downcased to keep `fw_proto`
            # queryable the same way across both.
            #
            # Ports stay strings like every other parsed field —
            # VictoriaLogs parses numerically for `range()` filters, so
            # nothing is lost, and a single type per column is kept.
            # The raw CSV stays in `.message`; these are additions, the
            # same "keep both" rationale as the enrich transforms above.
            # Deliberately NOT added to `_stream_fields` — source IPs
            # are unbounded and stream keys must stay low-cardinality.
            pfsense_filterlog = {
              type = "remap";
              inputs = [ "pfsense_enrich" ];
              source = ''
                if .unit == "filterlog" {
                  f = split(to_string(.message) ?? "", ",")
                  if length(f) > 9 {
                    .fw_rule = f[0]
                    .fw_tracker = f[3]
                    .fw_interface = f[4]
                    .fw_action = f[6]
                    .fw_direction = f[7]
                    .fw_ipver = f[8]

                    if f[8] == "4" && length(f) > 19 {
                      proto = downcase(f[16]) ?? ""
                      .fw_proto = proto
                      .fw_src_ip = f[18]
                      .fw_dst_ip = f[19]
                      if (proto == "tcp" || proto == "udp") && length(f) > 21 {
                        .fw_src_port = f[20]
                        .fw_dst_port = f[21]
                      }
                    }

                    if f[8] == "6" && length(f) > 16 {
                      proto = downcase(f[12]) ?? ""
                      .fw_proto = proto
                      .fw_src_ip = f[15]
                      .fw_dst_ip = f[16]
                      if (proto == "tcp" || proto == "udp") && length(f) > 18 {
                        .fw_src_port = f[17]
                        .fw_dst_port = f[18]
                      }
                    }
                  }
                }
              '';
            };
          };

          sinks = {
            # Loopback-only, like every other exporter on these hosts.
            vector_metrics = {
              type = "prometheus_exporter";
              inputs = [ "internal_metrics" ];
              address = "127.0.0.1:${toString metricsPort}";
            };

            victorialogs = {
              type = "elasticsearch";
              inputs = [
                "journal_enrich"
                "pfsense_filterlog"
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
      #
      # The second rule is what keeps a vector restart from detaching the
      # router. The accept rule above outlives the vector process — it is
      # installed by firewall.service, not by vector — so any datagram
      # arriving while vector is down is explicitly ACCEPTed into a closed
      # UDP port and the kernel answers ICMP port-unreachable, which is the
      # `sendto: Connection refused` that FreeBSD syslogd treats as fatal
      # for the target (see the hazard note at the top of this file).
      # Without the accept rule the packet would fall through to
      # `nixos-fw-refuse`, which DROPs (`networking.firewall.rejectPackets`
      # is false), and the router would never learn anything — so the ICMP
      # is manufactured by our own rule, not by anything pfSense does.
      # Suppressing just that reply toward the router restores the
      # drop-on-the-floor behaviour, degrading a vector outage to ordinary
      # UDP packet loss instead of a permanent detach needing a hands-on
      # syslogd restart.
      #
      # Code 3 (port unreachable) only, so frag-needed (code 4) still gets
      # through and PMTUD toward the router is unaffected. Nothing else on
      # this network wants port-unreachable from these hosts.
      #
      # This covers the frequent case as well as reboots: every
      # `nixos-rebuild switch` that bounces vector opens the same window,
      # which is how the 2026-08-31 auto-upgrade silently detached both
      # servers at once.
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p udp -s ${pfsenseAddress} --dport ${toString syslogPort} -j nixos-fw-accept
        iptables -A OUTPUT -p icmp --icmp-type port-unreachable -d ${pfsenseAddress} -j DROP
      '';
      networking.firewall.extraStopCommands = ''
        iptables -D nixos-fw -p udp -s ${pfsenseAddress} --dport ${toString syslogPort} -j nixos-fw-accept || true
        iptables -D OUTPUT -p icmp --icmp-type port-unreachable -d ${pfsenseAddress} -j DROP || true
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
