# Local LLM Inference

The inference owner is `modules/system/llama-cpp.nix`, with a common typed
model schema and preset renderer under `_llama-cpp/`. NixOS uses CUDA/systemd;
Apple Silicon uses Metal/launchd. Platform operator tasks consume the published
`myLlamaCpp.operator` contract (platform, cache, API URL, credential path and
configured routing names), rather than reading private service settings.

## Apple Silicon (`work`)

The logged-in primary user's launchd agent serves **http://127.0.0.1:8080/v1**.
`myLlamaCpp.port` is configurable; check availability with
`lsof -nP -iTCP:8080 -sTCP:LISTEN` before changing/activating it. The bind is
restricted to `127.0.0.1`, the bundled web UI is disabled (`--no-webui`), and
there is no proxy, TLS, SSO or LAN listener.

Initially `code` and `text` both select **gpt-oss-20b MXFP4**, at **32768**
tokens with f16 KV cache, all layers on Metal and no CPU expert offload.
Aliases, context and cache types come from `modules/hosts/work.nix` once;
the preset and local pi provider are generated from that declaration. Only one
model is resident at a time, and it sleeps after 600 idle seconds. A first
request downloads uncached weights; activation itself downloads no models.
The 48 GB unified memory is shared with macOS and applications. Start at 32k;
measure memory pressure and real client behavior before raising it. Linux
throughput measurements below do not predict Mac performance.

Validated on the M4 Pro with Chrome, Safari, Slack, Teams and Obsidian running:
pi 0.80.3 completed a streamed request and a `read` tool-call/result round trip.
A synthetic 4989-token prompt with 128 generated tokens measured **662 tok/s
prefill and 58 tok/s generation**, with normal macOS memory pressure and zero
swap. Logs confirm **25/25 layers on Metal** and a 32768-token slot context.
These are one throughput sample, not a coding-quality comparison. A temporary
5-second idle setting released GPU allocations and woke successfully; the
configured timeout remains 600 seconds. A temporary small second model also
verified eviction in both directions under the one-resident-model limit.

Data survives rebuilds, agent restarts and Nix GC under
`~/Library/Application Support/llama-cpp/` (`myLlamaCpp.dataDirectory`):

- `models/`: downloaded GGUFs, outside the Nix store (about 12 GB for the initial model).
- `api-key`: a separate local credential, generated on first launch with mode
  `0600`, read into the server environment at runtime. It never appears in the
  plist, server argv, or Nix store. Clients read the same file. Missing keys are
  generated; malformed/insecure existing files cause startup to fail.

Activate after reviewing the build with `task build_darwin:work`. Inspect and
control the agent as the primary user in their GUI login session:

```sh
launchctl print "gui/$(id -u)/org.nixos.llama-cpp"
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.nixos.llama-cpp.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.nixos.llama-cpp.plist"
tail -f "$HOME/Library/Logs/llama-cpp/server.log"

task llm:models HOST=work                 # local status and cache listing; no SSH
task llm:models:fetch HOST=work           # explicit sequential download/load, one token per model
task llm:models:prune HOST=work           # dry run
task llm:models:prune HOST=work APPLY=true
```

Prune uses the same algorithm as Linux, with pinned GNU tools on Darwin. Its
keep-set includes **every configured model**, including idle ones. It refuses
to delete when the router is unreachable, a configured model is absent, or a
candidate path holds a loaded configured model. It never prunes automatically.
`HOST=terra` and `HOST=amos1` retain the existing remote SSH operations.

Home Manager installs pi and combines the local provider with private work
providers in `~/.pi/agent/models.json`. The local contribution consumes the
published `myLlamaCpp.piProvider`; its aliases and limits are generated from
the serving configuration. `settings.json`, authentication state and sessions
remain writable and are not managed.

The same local provider is available as `/etc/llama-cpp/pi-models.json` for
standalone clients. It uses the OpenAI completions API and resolves the key
through `!cat <credential-path>`. To try it with an isolated agent directory:

```sh
mkdir -p "$HOME/.pi/local-llama"
cp /etc/llama-cpp/pi-models.json "$HOME/.pi/local-llama/models.json"
PI_CODING_AGENT_DIR="$HOME/.pi/local-llama" pi --provider local --model code
```

For another OpenAI-compatible harness, set its base URL to
`http://127.0.0.1:8080/v1`, model to `code` (or `text`), context to 32768 and
have it read the local key file at runtime. Compatibility requires checking
streaming and a complete tool-call/result exchange; API resemblance alone is
not a guarantee for every harness. No `vibes` import or fleet sops key is needed.

To roll back, remove the Darwin `llama-cpp` import and `myLlamaCpp` block from
`work.nix`, including its `myPi.providers.local` contribution, then rebuild.
Remove any manually copied provider example separately.
Downloaded weights and the credential remain until explicitly deleted.

## Linux (terra and amos1)

`llama-server` (llama.cpp's OpenAI-compatible HTTP API) runs on the host with
the GPU, wired up by `modules/system/llama-cpp.nix` — a thin wrapper over
nixpkgs' `services.llama-cpp` that adds a CUDA build, a sops-fed API key, and a
source-scoped firewall hole. A host enables inference with one attr set:

```nix
# modules/hosts/terra.nix
myLlamaCpp = {
  enable = true;
  cudaCapabilities = [ "12.0" ];      # RTX 5080 / Blackwell / sm_120
  models = {
    "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M" = {
      aliases = [ "vision" ];
      ctxSize = 98304;
      cacheTypeK = "q8_0";            # KV cache quantization; f16 is the default
      cacheTypeV = "q8_0";
    };
    "ggml-org/gpt-oss-20b-GGUF:MXFP4" = {
      aliases = [ "text" ];
      ctxSize = 131072;
      cacheTypeK = "q8_0";
      cacheTypeV = "q8_0";
    };
    "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q4_K_XL" = {
      aliases = [ "code" ];
      ctxSize = 131072;
      cacheTypeK = "q8_0";
      cacheTypeV = "q8_0";
      nCpuMoeLayers = 40;             # MoE experts to host RAM; weights exceed the card
    };
  };
  listenAddress = "0.0.0.0";
  allowedClients = [ "192.168.10.11" ]; # amos1 only
  sleepIdleSeconds = 600;
};
```

Two instances run today, and they are not redundant copies of each other:

| | terra | amos1 |
| --- | --- | --- |
| GPU | RTX 5080, 16 GB | RTX 3070, 8 GB, shared with Jellyfin |
| `vision` | Qwen3-VL-8B Q4_K_M @ 98304 | Qwen3-VL-4B Q4_K_M @ 32768 |
| `text` | gpt-oss-20b MXFP4 @ 131072 | Qwen3-8B Q4_K_M @ 16384 |
| `code` | Qwen3-Coder-30B-A3B UD-Q4_K_XL @ 131072 | — |
| `text-qwen` | Qwen3-14B Q4_K_M @ 40960 | — |
| resident VRAM | 13576 / 13352 / 10846 / 12226 MiB | 6080 / 6190 MiB |
| idle window | 600 s | 300 s |
| availability | only when the desktop is on | always |
| URL | `llm-terra.<serverDomain>` | `llm.<serverDomain>` |

So `llm.*` is the one to point a client at by default, and `llm-terra.*` is
the larger model of either kind when that machine happens to be up.

## Router mode: one model at a time

Each host serves a *set* of models rather than one. `llama-server` runs as a
**router**: the process that owns the port holds no model itself and spawns a
child `llama-server` per model on a loopback ephemeral port, picking the child
by the `"model"` field in the request body (or `?model=` on GET endpoints).

That exists because neither host has a single model that does everything.
Vision is the prerequisite for Tandoor photo import and paperless document AI,
and on both cards the best vision model that fits is materially weaker at text
than the generalist it displaced — terra's is 8B-class against a 14B, amos1's
4B-class against an 8B. Routing gets both back.

terra carries two more for a different reason. #518 set out to pick one model
for agentic coding and could not: gpt-oss-20b beats Qwen3-Coder-30B on every
*measured* axis (8.4x prefill, 5.1x generation, 9.5 GB less host RAM at the
same 128k context), but throughput is not code quality, and a coding specialist
against a general reasoner is a question only real sessions answer. Both are
routable by name — `text` and `code` — so the comparison is a model field
rather than a rebuild. `text-qwen` keeps the dense 14B that `text` displaced
available on the same terms.

`--models-max` is pinned to **1**. This is swap-on-demand, not concurrent
serving: terra's four are ~56 GB of models against a 16.3 GB card, amos1's pair
is 12.4 GB against 8.0 GB, and nothing fits two at once. Asking for a model that
isn't resident evicts the one that is. That costs 3–4 s on terra's NVMe with the
page cache cold, and 2–5 s on amos1 — cheap enough that the swap is not worth
designing around.

Three consequences worth knowing:

- **The `model` field is now mandatory and exact.** Single-model mode ignored
  it; the router answers `400 model name is missing from the request` without
  one and `400 model 'x' not found` for a name it doesn't have. A client that
  used to send a placeholder stops working.
- **`aliases` is the stable name to point clients at.** Both hosts register
  `text` and `vision` alongside the full `<repo>:<quant>` names, and terra adds
  `code` and `text-qwen`, so swapping the GGUF underneath a role is a change to
  `modules/hosts/<host>.nix` and not to every client. The role set is per-host:
  a client asking amos1 for `code` gets `400 model not found`, which is the
  correct answer rather than a silent downgrade.
- **The cache is a model *source*, not just storage.** The router enumerates
  `LLAMA_CACHE` as well as its preset, so a leftover GGUF from an earlier config
  is still routable — with llama.cpp defaults, since nothing sizes it. Pruning
  is therefore how the served set is kept equal to the declared one, not only
  how disk is reclaimed.

Multimodal capability is per-model and does not leak: `-hf` resolves and
downloads each repo's `mmproj` projector on its own, and in a mixed set the
text-only model reports `input_modalities: ["text"]` and rejects an image with
`image input is not supported`, while the vision model reports
`["text","image"]` and answers.

Nothing loads at service start. The first request that names a model pays its
load, which for a model not yet on disk is a multi-GB download inside that
request — `task llm:models:fetch HOST=<host>` does that warm-up deliberately,
with a timeout that expects it.

## The CUDA build is local and unavoidable

On Linux, `pkgs.llama-cpp` in this flake is a CPU build — nothing sets
`config.cudaSupport`. The module imports a second nixpkgs instance with CUDA on,
which no binary cache serves (CUDA is unfree), so the first rebuild on a host
compiles llama.cpp from scratch. Budget for it.

`cudaCapabilities` is what keeps that survivable. Left at the nixpkgs default it
builds kernels for nine architectures (7.5 → 12.1); pinned to the one the host
actually has, the compile drops to roughly a ninth of that (~10 min on terra's
16-core Ryzen). Getting the value *wrong* doesn't fail the build — it fails at
runtime with no usable kernels. RTX 5080 is `12.0`, RTX 3070 is `8.6`.

## Model files are not Nix's problem

GGUFs are gigabytes and don't belong in the store. Each `models.<name>` key is
passed straight through as `-hf <repo>:<quant>` and llama-server downloads the
weights itself, into `LLAMA_CACHE`. The module points that at the *state*
directory rather than upstream's `/var/cache/llama-cpp`, so nothing that treats
`/var/cache` as disposable can trigger a multi-GB re-download.

That download happens on first *use*, not first start, and takes as long as it
takes (~9 GB for a 14B at Q4_K_M) with working egress to huggingface.co. Do it
on purpose rather than inside somebody's request:

```sh
task llm:models:fetch HOST=terra   # one throwaway request per configured model
```

`systemctl status llama-cpp` shows nothing useful while this happens; watch the
blob instead:

```sh
sudo du -sh /var/lib/private/llama-cpp
```

Nothing outside nix's view gets garbage-collected, so old weights pile up as
`models` changes — and in router mode they stay *routable* while they do. Two
tasks handle that:

```sh
task llm:models                    # what's cached, what's routable, what's resident
task llm:models:prune              # dry run: what would go
task llm:models:prune APPLY=true   # actually delete
```

The keep-set is the declared `myLlamaCpp.models`, not what happens to be
loaded: at most one of several configured models is resident, so "keep the live
one" would delete whichever was idle. The running router is still consulted, to
prove it is on *this* generation of the config — the prune aborts unless it
answers `/v1/models` and every configured name is in the answer, so a
half-applied switch can't turn into a deletion. As a second check, any model
that *is* loaded has its `model_path` fetched and the prune aborts if that path
is in the doomed set.

What it removes: whole repos nothing configured maps to, revisions of a kept
repo other than the one `refs/main` names, superseded quants inside the current
revision, and blobs no surviving symlink points at. What it keeps: every shard
of a split model, any `mmproj*`/`mtp-*` sidecar, non-`.gguf` files, any filename
whose quant tag doesn't parse, and any `.downloadInProgress` touched in the last
hour.

## Sizing against VRAM

Every model is sized against the *whole* card, not a share of it, because only
one is resident at a time. Weights plus KV cache plus compute buffers have to
fit. KV cache is the part that surprises: at f16 Qwen3-14B is ~160 KB/token and
Qwen3-8B is ~144 KB/token, so context — not the model — is what runs a card out
of memory.

`cacheTypeK` / `cacheTypeV` are the lever. Quantizing the KV cache to `q8_0`
halves its per-token cost, and both hosts measurably buy context with it rather
than with VRAM (`f16` stays the module default, so a model opts in). Measured on
each host's `text` model:

| host | before | after | resident VRAM | generation |
| --- | --- | --- | --- | --- |
| terra (16 GB) | 16k, f16 | **40960, q8_0** | 12878 → 13768 MiB | 89.9 → 86.1 tok/s |
| amos1 (8 GB) | 8k, f16 | **16384, q8_0** | 6105 → 6199 MiB | 77.8 → 74.1 tok/s |

Both pay about 4% of generation throughput. Prompt processing pays a similar
few percent. It is not free on quality either — `q8_0` KV is a far smaller hit
than quantizing weights another step, but it is a hit, so it is worth a
subjective check on a real task before reaching for anything below `q8_0`.

The two hosts hit *different* ceilings on those models, which is why their
numbers differ (the vision models' budgets are worked through in the comments in
`modules/hosts/terra.nix` and `modules/hosts/amos1.nix`):

- **terra's `text-qwen` runs out of model, not card.** 40960 is Qwen3-14B's
  `n_ctx_train`; past it quality degrades without RoPE scaling. f16 KV at 40960
  does not fit at all (it would be ~6.4 GB of cache on top of ~9 GB of
  weights); q8_0 fits with a couple of GB spare — the deployed service reports
  40960 context at 86.8 tok/s holding 12226 MiB, with the card at 12937 of
  16303 MiB. `--no-kv-offload` would allow more still, but costs ~30%
  generation and ~40% prefill, so it is not worth reaching for here.
- **amos1 runs out of Jellyfin headroom.** The 3070's 8 GB is also NVENC
  scratch space. At 16384/q8_0 the model sits at 6199 MiB, leaving 1993 MiB —
  and with the model resident *and* generating, a 1080p `h264_nvenc` transcode
  peaks the card at 6586 MiB and a 4K `hevc_nvenc` one at 7730 MiB. Both
  succeed. 24576 does not clear that bar: 6811 MiB resident leaves 1381 MiB,
  under the ~1.5 GB a 4K transcode wants. Raising `ctxSize` there spends
  Jellyfin's margin, not spare capacity — which is also why the idle window is
  300 s rather than terra's 600 s.

## Two ways past "it doesn't fit"

The arithmetic above sizes a *dense* model with global attention. terra's two
128k models both break it, in opposite directions, and each needs a different
lever.

**Sliding-window attention makes long context nearly free — gpt-oss-20b.**
Alternating layers cap their cache at a 128-token window rather than growing it
with the prompt. Naive bytes-per-token arithmetic predicts ~3.1 GB of KV at
131072; measured, KV *and* compute buffers together come to ~1254 MiB on top of
12.1 GB of weights — 13352 MiB resident in all, for 1.5 GB of host RAM. That is the whole reason a 20B model holds 3.2x the context
of the 14B it displaced while also being faster than it (10817 vs 3282 tok/s
prefill, 189.5 vs 62.8 generation on a fixed 16,701-token prompt) — MXFP4
weights and ~3.6B active parameters of 20B do the rest. f16 KV at that context
still OOMs, so `q8_0` is a prerequisite here and not a tuning choice.

**`nCpuMoeLayers` puts a model bigger than the card on the card — Qwen3-Coder-30B.**
17.7 GB of weights against 16.3 GB of VRAM is not a context problem, and `-ngl`
is the wrong tool: dropping whole layers to the CPU drags their KV cache off the
card with them. `-ncmoe N` splits it the other way — attention and the entire KV
cache stay on the GPU while the first N layers' *expert* FFN weights live in host
RAM. An MoE activates a small fraction of its parameters per token, so the PCIe
traffic is far smaller than the resident size implies.

Fewer offloaded layers is monotonically faster, so the setting is bounded below
by VRAM and picked as the largest that leaves headroom:

| terra, Coder30B @ 131072 | VRAM | host RAM | prefill | generation |
| --- | --- | --- | --- | --- |
| `nCpuMoeLayers = 30` | 15655 MiB | 11.0 GB | 1282.8 tok/s | 37.0 tok/s |
| **`nCpuMoeLayers = 40`** | **12391 MiB** | **14.3 GB** | **1033.5 tok/s** | **30.0 tok/s** |

30 is faster and was rejected: ~650 MiB of headroom on a card also running a
GNOME session is not a margin. Deployed, 40 measures better than the bench
above — 10846 MiB resident under the router rather than 12391.

The host-RAM column needs reading carefully. Of that 14.3 GB of RSS, 13.6 GB is
`RssFile`: the offloaded experts are an mmap of the GGUF, so the kernel accounts
them as reclaimable page cache and `free` still reports ~26 GB available on a
30 GB machine. Only ~0.5 GB is anonymous. So it is much kinder to a desktop than
"14 GB gone" implies — but not free, because reclaiming those pages means
re-reading experts from NVMe per token, and the throughput above assumes they
stay resident. `sleepIdleSeconds` hands back VRAM, not this.

262144, the model's native limit, does not fit at any offload level: compute
buffers fail to allocate before the KV cache is even the constraint.

`sleepIdleSeconds` exists because terra is a gaming machine first — after the
idle window llama-server sleeps and hands the VRAM back. Measured on terra:
12.2 GB down to 1.7 GB at the 600 s mark, and ~3 s to wake on the next request
(the GGUF is still in page cache, so nothing is re-read from disk). `/health`
keeps answering while asleep and doesn't reset the timer.

Router mode does not change this — the flag is passed to the router and
inherited by every child, so it is uniform across a host's models by
construction. It is a separate mechanism from `--models-max` eviction and both
apply: a sleeping model still counts as loaded, so asking for a different model
unloads the sleeper outright rather than waiting for it to wake.

## The model cache under impermanence

Servers run impermanence, so llama-server's downloaded GGUFs would be wiped on
every reboot without a preservation entry — several GB of re-download per boot.
`modules/apps/llm.nix` preserves `/var/lib/private/llama-cpp` through
`myAppState` with `backup = false`: the declaration renders the preservation
entry but contributes no restic path, because a GGUF has no business in a
nightly snapshot. It is re-downloadable bytes, not state anyone authored. Same
reasoning as sabnzbd's incomplete dir — preserve-only, declared in the module
that owns the path, so the structural guard still asserts it stays preserved on
hosts that run the daemon.

That also means there is no `recovery:` dispatcher for it: nothing of it is in
restic to restore. After a catastrophic rebuild the model re-downloads on first
start.

A preservation bindmount hands the unit a `root:root 0700` directory on a fresh
boot, which looks wrong for a DynamicUser service. It isn't — systemd chowns an
existing `StateDirectory` to the on-disk sentinel (`nobody:nogroup 0755`) before
`ExecStart`, and the unit writes through the idmapped mount normally.

## Fronting a workstation from a server

terra imports the `workstation` profile: no caddy, no authentik, no tailscale.
Rather than replicate that stack onto a desktop, the servers proxy to it —
`modules/apps/llm-terra.nix` is a route-only module (no service, no state, hence
no `recovery:` dispatcher) that registers a `myAuthentik.forwardAuthApps` entry
pointing at `terra.ipreston.net`. Both hpp-1 and amos1 import it, so the same
backend answers on `llm-terra.dnix.ipreston.net` and
`llm-terra.amos.ipreston.net`; TLS terminates on each server's existing wildcard
cert.

Two things that follow from that shape:

- **`upstreamHost`.** `myAuthentik.forwardAuthApps` gained an `upstreamHost`
  option (default `localhost`) for exactly this. Only point it at a backend that
  has its own auth on whatever paths you bypass — the hop is plaintext HTTP over
  the LAN.
- **The address has to be pinned.** `terra.ipreston.net` is registered by the
  router from terra's DHCP lease, so terra needs a DHCP reservation (one is in
  place) or the route drifts. terra is also a desktop that gets powered off; the
  route 502s while it's down, which is expected rather than a fault.

## Why the `/v1/*` bypass is conditional

OpenAI-compatible clients send a bearer token and can't follow an authentik
login redirect, so the API paths bypass forward-auth and are gated by
llama-server's own `--api-key` instead — the same "app has its own key auth on
this sub-path" pattern as radarr's `/api/*`.

Path alone turned out to be the wrong condition. llama-server enforces its key
on nearly everything it serves — `/props` and `/slots` as well as
`/v1/chat/completions`, with only `/`, `/index.html` and the bundles public — so
the web UI would load and then prompt the human for a shared API key they had
just earned by logging into authentik. Gating on SSO and then demanding the
shared secret anyway defeats the SSO.

So `myAuthentik.forwardAuthApps.<app>.upstreamBearerEnvVar` names an env var in
caddy's `EnvironmentFile`, and when it's set the route changes shape: the
bypass additionally requires an `Authorization` header (catching API clients,
not browsers), and the authentik-gated branch injects the token upstream
itself. A browser logs into authentik and just works; an API client presents
its own token, which passes through untouched.

That also closed a leak this route previously accepted. llama-server treats
`/v1/models` and `/v1/health` as *public* — served with no key even when
`--api-key` is set — so a plain path bypass left the model list readable
without credentials. With the header condition, an unauthenticated request to
`/v1/*` lands on authentik instead of reaching llama-server at all.

Router mode made that closure worth more, because `/v1/models` now enumerates
every model the router knows *and* each one's full child argv and rendered
preset — store path, context size, cache types. The API key is not among them:
llama.cpp strips `LLAMA_API_KEY` from the preset before rendering a child's
argv, and the child picks it up from the inherited environment instead. So it is
a fingerprinting leak rather than a credential one, and the header condition is
what keeps it off the public hostname.

The key comes from sops via `LLAMA_API_KEY` in an `EnvironmentFile`, never
`--api-key` on the command line: `/proc/*/cmdline` and `/nix/store` are both
world-readable. It lives in `llm.yaml` rather than a per-host file because
terra and both servers need it, and `llm.yaml` lists exactly the hosts that read
a llama key.

## Evaluating a model

Model selection is decided per alias on one host. The published contract eval
tooling reads (`myLlamaCpp.evalTargets`), the private fixtures layout and the
design rationale are in the
[`_llama-cpp` README](../../modules/system/_llama-cpp/README.md#evaluation-555);
the end-to-end candidate workflow, including the privacy rule for fixture
material, is the [`llm-eval` skill](../../skills/llm-eval/SKILL.md). The tasks
it drives, each taking one host and one router name:

- **`task llm:gate HOST=<host> ALIAS=<alias> [MODEL=<router name>]`**
  is tier 0. It runs pass/fail probes of `MODEL` (default: the alias's
  incumbent) against what `ALIAS` needs on that host:
  - `tool-call`: a synthetic tool call comes back parseable and honours
    the schema's enum.
  - `tool-round-trip`: once the tool result is sent back, the model
    answers with it.
  - `image-input`: only checked for aliases that need images.
  - `context`: the alias's full `contextTokens`, less room for the
    answer, is filled and a needle placed early is recalled.
  - `modalities`: what the server reports against the target.
  - `vram`: the model's own llama-server child, measured with
    `nvidia-smi` after the long request, against `residentBudgetMiB`.
    It fails if the model is served at a smaller context than the
    target, because the KV cache it would need wasn't allocated.

  Every probe is synthetic, so the table it prints can go straight
  into an issue. It needs no fixtures and exits non-zero on any failure.
- **`task llm:eval HOST=<host> MODEL=<router name> TRIALS=3 [ALIAS=…] [FEATURE=…]`**
  is tier 1. It replays the private fixtures and writes scored results
  into the fixtures repo's `results/`. `ALIAS` limits the run to cases
  whose `meta.toml` targets that alias. Per-case spread is about ±3
  checks out of 40, so `TRIALS=3` is the minimum for a comparison.
- **`task llm:eval:compare RUNS="<run dir> …" [PUBLIC=true]`** renders
  runs side by side. Without `PUBLIC=true` the output is private: its
  failed-check labels (`tags:must:<name>`) carry expected values.
  `PUBLIC=true` reduces them to field and rule kind.
- **`task llm:eval:audit FILE=<draft>`** fails if a draft comment or PR
  body names any expected value. Run it before anything eval-derived
  goes on GitHub, since hand-written prose is the one path `PUBLIC=true`
  doesn't cover.

## Driving it from a coding agent

### Coding sandboxes

`work` (macOS, VZ) and the `terra` and `luna` workstations (NixOS, QEMU/KVM)
carry a Lima launcher for isolated coding and demo projects. Its visible per-project mount specification, pinned tool and agent bundles, network grants and
lateral boundary, hardened/open modes, per-session GitHub credential grants,
VM lifecycle, cache behaviour, and current limits are in the
[coding sandbox guide](../coding-sandbox.md).

`modules/programs/pi.nix` owns pi's Nix package and the single
`~/.pi/agent/models.json` writer on Linux and macOS. Enable it with
`myPi.enable = true` and contribute providers through `myPi.providers`.
Providers have typed URL, API, credential-reference and model fields, with
extensible JSON metadata for each API's compatibility flags. Duplicate model
IDs within a provider fail evaluation. Credentials are runtime references,
never token values embedded in Nix.

`vibes` imports this module and contributes the Linux inference providers;
`work` imports it directly and contributes the local Metal provider. Internal
work endpoints, model lists and OAuth helper commands live in the private
`nix-secrets` work Home Manager module, which contributes to the same option.
Each enabled host gets one Nix-managed pi installation, without pulling the
rest of `vibes` into the Mac.

For the first macOS activation, Home Manager backs up the existing regular
`models.json` using the configured `.hm-backup` extension. Check that any
existing providers have been migrated before switching. After a successful
rebuild, remove the old global npm install so Homebrew's earlier PATH entry
cannot shadow Nix's pi:

```sh
npm uninstall --global @earendil-works/pi-coding-agent
rehash
command -v pi
pi --version
```

Use plain `pi` for the combined configuration. `ug pi` uses its own agent
directory and generated provider overlay; it remains a separate launch mode.

`modules/programs/vibes.nix` also carries Claude Code and
[opencode](https://github.com/sst/opencode). Its pi and opencode providers can
both drive the fleet's GPUs:

| agent | config file | credential form |
| --- | --- | --- |
| pi | `~/.pi/agent/models.json` | `!cat <path>` |
| opencode | `~/.config/opencode/opencode.json` | `{file:<path>}` |

Both get the same six entries — `text` and `vision` on `amos1`, plus `code` and
`text-qwen` alongside those two on `terra` — rendered from one `llamaHosts`
attrset in that module rather than written twice. It mirrors each host's
`myLlamaCpp.models` and has to be edited in lockstep with it. The two agents disagree about nearly every field name
(`contextWindow` vs `limit.context`, `input` vs `modalities.input`) but not
about the facts.

Both use the flake's pinned `nixpkgs-unstable` packages, served by
`cache.nixos.org`. pi's community flake would add transitive inputs and a
separate update cadence for features this setup does not need.

Five things make this work, none of which needed a server-side change:

- **The model ids are the routers' `aliases`, not GGUF names.** `text`,
  `code`, `text-qwen` and `vision` survive swapping the weights underneath; the
  `<repo>:<quant>` names would not. That is what makes #518's open question —
  which model actually writes better patches — a picker entry rather than a
  rebuild.
- **Tool calling is already on.** llama.cpp rejects a `tools` param without
  `--jinja` — but `--jinja` defaults to *enabled* in b9190, so `myLlamaCpp`
  inherits it and a full agent loop (bash tool → answer) works from both agents
  against both hosts as deployed.
- **No OpenAI-compat shims.** llama-server accepts the `developer` role and
  takes `reasoning_effort` — ignoring it for Qwen3 rather than 400ing, and
  honouring it for gpt-oss — so pi's `compat` escape hatches stay unset and
  opencode's stock `@ai-sdk/openai-compatible` needs nothing beyond a URL and a
  key.
- **opencode's ai-sdk provider is bundled, not fetched.** Naming an `npm`
  package in a provider block normally implies a runtime install; this one ships
  inside the binary, so the config works on a host that has never reached the
  npm registry.
- **The key is read at request time, not baked in.** Both configs land in
  `/nix/store` and are world-readable, so each references a home-manager sops
  secret by path — the same `llm.yaml` key llama-server enforces. Rotation
  needs no rebuild.

Thinking is always on, and the lever differs per model. The Qwen3 models are
hybrid-thinking and `reasoning_effort` doesn't gate them, so pi's
`--thinking off` can't suppress the `<think>` pass;
`chat_template_kwargs.enable_thinking = false` does, via a model's
`samplingParams` (pi) or `options` (opencode). gpt-oss reasons through the
harmony format instead, where `reasoning_effort` *is* a real knob
(low/medium/high, default medium). Both are left unset — reasoning earns its
tokens for agentic work — and are worth reaching for only if a small-context
model is burning its window on preamble.

Both providers point at caddy, including on terra itself, so terra's own
requests loop out to amos1 and back rather than hitting its loopback port. That
buys one identical file on every host in exchange for a hop on a wired segment.
`terra` 502s whenever that desktop is off; pick an `amos1` model instead.

Two things stay unmanaged on purpose. pi's `settings.json` is written by pi
itself (`/model` Ctrl+S, `pi install`), so it is left alone — `models.json` is
the read-only half and the only one symlinked. opencode has no such split:
providers share `opencode.json` with everything else, so managing providers
means managing the file, and the cost is that `opencode plugin --global` can't
rewrite it (declare plugins in the module instead). Project-local
`opencode.json` still layers on top, and `opencode providers` writes credentials
to a separate `auth.json`.

penguin is the exception to all of it. It is a standalone home-manager config
with no sops, so it gets both agents with no local-inference providers rather
than entries pointing at a key file that will never exist.

## Tandoor's AI features

The first app in the fleet pointed at these endpoints rather than a paid API.
Tandoor uses AI for recipe import from an image, for sorting steps and
assigning ingredients to them, and for extracting food and recipe properties —
all of it through LiteLLM, so an OpenAI-compatible endpoint is all it wants.
Upstream also offers PDF import; that one cannot work here, for a reason worth
knowing about below.

The split between what the flake owns and what it doesn't is unusually sharp
here. The **provider** — model name, API key, base URL — is a database row
created in the UI, not config, and a rebuild will not reproduce it. What
`modules/apps/tandoor.nix` does own is `AI_ALLOWED_URLS`, an allowlist that
defaults to empty and that every provider URL is checked against before the
call is made. It is Tandoor's SSRF guard, since the URL is user-supplied, and
without it the feature cannot run at all.

Its value is derived from the host's own `myAuthentik.forwardAuthApps` entries
— the ones carrying `upstreamBearerEnvVar = "LLAMA_API_KEY"`, which is what
identifies a route as a llama-server one — so hpp-1 allows terra's route,
amos1 allows its own and terra's, and a host with neither (tests-server) gets
an empty string and no AI. Both the slashed and unslashed spelling of each
base URL are listed, because the check is an exact string match against a
field a human types and LiteLLM treats the two identically.

Nothing else in the stack needed changing. Tandoor sends the provider's API key
as a bearer token, so the request lands on the `@bypass_auth` branch of the
route (`/v1/*` plus an `Authorization` header) and llama-server's own
`--api-key` gates it. Caddy sets no response timeout and no body limit, and
gunicorn already runs `--threads 2`, which puts it on the `gthread` worker whose
arbiter heartbeat is not held up by a slow request — a synchronous AI call is
therefore not on a 30-second clock.

Two settings live in the UI and are easy to get wrong:

- **Model name takes LiteLLM's provider prefix** — `openai/vision`, not
  `vision`. LiteLLM strips it again on the wire, so the router still sees the
  alias. Image import needs the vision model; the other three features are
  text-only and `openai/text` is cheaper for them.
- **PDF import doesn't work against llama-server, on any model.** Tandoor never
  rasterizes: when PIL can't open the upload it posts the bytes as an
  `image_url` part with a `data:application/pdf;base64,` URI, and llama.cpp's
  multimodal path takes `data:image/` only. It comes back as
  `InternalServerError: Invalid url format: data:application/pdf` — unhandled,
  so the operator sees a 500 rather than Tandoor's provider-error message.
  Photograph or screenshot the page and import that.
- **Turn "log credit cost" off.** Tandoor meters every call against a monthly
  credit ceiling, priced from LiteLLM's estimate for the model — which it has no
  price list for when the model is local. The flag gates the whole computation,
  so switching it off retires the ceiling along with the accounting, and the
  space's credit balance never binds. That is why none of the
  `SPACE_AI_CREDITS_*` variables are set.
