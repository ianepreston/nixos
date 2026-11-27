#!/usr/bin/env python3
"""Collect, size and draft review-only local-LLM candidate issues.

This is intentionally stdlib-only. Network sources are leads, not authority:
only a primary Hugging Face config and an exact GGUF artifact can reach a draft.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html.parser
import http.client
import io
import json
import math
import re
import subprocess
import urllib.request
from pathlib import Path
from typing import Any

# The SWE-bench leaderboard includes per-instance data and is already several
# MiB; cap all source and evidence responses while allowing it room to grow.
MAX_RESPONSE_BYTES = 16 * 1024 * 1024

SOURCES = {
    "livebench": "https://raw.githubusercontent.com/LiveBench/livebench.github.io/main/src/App.js",
    "aider-polyglot": "https://aider.chat/docs/leaderboards/",
    "swe-bench-verified": "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json",
    "bfcl": "https://gorilla.cs.berkeley.edu/leaderboard.html",
    "ocrbench-v2": "https://huggingface.co/spaces/ling99/OCRBench-v2-leaderboard/raw/main/OCRBench_en.csv",
    "olmocr-bench": "https://raw.githubusercontent.com/allenai/olmocr/main/README.md",
}
SOURCE_POLICIES = {
    "livebench": {"role": "generalist", "limit": 5, "scoreFloor": 50.0},
    "aider-polyglot": {"role": "coding", "limit": 5, "scoreFloor": 50.0},
    "swe-bench-verified": {"role": "coding", "limit": 5, "scoreFloor": 10.0},
    "bfcl": {"role": "generalist", "limit": 5, "scoreFloor": 50.0},
    "ocrbench-v2": {"role": "vision", "limit": 5, "scoreFloor": 50.0},
    "olmocr-bench": {"role": "vision", "limit": 5, "scoreFloor": 50.0},
}
OPEN_WEIGHT_TOKENS = (
    "aya",
    "deepseek",
    "falcon",
    "gemma",
    "glm",
    "gpt-oss",
    "kimi",
    "llama",
    "mistral",
    "mixtral",
    "nemotron",
    "olmo",
    "phi",
    "qwen",
    "yi",
)
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
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 -- fixed HTTPS sources
            body = response.read(MAX_RESPONSE_BYTES + 1)
            if len(body) > MAX_RESPONSE_BYTES:
                raise OSError(f"response exceeds {MAX_RESPONSE_BYTES}-byte limit")
            return (
                json.loads(body)
                if "json" in response.headers.get("Content-Type", "")
                else body.decode()
            )
    except (OSError, http.client.HTTPException) as exc:
        raise OSError(f"{url}: {exc}") from exc


def fetch_json(url: str) -> Any:
    value = fetch(url)
    return json.loads(value) if isinstance(value, str) else value


def canonical_family(name: str) -> str:
    """Collapse provider/template variants without guessing an HF repository."""
    name = name.lower()
    name = re.sub(
        r"\((?:fc(?: thinking)?|prompt|chat|reasoner|diff|thinking|no think|api)\)",
        "",
        name,
    )
    name = re.sub(r"\b(chat|reasoner|diff|no think|thinking|api)\b", "", name)
    return " ".join(re.findall(r"[a-z0-9]+", name))


def likely_open_weight(name: str) -> bool:
    lowered = name.lower()
    return "+" not in name and any(token in lowered for token in OPEN_WEIGHT_TOKENS)


def percent(value: str) -> float | None:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)%\s*", value)
    return float(match.group(1)) if match else None


def number(value: Any) -> float | None:
    try:
        score = float(value)
    except (TypeError, ValueError):
        return None
    return score if math.isfinite(score) and 0 <= score <= 100 else None


def lead(
    source: str, url: str, name: str, label: str, score: float, **evidence: Any
) -> dict[str, Any]:
    return {
        "source": source,
        "sourceUrl": url,
        "family": name,
        "canonicalFamily": canonical_family(name),
        "role": SOURCE_POLICIES[source]["role"],
        "publishedScores": {label: score},
        **evidence,
    }


def csv_rows(data: Any, required: set[str]) -> list[dict[str, str]]:
    if not isinstance(data, str):
        raise ValueError("expected CSV text")
    reader = csv.DictReader(io.StringIO(data))
    if not reader.fieldnames or not required.issubset(reader.fieldnames):
        raise ValueError(f"CSV missing columns: {', '.join(sorted(required))}")
    return list(reader)


def livebench_leads(data: Any, categories: Any, url: str) -> list[dict[str, Any]]:
    if (
        not isinstance(categories, dict)
        or not categories
        or not all(
            isinstance(cols, list) and cols and all(isinstance(c, str) for c in cols)
            for cols in categories.values()
        )
    ):
        raise ValueError("invalid LiveBench category definitions")
    columns = {c for cols in categories.values() for c in cols}
    rows = csv_rows(data, {"model"} | columns)
    leads = []
    for row in rows:
        averages = []
        for cols in categories.values():
            values = [v for c in cols if (v := number(row.get(c))) is not None]
            if not values:
                break
            averages.append(sum(values) / len(values))
        if row.get("model") and len(averages) == len(categories):
            # The website averages category means, not the individual tasks.
            score = round(sum(averages) / len(averages), 2)
            leads.append(
                lead("livebench", url, row["model"], "LiveBench global average", score)
            )
    if not leads:
        raise ValueError("no model has a scored value in every LiveBench category")
    return leads


def swe_leads(data: Any, url: str) -> list[dict[str, Any]]:
    if not isinstance(data, dict) or not isinstance(data.get("leaderboards"), list):
        raise ValueError("missing leaderboards array")
    boards = [
        b
        for b in data["leaderboards"]
        if isinstance(b, dict) and b.get("name") == "Verified"
    ]
    if len(boards) != 1 or not isinstance(boards[0].get("results"), list):
        raise ValueError("missing unique Verified results")
    leads = []
    valid = 0
    for row in boards[0]["results"]:
        if not isinstance(row, dict) or not isinstance(row.get("model_display"), str):
            continue
        score = number(row.get("resolved"))
        if score is None or not isinstance(row.get("os_model"), bool):
            continue
        valid += 1
        tags = row.get("tags", [])
        model_tags = (
            [t[7:] for t in tags if isinstance(t, str) and t.startswith("Model: ")]
            if isinstance(tags, list)
            else []
        )
        if not row["os_model"] or len(model_tags) > 1:
            continue
        name = (
            model_tags[0].rstrip("/").rsplit("/", 1)[-1]
            if model_tags
            else row["model_display"]
        )
        if name and "+" not in name:
            leads.append(
                lead(
                    "swe-bench-verified",
                    url,
                    name,
                    "SWE-bench Verified resolved",
                    score,
                    agent=row.get("agent"),
                    submission=row.get("name"),
                )
            )
    if not valid:
        raise ValueError(
            "no Verified rows with model, resolved score and open-model flag"
        )
    return leads


def bfcl_leads(data: Any, url: str) -> list[dict[str, Any]]:
    rows = csv_rows(data, {"Model", "Overall Acc"})
    leads = []
    for row in rows:
        score = percent(row.get("Overall Acc", ""))
        if row.get("Model") and score is not None and number(score) is not None:
            leads.append(
                lead("bfcl", url, row["Model"], "BFCL v4 overall accuracy", score)
            )
    if not leads:
        raise ValueError("no BFCL rows with model and overall accuracy")
    return leads


def ocrbench_leads(data: Any, url: str) -> list[dict[str, Any]]:
    rows = csv_rows(data, {"Model", "Open Source", "Average Score"})
    leads = []
    valid = 0
    for row in rows:
        score = number(row.get("Average Score"))
        if (
            row.get("Model")
            and score is not None
            and row.get("Open Source") in {"Yes", "No"}
        ):
            valid += 1
            if row["Open Source"] == "Yes":
                leads.append(
                    lead(
                        "ocrbench-v2",
                        url,
                        row["Model"],
                        "OCRBench v2 English average",
                        score,
                    )
                )
    if not valid:
        raise ValueError(
            "no OCRBench English rows with model, score and open-source flag"
        )
    return leads


def olmocr_leads(data: Any, url: str) -> list[dict[str, Any]]:
    if (
        not isinstance(data, str)
        or "### Benchmark" not in data
        or "### Installation" not in data
    ):
        raise ValueError("olmOCR benchmark section missing")
    section = data.split("### Benchmark", 1)[1].split("### Installation", 1)[0]
    parser = TableText()
    parser.feed(section)
    headers = [
        row
        for row in parser.rows
        if len(row) == 10 and row[0] == "" and row[-1] == "Overall"
    ]
    if len(headers) != 1:
        raise ValueError("olmOCR benchmark table headers changed")
    leads = []
    for row in parser.rows:
        if len(row) != 10 or not row[0]:
            continue
        match = re.fullmatch(r"(\d+(?:\.\d+)?)±(?:\d+(?:\.\d+)?|\?)", row[-1])
        score = number(match.group(1)) if match else None
        if score is not None and not re.search(r"\bAPI\b", row[0], re.IGNORECASE):
            leads.append(
                lead(
                    "olmocr-bench",
                    url,
                    row[0].rstrip("*"),
                    "olmOCR-Bench overall",
                    score,
                )
            )
    if not leads:
        raise ValueError("no olmOCR overall scored rows")
    return leads


def source_leads(name: str, url: str) -> list[dict[str, Any]]:
    data = fetch(url)
    if name == "livebench":
        if not isinstance(data, str):
            raise ValueError("LiveBench site configuration is not text")
        match = re.search(r"useState\(['\"](\d{4}-\d{2}-\d{2})['\"]\)", data)
        if not match:
            raise ValueError("LiveBench default release date missing")
        date = match.group(1).replace("-", "_")
        base = "https://raw.githubusercontent.com/LiveBench/livebench.github.io/main/public"
        scores_url = f"{base}/table_{date}.csv"
        return livebench_leads(
            fetch(scores_url), fetch_json(f"{base}/categories_{date}.json"), scores_url
        )
    if name == "swe-bench-verified":
        return swe_leads(json.loads(data) if isinstance(data, str) else data, url)
    if name == "bfcl":
        if not isinstance(data, str) or not re.search(
            r"Berkeley Function Calling Leaderboard \(BFCL\) V4\b", data
        ):
            raise ValueError("BFCL v4 leaderboard identity missing or changed")
        scores_url = "https://gorilla.cs.berkeley.edu/data_overall.csv"
        return bfcl_leads(fetch(scores_url), scores_url)
    if name == "ocrbench-v2":
        return ocrbench_leads(data, url)
    if name == "olmocr-bench":
        return olmocr_leads(data, url)
    if name == "aider-polyglot":
        if not isinstance(data, str):
            raise ValueError("Aider page is not HTML")
        parser = TableText()
        parser.feed(data)
        if not any(
            len(row) >= 3 and row[1:3] == ["Model", "Percent correct"]
            for row in parser.rows
        ):
            raise ValueError("Aider model and percent-correct headers missing")
        leads = aider_leads(parser.rows, name, url)
        if not leads:
            raise ValueError("no Aider rows with model and percent-correct score")
        return leads
    raise ValueError("no adapter for source")


def aider_leads(rows: list[list[str]], source: str, url: str) -> list[dict[str, Any]]:
    """Aider's model and score are its second and third table columns."""
    leads = []
    for row in rows:
        if len(row) < 3 or row[1] == "Model":
            continue
        score = percent(row[2])
        if score is None or number(score) is None or not row[1]:
            continue
        leads.append(
            {
                "source": source,
                "sourceUrl": url,
                "family": row[1],
                # Keep Aider's pre-existing family keys and shortlist dedupe.
                "canonicalFamily": canonical_family(re.sub(r"\([^)]*\)", "", row[1])),
                "role": SOURCE_POLICIES[source]["role"],
                "publishedScores": {"Aider Polyglot": score},
                "evidence": row,
            }
        )
    return leads


def shortlist(leads: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Keep a small, source-ranked open-weight shortlist per alias role."""
    by_source: dict[str, dict[str, dict[str, Any]]] = {}
    for lead in leads:
        policy = SOURCE_POLICIES[lead["source"]]
        score = next(iter(lead["publishedScores"].values()))
        if score < policy["scoreFloor"] or not likely_open_weight(lead["family"]):
            continue
        family = lead["canonicalFamily"]
        current = by_source.setdefault(lead["source"], {}).get(family)
        if current is None or score > next(iter(current["publishedScores"].values())):
            by_source[lead["source"]][family] = lead
    selected = []
    for source, families in by_source.items():
        ranked = sorted(
            families.values(),
            key=lambda lead: next(iter(lead["publishedScores"].values())),
            reverse=True,
        )[: SOURCE_POLICIES[source]["limit"]]
        for rank, lead in enumerate(ranked, start=1):
            selected.append(lead | {"status": "shortlisted", "sourceRank": rank})
    return selected


def collect() -> list[dict[str, Any]]:
    """Collect adapter-specific leads, then return only the review shortlist."""
    report = []
    raw_leads = []
    for name, url in SOURCES.items():
        try:
            adapter_leads = source_leads(name, url)
        except (ValueError, TypeError, KeyError, csv.Error) as exc:
            report.append(
                {
                    "source": name,
                    "url": url,
                    "status": "unsupported",
                    "detail": str(exc),
                }
            )
            continue
        except OSError as exc:
            report.append(
                {
                    "source": name,
                    "url": url,
                    "status": "unavailable",
                    "detail": str(exc),
                }
            )
            continue
        raw_leads.extend(adapter_leads)
        if not shortlist(adapter_leads):
            report.append(
                {
                    "source": name,
                    "url": url,
                    "status": "no-shortlist",
                    "detail": "source parsed but no rows passed the open-weight and score filters",
                }
            )
    return report + shortlist(raw_leads)


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
        "roles",
    }
    if not required <= candidate.keys():
        missing = ", ".join(sorted(required - candidate.keys()))
        raise ValueError(f"missing candidate evidence declaration: {missing}")
    if not set(candidate["roles"]) <= {"generalist", "coding", "vision"}:
        raise ValueError("roles may contain only generalist, coding, or vision")
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
    output: dict[str, Any] = {
        "pending": [],
        "drafts": [],
        "rejected": [],
        "excluded": [],
    }
    evidenced_candidates = []
    for candidate in candidates:
        if candidate.get("status") and candidate["status"] != "shortlisted":
            output["excluded"].append(
                {
                    "source": candidate.get("source", "unknown"),
                    "reason": candidate["status"],
                    "detail": candidate.get("detail", ""),
                    "url": candidate.get("url", ""),
                }
            )
            continue
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
                if target["role"] not in candidate["roles"]:
                    continue
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
