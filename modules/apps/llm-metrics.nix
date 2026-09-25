# llm-metrics - per-model llama-server usage into the textfile collector
#
# Answers "which model aliases actually earn their keep" (#553): per-model
# load state, prompt/generation tokens, throughput and observed context
# high-water, for every llama-server this host can reach. Shared by both
# llama-server routes the way modules/apps/llm-caddy-auth.nix is —
# modules/apps/llm.nix contributes this host's own router,
# modules/apps/llm-terra.nix contributes terra's, and amos1 carries both.
#
# ## Why this is a textfile collector and not a scrape target
#
# The obvious shape — point VictoriaMetrics at llama-server's `/metrics`
# — is actively harmful under router mode, for three separate reasons
# found in the b9190 source (`tools/server/`):
#
# 1. **The router has no metrics of its own.** `routes.get_metrics` is
#    wired to `models_routes->proxy_get`, so `GET /metrics` is routed by
#    the `?model=` query param exactly like a completion request. With no
#    param it is a flat `400 model name is missing from the request`.
#
# 2. **A scrape would load models.** `models_autoload` defaults to true,
#    so `/metrics?model=X` against an *unloaded* model spawns a child and
#    pulls the GGUF into VRAM. Every request below therefore carries
#    `autoload=false`, which downgrades that to a 400.
#
# 3. **A scrape would defeat idle eviction.** `get_metrics` builds its
#    response with `create_response()` (no `bypass_sleep`, unlike
#    `/health`), which calls `queue_tasks.wait_until_no_sleep()` — i.e.
#    scraping a *sleeping* child wakes it and reloads its weights. A 30 s
#    scrape interval against a 300 s `sleepIdleSeconds` would pin a model
#    resident forever, which on amos1 means permanently holding VRAM that
#    Jellyfin's NVENC transcoding needs (see modules/hosts/amos1.nix).
#
# So the child's `/metrics` can only be read when the router says that
# model is `loaded` (awake), and nothing but a real client request may
# change that. That is a decision, not a scrape, hence the exporter
# below: it reads the router's public `/v1/models` for state and only
# then reaches for `/metrics` on the models that are already awake.
#
# The same shape also solves terra: it is a desktop that gets powered
# off, and a real scrape target for it would trip `InstanceDown` every
# time it sleeps. Polled from here, terra being off is just
# `llama_server_up{llama_server="terra"} 0`.
#
# Publishing through node_exporter's textfile collector follows
# modules/apps/{valheim,mylar3,sabnzbd}.nix; the liveness check on the
# checker is `LlamaMetricsStale` in modules/system/victoriametrics.nix
# (which is why this unit is deliberately *not* in that file's systemd
# unit-include regex — a stale `.prom` covers more failure modes than a
# failed unit does).
#
# ## What the numbers mean
#
# The counters live in the *child* process, so they reset when a model is
# evicted (`--models-max 1`, i.e. whenever a different model is asked
# for) but survive a sleep/wake cycle. `increase()` over a window is
# therefore the honest way to read them; an absolute total is not.
#
# Sampling is also lossy by construction: tokens a model serves between
# the last poll and its eviction are never observed. At a 1 min timer
# against models that stay loaded for `sleepIdleSeconds` (300-600 s)
# after their last request, that is a small tail, and the question this
# feeds ("is this alias worth its disk") is comparative, not exact.
#
# One row will always read as dead, and is meant to: terra publishes a
# phantom `unsloth/…-GGUF:Q4_K_XL` with an empty `alias`, which is
# llama.cpp's cache scan naming the configured `:UD-Q4_K_XL` file a
# second time (see the cache section in modules/system/llama-cpp.nix).
# Nothing routes to it, so it sits permanently `unloaded`. That is the
# correct reading of a name nobody should use — not a gap in coverage,
# and not something a prune can clear.
{ inputs, ... }:
{
  # `key` dedupes this when both llm.nix and llm-terra.nix import it on
  # the same host (amos1 does). Without it the module system treats each
  # import as distinct and the option declaration below collides with
  # itself. Same reasoning as llm-caddy-auth.nix.
  flake.modules.nixos.llm-metrics = {
    key = "llm-metrics";
    imports = [
      (
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.myLlmMetrics;

          # Set in modules/system/victoriametrics.nix; kept in sync by
          # hand, as in mylar3.nix and valheim.nix. Both modules land on
          # the same hosts.
          textfileDir = "/var/lib/node-exporter-textfile-collector";

          endpointsFile = pkgs.writeText "llama-endpoints.json" (
            builtins.toJSON (lib.mapAttrs (_: e: "http://${e.host}:${toString e.port}") cfg.endpoints)
          );

          exporter = pkgs.writers.writePython3 "llama-metrics" {
            flakeIgnore = [
              "E501"
              "W391"
            ];
          } (builtins.readFile ./_llm-metrics/collector.py);
        in
        {
          options.myLlmMetrics.endpoints = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  host = lib.mkOption {
                    type = lib.types.str;
                    description = "Host the llama-server router listens on, as this host reaches it.";
                  };
                  port = lib.mkOption {
                    type = lib.types.port;
                    description = "Port the llama-server router listens on.";
                  };
                };
              }
            );
            default = { };
            description = ''
              llama-server routers this host should publish metrics for,
              keyed by the name that lands in the `llama_server` label.
              Contributed by the route modules that already know an
              endpoint exists — `llm.nix` for this host's own router,
              `llm-terra.nix` for terra's.

              Reachability is the only requirement: nothing here has to
              run locally, and an endpoint that is down publishes
              `llama_server_up 0` rather than failing the run.
            '';
          };

          config = lib.mkIf (cfg.endpoints != { }) {
            myObservability.metricRuleGroups.llm.groups = [
              {
                name = "llm";
                rules = [
                  {
                    # A sleeping model and a powered-off terra are normal;
                    # this checks the textfile publisher itself instead.
                    alert = "LlamaMetricsStale";
                    expr = ''time() - node_textfile_mtime_seconds{file="${textfileDir}/llama.prom"} > 900'';
                    for = "10m";
                    labels.severity = "warning";
                    annotations = {
                      summary = "llama-server metrics are stale on {{ $labels.instance }}";
                      description = "llama.prom has not been rewritten for {{ $value | humanizeDuration }} on {{ $labels.instance }}, so the LLM dashboard is showing frozen per-model usage. Check llama-metrics.service and its timer.";
                    };
                  }
                ];
              }
            ];

            # Same key the routers enforce, from shared.yaml — see
            # modules/system/llama-cpp.nix for why one key covers the
            # fleet. Read directly by the oneshot (which runs as root)
            # rather than through a template: there is no env file to
            # render and no unit to restart on rotation, since the next
            # timer firing picks up the new value on its own.
            sops.secrets."llama-cpp/api_key" = {
              sopsFile = "${inputs.nix-secrets}/sops/shared.yaml";
            };

            systemd.services.llama-metrics = {
              description = "publish llama-server per-model usage to node_exporter textfile collector";
              serviceConfig = {
                Type = "oneshot";
                User = "root";
                ExecStart = exporter;
                Environment = [
                  "TEXTFILE_OUT=${textfileDir}/llama.prom"
                  "ENDPOINTS_FILE=${endpointsFile}"
                  "API_KEY_FILE=${config.sops.secrets."llama-cpp/api_key".path}"
                ];
              };
            };

            systemd.timers.llama-metrics = {
              description = "Periodic llama-server per-model usage refresh";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "2m";
                # Fast enough to catch a load/unload transition and to
                # sample a model's counters before an eviction takes them,
                # slow enough that a powered-off terra costs nothing.
                OnUnitActiveSec = "1m";
                AccuracySec = "10s";
                Unit = "llama-metrics.service";
              };
            };
          };
        }
      )
    ];
  };
}
