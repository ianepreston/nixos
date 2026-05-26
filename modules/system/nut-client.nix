# NUT client — every server monitors both UPS masters as a pure
# netclient (no upsd, no driver, just upsmon). Topology and rationale
# in issue #82:
#
#   UPS-A → Synology NAS (laconia) — DSM is the NUT master.
#   UPS-B → pfSense router (192.168.10.1) — pfSense NUT package master.
#   This host (and every other server) → both masters as secondary.
#
# Two MONITOR entries with powerValue=0 on the NAS line so its low-
# battery state still drives our shutdown without us pretending the NAS
# UPS feeds our own PSU. powerValue=1 on the router line because that
# UPS is the one actually feeding the server.
#
# Auth: DSM hardcodes upsd users to `monuser` / `secret` for its
# Network UPS Server; rotating it is not exposed in the DSM UI. The
# pfSense user is operator-defined — we generated a random hex
# password via `task secrets:secret APP=nut KEY=router_password` and
# pasted it into the pfSense NUT package's auth list.
#
# pfSense out-of-band setup (one-time, not in nix):
#   1. Services → UPS → UPS Settings → Advanced → upsd.conf, add:
#        LISTEN 192.168.10.1 3493
#      (default is loopback-only; the GUI has no "listen interface"
#      field, only the advanced free-form text block.)
#   2. Add `upsmon` user with the generated password in the
#      upsd.users advanced section.
#   3. Firewall → Rules → LAN → allow TCP/3493 from 192.168.10.10
#      (or server VLAN) to LAN address. (Default LAN→any rule may
#      already cover this; verify with `nc -z 192.168.10.1 3493`
#      from a server.)
#
# loss-of-comms tuning. NOCOMM_WARNTIME is generous (300s) so a
# pfSense package restart / upgrade flap doesn't trigger anything
# destructive — the pfSense NUT package is the weakest link per the
# decision log on #82. Communications loss is surfaced via vmalert
# rules (`UpsNoCommunication`) rather than upsmon SHUTDOWN actions.
#
# Metrics. A pair of DRuggeri/nut_exporter instances run on loopback
# ports 9199 (router-ups) / 9200 (nas-ups) and are scraped by the
# local VictoriaMetrics. Two instances rather than one with
# `?target=` keep the scrape job static-target-shaped and match how
# the per-source `instance` label flows through vmalert rules.
_: {
  flake.modules.nixos.nut-client =
    {
      config,
      inputs,
      lib,
      pkgs,
      ...
    }:
    let
      sopsFolder = "${inputs.nix-secrets}/sops";
      nasHost = "laconia.ipreston.net";
      nasUpsName = "ups";
      nasUser = "monuser";

      routerHost = "192.168.10.1";
      routerUpsName = "UPSA";
      routerUser = "upsmon";

      routerExporterPort = 9199;
      nasExporterPort = 9200;

      mkExporter =
        {
          name,
          server,
          port,
        }:
        {
          description = "Prometheus NUT exporter (${name})";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.prometheus-nut-exporter}/bin/nut_exporter"
              "--nut.server=${server}"
              "--web.listen-address=127.0.0.1:${toString port}"
              # Don't emit per-variable info metrics — they're high-
              # cardinality strings (firmware/model/serial) we'd
              # never alert on.
              "--nut.disable_device_info"
            ];
            Restart = "on-failure";
            RestartSec = "10s";
            # Hardening — exporter only needs network egress.
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
          };
        };
    in
    {
      sops.secrets = {
        "nut/nas_password" = {
          sopsFile = "${sopsFolder}/server-shared.yaml";
          restartUnits = [ "upsmon.service" ];
        };
        "nut/router_password" = {
          sopsFile = "${sopsFolder}/server-shared.yaml";
          restartUnits = [ "upsmon.service" ];
        };
      };

      power.ups = {
        enable = true;
        mode = "netclient";
        upsmon = {
          monitor = {
            # NAS UPS — DSM master at laconia. powerValue=0 means this
            # UPS doesn't power us, but losing it (low battery on the
            # NAS UPS) still triggers our shutdown via the
            # MINSUPPLIES=1 floor coming from the router monitor.
            # This is what makes us shut down *before* the NAS dies
            # from its own UPS draining (issue #82 acceptance test).
            nas = {
              system = "${nasUpsName}@${nasHost}";
              powerValue = 0;
              user = nasUser;
              passwordFile = config.sops.secrets."nut/nas_password".path;
              type = "secondary";
            };
            # Router UPS — pfSense master. This UPS actually feeds the
            # server PSU, so powerValue=1.
            router = {
              system = "${routerUpsName}@${routerHost}";
              powerValue = 1;
              user = routerUser;
              passwordFile = config.sops.secrets."nut/router_password".path;
              type = "secondary";
            };
          };
          settings = {
            MINSUPPLIES = 1;
            # 300s of upsd unreachability before upsmon yells. A
            # pfSense package restart usually flaps for <30s, so this
            # avoids false NOCOMM alarms without hiding real outages.
            # Directive name is one word (NOCOMMWARNTIME) per
            # upsmon.conf(5) — the underscored variant is silently
            # rejected as "invalid directive".
            NOCOMMWARNTIME = 300;
            # Default DEADTIME (15s) is fine — that's how long after
            # the last heartbeat from upsd we treat the UPS as dead.
            # Re-poll less aggressively so a single bad packet doesn't
            # trip DEADTIME.
            POLLFREQ = 5;
            POLLFREQALERT = 5;
            # Log notifications to syslog (journal) — no exec path so
            # we don't need an upssched / NOTIFYCMD shell harness.
            # Alerting is owned by vmalert + alertmanager on top of
            # nut_exporter metrics.
            NOTIFYFLAG = [
              [
                "ONLINE"
                "SYSLOG"
              ]
              [
                "ONBATT"
                "SYSLOG"
              ]
              [
                "LOWBATT"
                "SYSLOG"
              ]
              [
                "FSD"
                "SYSLOG"
              ]
              [
                "COMMOK"
                "SYSLOG"
              ]
              [
                "COMMBAD"
                "SYSLOG"
              ]
              [
                "SHUTDOWN"
                "SYSLOG"
              ]
              [
                "REPLBATT"
                "SYSLOG"
              ]
              [
                "NOCOMM"
                "SYSLOG"
              ]
              [
                "NOPARENT"
                "SYSLOG"
              ]
            ];
          };
        };
      };

      # NUT bundles cli tools (upsc, upscmd, upsrw) we'll want for
      # interactive debugging on the host.
      environment.systemPackages = [ pkgs.nut ];

      systemd.services = {
        nut-exporter-router = mkExporter {
          name = "router-ups";
          server = routerHost;
          port = routerExporterPort;
        };
        nut-exporter-nas = mkExporter {
          name = "nas-ups";
          server = nasHost;
          port = nasExporterPort;
        };
      };

      # Hook into VictoriaMetrics scrape config. Two static targets,
      # one per master. The `ups_source` label distinguishes them in
      # dashboards / alerts — `instance` ends up as the exporter
      # loopback port, which is meaningless to humans.
      services.victoriametrics.prometheusConfig.scrape_configs = [
        {
          job_name = "nut";
          metrics_path = "/ups_metrics";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString routerExporterPort}" ];
              labels.ups_source = "router";
            }
            {
              targets = [ "127.0.0.1:${toString nasExporterPort}" ];
              labels.ups_source = "nas";
            }
          ];
        }
      ];
    };
}
