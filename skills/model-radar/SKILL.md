---
name: model-radar
description: Review local-LLM leaderboard leads and publish human-approved candidate evaluation issues.
---

# Model radar

Run `task llm:radar` first. It collects the agreed public leaderboard sources
(LiveBench, Aider Polyglot, SWE-bench Verified, BFCL, OCRBench v2 and
olmOCR-Bench) and exports the current fleet evaluation targets. Its first
report classifies incomplete leads as pending; it creates no issue and
downloads no model.

Review the lead report at `${XDG_CACHE_HOME:-$HOME/.cache}/nixos-llm-radar/leads.json`.
Community posts can supply context, but they are leads only. Do not promote one
until it has all of:

- a primary Hugging Face model repository;
- one exact GGUF artifact (or a complete shard set) in a Hugging Face
  repository;
- the source URL and published score that make it worth considering; and
- `config.json` content sufficient for the radar's KV calculation.

The collector admits only likely open-weight, standalone families above each
source's role-specific score floor, deduplicates family/template variants, and
keeps the top five per source and role. A source whose page no longer exposes a
supported scored table is reported as `no-shortlist`, never silently treated as
an empty leaderboard.

Place the reviewed records in a local, disposable JSON file. Its top level is
an array; each record uses this shape:

```json
{
  "family": "Example-7B-Instruct",
  "revision": "v1.2",
  "roles": ["coding"],
  "modalities": ["text"],
  "sourceUrl": "https://example.invalid/leaderboard",
  "publishedScores": {"LiveBench": 42.0},
  "primaryRepo": "org/example",
  "artifactRepo": "org/example-GGUF",
  "artifactFiles": ["example-q4_k_m.gguf"]
}
```

Run `task llm:radar CANDIDATES=/absolute/path/to/candidates.json`. The script
fetches the primary `config.json` and exact declared GGUF/shard sizes itself,
then does the reproducible policy work: standard KV sizing, explicit 1-GiB
compute-buffer reserve, manual-review classification for sliding-window/MoE
architectures, target/runtime fingerprints, and GitHub deduplication across
open and closed `llm-candidate` issues. The role list restricts a coding lead
to the `code` alias rather than drafting an irrelevant generalist comparison.
It writes drafts only.

Read every draft. In particular, `manual-review` means the configuration is
not enough to claim it fits; it is a retained candidate, not an approval.
Reject missing/ambiguous artifact evidence instead of guessing a quant or
shard set. Re-run the same inputs once and confirm there are no new drafts.

For a human-approved draft, create exactly one issue labelled `llm-candidate`
with the rendered title/body. Do not add a model to `myLlamaCpp.models`,
download a GGUF, or run an eval. Record its final accepted/deferred/rejected
reason in that issue; GitHub is the durable ledger. The local cache and
candidate JSON are disposable.
