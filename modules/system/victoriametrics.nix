# VictoriaMetrics + vmalert — metrics storage / scrape / rule evaluation,
# plus the Prometheus exporter modules and cAdvisor (container metrics).
#
# Replaces the Prometheus storage + rule evaluator from #126. The
# `services.prometheus.exporters.*` namespace is kept (it does not
# depend on `services.prometheus.enable`; each exporter sub-option
# creates its own systemd unit). No top-level alias exists for
# `prometheus-node-exporter` etc. in nixpkgs, so the option path stays
# under the prometheus namespace even though there is no prometheus
# storage on the host.
#
# Components:
#   victoriametrics — scrapes node/postgres/mysqld/redis/caddy/cadvisor/
#                     itself; 15d retention, ephemeral on-disk.
#   vmalert         — evaluates the rule YAML and emits to alertmanager.
#                     MetricsQL is a strict PromQL superset, so the
#                     existing rule expressions move over unchanged.
#   cAdvisor        — per-container cgroups metrics (podman containers).
#   Prometheus exporters — node/postgres/mysqld/redis, all unchanged.
#
# Data is ephemeral by design (#65 / #126). If the host dies, rules,
# exporters, dashboards recreate themselves declaratively; only the
# historical timeseries is lost.
_: {
  flake.modules.nixos.victoriametrics =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      vmHost = "victoriametrics.${hostSpec.serverDomain}";
      vmalertHost = "vmalert.${hostSpec.serverDomain}";

      # Textfile collector — writable by root oneshots, scraped by
      # node_exporter's textfile collector. Used by server-backups.nix
      # to publish per-snapshot restic stats once per nightly backup.
      textfileDir = "/var/lib/node-exporter-textfile-collector";

      vmPort = 8428;
      # 8880 is vmalert's default but UniFi controller binds it; bump by 1.
      vmalertPort = 8881;
      alertmanagerPort = 9093;
      caddyMetricsPort = 2019;
      cadvisorPort = 8081;
      gatusPort = 8084;

      # Same alert content as the prior prometheus.ruleFiles; vmalert
      # accepts the Prometheus rule YAML verbatim. Watchdog stays in
      # its own group so the route in alertmanager.nix
      # (alertname="Watchdog" → heartbeat) still matches.
      ruleGroups = {
        groups = [
          {
            name = "watchdog";
            rules = [
              {
                alert = "Watchdog";
                expr = "vector(1)";
                labels.severity = "none";
                annotations.summary = "Heartbeat — alerting pipeline is alive.";
              }
            ];
          }
          {
            name = "homelab";
            rules = [
              {
                alert = "InstanceDown";
                expr = "up == 0";
                for = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "{{ $labels.job }} target down ({{ $labels.instance }})";
                  description = "vmalert has not been able to scrape {{ $labels.job }} at {{ $labels.instance }} for 5 minutes.";
                };
              }
              {
                alert = "FilesystemAlmostFull";
                expr = ''(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|devtmpfs|fuse.*|squashfs|ramfs|nsfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|devtmpfs|fuse.*|squashfs|ramfs|nsfs"}) < 0.20'';
                for = "10m";
                labels.severity = "critical";
                annotations = {
                  summary = "Disk almost full on {{ $labels.instance }} ({{ $labels.mountpoint }})";
                  description = "{{ $labels.mountpoint }} on {{ $labels.instance }} is below 20% free for 10m. Current value: {{ $value | humanizePercentage }}.";
                };
              }
              {
                alert = "SystemdUnitFailed";
                expr = ''node_systemd_unit_state{state="failed"} == 1'';
                for = "5m";
                labels.severity = "warning";
                annotations = {
                  summary = "systemd unit {{ $labels.name }} failed on {{ $labels.instance }}";
                  description = "Unit {{ $labels.name }} has been in failed state for 5m on {{ $labels.instance }}.";
                };
              }
              {
                # initrd @old_roots prune failed (#310). The host still
                # boots — @root is recreated from @root-blank *before*
                # the prune — but the initrd rollback left a
                # /persist/var/lib/rollback-root/prune-failed marker, so
                # old roots are accumulating on the root filesystem.
                # Metric published every 5m by the
                # rollback-root-prune-metrics oneshot in
                # modules/hosts/_rollback-root.nix; absent on hosts
                # without the rollback service. Recover by checking the
                # next boot's `rollback-root` journal and rebooting,
                # which re-runs the prune (and clears the marker on
                # success).
                alert = "RollbackRootPruneFailed";
                expr = "rollback_root_prune_failed == 1";
                for = "15m";
                labels.severity = "warning";
                annotations = {
                  summary = "initrd @old_roots prune failed on {{ $labels.instance }}";
                  description = "The btrfs rollback service could not prune old @old_roots on the last boot; the host booted fine but old roots are piling up under the root filesystem. Check the rollback-root journal and reboot to re-run the prune. See modules/hosts/_rollback-root.nix (#310).";
                };
              }
              {
                alert = "HostHighMemory";
                expr = "(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.10";
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "Memory pressure on {{ $labels.instance }}";
                  description = "Less than 10% available memory for 10m on {{ $labels.instance }}. Currently {{ $value | humanizePercentage }} available.";
                };
              }
              {
                alert = "HostOOMKill";
                expr = "rate(node_vmstat_oom_kill[5m]) > 0";
                # The kernel OOM counter is monotonic and doesn't
                # oscillate, so a 1m confirmation costs nothing but
                # suppresses single-bad-sample false positives (see #239,
                # where this fired with the counter flat at 0 all window).
                for = "1m";
                labels.severity = "warning";
                annotations = {
                  summary = "OOM kill on {{ $labels.instance }}";
                  description = "Kernel OOM killer activated on {{ $labels.instance }} in the last 5m. Check what got killed via journalctl -k.";
                };
              }
              {
                alert = "PostgresDown";
                expr = "pg_up == 0";
                for = "2m";
                labels.severity = "critical";
                annotations = {
                  summary = "PostgreSQL is down on {{ $labels.instance }}";
                  description = "postgres_exporter reports pg_up=0 for 2m. All apps using shared postgres are broken.";
                };
              }
              {
                alert = "MariadbDown";
                expr = "mysql_up == 0";
                for = "2m";
                labels.severity = "critical";
                annotations = {
                  summary = "MariaDB is down on {{ $labels.instance }}";
                  description = "mysqld_exporter reports mysql_up=0 for 2m. All apps using shared mariadb are broken.";
                };
              }
              {
                alert = "RedisDown";
                expr = "redis_up == 0";
                for = "2m";
                labels.severity = "critical";
                annotations = {
                  summary = "Redis/Valkey instance {{ $labels.redis_instance }} is down";
                  description = "redis_exporter reports redis_up=0 for {{ $labels.instance }} (redis_instance={{ $labels.redis_instance }}) for 2m. Consumers of this redis are broken.";
                };
              }
              {
                alert = "ContainerRestartLoop";
                expr = ''changes(container_start_time_seconds{name!=""}[15m]) >= 3'';
                for = "0m";
                labels.severity = "warning";
                annotations = {
                  summary = "Container {{ $labels.name }} restart-looping";
                  description = "Container {{ $labels.name }} on {{ $labels.instance }} has restarted {{ $value }} times in the last 15m.";
                };
              }
              {
                alert = "GatusEndpointDown";
                expr = "gatus_results_endpoint_success == 0";
                for = "3m";
                labels.severity = "warning";
                annotations = {
                  summary = "Gatus probe failing: {{ $labels.name }} ({{ $labels.group }})";
                  description = "Endpoint {{ $labels.name }} in group {{ $labels.group }} has been failing its gatus probe for 3m.";
                };
              }
              {
                # Stale file under sabnzbd's incomplete dir (#276).
                # Metric is published by the sabnzbd-incomplete-metrics
                # oneshot in modules/apps/sabnzbd.nix every 5m. >24h
                # means a download is stalled (missing articles across
                # all configured providers, post-processing wedged, or
                # the queue is paused and forgotten). Absent on hosts
                # that don't run sabnzbd — `for: 30m` debounces the gap
                # between the oneshot's first write and node_exporter's
                # next scrape.
                alert = "SabnzbdIncompleteStale";
                expr = "sabnzbd_incomplete_oldest_seconds > 86400";
                for = "30m";
                labels.severity = "warning";
                annotations = {
                  summary = "sabnzbd has a stale file in incomplete/ on {{ $labels.instance }}";
                  description = "A file under sabnzbd's incomplete dir has been there for >24h ({{ $value | humanizeDuration }}). Stalled download, wedged post-processing, or forgotten paused queue.";
                };
              }
              {
                # Incomplete dir filling up (#276). The dir lives under
                # /persist, sharing the root filesystem — the existing
                # FilesystemAlmostFull rule (above) covers truly-full
                # /persist, but a stuck unrar can chew through 100s of
                # GB inside a healthy-looking root. 200 GiB is well
                # above any single in-flight release (~100 GB for a 4K
                # blu-ray rip) and flags accumulation.
                alert = "SabnzbdIncompleteLarge";
                expr = "sabnzbd_incomplete_dir_bytes > 200 * 1024 * 1024 * 1024";
                for = "30m";
                labels.severity = "warning";
                annotations = {
                  summary = "sabnzbd incomplete dir over 200 GiB on {{ $labels.instance }}";
                  description = "sabnzbd_incomplete_dir_bytes = {{ $value | humanize1024 }}B for 30m. Either a release got stuck in post-processing or multiple downloads are piling up faster than they're finishing.";
                };
              }
              {
                # Stuck Mylar grab (#299 follow-up). Metric published by
                # the mylar3-snatched-metrics oneshot in
                # modules/apps/mylar3.nix every 5m; absent on hosts not
                # running mylar3. Mylar's SAB completed-download-handling
                # tracks each grab by the SAB nzo_id and never recovers
                # when that id vanishes (SAB retry/re-add, or a failed
                # slot purged by sab_remove_failed) — the issue sits in
                # Snatched, the historycheck loops "Cannot find nzb …"
                # forever, and nothing imports even though the file is
                # usually complete on disk. Also catches genuinely
                # unavailable releases (out of retention) that need a
                # manual re-search, and mis-matched grabs (a search that
                # fetched the wrong issue number). The metric unions the
                # `issues` and `annuals` tables, so annual-only stucks —
                # which live in a separate table and would otherwise
                # never surface — are covered too. 6h is well past any
                # real comic download (tens of MB) yet tolerates a long
                # SAB queue; `for: 30m` debounces the publish/scrape gap.
                # Recover with the manual post_process runbook in
                # mylar3.nix (annuals-table stucks take the markissues
                # Retry path documented there instead), then
                # `podman restart mylar3`.
                alert = "MylarSnatchedStuck";
                expr = "mylar3_snatched_oldest_seconds > 21600";
                for = "30m";
                labels.severity = "warning";
                annotations = {
                  summary = "Mylar has a stuck Snatched issue on {{ $labels.instance }}";
                  description = "A Mylar issue has been Snatched for >6h ({{ $value | humanizeDuration }}) without importing — completed-download-handling likely lost the SAB nzo_id, or the release is unavailable. See the manual post_process runbook in modules/apps/mylar3.nix.";
                };
              }
              {
                alert = "HighCaddy5xx";
                expr = ''sum by (instance, server) (rate(caddy_http_requests_total{code=~"5.."}[5m])) > 0.1'';
                for = "5m";
                labels.severity = "warning";
                annotations = {
                  summary = "Caddy serving 5xx ({{ $labels.server }})";
                  description = "Caddy server {{ $labels.server }} on {{ $labels.instance }} is returning 5xx at {{ $value }} req/s — usually means a backend (mealie, authentik, grafana, etc.) is unhealthy.";
                };
              }
            ];
          }
          {
            # Temperature alerts (#240). CPU package temps come from
            # node_exporter's hwmon collector — Intel exposes "Package
            # id 0", AMD exposes "Tdie"/"Tctl"; matching on the label
            # makes this vendor-agnostic. iGPUs share the CPU package
            # thermal zone, so there is no separate iGPU sensor to
            # alert on. The NVIDIA rules use nvidia_smi_temperature_gpu
            # which is absent until a host runs the nvidia exporter
            # (#242); silently no-ops on hosts without an NVIDIA GPU.
            name = "temperature";
            rules = [
              {
                alert = "HostCPUTemperatureHigh";
                expr = ''max by (instance) (node_hwmon_temp_celsius * on (chip, sensor) group_left(label) node_hwmon_sensor_label{label=~"Package id.*|Tdie|Tctl"}) > 80'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "CPU running hot on {{ $labels.instance }}";
                  description = "CPU package temperature on {{ $labels.instance }} has been above 80°C for 10m. Currently {{ $value }}°C. Check airflow / fan health.";
                };
              }
              {
                alert = "HostCPUTemperatureCritical";
                expr = ''max by (instance) (node_hwmon_temp_celsius * on (chip, sensor) group_left(label) node_hwmon_sensor_label{label=~"Package id.*|Tdie|Tctl"}) > 90'';
                for = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "CPU thermal-throttling imminent on {{ $labels.instance }}";
                  description = "CPU package temperature on {{ $labels.instance }} has been above 90°C for 5m. Currently {{ $value }}°C. Thermal throttling likely; investigate immediately.";
                };
              }
              {
                alert = "HostGPUTemperatureHigh";
                expr = "max by (instance) (nvidia_smi_temperature_gpu) > 80";
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "GPU running hot on {{ $labels.instance }}";
                  description = "GPU temperature on {{ $labels.instance }} has been above 80°C for 10m. Currently {{ $value }}°C.";
                };
              }
              {
                alert = "HostGPUTemperatureCritical";
                expr = "max by (instance) (nvidia_smi_temperature_gpu) > 90";
                for = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "GPU thermal-throttling imminent on {{ $labels.instance }}";
                  description = "GPU temperature on {{ $labels.instance }} has been above 90°C for 5m. Currently {{ $value }}°C. Thermal throttling likely; investigate immediately.";
                };
              }
              # NVMe thresholds come from the drive itself (NVMe spec
              # WCTEMP / CCTEMP fields, exposed by node_exporter as
              # node_hwmon_temp_{max,crit}_celsius). Comparing against
              # the drive's own thresholds rather than a hardcoded
              # number generalises across drives — e.g. hpp-1's WD
              # Black SN850 reports 85°C/88°C, but a different drive
              # might throttle at 70°C and we'd want this to alert
              # there instead of waiting until 80.
              {
                alert = "HostNVMeTemperatureHigh";
                expr = ''node_hwmon_temp_celsius{chip=~"nvme_.*"} >= on (instance, chip, sensor) node_hwmon_temp_max_celsius{chip=~"nvme_.*"}'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "NVMe at warning threshold on {{ $labels.instance }}";
                  description = "NVMe drive on {{ $labels.instance }} ({{ $labels.chip }}) has been at or above its self-reported warning temperature (WCTEMP) for 10m. Currently {{ $value }}°C. Check airflow / add a heatsink.";
                };
              }
              {
                alert = "HostNVMeTemperatureCritical";
                expr = ''node_hwmon_temp_celsius{chip=~"nvme_.*"} >= on (instance, chip, sensor) node_hwmon_temp_crit_celsius{chip=~"nvme_.*"}'';
                for = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "NVMe at critical threshold on {{ $labels.instance }}";
                  description = "NVMe drive on {{ $labels.instance }} ({{ $labels.chip }}) has been at or above its self-reported critical temperature (CCTEMP) for 5m. Currently {{ $value }}°C. Drive will throttle or shut down; intervene immediately.";
                };
              }
              # Synology HDD temperature. diskTemperature comes from
              # the synology MIB via snmp_exporter. 50°C / 60°C are
              # the conventional warning / critical thresholds for
              # enterprise 7200rpm spinning drives (Seagate Exos and
              # similar — rated max 60°C operating). diskID is hex-
              # encoded ASCII because snmp_exporter treats Synology's
              # OctetString as binary; "0x4469736B2031" = "Disk 1",
              # cross-reference the dashboard to find the slot.
              {
                alert = "NASDiskTemperatureHigh";
                expr = ''diskTemperature{job="snmp_synology"} > 50'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "NAS disk running hot ({{ $labels.diskID }})";
                  description = "Synology disk {{ $labels.diskID }} has been above 50°C for 10m. Currently {{ $value }}°C. Check NAS airflow / fan health.";
                };
              }
              {
                alert = "NASDiskTemperatureCritical";
                expr = ''diskTemperature{job="snmp_synology"} > 60'';
                for = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "NAS disk at thermal limit ({{ $labels.diskID }})";
                  description = "Synology disk {{ $labels.diskID }} has been above 60°C for 5m. Currently {{ $value }}°C. Drives are at or above the rated operating ceiling; intervene immediately.";
                };
              }
            ];
          }
          {
            # UPS / power alerts (#82). Metrics come from
            # nut_exporter; the `ups_source` label is set in
            # nut-client.nix's scrape config (router|nas), the `ups`
            # label is the upsname on each master (typically `ups`).
            #
            # ups.status is a bitfield surfaced as
            # network_ups_tools_ups_status{flag="OL|OB|LB|FSD|RB|..."}
            # — 1 when the flag is asserted. OL=online (mains),
            # OB=on battery, LB=low battery, FSD=forced shutdown,
            # RB=replace battery.
            name = "power";
            rules = [
              {
                alert = "UpsOnBattery";
                expr = ''network_ups_tools_ups_status{flag="OB"} == 1'';
                for = "30s";
                labels.severity = "warning";
                annotations = {
                  summary = "UPS {{ $labels.ups_source }} on battery";
                  description = "{{ $labels.ups_source }}-side UPS ({{ $labels.ups }}) has been on battery for 30s. Mains lost or upstream breaker tripped.";
                };
              }
              {
                alert = "UpsLowBattery";
                expr = ''network_ups_tools_ups_status{flag="LB"} == 1'';
                for = "0m";
                labels.severity = "critical";
                annotations = {
                  summary = "UPS {{ $labels.ups_source }} at low battery";
                  description = "{{ $labels.ups_source }}-side UPS ({{ $labels.ups }}) signaled low battery. Hosts monitoring this UPS as primary are about to shut down.";
                };
              }
              {
                alert = "UpsBatteryReplace";
                expr = ''network_ups_tools_ups_status{flag="RB"} == 1'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "UPS {{ $labels.ups_source }} needs battery replacement";
                  description = "{{ $labels.ups_source }}-side UPS ({{ $labels.ups }}) is reporting RB (replace battery) — self-test has failed. Schedule a swap before the next power event.";
                };
              }
              {
                alert = "UpsBatteryCharge";
                expr = "network_ups_tools_battery_charge < 50";
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "UPS {{ $labels.ups_source }} battery low ({{ $value | humanize }}%)";
                  description = "{{ $labels.ups_source }}-side UPS ({{ $labels.ups }}) battery charge below 50% for 10m. Investigate — either we're on battery and didn't notice, or it isn't holding charge.";
                };
              }
              {
                # nut_exporter returns no metrics at all when it
                # can't reach upsd, so `up == 0` for the nut job is
                # how we detect master loss-of-comms. The 10m `for`
                # window is intentionally longer than upsmon's
                # NOCOMM_WARNTIME (300s) so a pfSense package
                # restart flap doesn't page.
                alert = "UpsNoCommunication";
                expr = ''up{job="nut"} == 0'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "Lost communication with {{ $labels.ups_source }}-side UPS master";
                  description = "nut_exporter for {{ $labels.ups_source }}-side UPS has failed to reach its master for 10m. If this is the router-side UPS, the pfSense NUT package may have crashed (known fragility — see #82). Loss of comms with both at once probably means LAN-down, not power.";
                };
              }
              {
                alert = "UpsHighLoad";
                expr = "network_ups_tools_ups_load > 80";
                for = "15m";
                labels.severity = "warning";
                annotations = {
                  summary = "UPS {{ $labels.ups_source }} load high ({{ $value | humanize }}%)";
                  description = "{{ $labels.ups_source }}-side UPS ({{ $labels.ups }}) load above 80% for 15m. Runtime on battery will be shorter than rated; consider re-balancing loads across PDUs.";
                };
              }
            ];
          }
        ];
      };
    in
    {
      # Textfile collector directory. World-readable so node_exporter's
      # DynamicUser can traverse it; root-writable for the oneshots that
      # publish `.prom` files into it (currently just server-backups).
      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
      ];

      systemd.services = {
        # Wait for mariadb's socket before the exporter tries to connect;
        # without this it crashloops at boot until mysql.service is up.
        prometheus-mysqld-exporter = {
          after = [ "mysql.service" ];
          requires = [ "mysql.service" ];
        };
      };

      # Provision the exporter's mariadb role. ensureUsers gives it
      # unix_socket auth, which matches the OS user the prometheus
      # mysqld_exporter unit runs as ("mysqld-exporter") so no password
      # is needed.
      services.mysql.ensureUsers = [
        {
          name = "mysqld-exporter";
          ensurePermissions = {
            "*.*" = "PROCESS, REPLICATION CLIENT, SELECT";
          };
        }
      ];

      services = {
        # ========== Caddy admin metrics ==========
        # Enable per-server metrics collection so the admin endpoint at
        # :2019/metrics has request/duration counters, not just runtime
        # stats. NixOS concatenates this onto the value declared in
        # modules/system/caddy.nix.
        caddy.globalConfig = ''
          servers {
            metrics
          }
        '';

        # ========== Prometheus exporters ==========
        # These live under the `services.prometheus.exporters.*`
        # namespace but do not require `services.prometheus.enable`
        # — each is an independent systemd unit. No top-level alias
        # exists in nixpkgs, so the option path stays here even after
        # the prometheus storage has been retired.
        prometheus.exporters = {
          node = {
            enable = true;
            enabledCollectors = [
              "systemd"
              "processes"
              # textfile collector — slurps any `*.prom` written into
              # textfileDir below. server-backups.nix writes per-app
              # restic snapshot sizes there once per nightly run.
              "textfile"
            ];
            # Narrow the systemd collector to units we actually
            # dashboard/alert on. Without this, node_systemd_unit_state
            # emits a series per (unit × state) for every unit on the
            # host — hundreds of mounts, scopes, user@*.service slices,
            # podman-internal helpers — which blows up TSDB cardinality
            # for no observability gain.
            #
            # Per #157: re-evaluate this regex when adding a new app
            # module. Anything not matched here is invisible to
            # SystemdUnitFailed alerting.
            extraFlags = [
              "--collector.textfile.directory=${textfileDir}"
              (
                "--collector.systemd.unit-include=^("
                # Core infra:
                #   sshd       — remote access; if it dies we're cooked.
                #   caddy      — TLS edge / reverse proxy for everything.
                #   postgresql — shared DB for most apps.
                #   mysql      — shared MariaDB (grimmory, etc.).
                #   redis*     — unnamed instance + named per-app servers
                #                (paperless, …) get redis-<name>.service.
                #   restic-backups-server — nightly off-site backup.
                + "sshd|caddy|postgresql|mysql|redis(-.+)?|restic-backups-server"
                # Authentik (SSO) — server + worker + migrate one-shot.
                + "|authentik(-worker|-migrate)?"
                # Observability stack itself — useful to know if our
                # own scrapers fall over.
                + "|victoriametrics|victorialogs|vmalert(-.+)?"
                + "|alertmanager|grafana|vector|cadvisor|gatus"
                + "|prometheus-(node|postgres|mysqld|redis|snmp|nvidia-gpu)-exporter"
                # NUT client + per-master exporters (issue #82).
                + "|upsmon|nut-exporter-(router|nas)"
                # Native NixOS app services (modules/apps/*.nix using
                # services.<app>): audiobookshelf, bazarr, flaresolverr,
                # jellyfin, kavita, komga, matter-server, mealie, miniflux,
                # paperless (multi-unit: web/scheduler/task-queue/consumer),
                # pinchflat, prowlarr, radarr, readeck, sabnzbd, sonarr,
                # spierscraper.
                + "|audiobookshelf|bazarr|flaresolverr|jellyfin|kavita|komga"
                + "|matter-server|mealie|miniflux|paperless(-.+)?|pinchflat"
                + "|prowlarr|radarr|readeck|sabnzbd(-.+)?|sonarr|spierscraper"
                # Container-based apps (modules/apps/*.nix using
                # virtualisation.oci-containers): each registers a
                # podman-<name>.service unit. Includes unifi-os-server —
                # it runs as an OCI container (podman-unifi-os-server),
                # not a native service. bookorbit is dev-only, so the
                # token simply never matches on prod hosts.
                + "|podman-(actualbudget|bookorbit|decluttarr|grimmory"
                + "|homeassistant|kapowarr|manyfold|mylar3|profilarr"
                + "|readmeabook|seerr|shelfarr|tandoor|unifi-os-server"
                + "|valheim))\\.service$"
              )
            ];
          };
          postgres = {
            enable = true;
            # Connect over the Unix socket as the postgres superuser via
            # peer auth — no password to manage, and no extra role to
            # provision in modules/system/postgresql.nix.
            runAsLocalSuperUser = true;
          };
          mysqld = {
            enable = true;
            # Connect over the Unix socket as the `mysqld-exporter` OS
            # user; MariaDB matches that to the `'mysqld-exporter'@'localhost'`
            # role provisioned via ensureUsers above (unix_socket plugin),
            # so no password to manage. The role gets PROCESS / REPLICATION
            # CLIENT / SELECT — the minimum mysqld_exporter needs.
            configFile = pkgs.writeText "mysqld-exporter.cnf" ''
              [client]
              socket = /run/mysqld/mysqld.sock
              user = mysqld-exporter
            '';
          };
          redis = {
            enable = true;
          };
        };

        # ========== VictoriaMetrics ==========
        victoriametrics = {
          enable = true;
          # Loopback-only — Caddy proxies the UI (vmui) for human
          # access; scraping is local; no need to expose on the LAN.
          listenAddress = "127.0.0.1:${toString vmPort}";
          retentionPeriod = "15d";
          prometheusConfig = {
            # 30s scrape gives Grafana enough samples for `rate()` over
            # short windows. With the default 1m, `rate(...[$__rate_interval])`
            # routinely sees only one sample and returns empty. Match this
            # against the Prometheus datasource's `jsonData.timeInterval`
            # in ./grafana.nix so Grafana picks a compatible
            # $__rate_interval floor.
            global.scrape_interval = "30s";
            scrape_configs = [
              {
                job_name = "victoriametrics";
                static_configs = [ { targets = [ "127.0.0.1:${toString vmPort}" ]; } ];
              }
              {
                job_name = "vmalert";
                static_configs = [ { targets = [ "127.0.0.1:${toString vmalertPort}" ]; } ];
              }
              {
                job_name = "node";
                static_configs = [
                  { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
                ];
              }
              {
                job_name = "postgres";
                static_configs = [
                  { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.postgres.port}" ]; }
                ];
              }
              {
                job_name = "mysqld";
                static_configs = [
                  { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.mysqld.port}" ]; }
                ];
              }
              # Multi-target scrape: one redis_exporter, many redis
              # instances. Each app's `services.redis.servers.<name>`
              # is picked up automatically so long as it exposes a TCP
              # port (loopback is fine). Unix-socket-only instances
              # aren't reachable from the exporter's user — apps that
              # want metrics must open a loopback port (see
              # modules/apps/paperless-ngx.nix for the pattern).
              #
              # `redis_instance` label preserves the friendly attr name
              # ("default" for the unnamed authentik instance); the
              # `instance` label ends up as the redis URL so per-target
              # alerts (RedisDown) differentiate cleanly.
              {
                job_name = "redis";
                metrics_path = "/scrape";
                static_configs = lib.mapAttrsToList (name: srv: {
                  targets = [ "redis://127.0.0.1:${toString srv.port}" ];
                  labels.redis_instance = if name == "" then "default" else name;
                }) (lib.filterAttrs (_: srv: srv.enable && srv.port != 0) config.services.redis.servers);
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "__param_target";
                  }
                  {
                    source_labels = [ "__param_target" ];
                    target_label = "instance";
                  }
                  {
                    target_label = "__address__";
                    replacement = "127.0.0.1:${toString config.services.prometheus.exporters.redis.port}";
                  }
                ];
              }
              {
                job_name = "caddy";
                static_configs = [ { targets = [ "127.0.0.1:${toString caddyMetricsPort}" ]; } ];
              }
              {
                job_name = "cadvisor";
                static_configs = [ { targets = [ "127.0.0.1:${toString cadvisorPort}" ]; } ];
              }
              {
                job_name = "gatus";
                static_configs = [ { targets = [ "127.0.0.1:${toString gatusPort}" ]; } ];
              }
              # ========== External device SNMP ==========
              # Multi-target scrape: one snmp_exporter, many devices.
              # Targets list device IPs/hostnames in `static_configs`,
              # then relabel_configs rewrite __address__ to the local
              # exporter and stash the original into __param_target.
              # The `modules` query string (repeatable) selects which
              # generator profiles to walk; `auth` picks the auth name
              # from snmp.yml (we kept the shipped `public_v2` slot
              # with its community sed-substituted at build time).
              #
              # pfSense bsnmpd only exposes standard mibII (no UCD-SNMP),
              # so we limit it to if_mib + system. Synology gets the
              # dedicated synology module plus if_mib + system.
              {
                job_name = "snmp_pfsense";
                metrics_path = "/snmp";
                params = {
                  module = [
                    "if_mib"
                    "system"
                  ];
                  auth = [ "public_v2" ];
                };
                static_configs = [ { targets = [ "192.168.10.1" ]; } ];
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "__param_target";
                  }
                  {
                    source_labels = [ "__param_target" ];
                    target_label = "instance";
                  }
                  {
                    target_label = "__address__";
                    replacement = "127.0.0.1:${toString config.services.prometheus.exporters.snmp.port}";
                  }
                ];
              }
              {
                job_name = "snmp_synology";
                metrics_path = "/snmp";
                params = {
                  module = [
                    "synology"
                    "if_mib"
                    "system"
                    "ucd_la_table"
                    "ucd_memory"
                    "ucd_system_stats"
                  ];
                  auth = [ "public_v2" ];
                };
                static_configs = [ { targets = [ "laconia.ipreston.net" ]; } ];
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "__param_target";
                  }
                  {
                    source_labels = [ "__param_target" ];
                    target_label = "instance";
                  }
                  {
                    target_label = "__address__";
                    replacement = "127.0.0.1:${toString config.services.prometheus.exporters.snmp.port}";
                  }
                ];
              }
            ];
          };
        };

        # ========== vmalert ==========
        # Evaluates the rule YAML against VictoriaMetrics and emits to
        # the local Alertmanager. Single instance — the `main` name is
        # cosmetic; the systemd unit ends up `vmalert-main.service`.
        # Rule format is identical to Prometheus's; MetricsQL is a
        # strict PromQL superset so every existing expression carries
        # over verbatim.
        vmalert.instances.main = {
          enable = true;
          rules = ruleGroups;
          settings = {
            "datasource.url" = "http://127.0.0.1:${toString vmPort}";
            "notifier.url" = [ "http://127.0.0.1:${toString alertmanagerPort}" ];
            "httpListenAddr" = "127.0.0.1:${toString vmalertPort}";
            # Match VM's scrape cadence so `rate()` and `for:` windows
            # behave the same as they did under Prometheus's evaluator.
            "evaluationInterval" = "30s";
            # Persist alert state back into VictoriaMetrics. Without this
            # there's no record of what fired once an alert resolves —
            # #239's false positive left nothing to query after the fact.
            # remoteWrite emits the `ALERTS` / `ALERTS_FOR_STATE` series
            # (queryable in vmui for post-hoc correlation); remoteRead
            # restores pending-alert state across vmalert restarts so a
            # bounce doesn't reset every `for:` window.
            "remoteWrite.url" = "http://127.0.0.1:${toString vmPort}";
            "remoteRead.url" = "http://127.0.0.1:${toString vmPort}";
          };
        };

        # ========== cAdvisor (container metrics) ==========
        # node_exporter has no per-container view, so cgroups-level
        # metrics for podman containers come from cAdvisor. Listens on
        # loopback only — Caddy doesn't proxy this, scraping is local.
        cadvisor = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = cadvisorPort;
        };
      };

      # ========== Forward-auth UIs ==========
      # Both VM (vmui) and vmalert have built-in web UIs but no auth.
      # Front them with the embedded authentik outpost — same
      # `authentik_forward_auth` snippet that previously gated the
      # prometheus UI.
      myAuthentik.forwardAuthApps = {
        victoriametrics = {
          host = vmHost;
          port = vmPort;
          displayName = "VictoriaMetrics";
          homepage = {
            group = "Infrastructure";
            icon = "prometheus";
            description = "metrics";
          };
        };
        vmalert = {
          host = vmalertHost;
          port = vmalertPort;
          displayName = "vmalert";
          homepage = {
            group = "Infrastructure";
            icon = "prometheus";
            description = "alert rules";
          };
        };
      };
    };
}
