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

The operator-facing contract (the mandatory, exact `model` field, `aliases` as
the stable name to point clients at, swap-on-demand and its measured cost)
is owned by the runbook's
[Router mode](../../../docs/runbooks/local-llm.md#router-mode-one-model-at-a-time) section. What follows is
the mechanism behind it that explains odd wiring in this module.

**The cache is a model source, not just storage.** The router always
enumerates `LLAMA_CACHE` in addition to the preset, deriving a name of
`<repo>:<TAG>` per cached GGUF, so keeping the cache pruned is a
correctness concern (the
[runbook](../../../docs/runbooks/local-llm.md#model-files-are-not-nixs-problem) owns the prune
procedure).

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

`--models-max` is pinned to 1 rather than exposed as an option: on the
Linux hosts that run this, no two configured models fit in VRAM at once
(see #524), so this is deliberately swap-on-demand, not concurrent serving.
The measured costs are in the runbook. Swapping is not uniformly cheap,
though: a model with `nCpuMoeLayers` set also has to stream its offloaded
expert weights back into host RAM, so terra's `code` is the slow one to
bring up.

## Model files and the CUDA build

Both are operator procedures and live in the runbook: how GGUFs are fetched
into `LLAMA_CACHE` and pruned
([Model files](../../../docs/runbooks/local-llm.md#model-files-are-not-nixs-problem)), why
the cache sits in the state directory rather than `/var/cache`, and why the
CUDA build is local and pinned to one architecture
([The CUDA build](../../../docs/runbooks/local-llm.md#the-cuda-build-is-local-and-unavoidable)).
One fact belongs here because it was verified against the pinned build: a
vision model's mmproj needs no declaration and does not leak across models in
the same router (at b9190 a text-only model in the same preset reported
`input_modalities: ["text"]` while the vision model reported
`["text","image"]`).

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

The radar's sizing and issue-deduplication policy has offline unit tests
(`scripts/llm-radar-test.py`), run by CI and `task check` as the `llm-radar`
flake check: `nix build .#checks.<system>.llm-radar`.

**Fixtures live in the private sibling checkout `../nix-eval-fixtures`**
(`ianepreston/nix-eval-fixtures`). Like `../nix-secrets` it sits next to
this repo, but unlike it it is *not* a flake input: the harness reads it
at runtime, so adding a fixture needs no `flake.lock` bump or rebuild,
and the harness skips the fixture tiers when the checkout is absent.
Its README is authoritative for layout, `meta.toml`, and capture.

The privacy rule for fixture material is stricter than this repo's PII rule,
because a published fixture also stops working as an eval once it is in a
training corpus. The
[`llm-eval` skill](../../../skills/llm-eval/SKILL.md#the-privacy-rule-in-one-place)
owns that rule and its two mechanical guards.

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

The task reference (`task llm:gate`, `llm:eval`, `llm:eval:compare`,
`llm:eval:audit`) is in the runbook's
[Evaluating a model](../../../docs/runbooks/local-llm.md#evaluating-a-model) section, and the
end-to-end candidate procedure (serve a temporary peer, gate, replay,
verdict, adopt or drop) is the
[`llm-eval` skill](../../../skills/llm-eval/SKILL.md).
