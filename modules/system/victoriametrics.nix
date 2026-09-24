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
#                     vector/itself; 45d retention (see `retentionPeriod`
#                     below, raised from 15d for #458), ephemeral on-disk.
#                     The vector job exists so a silent pfSense syslog
#                     feed is alertable — see PfsenseLogsAbsent.
#   vmalert         — evaluates the rule YAML and emits to alertmanager.
#                     MetricsQL is a strict PromQL superset, so the
#                     existing rule expressions move over unchanged.
#   cAdvisor        — per-container cgroups metrics (podman containers).
#   Prometheus exporters — node/postgres/mysqld/redis, all unchanged.
#
# Data is ephemeral by design (#65 / #126) *for host-failure DR* —
# there is no restic hook. If the host dies, rules, exporters,
# dashboards recreate themselves declaratively; only the historical
# timeseries is lost. Routine reboots are a different case: the
# storage dir is preserved across the impermanence rollback (see
# modules/system/preservation-server.nix) so `retentionPeriod` below
# means what it says. Closes #578.
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
      # The retired controller only displaced this default on amos1. Keep the
      # dev host's existing loopback endpoint unchanged (#714).
      vmalertPort = if hostSpec.serverEnvironment == "prod" then 8880 else 8881;
      alertmanagerPort = 9093;
      caddyMetricsPort = 2019;
      cadvisorPort = 8081;
      # Vector's prometheus_exporter sink; declared in vector.nix, repeated
      # here the same way the other loopback exporter ports are.
      vectorMetricsPort = 9598;
      gatusPort = 8084;

      # CPU package temperature, vendor-agnostic: Intel exposes
      # "Package id 0", AMD exposes "Tdie"/"Tctl". Bound here because
      # the CPU rules below use it three times and it is long enough
      # that inlining it hides what each rule actually differs in.
      cpuPackageTemp = ''max by (instance) (node_hwmon_temp_celsius * on (chip, sensor) group_left(label) node_hwmon_sensor_label{label=~"Package id.*|Tdie|Tctl"})'';
      # Whole-system CPU busy fraction (0-1), used to restrict the
      # cooling-baseline rule to low-load samples.
      cpuBusyFraction = ''1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))'';

      # CPU fan RPM (#637). amos1 is the only host in the fleet with a
      # readable Super I/O — an ITE IT8665E behind the out-of-tree
      # it87 fork pinned in modules/hosts/amos1.nix, which is also
      # where the "why not nct6775 / asus-ec-sensors" reasoning lives
      # — so this series exists there and nowhere else, and the two
      # rules below silently no-op on every other host.
      #
      # fan1 is the CPU_FAN header. It is the only populated one of
      # the chip's five channels (fan2/3/4/6 read a flat 0 — the rack
      # case's own fans are not on board headers) and the only one
      # that tracks CPU load: 1331 rpm at 42°C idle, ~1650 at the
      # 70-76°C the host sits at under its normal Jellyfin/Valheim
      # background, and 2109 after 45s of all-core load with Tctl
      # pinned at 90°C. That last number answers the open question in
      # #637 — the BIOS curve does reach the ARCTIC Alpine 23 CO
      # fan's rated 2000 rpm ceiling, so there is no headroom left to
      # reclaim from a BIOS setting.
      #
      # `pwm1` is deliberately unused: it read a constant 51 across
      # that entire ramp, so the chip's PWM registers do not reflect
      # the duty the firmware's fan curve is actually applying. The
      # "same duty, falling RPM" bearing-wear rule #637 sketches
      # cannot be built on it, and building it off a temperature band
      # instead needs a baseline this host has no history for yet.
      cpuFanRpm = ''max by (instance) (node_hwmon_fan_rpm{chip=~"platform_it87.*",sensor="fan1"})'';

      metricRuleGroups = lib.concatMap (contribution: contribution.groups) (
        lib.attrValues config.myObservability.metricRuleGroups
      );

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
                # `job="nut"` is excluded because the power group below
                # owns that job's up-ness with far better runbooks, and
                # firing both gave two pages for one fault (#643). The
                # `instance` label there is a loopback exporter port,
                # which told a human nothing anyway.
                alert = "InstanceDown";
                expr = ''up{job!="nut"} == 0'';
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
                # pfSense's remote syslog feed going silent is a failure
                # that is invisible in the log data itself — an empty feed
                # looks exactly like a quiet network, so nothing short of
                # an absence rule can see it.
                #
                # It used to also be non-self-healing: a datagram arriving
                # while vector was down hit a closed port (the firewall
                # rule accepts it), the kernel answered ICMP
                # port-unreachable, and FreeBSD syslogd treated that
                # ECONNREFUSED as fatal and detached the target for good.
                # vector.nix now drops outbound port-unreachable toward
                # the router, so a vector bounce loses only the datagrams
                # sent during it and the feed resumes on its own. This
                # rule stays because the feed can still go quiet for
                # reasons that fix does not cover — the router's syslog
                # config being changed or disabled, syslogd dying on the
                # box, or the mgmt path between the two breaking.
                #
                # The `and on() sum(up{job="vector"}) == 1` guard keeps
                # this distinct from vector simply being down, which
                # InstanceDown and SystemdUnitFailed already cover — this
                # rule is specifically "vector is healthy but the router
                # stopped talking to it", which is the case nothing else
                # can see.
                #
                # The `absent(...)` branch is load-bearing and was
                # missing: vector only publishes a component's
                # `received_events_total` after that component has
                # handled its first event, so a vector restart while the
                # router is detached leaves the series *absent*, not
                # zero — and `rate(...) == 0` over a series that does not
                # exist matches nothing and never fires. That is exactly
                # the shape this rule is meant to catch, and exactly how
                # it was missed: on 2026-08-31 an auto-upgrade bounced
                # vector on both servers, syslogd detached both targets
                # with `sendto: Connection refused`, and the feed stayed
                # dead with no alert until someone looked. `absent()`
                # covers the restarted-and-never-fed case; the rate
                # branch still covers the went-quiet-while-running one.
                #
                # `on()` rather than `on(instance)`: the `absent()`
                # branch synthesises a series carrying only the matcher's
                # own labels, with no `instance` to join on. Each host
                # scrapes exactly one vector (127.0.0.1:9598, see the
                # scrape config below), so the instance join was never
                # doing anything anyway.
                #
                # 15m window with a 10m confirmation. Measured over a 30m
                # sample of the live feed, the largest gap between
                # consecutive events was 40s (a 6.7m gap in the same
                # sample was an induced outage, not normal quiet), so this
                # carries better than a 20x margin over observed silence.
                #
                # Keyed on the `pfsense_filterlog` *transform*, not the
                # `pfsense` source. pfSense forwards under three separate
                # `syslog.conf` entries, and syslogd's fatal
                # ECONNREFUSED detach is per entry — so on 2026-09-08 the
                # `!filterlog` entries died on both hosts while the
                # `!dhcpd` ones lived, and a WAN lease renewal every ~2h
                # kept the source counter non-zero and this rule quiet
                # while the feed the ingest exists for was dead (#581).
                # The transform receives only filterlog events (see the
                # `pfsense_route` split in vector.nix), so its counter is
                # the specific thing worth watching. It strictly dominates
                # the old source-wide expression — the whole source dying
                # kills filterlog too — hence a retarget rather than a
                # second alert.
                alert = "PfsenseLogsAbsent";
                expr = ''(absent(vector_component_received_events_total{component_id="pfsense_filterlog",component_kind="transform"}) or sum(rate(vector_component_received_events_total{component_id="pfsense_filterlog",component_kind="transform"}[15m])) == 0) and on() sum(up{job="vector"}) == 1'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "No pfSense firewall logs received on this host";
                  description = "vector is up but has received no pfSense filterlog events for 15m. This should now self-heal across vector restarts and reboots, so suspect the router side: check `grep syslogd /var/log/system.log` on behemoth and confirm the target is still listed under Status → System Logs → Settings. Note the detach is per `syslog.conf` entry, so other pfSense events may still be arriving while the `!filterlog` entry is dead — do not take a non-empty pfsense stream in VictoriaLogs as proof the feed is healthy. Restore with `pfSsh.php playback svc restart syslogd` — a SIGHUP kills syslogd rather than reloading it.";
                };
              }
              {
                # Log-rate runaway — "something on this host is flooding
                # the journal", deliberately not scoped to a unit (#590).
                #
                # The gap this fills: on 2026-09-08 the Valheim container
                # wedged into a 68/s logging loop after a single transient
                # HTTP failure (see the GetPublicIP block in
                # modules/apps/valheim.nix) and wrote 1.04 GB of journal —
                # ~96% of hpp-1's 24h volume — in under four hours. Not one
                # existing rule fired, and each was correct to stay silent:
                # the unit never failed (SystemdUnitFailed), systemd never
                # restarted it (ServiceRestartLoop, NRestarts=0), the game
                # server was up and serving throughout (ValheimServerDown),
                # its exporter kept publishing (ValheimMetricsStale), and
                # journald's rotation absorbed the gigabyte without going
                # near a disk threshold (FilesystemAlmostFull). journald's
                # own rate limiter did not engage either — the NixOS default
                # (RateLimitInterval=30s, RateLimitBurst=10000) permits
                # 333 msg/s per service, and the loop sat well under it.
                #
                # A healthy service logging itself into the ground is a
                # whole class of failure with no signal of its own, so this
                # names no unit: it fires on the aggregate and the operator
                # finds the culprit. A per-unit rule would only ever have
                # caught the one instance already seen.
                #
                # No new exporter — vector's `internal_metrics` source
                # (modules/system/vector.nix) already counts every event its
                # journald source reads, and the `vector` scrape job below
                # already collects it.
                #
                # Threshold from 7 days of per-minute journal buckets on
                # both servers, measured as the rolling 5m rate this
                # expression evaluates:
                #
                #   host   p50    p90    p99    max (normal)   incident
                #   hpp-1  5.2/s  6.1/s  12.1/s  136.7/s       415/s
                #   amos1  4.9/s  6.3/s  21.9/s   69.0/s        —
                #
                # `for: 15m` is the load-bearing half, not the threshold.
                # The only thing in normal operation that crosses 50/s is
                # nix-gc printing one line per deleted store path (38,860
                # lines across 00:00–00:07 on 2026-09-07, on both hosts at
                # once), plus a recurring ~46/s nightly on amos1 at 01:00.
                # Those are bounded runs of work: the longest stretch above
                # 50/s anywhere in the 7d sample was 7 minutes, so a 15m
                # confirmation clears every one of them while still firing
                # on a runaway that has no reason to ever stop. Do not trade
                # the `for` down without re-measuring — a burst threshold
                # high enough to reject nix-gc on its own (>140/s) would
                # have to sit above the 68/s loop this rule exists for.
                #
                # Caveat when it does fire: vector reads the journal from a
                # persisted cursor, so a vector outage long enough to build
                # a real backlog makes the catch-up replay look like a rate
                # spike. Check whether vector restarted recently before
                # chasing a producer.
                #
                # Finding the culprit:
                #   journalctl --since -15m -o json --output-fields=_SYSTEMD_UNIT \
                #     | jq -r '._SYSTEMD_UNIT // "?"' | sort | uniq -c | sort -rn | head
                alert = "JournalLogRateHigh";
                expr = ''rate(vector_component_received_events_total{component_id="journald",component_kind="source"}[5m]) > 50'';
                for = "15m";
                labels.severity = "warning";
                annotations = {
                  summary = "Journal log rate runaway on {{ $labels.host }}";
                  description = "vector has been reading {{ $value | humanize }} journal events/sec on {{ $labels.host }} for 15m; normal is ~5/s and the busiest legitimate burst measured (nix-gc) tops out around 137/s for a few minutes. Something is stuck in a logging loop. Find it with `journalctl --since -15m -o json --output-fields=_SYSTEMD_UNIT | jq -r '._SYSTEMD_UNIT' | sort | uniq -c | sort -rn | head`, then check whether vector merely restarted and is replaying a backlog before blaming the top unit.";
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
                # Retention drift. `restic forget` groups snapshots
                # before applying the policy, and its default grouping
                # (`host,paths`) fragmented ours into one frozen,
                # never-expiring budget per paths-set — so the repo held
                # ~4x the intended snapshots for months with nothing
                # watching (#568). `--group-by host` in
                # modules/system/server-backups.nix fixes the cause;
                # this watches the effect. 7 daily + 4 weekly + 6
                # monthly is ~17 in steady state, so 25 leaves room for
                # a manual snapshot or two without flapping. Metric is
                # rewritten once per nightly backup, hence the long
                # `for` — it only needs to survive a couple of runs.
                alert = "ResticSnapshotCountHigh";
                expr = "restic_repo_snapshot_count > 25";
                for = "6h";
                labels.severity = "warning";
                annotations = {
                  summary = "restic repo on {{ $labels.instance }} is retaining too many snapshots";
                  description = "{{ $value }} snapshots in the restic repo on {{ $labels.instance }}; the 7-daily/4-weekly/6-monthly policy implies ~17. Suspect retention fragmenting into per-paths-set groups again — check `restic snapshots --group-by host` and that pruneOpts still carries --group-by host (see modules/system/server-backups.nix, #568).";
                };
              }
              {
                # Liveness check for the metric ResticSnapshotCountHigh
                # above depends on — same role as ValheimMetricsStale /
                # LlamaMetricsStale / PodmanImageMetricsStale, and
                # restic-metrics-server.service is left out of the
                # unit-include regex below for the same reason.
                #
                # Two branches, because for restic "gone" is the failure
                # mode that actually happened (#579) and a bare
                # `time() - mtime` cannot see it. textfileDir lives on
                # the rolled-back @root subvolume, so restic.prom is
                # destroyed on every boot; until #579 nothing rewrote it
                # until the next 03:00 backup, leaving
                # ResticSnapshotCountHigh evaluating an empty vector for
                # ~22h a day with no complaint from anything. A missing
                # file means *no* node_textfile_mtime_seconds series to
                # subtract from, so the staleness branch alone is silent
                # in precisely the case worth alerting on.
                #
                # Branch 2 reads as "an instance that runs the nightly
                # backup but is publishing no restic.prom at all".
                # node_systemd_unit_state{name="restic-backups-server.service"}
                # is the per-instance anchor: it exists exactly on hosts
                # importing server-backups.nix (the unit is in the
                # unit-include regex), which keeps this from firing
                # forever on hosts that legitimately have no restic repo.
                # `max by (instance)` collapses the one-series-per-state
                # fan-out to a single 1 per host; plain `absent()` is not
                # usable here because it drops the instance label and so
                # would only fire when *every* host lost the file.
                #
                # 12h: the metric refreshes on boot, every 6h, and after
                # each nightly backup (modules/system/server-backups.nix),
                # so 12h is two missed runs. `for` is 15m rather than the
                # usual 10m to clear the ~5m post-boot window where the
                # file is legitimately absent before the OnBootSec timer
                # has run.
                alert = "ResticMetricsStale";
                expr = ''
                  (time() - node_textfile_mtime_seconds{file="${textfileDir}/restic.prom"} > 43200)
                  or
                  (
                    max by (instance) (node_systemd_unit_state{name="restic-backups-server.service"})
                    unless on (instance)
                    node_textfile_mtime_seconds{file="${textfileDir}/restic.prom"}
                  )
                '';
                for = "15m";
                labels.severity = "warning";
                annotations = {
                  summary = "restic metrics are stale or missing on {{ $labels.instance }}";
                  description = "restic.prom has not been rewritten recently (or is absent entirely) on {{ $labels.instance }}, so ResticSnapshotCountHigh and the restic size metrics are evaluating frozen or empty data. Check restic-metrics-server.service and its timer, and that /mnt/backups is mounted.";
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
                # Was ContainerRestartLoop, keyed on
                # `container_start_time_seconds{name!=""}`. That selector
                # matched nothing and the alert could never fire for any
                # container on any host: cAdvisor discovers podman
                # containers by cgroup and never populates a `name` label,
                # so while `count(container_start_time_seconds)` was 141,
                # `count(container_start_time_seconds{name!=""})` was 0.
                #
                # systemd's own NRestarts counter is the honest source —
                # it is what actually decides a restart happened, it comes
                # pre-scoped by the unit-include regex above, and it covers
                # native services too, hence the rename off "Container".
                alert = "ServiceRestartLoop";
                expr = "increase(node_systemd_service_restart_total[15m]) >= 3";
                for = "0m";
                labels.severity = "warning";
                annotations = {
                  summary = "Unit {{ $labels.name }} restart-looping on {{ $labels.instance }}";
                  description = "Unit {{ $labels.name }} on {{ $labels.instance }} has been restarted {{ $value }} times by systemd in the last 15m.";
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
                # Podman's image store grew unbounded until #570 (92 GB on
                # hpp-1, 88% of it unreferenced) because nothing pruned
                # it. FilesystemAlmostFull does eventually catch that, but
                # only once / is 80% full and without saying which
                # directory did it. This fires far earlier and names the
                # cause.
                #
                # 40 GB sits comfortably above the steady state the
                # daily podman-image-prune leaves behind: hpp-1 settled at
                # 15 GB over 24 images (the running set plus two weeks of
                # superseded tags) on the first pass, down from 81 GB over
                # 125. A legitimate burst of renovate bumps will not trip
                # it; a prune that has quietly stopped reclaiming will,
                # within a few weeks and long before the disk rule would.
                # Metric comes from modules/system/oci-containers.nix.
                alert = "PodmanImageStoreLarge";
                expr = "podman_image_store_bytes > 40e9";
                for = "1h";
                labels.severity = "warning";
                annotations = {
                  summary = "Podman image store is oversized on {{ $labels.instance }}";
                  description = "The podman image store on {{ $labels.instance }} has been above 40 GB for an hour (currently {{ $value | humanize1024 }}B). Check podman-image-prune.service — see modules/system/oci-containers.nix.";
                };
              }
              {
                # Same liveness-check-on-the-checker shape as
                # ValheimMetricsStale / LlamaMetricsStale above, and
                # podman-image-metrics.service is left out of the
                # unit-include regex for the same reason. 1h is roughly
                # four missed runs of the 15m timer.
                alert = "PodmanImageMetricsStale";
                expr = ''time() - node_textfile_mtime_seconds{file="${textfileDir}/podman-images.prom"} > 3600'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "Podman image store metrics are stale on {{ $labels.instance }}";
                  description = "podman-images.prom has not been rewritten for {{ $value | humanizeDuration }} on {{ $labels.instance }}, so PodmanImageStoreLarge is evaluating a frozen value. Check podman-image-metrics.service and its timer.";
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
            # Temperature alerts (#240, retuned in #636). CPU package
            # temps come from node_exporter's hwmon collector; see
            # `cpuPackageTemp` above for the vendor-agnostic match.
            # iGPUs share the CPU package thermal zone, so there is no
            # separate iGPU sensor to alert on. The NVIDIA rules use
            # nvidia_smi_temperature_gpu which is absent until a host
            # runs the nvidia exporter (#242); silently no-ops on
            # hosts without an NVIDIA GPU.
            #
            # The two CPU rules average over a 30m window instead of
            # gating an instantaneous threshold behind `for:`. The
            # original `> 80 for 10m` / `> 90 for 5m` form needs the
            # temperature to stay above the line for the whole window,
            # which amos1 never does: its cooler is an ARCTIC Alpine
            # 23 CO (95 W rated) on a 105 W / 142 W PPT Ryzen 7 5800X,
            # deliberately undersized to fit the rack case, so it
            # spikes into the 80s and falls back within a minute or
            # two. Over 15 days both rules only ever reached `pending`
            # — 32 hours of them, including a 90.9°C peak — and
            # neither fired. A window average counts the dips, so
            # "hot in bursts all afternoon" and "pinned at 90°C" stop
            # looking the same.
            name = "temperature";
            rules = [
              {
                # 15d of history: the 30m mean peaked at 82.3°C on
                # amos1 and 70.8°C on hpp-1, so this fires roughly
                # monthly, on the nights `nixos-upgrade` builds
                # authentik / CUDA llama-cpp / the NVIDIA modules from
                # source and holds the CPU near throttle for ~25m.
                # That is intentional rather than noise to suppress:
                # half an hour averaging above 80°C is worth a line in
                # the inbox even when the cause is known, and it is
                # rare enough not to train the reader to ignore it.
                alert = "HostCPUTemperatureHigh";
                expr = "avg_over_time((${cpuPackageTemp})[30m:1m]) > 80";
                labels.severity = "warning";
                annotations = {
                  summary = "CPU running hot on {{ $labels.instance }}";
                  description = "CPU package temperature on {{ $labels.instance }} has averaged above 80°C over the last 30m ({{ $value }}°C). Expected on a from-source nixos-upgrade build; otherwise check airflow / fan health.";
                };
              }
              {
                # Same window at the throttle point. 90°C is the
                # 5800X's Tctl limit, and averaging it over 30m means
                # the CPU has been losing clock to heat for that whole
                # half hour rather than touching the limit in passing.
                # The worst 15m mean in 15d was 90.4°C (that same
                # build) and the worst 30m mean 82.3°C, so the 30m
                # window is what keeps an expected build off a
                # critical-severity page.
                alert = "HostCPUTemperatureCritical";
                expr = "avg_over_time((${cpuPackageTemp})[30m:1m]) > 90";
                labels.severity = "critical";
                annotations = {
                  summary = "CPU thermal-throttling on {{ $labels.instance }}";
                  description = "CPU package temperature on {{ $labels.instance }} has averaged above 90°C over the last 30m ({{ $value }}°C). The CPU is throttling continuously, not in bursts; investigate immediately.";
                };
              }
              # Fan rules (#637). These are what let a reader tell a
              # failing cooler apart from a busy one: the rules above
              # fire on "hot" regardless of cause, and a Jellyfin
              # transcode and a seizing bearing look identical to
              # them.
              {
                # Unambiguous: the fan has never been seen below
                # 1331 rpm, which is where its curve idles at 42°C,
                # so anything under 500 is a stopped fan, a pulled
                # header or a dead tach — not a slow one.
                #
                # 5m rather than the "couple of minutes" #637
                # suggests. The CPU defends itself by throttling at
                # 90°C, so this alert's job is to get a human
                # looking rather than to prevent damage in seconds,
                # and the wider window rides out both a tach glitch
                # and a BIOS fan-stop dip should Q-Fan ever be set
                # to allow one (it does not today — the fan was
                # still turning at 42°C).
                alert = "HostCPUFanStopped";
                expr = "${cpuFanRpm} < 500";
                for = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "CPU fan stopped on {{ $labels.instance }}";
                  description = "CPU fan on {{ $labels.instance }} has been below 500 rpm for 5m (currently {{ $value }} rpm, against 1331 at idle and ~2100 under load). The cooler is an ARCTIC Alpine 23 CO with no thermal margin to spare on a 105 W 5800X; expect sustained throttling within minutes. Check the fan and its CPU_FAN header.";
                };
              }
              {
                # The same 30m window and the same 80°C line as
                # HostCPUTemperatureHigh, plus the fan condition, so
                # this fires alongside that rule and says *why*: at a
                # 30m mean of 80°C the BIOS curve has the fan at
                # 1900-2100 rpm, so under 1500 means the fan is not
                # answering the heat. Ordered fan-first because
                # `and` keeps the left-hand side's sample, and the
                # rpm is the number worth putting in the
                # notification.
                alert = "HostCPUFanNotRamping";
                expr = "avg_over_time((${cpuFanRpm})[30m:1m]) < 1500 and on (instance) avg_over_time((${cpuPackageTemp})[30m:1m]) > 80";
                labels.severity = "warning";
                annotations = {
                  summary = "CPU hot and fan not keeping up on {{ $labels.instance }}";
                  description = "CPU fan on {{ $labels.instance }} has averaged {{ $value }} rpm over the last 30m while the CPU package averaged above 80°C — the curve puts it near 1900-2100 rpm at that temperature. This is the cooling failing rather than the workload being heavy, which is the distinction HostCPUTemperatureHigh cannot make alone. Check the fan bearing, dust in the heatsink fins and the rack's ambient temperature.";
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
            # Cooling-health drift (#636). The temperature rules above
            # answer "is it hot right now"; this one answers "is the
            # cooling working as well as it did", which is the
            # question that actually matters on a host whose hot
            # bursts are expected by design.
            #
            # It measures the CPU package temperature over only the
            # minutes the machine was near idle (< 15% busy), averaged
            # across 24h. Restricting to low load is what makes it a
            # cooling measurement rather than a workload one: a day of
            # Jellyfin transcodes and a quiet day produce the same
            # number, but a fan slowing down, dust in the fins, MX-2
            # pumping out, or the rack warming up all move it.
            #
            # Calibration, 15 days on both server hosts: amos1 sat
            # between 38.0°C and 43.5°C, hpp-1 between 41.5°C and
            # 44.1°C. 60°C is therefore ~16°C above anything either
            # host has actually done. The headroom is deliberate — the
            # baseline tracks ambient, so it has to survive the
            # difference between a heating season and a hot week
            # without crying wolf. That does mean a slow 10°C
            # degradation stays under the line; catching that needs
            # fan RPM, which HostCPUFanNotRamping in the temperature
            # group above now supplies (#637) — "hot with the fan
            # slow" is a far sharper statement than any temperature
            # threshold alone.
            #
            # The alternative — comparing against this host's own
            # reading two weeks ago — was originally rejected because
            # retention was 15 days, so `offset 14d` sat on the edge of
            # the data and would silently evaluate to nothing after any
            # gap. That reason expired when retention went to 45d (see the
            # header): 14d is now well inside the window. The comparison is
            # therefore viable again and simply hasn't been revisited —
            # treat this as an open option, not a closed one.
            #
            # Own group with a 5m interval rather than the file-wide
            # 30s: a 24h mean cannot move meaningfully in half a
            # minute, so 59 of every 60 evaluations would re-derive
            # the same number. (Cost is not the reason — VM answers
            # the 24h subquery in ~10ms on both hosts.)
            name = "cooling";
            interval = "5m";
            rules = [
              {
                alert = "HostCPUCoolingDegraded";
                expr = "avg_over_time(((${cpuPackageTemp}) and on (instance) ((${cpuBusyFraction}) < 0.15))[24h:5m]) > 60";
                for = "30m";
                labels.severity = "warning";
                annotations = {
                  summary = "CPU cooling degraded on {{ $labels.instance }}";
                  description = "Near-idle CPU package temperature on {{ $labels.instance }} has averaged {{ $value }}°C over the last 24h, against a 38-44°C baseline for this fleet. Load is not the cause — this only samples minutes below 15% CPU. Check fan RPM, dust in the heatsink fins, thermal paste age, and the rack's ambient temperature.";
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
                # #643. nut_exporter returns no metrics at all when it
                # can't get a reading, so `up == 0` for the nut job is
                # all we have — and it collapses "behemoth is gone"
                # into "behemoth is fine but its NUT is dead", which
                # need different responses.
                #
                # We split them on `snmp_pfsense`, which we already
                # scrape off behemoth (192.168.10.1) for interface
                # counters. If SNMP answers while the nut exporter
                # can't read a thing, the router is up and it is NUT
                # that is broken — a one-command fix, not an
                # investigation.
                #
                # Deliberately *not* split on which NUT process died.
                # All three observed shapes (driver dead / upsd dead /
                # both) come from the same unchecked `nut.sh rc_start`
                # and take the same repair, so a probe exporter that
                # told them apart would cost a service per host and
                # change nothing about what you do next. See the
                # header of ./nut-client.nix.
                #
                # Critical rather than warning: this is the
                # powerValue=1 UPS, the one actually feeding the
                # server PSUs, so while it fires there is no OB/LB
                # signal and no coordinated shutdown on any host. It
                # also means the 5-minute pfSense cron watchdog has
                # already failed twice over.
                #
                # Since #728, `snmp_pfsense` is scraped by amos1
                # only, so this split exists on prod alone. On hpp-1
                # the `up{job="snmp_pfsense"}` series is absent, the rule
                # can never fire, and the router case falls into
                # UpsNoCommunication's `unless on()` branch below —
                # which is exactly the fail-safe that branch is for.
                alert = "UpsMasterNutBroken";
                expr = ''up{job="nut",ups_source="router"} == 0 and on() up{job="snmp_pfsense"} == 1'';
                for = "10m";
                labels.severity = "critical";
                annotations = {
                  summary = "behemoth is up but its NUT master is dead";
                  description = "The router-side UPS has been unreadable for 10m while behemoth still answers SNMP, so this is the pfSense NUT package, not the network. The cron watchdog on behemoth should have repaired it within 5m and did not. Fix: `ssh behemoth /usr/local/etc/rc.d/nut.sh restart` (`service nut restart` does not work). Confirm the shape first with `upsc UPSA` on behemoth — `Driver not connected` vs `Connection refused` both mean the same restart. Until it clears, the UPS feeding the servers is unmonitored: a mains failure produces no OB/LB signal and no coordinated shutdown.";
                };
              }
              {
                # Everything the rule above doesn't claim: the NAS-side
                # master, and the router-side case where behemoth
                # itself is unreachable. The `unless on()` is
                # fail-safe — if the snmp_pfsense target is missing
                # entirely (snmp_exporter down), the router case lands
                # here rather than vanishing.
                #
                # The 10m `for` window is intentionally longer than
                # upsmon's NOCOMMWARNTIME (300s) so a pfSense package
                # restart flap doesn't page.
                alert = "UpsNoCommunication";
                expr = ''up{job="nut",ups_source="nas"} == 0 or (up{job="nut",ups_source="router"} == 0 unless on() up{job="snmp_pfsense"} == 1)'';
                for = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "Lost communication with {{ $labels.ups_source }}-side UPS master";
                  description = "nut_exporter for the {{ $labels.ups_source }}-side UPS has failed to reach its master for 10m, and no independent channel contradicted that — so treat this as a host or network problem before a NUT one. Confirm with `upsc UPSA` on behemoth: if it answers at all, this is the NUT-only failure UpsMasterNutBroken describes and `ssh behemoth /usr/local/etc/rc.d/nut.sh restart` is the fix. Note the independent channel is the snmp_pfsense scrape, which since #728 runs on amos1 only — on hpp-1 there is nothing to contradict it, so the router-side NUT failure lands here rather than in UpsMasterNutBroken. Loss of comms with both masters at once probably means LAN-down, not power.";
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
          {
            # The metrics half of the security rule set. The other
            # half is log-derived (authentik / sudo / pfSense) and
            # lives in ./log-alerts.nix, on its own vmalert
            # instance pointed at VictoriaLogs — vmalert's
            # `-datasource.url` is process-wide, so the two cannot
            # share an evaluator. Both emit into the same
            # alertmanager and the same Discord receiver.
            name = "security";
            rules = [
              {
                # Certificate expiry (audit checklist §5). gatus is
                # the only cert-expiry source on the host: it probes
                # each app's external URL and exports the remaining
                # lifetime it saw on the wire, which measures what
                # clients actually get rather than what is on disk.
                #
                # Aggregated with `min by (group)` rather than
                # alerted per endpoint. Caddy serves one wildcard
                # cert for every app host, so a per-endpoint rule
                # would fire ~37 identical alerts for one
                # certificate; the `group` label (apps /
                # infrastructure / external) is the coarsest split
                # that still separates our own certs from an
                # external dependency's. Gatus itself shows the
                # per-endpoint view.
                #
                # 21d threshold, sitting in a deliberate gap: Caddy
                # renews a 90d Let's Encrypt cert at ~30d
                # remaining, and gatus's own
                # `[CERTIFICATE_EXPIRATION] > 336h` condition (see
                # ../apps/gatus.nix) trips at 14d and turns this
                # into a GatusEndpointDown cascade across every
                # app. So 21d means renewal has been failing for
                # about nine days and there is still a week of lead
                # time — which is the warning the checklist asks
                # for, rather than a notification that it is
                # already too late.
                alert = "CertificateExpiringSoon";
                expr = "min by (group) (gatus_results_certificate_expiration_seconds) < 21 * 24 * 3600";
                for = "1h";
                labels.severity = "warning";
                annotations = {
                  summary = "TLS certificate expiring in {{ $value | humanizeDuration }} ({{ $labels.group }})";
                  description = "The shortest-lived certificate gatus sees in the {{ $labels.group }} group expires in {{ $value | humanizeDuration }}, below the 21d warning threshold. Caddy should have auto-renewed at ~30d remaining, so check `journalctl -u caddy | grep -i certificate` for ACME failures. At 14d gatus starts failing every affected endpoint outright.";
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
            # The platform owns only the core-unit alternatives here. App
            # modules add their own service names through
            # myObservability.monitoredSystemdUnits, so a new app cannot be
            # healthy-looking solely because this central list was missed.
            extraFlags = [
              "--collector.textfile.directory=${textfileDir}"
              # Publishes node_systemd_service_restart_total (systemd's own
              # NRestarts counter) per unit. Off by default in node_exporter.
              # ServiceRestartLoop below is built on it — see the note there
              # for why the cAdvisor-based predecessor never worked.
              # Scoped by the same unit-include regex below, so this adds one
              # series per already-tracked unit rather than per unit on the host.
              "--collector.systemd.enable-restarts-metrics"
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
                #   nixos-upgrade — the nightly auto-rebuild
                #                (modules/system/auto-rebuild.nix). A failed
                #                fetch of the private nix-secrets input, an
                #                eval error or a bad switch otherwise goes
                #                unnoticed until someone looks: the unit is a
                #                oneshot, so it stays `failed` (and the alert
                #                stays firing) until the next night's run
                #                succeeds.
                + "sshd|caddy|postgresql|mysql|redis(-.+)?|restic-backups-server"
                + "|nixos-upgrade"
                # Authentik (SSO) — server + worker + migrate one-shot.
                + "|authentik(-worker|-migrate)?"
                # Observability stack itself — useful to know if our
                # own scrapers fall over.
                + "|victoriametrics|victorialogs|vmalert(-.+)?"
                + "|alertmanager|grafana|vector|cadvisor|gatus"
                + "|prometheus-(node|postgres|mysqld|redis|snmp|nvidia-gpu)-exporter"
                # NUT client + per-master exporters (issue #82).
                + "|upsmon|nut-exporter-(router|nas)"
                # App modules contribute their own alternatives. Keep the
                # literal `|` prefix here so an empty contribution list does
                # not perturb the core-only configuration.
                + lib.optionalString (config.myObservability.monitoredSystemdUnits != [ ]) (
                  "|" + lib.concatStringsSep "|" config.myObservability.monitoredSystemdUnits
                )
                # The daily image-store GC (modules/system/oci-containers.nix).
                # Not a container: if it fails the store silently resumes
                # growing, and PodmanImageStoreLarge would not notice for
                # weeks. podman-image-metrics is deliberately *not* here —
                # PodmanImageMetricsStale is its liveness check, same
                # convention as valheim-metrics / llama-metrics.
                + "|podman-image-prune)\\.service$"
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
          # 15d had days to spare against the old daily Valheim restart
          # cadence. #458 moved that to weekly, and judging its Phase 2
          # ("restart only on update, reboot or deploy") means comparing
          # several complete week-long cycles — 15d holds two. 45d holds
          # six and costs ~350 MB: the whole store measured 116 MB for
          # 15 days on amos1 (2026-09-14), on a filesystem with 331 GB
          # free. Still ephemeral by design, see the header.
          retentionPeriod = "45d";
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
              {
                # Vector's internal telemetry. Scraped mainly so the
                # pfSense syslog feed can be alerted on when it goes
                # silent — see PfsenseLogsAbsent below.
                job_name = "vector";
                static_configs = [ { targets = [ "127.0.0.1:${toString vectorMetricsPort}" ]; } ];
              }
            ]
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
            #
            # Prod-only (#728). Every job below walks a device outside
            # this fleet, so running them on both servers polls the
            # same agent twice for no redundancy — the dev host's
            # alerts are not the notification path. On the Omada
            # switches that is not merely wasteful: their SNMP agent
            # serializes concurrent walks, so two pollers doubled every
            # walk (192.168.15.3 measured 17.6s against a ~8.8s solo
            # walk) and left less headroom under the 25s
            # `scrape_timeout` than one more walker costs. A single
            # extra SNMP client anywhere on the network then pushed it
            # over, `up` went to 0 and `InstanceDown` paged — observed
            # 2026-09-22/23 and reproduced on demand. Gating here keeps
            # `services.prometheus.exporters.snmp` enabled on both
            # hosts, so hpp-1 stays the ad-hoc diagnosis path (#629,
            # #686, #693) while walking nothing on a schedule.
            ++ lib.optionals (hostSpec.serverEnvironment == "prod") [
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
              # Omada switches and APs (SNMPv3 — see
              # modules/system/snmp-exporter.nix for the single
              # authPriv/SHA/AES auth both jobs use). SNMP is a
              # site-level setting in the controller, pushed to every
              # managed device; the controller itself is not an agent
              # and has nothing to scrape.
              #
              # Switches: if_mib + system gets per-port counters,
              # errors, link state and uptime. PoE draw is behind a
              # TP-Link private MIB that upstream's generated snmp.yml
              # does not carry, so it is not available here.
              #
              # The if_mib walk is ~1,200 PDUs over v3 AuthPriv and
              # runs past the 10s default scrape_timeout, so every
              # scrape was cancelled and the target read up=0 (#629).
              # 25s leaves headroom inside the 30s interval.
              #
              # #638 sized that 25s against "~11s per switch (14.1s on
              # the SG3428X)", but those were two-poller numbers — both
              # servers walking the same serializing agent at once —
              # and nothing recorded that they were, so they read as a
              # property of the switch. Under the prod-only gating
              # above the same walks measure 6.6s on 192.168.15.2 and
              # 9.0s on 192.168.15.3. Size any future timeout change
              # against a walk you measured, not against a recorded
              # scrape_duration_seconds.
              {
                job_name = "snmp_omada_switches";
                metrics_path = "/snmp";
                scrape_timeout = "25s";
                params = {
                  module = [
                    "if_mib"
                    "system"
                  ];
                  auth = [ "omada_v3" ];
                };
                static_configs = [
                  {
                    targets = [
                      "192.168.15.2"
                      "192.168.15.3"
                    ];
                  }
                ];
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
              # APs: the shipped `eap` module is TP-Link's private
              # enterprise tree (11863) and carries exactly one gauge,
              # `clientCount` — per-AP associated clients, which is the
              # number the coverage/band-steering work keeps needing.
              # `system` supplies sysName/sysUpTime so the two APs are
              # distinguishable in a dashboard. Those two modules walk
              # in tens of milliseconds, so the 10s default
              # scrape_timeout is ample here — no #629-style bump
              # needed. if_mib stays absent, but no longer because the
              # APs can't serve it: it was to be added only if a walk
              # showed it returns, and on firmware 1.4.3 it does.
              # Taking it is #693's call — it carries a cardinality
              # question (5 radio BSSID interfaces per AP × counters)
              # and would likely want the #629 scrape_timeout bump
              # along with it. #693's sizing predates #728 and was
              # measured with both servers walking, so re-measure solo
              # before assuming a bump is needed at all.
              {
                job_name = "snmp_omada_aps";
                metrics_path = "/snmp";
                params = {
                  module = [
                    "eap"
                    "system"
                  ];
                  auth = [ "omada_v3" ];
                };
                static_configs = [
                  {
                    targets = [
                      "omada-ap-basement.ipreston.net"
                      "omada-ap-upstairs.ipreston.net"
                    ];
                  }
                ];
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
          rules = ruleGroups // {
            groups = ruleGroups.groups ++ metricRuleGroups;
          };
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
