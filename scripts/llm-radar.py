#!/usr/bin/env python3
"""Collect, size and draft review-only local-LLM candidate issues.

This is intentionally stdlib-only. Network sources are leads, not authority:
only a primary Hugging Face config and an exact GGUF artifact can reach a draft.
"""

from __future__ import annotations

import argparse
import hashlib
import html.parser
import json
import subprocess
import urllib.request
from pathlib import Path
from typing import Any

SOURCES = {
    "livebench": "https://livebench.ai",
    "aider-polyglot": "https://aider.chat/docs/leaderboards/",
    "swe-bench-verified": "https://www.swebench.com/",
    "bfcl": "https://gorilla.cs.berkeley.edu/leaderboard.html",
    "ocrbench-v2": "https://ocrbench.github.io/",
    "olmocr-bench": "https://olmocr.ai/",
}
CACHE_BYTES = {
    "f32": 4,
    "f16": 2,
    "bf16": 2,
    "q8_0": 1,
    "q5_0": 0.625,
    "q5_1": 0.625,
    "q4_0": 0.5,
    "q4_1": 0.5,
    "iq4_nl": 0.5,
}


class TableText(html.parser.HTMLParser):
    """Small, dependency-free table reader for leaderboard pages."""

    def __init__(self) -> None:
        super().__init__()
        self.rows: list[list[str]] = []
        self.row: list[str] | None = None
        self.cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "tr":
            self.row = []
        elif tag in {"td", "th"} and self.row is not None:
            self.cell = []

    def handle_data(self, data: str) -> None:
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag in {"td", "th"} and self.cell is not None and self.row is not None:
            self.row.append(" ".join("".join(self.cell).split()))
            self.cell = None
        elif tag == "tr" and self.row:
            self.rows.append(self.row)
            self.row = None


def fetch(url: str) -> Any:
    request = urllib.request.Request(url, headers={"User-Agent": "nixos-llm-radar/1"})
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 -- fixed HTTPS sources
        return (
            json.load(response)
            if "json" in response.headers.get("Content-Type", "")
            else response.read().decode()
        )


def fetch_json(url: str) -> Any:
    value = fetch(url)
    return json.loads(value) if isinstance(value, str) else value


def collect() -> list[dict[str, Any]]:
    """Return leaderboard rows as leads; interpretation remains human work."""
    leads = []
    for name, url in SOURCES.items():
        try:
            page = fetch(url)
        except Exception as exc:  # source breakage is an expected non-fatal outcome
            leads.append(
                {
                    "source": name,
                    "url": url,
                    "status": "unavailable",
                    "detail": str(exc),
                }
            )
            continue
        parser = TableText()
        parser.feed(page if isinstance(page, str) else json.dumps(page))
        count = 0
        for row in parser.rows[:100]:
            if row:
                count += 1
                leads.append(
                    {
                        "source": name,
                        "url": url,
                        "status": "lead",
                        "family": row[0],
                        "sourceUrl": url,
                        "model": row[0],
                        "evidence": row,
                    }
                )
        if count == 0:
            leads.append(
                {
                    "source": name,
                    "url": url,
                    "status": "no-machine-readable-leads",
                    "detail": "source fetched but exposed no HTML table rows",
                }
            )
    return leads


def bytes_per_token(
    config: dict[str, Any], key_type: str, value_type: str
) -> float | None:
    layers = config.get("num_hidden_layers") or config.get("n_layer")
    kv_heads = config.get("num_key_value_heads") or config.get("n_head_kv")
    head_dim = config.get("head_dim") or config.get("hidden_size", 0) // config.get(
        "num_attention_heads", 1
    )
    if not all(
        isinstance(value, int) and value > 0 for value in (layers, kv_heads, head_dim)
    ):
        return None
    return (
        layers * kv_heads * head_dim * (CACHE_BYTES[key_type] + CACHE_BYTES[value_type])
    )


def architecture_needs_review(config: dict[str, Any]) -> str | None:
    if any(key in config for key in ("sliding_window", "max_window_layers")):
        return "sliding-window attention needs a measured residency; full-attention KV arithmetic is invalid"
    if any(
        key in config
        for key in ("num_local_experts", "num_experts", "n_routed_experts")
    ):
        return "mixture-of-experts residency depends on an explicit offload plan"
    return None


def target_fingerprint(target: dict[str, Any]) -> str:
    canonical = json.dumps(target, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def assess(
    candidate: dict[str, Any],
    host: str,
    alias: str,
    target: dict[str, Any],
    budget_mib: int,
) -> dict[str, Any]:
    """Classify a fully evidenced candidate; unknown architectures fail open."""
    config = candidate["config"]
    review = architecture_needs_review(config)
    bpt = bytes_per_token(config, target["cacheTypeK"], target["cacheTypeV"])
    result = {
        "host": host,
        "alias": alias,
        "fingerprint": target_fingerprint({"budgetMiB": budget_mib, **target}),
        "bytesPerToken": bpt,
        "weightMiB": round(candidate["weightBytes"] / 1024 / 1024, 1),
        "contextTokens": target["contextTokens"],
    }
    if review:
        return result | {"disposition": "manual-review", "reason": review}
    if bpt is None:
        return result | {
            "disposition": "manual-review",
            "reason": "config lacks standard KV dimensions",
        }
    # 1 GiB is deliberately explicit headroom for compute/graph buffers. This
    # is a shortlist calculation, not a statement a model will load.
    estimate = candidate["weightBytes"] + bpt * target["contextTokens"] + 1024**3
    result["estimatedResidentMiB"] = round(estimate / 1024 / 1024, 1)
    if estimate > budget_mib:
        return result | {
            "disposition": "reject",
            "reason": "standard estimate exceeds resident budget",
        }
    return result | {
        "disposition": "draft",
        "reason": "standard estimate is within resident budget",
    }


def issue_marker(candidate: dict[str, Any], result: dict[str, Any]) -> str:
    identity = f"{candidate['family']}|{candidate['revision']}|{candidate['artifact']}|{result['host']}|{result['alias']}"
    return f"<!-- llm-radar identity={identity} fingerprint={result['fingerprint']} -->"


def is_duplicate(marker: str, issues: list[dict[str, Any]]) -> bool:
    return any(marker in issue.get("body", "") for issue in issues)


def render_draft(candidate: dict[str, Any], result: dict[str, Any]) -> dict[str, str]:
    marker = issue_marker(candidate, result)
    title = (
        f"llm: evaluate {candidate['family']} for {result['host']} {result['alias']}"
    )
    body = "\n".join(
        [
            marker,
            "## Candidate evidence",
            f"- Primary config: {candidate['configUrl']}",
            f"- Exact GGUF artifact: `{candidate['artifact']}` ({result['weightMiB']} MiB)",
            f"- Source: {candidate['sourceUrl']}",
            f"- Published scores: {json.dumps(candidate['publishedScores'], sort_keys=True)}",
            "",
            "## Fleet target",
            f"- `{result['host']}` alias `{result['alias']}` challenges `{candidate['incumbent']}` at {result['contextTokens']} tokens.",
            f"- K/V cache: `{candidate['cacheTypeK']}` / `{candidate['cacheTypeV']}`; resident budget: {candidate['budgetMiB']} MiB.",
            f"- Disposition: **{result['disposition']}** — {result['reason']}.",
            "",
            "## Next step",
            "Human review decides whether to download and run the tiered evals; this issue changes no model configuration.",
        ]
    )
    return {"title": title, "body": body}


def github_issues(repo: str) -> list[dict[str, Any]]:
    command = [
        "gh",
        "issue",
        "list",
        "--repo",
        repo,
        "--state",
        "all",
        "--label",
        "llm-candidate",
        "--limit",
        "1000",
        "--json",
        "number,title,url,body,labels",
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout)


def materialize_evidence(candidate: dict[str, Any]) -> dict[str, Any]:
    """Fetch the authoritative config and declared GGUF shard sizes from HF."""
    required = {
        "primaryRepo",
        "artifactRepo",
        "artifactFiles",
        "sourceUrl",
        "publishedScores",
        "family",
        "revision",
    }
    if not required <= candidate.keys():
        missing = ", ".join(sorted(required - candidate.keys()))
        raise ValueError(f"missing candidate evidence declaration: {missing}")
    config_url = (
        f"https://huggingface.co/{candidate['primaryRepo']}/raw/main/config.json"
    )
    config = fetch_json(config_url)
    if not isinstance(config, dict):
        raise ValueError("primary config is not JSON")
    tree_url = (
        f"https://huggingface.co/api/models/{candidate['artifactRepo']}"
        "/tree/main?recursive=true&expand=true"
    )
    tree = fetch_json(tree_url)
    if not isinstance(tree, list):
        raise ValueError("artifact repository tree is not JSON")
    files = {
        entry.get("path"): entry.get("size")
        for entry in tree
        if entry.get("type") == "file" and isinstance(entry.get("path"), str)
    }
    requested = candidate["artifactFiles"]
    if not requested or any(not name.lower().endswith(".gguf") for name in requested):
        raise ValueError("artifactFiles must name one GGUF or every GGUF shard")
    missing = [name for name in requested if not isinstance(files.get(name), int)]
    if missing:
        raise ValueError(
            f"exact GGUF artifact/shard set is absent or size-less: {', '.join(missing)}"
        )
    return candidate | {
        "config": config,
        "configUrl": config_url,
        "artifact": ", ".join(requested),
        "weightBytes": sum(files[name] for name in requested),
    }


def radar(
    target_paths: list[Path], candidates_path: Path, repo: str, offline: bool
) -> dict[str, Any]:
    candidates = json.loads(candidates_path.read_text())
    issues = [] if offline else github_issues(repo)
    output: dict[str, Any] = {"pending": [], "drafts": [], "rejected": []}
    evidenced_candidates = []
    for candidate in candidates:
        try:
            evidenced_candidates.append(materialize_evidence(candidate))
        except (ValueError, OSError) as exc:
            output["pending"].append(
                {"candidate": candidate.get("family", "unknown"), "reason": str(exc)}
            )
    for target_path in target_paths:
        host = target_path.stem
        contract = json.loads(target_path.read_text())
        for candidate in evidenced_candidates:
            for alias, target in contract["targets"].items():
                if not set(target["modalities"]).issubset(
                    set(candidate.get("modalities", ["text"]))
                ):
                    continue
                result = assess(
                    candidate, host, alias, target, contract["residentBudgetMiB"]
                )
                result["candidate"] = candidate["family"]
                if result["disposition"] == "reject":
                    output["rejected"].append(result)
                    continue
                enriched = candidate | {
                    "incumbent": target["incumbent"],
                    "cacheTypeK": target["cacheTypeK"],
                    "cacheTypeV": target["cacheTypeV"],
                    "budgetMiB": contract["residentBudgetMiB"],
                }
                draft = render_draft(enriched, result)
                if not is_duplicate(issue_marker(candidate, result), issues):
                    output["drafts"].append(draft | {"result": result})
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("collect")
    radar_parser = subparsers.add_parser("radar")
    radar_parser.add_argument("--target", action="append", required=True, type=Path)
    radar_parser.add_argument("--candidates", required=True, type=Path)
    radar_parser.add_argument("--repo", default="ianepreston/nixos")
    radar_parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    output = (
        collect()
        if args.command == "collect"
        else radar(args.target, args.candidates, args.repo, args.offline)
    )
    print(json.dumps(output, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
