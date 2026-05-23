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
            ];
          }
        ];
      };
    in
    {
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
                + "|prometheus-(node|postgres|mysqld|redis)-exporter"
                # Native NixOS app services (modules/apps/*.nix using
                # services.<app>): audiobookshelf, bazarr, jellyfin,
                # kavita, komga, mealie, miniflux, paperless (multi-unit:
                # web/scheduler/task-queue/consumer), prowlarr, radarr,
                # readeck, sabnzbd, sonarr, spierscraper, unifi-os-server.
                + "|audiobookshelf|bazarr|jellyfin|kavita|komga|mealie|miniflux"
                + "|paperless(-.+)?|prowlarr|radarr|readeck|sabnzbd|sonarr"
                + "|spierscraper|unifi-os-server"
                # Container-based apps (modules/apps/*.nix using
                # virtualisation.oci-containers): each registers a
                # podman-<name>.service unit.
                + "|podman-(actualbudget|grimmory|homeassistant|kapowarr"
                + "|maintainerr|mylar3|profilarr|readmeabook|seerr|shelfarr"
                + "|tandoor|valheim|watchstate))\\.service$"
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
