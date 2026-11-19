# llama.cpp inference
Runs llama.cpp's `llama-server` (OpenAI-compatible HTTP API) on a host
with an NVIDIA GPU. Thin wrapper over nixpkgs' `services.llama-cpp`
that adds this flake's cross-cutting concerns: a CUDA build scoped to
the host's GPU, a sops-fed API key, and a source-scoped firewall hole
for hosts that serve other machines on the LAN.

Deliberately daemon-only. The HTTPS/authentik front door is *not* part
of this module: on a server the route is a `myAuthentik.forwardAuthApps`
entry next to the rest of the app fleet, and terra (a workstation, no
caddy/authentik/tailscale) is fronted by a route on amos1 instead. See
`modules/hosts/amos1.nix` for that side.

## Router mode (#519)

llama-server runs as a **router**: the main process holds no model and
instead spawns one child llama-server per model on a loopback ephemeral
port, routing each request by the `"model"` field in the body (or the
`?model=` query param on GET). That is what lets a host serve more than
one model without a config edit and a rebuild — which matters because
there is no single best model per host (see #517/#518/#524: vision and
generalist capability do not fit in one GGUF that fits these cards).

Three things follow from the mechanism and are worth knowing before
editing this file:

**The `model` field is mandatory and exact.** A request with no `model`
gets `400 model name is missing from the request`; an unrecognised name
gets `400 model 'x' not found`. Single-model mode ignored the field
entirely, so any client that sent a placeholder ("gpt-3.5-turbo") stops
working. `aliases` exists for this: it registers extra router-level
names for a model, so a client can be pointed at a stable role name
("vision") that survives swapping the GGUF underneath it.

**The cache is a model source, not just storage.** The router always
enumerates `LLAMA_CACHE` in addition to the preset, deriving a name of
`<repo>:<TAG>` per cached GGUF. So a leftover model from a previous
config still shows up in `/v1/models` and is still routable — with only
llama.cpp defaults applied, since no preset section names it. Keeping
the cache pruned (`task llm:models:prune`) is therefore a correctness
concern here, not just a disk one.

A pruned cache is not sufficient, though, because that `<TAG>` is
derived from the *filename* rather than from whatever `-hf` asked for:
`common_list_cached_models` takes `get_gguf_split_info(path).tag`, which
is the last `[-.]([A-Za-z0-9_]+)` run in the name. For a quant whose tag
carries a prefix the filename keeps but the derivation drops — unsloth's
`UD-` dynamic quants are the case in the fleet — the scan invents a
*second* name for a file the preset already names, and the two do not
merge because they are not spelled the same. terra therefore serves
`unsloth/…-GGUF:Q4_K_XL` alongside the configured `:UD-Q4_K_XL`, both
resolving to the same 17 GB of weights, one of them with no `ctxSize`
and no `nCpuMoeLayers`. Nothing configures this away: `load_from_cache`
is unconditional and there is no flag to skip it. Treat an unaliased
entry in `/v1/models` as suspect, check it against the cache listing
(`task llm:models`) before assuming it is prunable garbage, and don't
point a client at one.

**Router CLI flags outrank the preset.** llama.cpp merges the router's
own argv into every child's preset at *highest* precedence, so a `-c` on
the router would silently override every model's `ctxSize`. Anything
model-shaped must live in `models.<name>`; only genuinely service-wide
flags belong in `extraFlags`.

`--models-max` is pinned to 1 below rather than exposed as an option:
on the Linux hosts that run this, no two configured models fit in VRAM at
once (terra ~56 GB of models against a 16.3 GB card, amos1 12.4 GB
against 8.0 GB — see #524). This is deliberately swap-on-demand, not
concurrent serving. Measured swap cost on terra's NVMe is 3-4 s, cold
page cache included, so the trade is cheap.

Swapping is not uniformly cheap across the set, though: a model with
`nCpuMoeLayers` set also has to stream its offloaded expert weights
back into host RAM, so terra's `code` is the slow one to bring up.

## Model files

GGUFs are gigabytes and are not nix-store material, so they are *not*
fetched by nix. Each `models.<name>` attribute name is the `<repo>:<tag>`
llama-server resolves as `-hf`, and it downloads the weights itself into
`LLAMA_CACHE`. That directory is overridden below from the upstream
module's `/var/cache/llama-cpp` to the state directory, so
`systemctl clean --what=cache llama-cpp` (or anything else that treats
/var/cache as disposable) doesn't silently trigger a multi-GB re-download.

Nothing loads at service start: a model is downloaded and loaded by the
first request that names it. So the first request for an uncached model
blocks for the whole download and will almost certainly time out at the
client, though the download itself continues and a later retry is a
cache hit. `task llm:models:fetch HOST=<host>` does that warm-up
deliberately, with a timeout that expects it.

A vision model's mmproj (the projector) needs no declaration: `-hf`
resolves and downloads it per model, and it does not leak across models
in the same router — verified at b9190, where a text-only model in the
same preset reports `input_modalities: ["text"]` while the vision model
reports `["text","image"]`.

## CUDA build

`pkgs.llama-cpp` in this flake is a CPU build (nothing sets
`config.cudaSupport`), so a separate nixpkgs instance is imported with
CUDA on and `cudaCapabilities` pinned to the *one* architecture the host
actually has. That pin matters: the nixpkgs default builds nine
architectures (7.5 through 12.1), and the CUDA kernels dominate the
build. Scoping to one cuts the compile by roughly that factor.

CUDA is unfree and no binary cache serves it, so this always builds
locally the first time. Budget for it — it is not a `nixos-rebuild`
you want to start five minutes before you need the machine.

## Evaluation (#555)

Model selection is decided per **alias** on one host: a candidate is
challenger-vs-incumbent for `text`, `vision` or `code`, never "is this
model good". Two pieces feed that:

**`myLlamaCpp.evaluation`** is the published contract for eval tooling:
the host's resident VRAM budget, plus each alias's role and modalities,
with the active context, KV-cache types and MoE offload filled in from
`models.<name>`. It's rendered read-only as `myLlamaCpp.evalTargets`,
which `task llm:radar` (the `model-radar` skill) and `task llm:gate`
read. Eval code reads that export and never the router's private preset.

**Fixtures live in the private sibling checkout `../nix-eval-fixtures`**
(`ianepreston/nix-eval-fixtures`). Like `../nix-secrets` it sits next to
this repo, but unlike it it is *not* a flake input: the harness reads it
at runtime, so adding a fixture needs no `flake.lock` bump or rebuild,
and the harness skips the fixture tiers when the checkout is absent.
Its README is authoritative for layout, `meta.toml`, and capture.

The privacy rule is stricter than this repo's PII rule, because a
published fixture also stops working as an eval once it's in a training
corpus. Nothing from a fixture goes in this repo, its issues or its PRs:
not source documents, captured request bodies, prompts, expected values,
or raw responses. Fixture IDs, hashes, schemas, aggregate and per-field
scores, and the adoption verdict are fine.

Fixtures are organised per *app feature*, one directory per LLM call
an app actually makes (`tandoor-image-import`, `paperless-classify`,
`minuspod-ads`, …), and each case replays the app's real
`/v1/chat/completions` body. That's because the app's own system
prompt, JSON schema and tool list affect the result as much as the
model does. Bodies are captured with a packet capture on amos1, where the
production apps run: every hop to a llama-server is plain HTTP (amos1's
loopback `:8091`, terra's LAN `:8080`), whether it goes through Caddy or,
like paperless, straight to terra.

### Running it

Every task takes one host and one router name:

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

### Evaluating a candidate

The `llm-eval` skill (`skills/llm-eval/SKILL.md`) runs this procedure
from an `llm-candidate` issue through to a sanitized verdict comment and
the adopt/drop PR. The steps:

1. **Serve it as a temporary peer.** Add a `models."<repo>:<tag>"`
   entry with its own alias (`aliases = [ "text-next" ]`) and the
   context, KV types and offload the target needs, then deploy. Don't
   point the alias at it yet: the incumbent stays routable for the
   comparison. And don't rely on a GGUF that's only in the cache, since
   that runs with llama.cpp defaults (see the cache section above).
2. **`task llm:models:fetch HOST=<host>`** downloads it ahead of the
   first request.
3. **`task llm:gate HOST=<host> ALIAS=text MODEL=text-next`** must pass.
   A model that can't hold the alias's context fails `context` and
   `vram` here.
4. **`task llm:eval ALIAS=<alias>`** runs the candidate and the
   incumbent with `TRIALS=3` each. Then run `task llm:eval:compare`, and
   `PUBLIC=true` for anything headed to the issue.
5. **Adopt or drop it.** To adopt, move the alias onto the candidate's
   entry, and remove the old entry or keep it as a named peer. To drop,
   delete the entry. Either way, run `task llm:models:prune` afterwards.
