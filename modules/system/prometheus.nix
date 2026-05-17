# Prometheus — metrics collection, exporters, scrape config, alerting
# rules, and cAdvisor (container metrics).
#
# Scrapes node/postgres/mysqld/redis/caddy/cadvisor/itself; ephemeral
# on-disk TSDB with 15d retention. Alerts are emitted to the local
# alertmanager (see ./alertmanager.nix) — Watchdog always fires as a
# heartbeat so an empty pipeline is detectable.
#
# Data is intentionally ephemeral per issue #65 thread — no
# postgresqlBackup-style hook for prometheus state. If the host dies,
# rules/exporters recreate themselves declaratively from this module
# on the new box; only the historical timeseries is lost.
_: {
  flake.modules.nixos.prometheus =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      prometheusHost = "prometheus.${hostSpec.serverDomain}";

      prometheusPort = 9090;
      alertmanagerPort = 9093;
      caddyMetricsPort = 2019;
      cadvisorPort = 8081;
      gatusPort = 8084;
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

        # ========== Prometheus ==========
        prometheus = {
          enable = true;
          port = prometheusPort;
          retentionTime = "15d";
          # 30s scrape gives Grafana enough samples for `rate()` over
          # short windows. With the default 1m, `rate(...[$__rate_interval])`
          # routinely sees only one sample and returns empty. Match this
          # against the Prometheus datasource's `jsonData.timeInterval`
          # in ./grafana.nix so Grafana picks a compatible
          # $__rate_interval floor.
          globalConfig.scrape_interval = "30s";

          exporters = {
            node = {
              enable = true;
              enabledCollectors = [
                "systemd"
                "processes"
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
              # role provisioned via ensureUsers below (unix_socket plugin),
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

          scrapeConfigs = [
            {
              job_name = "prometheus";
              static_configs = [ { targets = [ "127.0.0.1:${toString prometheusPort}" ]; } ];
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
            {
              job_name = "redis";
              static_configs = [
                { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.redis.port}" ]; }
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

          alertmanagers = [
            { static_configs = [ { targets = [ "127.0.0.1:${toString alertmanagerPort}" ]; } ]; }
          ];

          # Watchdog always fires, so an empty alertmanager == broken
          # pipeline. Routed to a healthchecks.io ping receiver in
          # ./alertmanager.nix; if the heartbeat stops, healthchecks.io
          # pages out-of-band.
          ruleFiles = [
            (pkgs.writeText "watchdog.rules.yml" (
              builtins.toJSON {
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
                ];
              }
            ))
            # Real alerts. Severity labels are set so alertmanager can
            # route by severity later (everything currently lands in
            # the Discord receiver via the default route).
            (pkgs.writeText "homelab.rules.yml" (
              builtins.toJSON {
                groups = [
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
                          description = "Prometheus has not been able to scrape {{ $labels.job }} at {{ $labels.instance }} for 5 minutes.";
                        };
                      }
                      {
                        alert = "FilesystemAlmostFull";
                        # Skip pseudo-filesystems; a real ext4/btrfs/zfs/xfs
                        # mount under 20% free is the actionable signal.
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
                        # A unit that exited and isn't being kept alive
                        # by Restart=. Restart-loops never sit in `failed`
                        # long enough to trip this, but they do trip
                        # InstanceDown for the units we scrape.
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
                        # vmstat collector is on by default in node_exporter.
                        # Any non-zero rate means the kernel killed something.
                        expr = "rate(node_vmstat_oom_kill[5m]) > 0";
                        labels.severity = "warning";
                        annotations = {
                          summary = "OOM kill on {{ $labels.instance }}";
                          description = "Kernel OOM killer activated on {{ $labels.instance }} in the last 5m. Check what got killed via journalctl -k.";
                        };
                      }
                      {
                        alert = "PostgresDown";
                        # Faster + clearer message than InstanceDown for
                        # this; postgres going dark breaks every app.
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
                        # Same shape as PostgresDown — all mariadb-backed
                        # apps (grimmory, …) are broken when this fires.
                        expr = "mysql_up == 0";
                        for = "2m";
                        labels.severity = "critical";
                        annotations = {
                          summary = "MariaDB is down on {{ $labels.instance }}";
                          description = "mysqld_exporter reports mysql_up=0 for 2m. All apps using shared mariadb are broken.";
                        };
                      }
                      {
                        alert = "ContainerRestartLoop";
                        # changes() counts how many times start_time_seconds
                        # changed in the window — i.e. how many restarts.
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
                        # Gauge of the most recent probe result per
                        # endpoint. Probe interval is 60s for app/auth
                        # endpoints (5m for external), so `for: 3m`
                        # ignores a single transient failure and pages
                        # on the second consecutive miss.
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
                        # 0.1 req/s = ~6/min sustained. Anything below
                        # this is normal occasional flakiness.
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
                ];
              }
            ))
          ];
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

      # Forward-auth via the embedded authentik outpost — prometheus
      # has no built-in auth so it sits behind the
      # `authentik_forward_auth` Caddy snippet (see
      # modules/platform/authentik.nix for the aggregator that owns
      # the outpost's providers list).
      myAuthentik.forwardAuthApps.prometheus = {
        host = prometheusHost;
        port = prometheusPort;
        displayName = "Prometheus";
        homepage = {
          group = "Infrastructure";
          icon = "prometheus";
          description = "metrics";
        };
      };
    };
}
