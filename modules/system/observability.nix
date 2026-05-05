# Observability — metrics, logs, dashboards, alerting.
#
# Stack:
#   Prometheus     — scrapes node/postgres/redis/caddy/itself; ephemeral
#                    on-disk TSDB with 15d retention.
#   Loki           — single-node, filesystem store; ~7d retention.
#   Promtail       — ships the systemd journal into Loki.
#   Grafana        — dashboards + provisioned datasources, OIDC against
#                    Authentik using existing grafana/* sops secrets.
#   Alertmanager   — Discord receiver (via Discord's Slack-compatible
#                    `/slack` endpoint) + a Watchdog → healthchecks.io
#                    heartbeat receiver. Config rendered through
#                    envsubst so webhook URLs never hit /nix/store.
#
# Auth model. Per #65 comment, every UI exposed by this stack is gated
# on Authentik group `Infrastructure`. Grafana speaks OIDC natively; the
# Authentik blueprint pins the launcher tile to the Infrastructure group
# and Grafana itself accepts anyone who completes OIDC, then maps roles
# from the `groups` claim. Prometheus and Alertmanager don't do auth, so
# they sit behind the `authentik_forward_auth` Caddy snippet (embedded
# outpost, three proxy providers in `forward_single` mode).
#
# Data is intentionally ephemeral per the issue thread — no
# postgresqlBackup-style hook for prometheus/loki state. If the host
# dies, dashboards and alerting recreate themselves declaratively from
# this module on the new box; only the historical timeseries is lost.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.observability =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      grafanaHost = "grafana.${hostSpec.serverDomain}";
      prometheusHost = "prometheus.${hostSpec.serverDomain}";
      alertmanagerHost = "alertmanager.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";

      grafanaPort = 3000;
      prometheusPort = 9090;
      alertmanagerPort = 9093;
      lokiPort = 3100;
      promtailPort = 9080;
      caddyMetricsPort = 2019;
      cadvisorPort = 8081;

      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];

      dashboardsDir = pkgs.runCommandLocal "grafana-dashboards" { } ''
        mkdir -p $out
        cp -r ${./_grafana-dashboards}/. $out/
      '';
    in
    {
      sops.secrets = {
        "grafana/client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          owner = "grafana";
          restartUnits = restartAuthentik ++ [ "grafana.service" ];
        };
        "grafana/client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          owner = "grafana";
          restartUnits = restartAuthentik ++ [ "grafana.service" ];
        };
        "grafana/bootstrap_password" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          owner = "grafana";
          restartUnits = [ "grafana.service" ];
        };
        "discord/alerts_webhook" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = [ "alertmanager.service" ];
        };
        "alertmanager/heartbeat_url" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = [ "alertmanager.service" ];
        };
      };

      sops.templates = {
        # Same secret values, exposed under GRAFANA_OIDC_* names so the
        # authentik worker can substitute them into the blueprint at
        # apply time. Mirrors the pattern in modules/apps/mealie.nix.
        "grafana-authentik.env" = {
          content = ''
            GRAFANA_OIDC_CLIENT_ID=${config.sops.placeholder."grafana/client_id"}
            GRAFANA_OIDC_CLIENT_SECRET=${config.sops.placeholder."grafana/client_secret"}
          '';
          restartUnits = restartAuthentik;
        };

        # Alertmanager reads this via EnvironmentFile and the NixOS
        # module envsubst's $VAR references in configText at start-up.
        "alertmanager.env" = {
          content = ''
            DISCORD_WEBHOOK=${config.sops.placeholder."discord/alerts_webhook"}
            ALERTMANAGER_HEARTBEAT_URL=${config.sops.placeholder."alertmanager/heartbeat_url"}
          '';
          restartUnits = [ "alertmanager.service" ];
        };
      };

      myAuthentik.extraBlueprints = [ ./observability-blueprints ];

      systemd.services = {
        # Stack the grafana-authentik env file onto authentik's existing
        # EnvironmentFile so the worker has GRAFANA_OIDC_* in scope when
        # applying our blueprint. NixOS merges listOf path definitions.
        authentik.serviceConfig.EnvironmentFile = [
          config.sops.templates."grafana-authentik.env".path
        ];
        authentik-worker.serviceConfig.EnvironmentFile = [
          config.sops.templates."grafana-authentik.env".path
        ];
        authentik-migrate.serviceConfig.EnvironmentFile = [
          config.sops.templates."grafana-authentik.env".path
        ];
      };

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
          # below so Grafana picks a compatible $__rate_interval floor.
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
          ];

          alertmanagers = [
            { static_configs = [ { targets = [ "127.0.0.1:${toString alertmanagerPort}" ]; } ]; }
          ];

          # Watchdog always fires, so an empty alertmanager == broken
          # pipeline. Routed to a healthchecks.io ping receiver below; if
          # the heartbeat stops, healthchecks.io pages out-of-band.
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

          # ========== Alertmanager ==========
          alertmanager = {
            enable = true;
            port = alertmanagerPort;
            environmentFile = config.sops.templates."alertmanager.env".path;
            # amtool runs at build time and can't see envsubst values, so
            # the unresolved $DISCORD_WEBHOOK / $ALERTMANAGER_HEARTBEAT_URL
            # placeholders look like malformed URLs to it. Skip the
            # sandboxed check; the runtime envsubst step still surfaces
            # config errors when the unit starts.
            checkConfig = false;
            configText = ''
              route:
                receiver: discord
                group_by: [alertname]
                group_wait: 30s
                group_interval: 5m
                repeat_interval: 4h
                routes:
                  - matchers:
                      - alertname="Watchdog"
                    receiver: heartbeat
                    group_wait: 0s
                    group_interval: 1m
                    repeat_interval: 1m

              receivers:
                - name: discord
                  # Native discord_configs (Alertmanager ≥ 0.26) — the
                  # Slack-compat path Discord exposes rejects the
                  # `attachments` field that slack_configs ships by
                  # default with HTTP 400.
                  discord_configs:
                    - webhook_url: "''${DISCORD_WEBHOOK}"
                      send_resolved: true
                      title: "{{ .Status | toUpper }} — {{ .CommonLabels.alertname }}"
                      message: |
                        {{ range .Alerts }}**{{ .Annotations.summary }}**
                        {{ .Annotations.description }}
                        {{ end }}
                - name: heartbeat
                  webhook_configs:
                    - url: "''${ALERTMANAGER_HEARTBEAT_URL}"
                      send_resolved: false
            '';
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

        # ========== Loki ==========
        loki = {
          enable = true;
          configuration = {
            auth_enabled = false;
            server = {
              http_listen_address = "127.0.0.1";
              http_listen_port = lokiPort;
              grpc_listen_address = "127.0.0.1";
            };
            common = {
              path_prefix = "/var/lib/loki";
              replication_factor = 1;
              ring.kvstore.store = "inmemory";
              # In monolithic mode every component talks to every other
              # over gRPC. Without instance_addr Loki picks up the LAN
              # IP (192.168.x.x) for self-registration, which doesn't
              # match the loopback-only listener — queries hit a
              # `dial: connection refused` and silently time out while
              # ingestion still works. Pin to loopback so all
              # components agree on where the frontend lives.
              instance_addr = "127.0.0.1";
            };
            schema_config.configs = [
              {
                from = "2024-01-01";
                store = "tsdb";
                object_store = "filesystem";
                schema = "v13";
                index = {
                  prefix = "index_";
                  period = "24h";
                };
              }
            ];
            storage_config = {
              tsdb_shipper = {
                active_index_directory = "/var/lib/loki/tsdb-index";
                cache_location = "/var/lib/loki/tsdb-cache";
              };
              filesystem.directory = "/var/lib/loki/chunks";
            };
            compactor = {
              working_directory = "/var/lib/loki/compactor";
              retention_enabled = true;
              delete_request_store = "filesystem";
            };
            limits_config = {
              retention_period = "168h"; # 7d
              allow_structured_metadata = true;
              reject_old_samples = true;
              reject_old_samples_max_age = "168h";
            };
            analytics.reporting_enabled = false;
          };
        };

        # ========== Promtail (journal -> Loki) ==========
        promtail = {
          enable = true;
          configuration = {
            server = {
              http_listen_address = "127.0.0.1";
              http_listen_port = promtailPort;
              grpc_listen_address = "127.0.0.1";
              # Loki claims the default 9095; promtail doesn't actually
              # need its gRPC listener exposed, so park it somewhere else.
              grpc_listen_port = 9096;
            };
            clients = [ { url = "http://127.0.0.1:${toString lokiPort}/loki/api/v1/push"; } ];
            scrape_configs = [
              {
                job_name = "journal";
                journal = {
                  max_age = "12h";
                  labels = {
                    job = "systemd-journal";
                    host = config.networking.hostName;
                  };
                };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "unit";
                  }
                  {
                    source_labels = [ "__journal_priority_keyword" ];
                    target_label = "level";
                  }
                ];
              }
            ];
          };
        };

        # ========== Grafana ==========
        grafana = {
          enable = true;
          settings = {
            server = {
              http_addr = "127.0.0.1";
              http_port = grafanaPort;
              domain = grafanaHost;
              root_url = "https://${grafanaHost}/";
            };
            analytics.reporting_enabled = false;
            security = {
              # `$__file{}` reads the secret out of the sops-decrypted
              # path at runtime, so the password never lands in the
              # rendered grafana.ini in /nix/store.
              admin_password = "$__file{${config.sops.secrets."grafana/bootstrap_password".path}}";
            };
            # OIDC against Authentik. `role_attribute_path` is JMESPath
            # over the id_token claims — `Infrastructure` group → Admin,
            # everyone else who somehow makes it past the Authentik app
            # binding → Viewer.
            "auth.generic_oauth" = {
              enabled = true;
              name = "Authentik";
              client_id = "$__file{${config.sops.secrets."grafana/client_id".path}}";
              client_secret = "$__file{${config.sops.secrets."grafana/client_secret".path}}";
              scopes = "openid email profile";
              auth_url = "https://${authentikHost}/application/o/authorize/";
              token_url = "https://${authentikHost}/application/o/token/";
              api_url = "https://${authentikHost}/application/o/userinfo/";
              login_attribute_path = "preferred_username";
              email_attribute_path = "email";
              name_attribute_path = "name";
              groups_attribute_path = "groups";
              role_attribute_path = "contains(groups[*], 'Infrastructure') && 'Admin' || 'Viewer'";
              allow_assign_grafana_admin = false;
              auto_login = false;
              # We restrict access at the Authentik app/policy binding,
              # not here, so users coming through OIDC are already
              # vetted; allow auto-signup so first login provisions the
              # local Grafana account.
              allow_sign_up = true;
              use_pkce = true;
            };
            users = {
              auto_assign_org = true;
              auto_assign_org_role = "Viewer";
            };
          };

          provision = {
            enable = true;
            # UIDs are pinned (rather than letting Grafana
            # auto-generate) so provisioned dashboards can reference
            # them by literal `"uid": "prometheus"` instead of
            # `${DS_PROMETHEUS}` placeholders that need import-time
            # resolution.
            datasources.settings.datasources = [
              {
                name = "Prometheus";
                uid = "prometheus";
                type = "prometheus";
                access = "proxy";
                url = "http://127.0.0.1:${toString prometheusPort}";
                isDefault = true;
                # Tell Grafana the scrape interval so $__rate_interval
                # stays >= 4 * 30s = 2m (always wide enough for rate()).
                jsonData.timeInterval = "30s";
              }
              {
                name = "Loki";
                uid = "loki";
                type = "loki";
                access = "proxy";
                url = "http://127.0.0.1:${toString lokiPort}";
              }
              {
                name = "Alertmanager";
                uid = "alertmanager";
                type = "alertmanager";
                access = "proxy";
                url = "http://127.0.0.1:${toString alertmanagerPort}";
                jsonData.implementation = "prometheus";
              }
            ];
            dashboards.settings.providers = [
              {
                name = "homelab";
                type = "file";
                folder = "Homelab";
                updateIntervalSeconds = 30;
                allowUiUpdates = false;
                options.path = "${dashboardsDir}";
                options.foldersFromFilesStructure = true;
              }
            ];
          };
        };

      };

      # ========== Caddy routes ==========
      # Grafana speaks OIDC natively, so no forward_auth here. The
      # Authentik app binding still pins the launcher tile to the
      # Infrastructure group; this route is the destination of the OIDC
      # redirect.
      #
      # Prometheus and Alertmanager have no auth of their own; the
      # `authentik_forward_auth` snippet (defined in
      # modules/apps/authentik.nix) gates every request through the
      # embedded outpost.
      myCaddy.apps = {
        grafana = {
          host = grafanaHost;
          routeConfig = ''
            reverse_proxy localhost:${toString grafanaPort}
          '';
        };
        prometheus = {
          host = prometheusHost;
          routeConfig = ''
            import authentik_forward_auth
            reverse_proxy localhost:${toString prometheusPort}
          '';
        };
        alertmanager = {
          host = alertmanagerHost;
          routeConfig = ''
            import authentik_forward_auth
            reverse_proxy localhost:${toString alertmanagerPort}
          '';
        };
      };

      # Promtail needs to read the journal — the upstream NixOS module
      # already runs it as `promtail`, but doesn't add the user to the
      # `systemd-journal` group, so without this it can only see its own
      # unit's messages.
      users.users.promtail.extraGroups = [ "systemd-journal" ];
    };
}
