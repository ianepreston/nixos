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

Router mode (#519)

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

Model files

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

CUDA build

`pkgs.llama-cpp` in this flake is a CPU build (nothing sets
`config.cudaSupport`), so a separate nixpkgs instance is imported with
CUDA on and `cudaCapabilities` pinned to the *one* architecture the host
actually has. That pin matters: the nixpkgs default builds nine
architectures (7.5 through 12.1), and the CUDA kernels dominate the
build. Scoping to one cuts the compile by roughly that factor.

CUDA is unfree and no binary cache serves it, so this always builds
locally the first time. Budget for it — it is not a `nixos-rebuild`
you want to start five minutes before you need the machine.
