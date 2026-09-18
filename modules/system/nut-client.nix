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
# rules (`UpsMasterNutBroken` / `UpsNoCommunication`) rather than
# upsmon SHUTDOWN actions.
#
# The pfSense NUT package's weakness, concretely (#643). Its generated
# `/usr/local/etc/rc.d/nut.sh` is neither idempotent nor checked:
#
#   rc_start() {
#           /usr/bin/killall -q -9 upsmon upsd upsdrvctl usbhid-ups
#           /usr/local/sbin/upsdrvctl start &   # backgrounded, unchecked
#           /usr/local/sbin/upsd -u root        # races the driver
#           sleep 1
#           /usr/local/sbin/upsmon
#   }
#
# pfSense re-runs it on every "Restarting packages" (each WAN link
# flap via `rc.newwanip`) and twice during boot. A second invocation
# `killall -9`s a *healthy* set, and whatever loses the ensuing race
# stays dead — upsd's and the driver's early startup errors go to
# stderr, which `/rc.start_packages` discards, so the failure is
# silent. Three shapes observed, all from this one cause:
#
#   * driver dead, upsd alive  → `LIST VAR UPSA` = ERR DRIVER-NOT-CONNECTED
#   * upsd dead, upsmon alive  → connection refused (2026-09-17 boot)
#   * both dead
#
# All three are repaired by the same command, so we deliberately do
# *not* try to tell them apart in alerting — see the rules in
# ./victoriametrics.nix, which discriminate on the axis that actually
# changes the response (is behemoth itself reachable?) using the
# `snmp_pfsense` scrape we already run.
#
# Manual repair:
#
#   ssh behemoth /usr/local/etc/rc.d/nut.sh restart
#
# `service nut restart` does *not* work — the base rc script refuses
# without `nut_enable=YES` in /etc/rc.conf and points at `onerestart`.
# `nut.sh` is the pfSense package wrapper and the right entry point.
#
# pfSense self-heal (one-time, out-of-band — #643 Ask 2):
#   1. System → Package Manager → install the **Cron** package.
#   2. Services → Cron → Add, running as `root` every 5 minutes
#      (min `*/5`, everything else `*`), with this as the command —
#      one line, no wrapping:
#
#        U=/usr/local/bin/upsc; D=/usr/local/sbin/upsdrvctl; L=/usr/bin/logger; $U UPSA >/dev/null 2>&1 || { sleep 10; $U UPSA >/dev/null 2>&1; } || { $L -t nut-watchdog 'UPSA unreadable, repairing'; $D start >/dev/null 2>&1; sleep 5; $U UPSA >/dev/null 2>&1 || { /usr/local/etc/rc.d/nut.sh restart >/dev/null 2>&1; sleep 5; $D start >/dev/null 2>&1; sleep 5; }; $U UPSA >/dev/null 2>&1 && $L -t nut-watchdog 'UPSA repaired' || $L -t nut-watchdog 'UPSA repair FAILED'; }
#
#      Read it as: probe, re-probe, repair cheaply, escalate, report.
#
#      * `upsc` exits 1 on both DRIVER-NOT-CONNECTED and
#        connection-refused, so one probe covers every shape above.
#      * The 10s re-probe is load-bearing, not politeness. `upsdrvctl
#        start` against a *live* driver prints "Duplicate driver
#        instance detected! Terminating other driver!" and replaces
#        it, so a false positive costs a real bounce.
#      * `upsdrvctl start` is tried alone first: when upsd is up and
#        only the driver died — the common shape — it repairs in place
#        and upsd reconnects on its own, without bouncing upsd or
#        upsmon the way `nut.sh restart` does.
#      * The second `$D start` after `nut.sh restart` is there because
#        one `nut.sh restart` is genuinely not always enough: on
#        2026-09-18 the driver came up only on the second attempt
#        (`nut_libusb_get_report: No device` the first time, clean the
#        second), which is the same USB flakiness behind the recurring
#        `libusb1: Could not open any HID devices` staleness flaps.
#      * Those `Data stale` flaps (a few per day, 5-10s) still serve
#        variables, so `upsc` succeeds and the watchdog ignores them.
#      * The `logger` lines land in the pfSense syslog stream we
#        already ship to VictoriaLogs, so a watchdog that is papering
#        over a failing UPS every 5 minutes is visible rather than
#        silent. `UPSA repair FAILED` is the one to look for.
#
#      Cron jobs live in `config.xml`, so this survives reboots and
#      backup/restore — unlike a hand-edited `/etc/crontab`, which
#      pfSense regenerates. Patching `nut.sh` itself is not an option:
#      the package service handler rewrites it on every config change.
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
          # nut_exporter *hangs* rather than erroring when upsd is
          # unreachable or answers DRIVER-NOT-CONNECTED, so the default
          # 10s scrape_timeout was being burned in full on every
          # attempt (#643). A healthy scrape returns in ~0.15s; 5s is
          # ~30x headroom and gets `up` to 0 promptly instead of
          # pinning a scrape worker for a third of the interval.
          scrape_timeout = "5s";
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
