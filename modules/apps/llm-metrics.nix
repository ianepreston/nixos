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

          exporter =
            pkgs.writers.writePython3 "llama-metrics"
              {
                flakeIgnore = [
                  "E501"
                  "W391"
                ];
              }
              ''
                import json
                import os
                import sys
                import tempfile
                import urllib.parse
                import urllib.request

                OUT = os.environ["TEXTFILE_OUT"]
                ENDPOINTS = json.load(open(os.environ["ENDPOINTS_FILE"]))
                API_KEY_FILE = os.environ["API_KEY_FILE"]

                # Long enough to ride out a busy child answering a metrics
                # task behind a decode, short enough that a powered-off
                # terra doesn't stall a 1-minute timer.
                TIMEOUT = 10

                # The four states llama.cpp's router reports
                # (server_model_status_to_string). Emitted as a state set,
                # the way node_exporter does node_systemd_unit_state, so a
                # transition is visible as a series flipping rather than a
                # label value changing. Anything unrecognised leaves all
                # four at 0.
                STATES = ["unloaded", "loading", "loaded", "sleeping"]

                # llama.cpp names its metrics "llamacpp:foo", and a colon in
                # a metric name is reserved for recording rules — PromQL can
                # only reach it through a __name__ matcher, which Grafana
                # panels handle badly. Renamed on the way through, and given
                # the model/alias labels the source has no room for.
                COUNTERS = {
                    "llamacpp:prompt_tokens_total": (
                        "llama_prompt_tokens_total",
                        "Prompt tokens processed by this model since its child process started.",
                    ),
                    "llamacpp:prompt_seconds_total": (
                        "llama_prompt_seconds_total",
                        "Seconds spent processing prompts since this model's child process started.",
                    ),
                    "llamacpp:tokens_predicted_total": (
                        "llama_tokens_predicted_total",
                        "Tokens generated by this model since its child process started.",
                    ),
                    "llamacpp:tokens_predicted_seconds_total": (
                        "llama_tokens_predicted_seconds_total",
                        "Seconds spent generating tokens since this model's child process started.",
                    ),
                    "llamacpp:n_decode_total": (
                        "llama_decode_total",
                        "llama_decode() calls since this model's child process started.",
                    ),
                }
                GAUGES = {
                    "llamacpp:n_tokens_max": (
                        "llama_tokens_max",
                        "Largest prompt+generation token count this model has been asked for, against its configured ctxSize.",
                    ),
                    "llamacpp:requests_processing": (
                        "llama_requests_processing",
                        "Requests this model is currently serving.",
                    ),
                }


                def read_api_key():
                    # Missing key is survivable: /v1/models is public, so
                    # state still publishes and only the token counters go
                    # dark (recorded as llama_model_metrics_error).
                    try:
                        with open(API_KEY_FILE) as fh:
                            return fh.read().strip()
                    except OSError as exc:
                        sys.stderr.write("api key unreadable: %s\n" % exc)
                        return None


                def fetch(url, api_key=None):
                    req = urllib.request.Request(url)
                    if api_key:
                        req.add_header("Authorization", "Bearer " + api_key)
                    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                        return resp.read().decode()


                def parse_prometheus(text):
                    out = {}
                    for line in text.splitlines():
                        if not line or line.startswith("#"):
                            continue
                        parts = line.split()
                        if len(parts) == 2:
                            try:
                                out[parts[0]] = float(parts[1])
                            except ValueError:
                                pass
                    return out


                def labels(**kwargs):
                    def esc(v):
                        return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

                    body = ",".join('%s="%s"' % (k, esc(v)) for k, v in sorted(kwargs.items()))
                    return "{" + body + "}"


                rows = {}


                def emit(metric, mtype, help_text, label_str, value):
                    rows.setdefault(metric, (mtype, help_text, []))[2].append((label_str, value))


                api_key = read_api_key()

                for server in sorted(ENDPOINTS):
                    base = ENDPOINTS[server].rstrip("/")
                    try:
                        models = json.loads(fetch(base + "/v1/models"))["data"]
                    except Exception as exc:
                        # A powered-off terra lands here every minute. It is
                        # a value, not a fault: publish up=0 and move on.
                        sys.stderr.write("%s: /v1/models failed: %s\n" % (server, exc))
                        emit("llama_server_up", "gauge", "Whether this llama-server router answered /v1/models.", labels(llama_server=server), 0)
                        continue
                    emit("llama_server_up", "gauge", "Whether this llama-server router answered /v1/models.", labels(llama_server=server), 1)

                    for model in models:
                        name = model["id"]
                        # Joined rather than one series per alias: the label
                        # is here so a dashboard can legend by role name
                        # ("text", "vision", "code") instead of by GGUF, and
                        # every model in this fleet has exactly one.
                        alias = ",".join(sorted(model.get("aliases") or []))
                        state = model.get("status", {}).get("value", "")
                        common = dict(llama_server=server, model=name, alias=alias)

                        for candidate in STATES:
                            emit(
                                "llama_model_state",
                                "gauge",
                                "Router-reported state of this model, one series per state (loaded means resident and awake; sleeping means the child is alive but has handed its VRAM back).",
                                labels(state=candidate, **common),
                                int(candidate == state),
                            )

                        # Only an awake model may be asked for /metrics —
                        # see the module header. `autoload=false` is the
                        # second line of defence for the case where the
                        # model sleeps between this check and the request.
                        if state != "loaded":
                            continue

                        url = "%s/metrics?model=%s&autoload=false" % (
                            base,
                            urllib.parse.quote(name, safe=""),
                        )
                        try:
                            parsed = parse_prometheus(fetch(url, api_key))
                            failed = 0
                        except Exception as exc:
                            sys.stderr.write("%s: /metrics for %s failed: %s\n" % (server, name, exc))
                            parsed = {}
                            failed = 1

                        # The one silent-failure mode worth a series of its
                        # own: this exporter depends on `--metrics` reaching
                        # the child through llama.cpp's argv merge, and if
                        # that ever stops happening the counters just go
                        # quiet while everything else looks healthy.
                        emit(
                            "llama_model_metrics_error",
                            "gauge",
                            "Whether the last /metrics read for this loaded model failed.",
                            labels(**common),
                            failed,
                        )

                        for src, (dst, help_text) in COUNTERS.items():
                            if src in parsed:
                                emit(dst, "counter", help_text + " Resets when the model is evicted; survives sleep/wake.", labels(**common), parsed[src])
                        for src, (dst, help_text) in GAUGES.items():
                            if src in parsed:
                                emit(dst, "gauge", help_text, labels(**common), parsed[src])

                # Atomic write via tempfile + rename, so node_exporter never
                # reads a half-written file.
                fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT), prefix=".llama.prom.")
                with os.fdopen(fd, "w") as fh:
                    for metric in sorted(rows):
                        mtype, help_text, samples = rows[metric]
                        fh.write("# HELP %s %s\n" % (metric, help_text))
                        fh.write("# TYPE %s %s\n" % (metric, mtype))
                        for label_str, value in samples:
                            fh.write("%s%s %s\n" % (metric, label_str, repr(float(value))))
                os.chmod(tmp, 0o644)
                os.rename(tmp, OUT)
              '';
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
