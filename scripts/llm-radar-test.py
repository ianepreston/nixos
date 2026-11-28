#!/usr/bin/env python3
"""Regression cases for the model-radar sizing and issue-deduplication policy."""

import importlib.util
import http.client
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location(
    "radar", Path(__file__).with_name("llm-radar.py")
)
assert SPEC and SPEC.loader
radar = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(radar)

TARGET = {
    "cacheTypeK": "q8_0",
    "cacheTypeV": "q8_0",
    "contextTokens": 131072,
    "incumbent": "old",
}

# Small, non-sensitive excerpts from the publishers' exports. Kept here so
# the existing Nix check copies the fixtures alongside the test module.
LIVE_CATEGORIES = {
    "Reasoning": ["theory_of_mind", "zebra_puzzle", "spatial", "logic_with_navigation"],
    "Coding": ["code_generation", "code_completion"],
    "Agentic Coding": ["javascript", "typescript", "python"],
    "Mathematics": ["AMPS_Hard", "integrals_with_game", "math_comp", "olympiad"],
    "Data Analysis": ["consecutive_events", "tablejoin", "tablereformat"],
    "Language": ["connections", "plot_unscrambling", "typos"],
    "IF": ["paraphrase", "simplify", "story_generation", "summarize"],
}
LIVE_CSV = """model,AMPS_Hard,code_completion,code_generation,connections,consecutive_events,integrals_with_game,javascript,logic_with_navigation,math_comp,olympiad,paraphrase,plot_unscrambling,python,simplify,spatial,story_generation,summarize,tablejoin,tablereformat,theory_of_mind,typescript,typos,zebra_puzzle
qwen3.6-27b,93.0,71.739,71.831,77.167,70.395,52.0,54.545,62.0,92.157,82.317,49.433,42.746,40.0,50.733,100.0,60.133,52.617,42.846,98.039,65.385,23.333,70.0,53.75
"""
SWE_DATA = {
    "leaderboards": [
        {
            "name": "Verified",
            "results": [
                {
                    "agent": "OpenHands",
                    "model_display": "Qwen3-Coder-480B-A35B-Instruct",
                    "name": "OpenHands + Qwen3-Coder-480B-A35B-Instruct",
                    "os_model": True,
                    "resolved": 69.6,
                    "tags": [
                        "Model: https://huggingface.co/Qwen/Qwen3-Coder-480B-A35B-Instruct",
                        "Org: Qwen",
                        "Org: OpenHands",
                        "System: Attempts - 1",
                    ],
                }
            ],
        }
    ]
}
BFCL_CSV = """Rank,Overall Acc,Model,Model Link,Total Cost ($)
4,72.38%,GLM-4.6 (FC thinking),https://huggingface.co/zai-org/GLM-4.6,4.64
"""
OCR_CSV = """Model,Open Source,Text Recognition,Text Referring,Text Spotting,Relation Extraction,Element Parsing,Mathematical Calculation,Visual Text Understanding,Knowledge Reasoning,Average Score,Link
Qwen2-VL-7B,Yes,72.1,47.9,17.5,82.5,25.5,25.4,78.4,61.5,51.4,https://arxiv.org/abs/2409.12191
"""
OLMO_README = """### Benchmark
<table><thead><tr><th></th><th>ArXiv</th><th>Old<br>scans<br>math</th><th>Tables</th><th>Old<br>scans</th><th>Headers<br>&<br>footers</th><th>Multi<br>column</th><th>Long<br>tiny<br>text</th><th>Base</th><th>Overall</th></tr></thead><tbody>
<tr><td>DeepSeek-OCR</td><td>77.2</td><td>73.6</td><td>80.2</td><td>33.3</td><td>96.1</td><td>66.4</td><td>79.4</td><td>99.8</td><td>75.7±1.0</td></tr>
</tbody></table>
### Installation
"""


class RadarTest(unittest.TestCase):
    def test_published_source_fixtures(self):
        url = "https://example.invalid/source"
        cases = [
            (
                radar.livebench_leads(LIVE_CSV, LIVE_CATEGORIES, url),
                "qwen3.6-27b",
                "generalist",
                "LiveBench global average",
                64.03,
            ),
            (
                radar.swe_leads(SWE_DATA, url),
                "Qwen3-Coder-480B-A35B-Instruct",
                "coding",
                "SWE-bench Verified resolved",
                69.6,
            ),
            (
                radar.bfcl_leads(BFCL_CSV, url),
                "GLM-4.6 (FC thinking)",
                "generalist",
                "BFCL v4 overall accuracy",
                72.38,
            ),
            (
                radar.ocrbench_leads(OCR_CSV, url),
                "Qwen2-VL-7B",
                "vision",
                "OCRBench v2 English average",
                51.4,
            ),
            (
                radar.olmocr_leads(OLMO_README, url),
                "DeepSeek-OCR",
                "vision",
                "olmOCR-Bench overall",
                75.7,
            ),
        ]
        for results, name, role, label, score in cases:
            with self.subTest(source=label):
                self.assertEqual(1, len(results))
                result = results[0]
                self.assertEqual(
                    (name, radar.canonical_family(name), role, url),
                    (
                        result["family"],
                        result["canonicalFamily"],
                        result["role"],
                        result["sourceUrl"],
                    ),
                )
                self.assertEqual(score, result["publishedScores"][label])

    def test_livebench_uses_published_default_release(self):
        with patch.object(
            radar,
            "fetch",
            side_effect=[
                "const [selectedDate, setSelectedDate] = useState('2026-06-25');",
                LIVE_CSV,
                LIVE_CATEGORIES,
            ],
        ) as fetch:
            result = radar.source_leads("livebench", radar.SOURCES["livebench"])
        self.assertTrue(result[0]["sourceUrl"].endswith("table_2026_06_25.csv"))
        self.assertTrue(
            fetch.call_args_list[2].args[0].endswith("categories_2026_06_25.json")
        )

    def test_bfcl_checks_version_and_deduplicates_template_variants(self):
        csv = (
            BFCL_CSV
            + "5,70.00%,GLM-4.6 (Prompt),https://huggingface.co/zai-org/GLM-4.6,4.64\n"
        )
        with patch.object(
            radar,
            "fetch",
            side_effect=["Berkeley Function Calling Leaderboard (BFCL) V4", csv],
        ):
            leads = radar.source_leads("bfcl", radar.SOURCES["bfcl"])
        self.assertEqual(2, len(leads))
        self.assertTrue(leads[0]["sourceUrl"].endswith("data_overall.csv"))
        selected = radar.shortlist(leads)
        self.assertEqual(1, len(selected))
        self.assertEqual("GLM-4.6 (FC thinking)", selected[0]["family"])

    def test_fetch_failure_identifies_failing_dependency(self):
        with patch("urllib.request.urlopen", side_effect=OSError("offline")):
            with self.assertRaisesRegex(
                OSError, "https://example.invalid/data: offline"
            ):
                radar.fetch("https://example.invalid/data")

    def test_oversized_response_reports_named_unavailable_source(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.headers = {"Content-Type": "application/json"}
        response.read.return_value = b"x" * 17
        url = "https://example.invalid/data"
        with (
            patch.object(radar, "MAX_RESPONSE_BYTES", 16),
            patch.object(radar, "SOURCES", {"swe-bench-verified": url}),
            patch("urllib.request.urlopen", return_value=response),
        ):
            result = radar.collect()
        response.read.assert_called_once_with(17)
        self.assertEqual(1, len(result))
        self.assertEqual("swe-bench-verified", result[0]["source"])
        self.assertEqual("unavailable", result[0]["status"])
        self.assertIn(url, result[0]["detail"])
        self.assertIn("exceeds 16-byte limit", result[0]["detail"])

    def test_fetch_accepts_json_at_response_limit(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.headers = {"Content-Type": "application/json"}
        response.read.return_value = b'{"score": 42}'
        with (
            patch.object(radar, "MAX_RESPONSE_BYTES", len(response.read.return_value)),
            patch("urllib.request.urlopen", return_value=response),
        ):
            result = radar.fetch("https://example.invalid/data")
        self.assertEqual({"score": 42}, result)
        response.read.assert_called_once_with(len(response.read.return_value) + 1)

    def test_http_exception_reports_named_unavailable_source(self):
        url = "https://example.invalid/data"
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.side_effect = http.client.IncompleteRead(b"partial", 10)
        with (
            patch.object(radar, "SOURCES", {"bfcl": url}),
            patch("urllib.request.urlopen", return_value=response),
        ):
            result = radar.collect()
        self.assertEqual(1, len(result))
        self.assertEqual(
            ("bfcl", "unavailable"), (result[0]["source"], result[0]["status"])
        )
        self.assertIn(url, result[0]["detail"])
        self.assertIn("IncompleteRead", result[0]["detail"])

    def test_swe_skips_closed_and_multi_model_submissions(self):
        row = SWE_DATA["leaderboards"][0]["results"][0]
        data = {
            "leaderboards": [
                {
                    "name": "Verified",
                    "results": [
                        row | {"os_model": False},
                        row | {"tags": ["Model: qwen", "Model: claude"]},
                    ],
                }
            ]
        }
        self.assertEqual([], radar.swe_leads(data, "https://example.invalid"))

    def test_collection_reports_source_health(self):
        with (
            patch.object(radar, "SOURCES", {"ocrbench-v2": "https://example.invalid"}),
            patch.object(radar, "fetch", return_value="<html>changed</html>"),
        ):
            leads = radar.collect()
        self.assertEqual("unsupported", leads[0]["status"])
        self.assertEqual("ocrbench-v2", leads[0]["source"])
        self.assertIn("missing columns", leads[0]["detail"])
        with (
            patch.object(radar, "SOURCES", {"bfcl": "https://example.invalid"}),
            patch.object(radar, "fetch", side_effect=OSError("offline")),
        ):
            leads = radar.collect()
        self.assertEqual(
            ("unavailable", "offline"), (leads[0]["status"], leads[0]["detail"])
        )

    def test_each_adapter_rejects_changed_schema(self):
        for name in (
            "livebench",
            "swe-bench-verified",
            "bfcl",
            "ocrbench-v2",
            "olmocr-bench",
        ):
            with (
                self.subTest(source=name),
                patch.object(radar, "SOURCES", {name: "https://example.invalid"}),
                patch.object(radar, "fetch", return_value="changed"),
            ):
                result = radar.collect()
                self.assertEqual(
                    (name, "unsupported"), (result[0]["source"], result[0]["status"])
                )
                self.assertTrue(result[0]["detail"])

    def test_source_with_no_eligible_leads_reports_reason(self):
        with (
            patch.object(radar, "SOURCES", {"ocrbench-v2": "https://example.invalid"}),
            patch.object(radar, "fetch", return_value=OCR_CSV.replace("51.4", "41.4")),
        ):
            result = radar.collect()
        self.assertEqual("no-shortlist", result[0]["status"])

    def test_shortlist_keeps_top_open_weight_family_per_source_and_role(self):
        leads = [
            {
                "source": "aider-polyglot",
                "family": "Qwen3 32B (diff)",
                "canonicalFamily": "qwen3 32b",
                "publishedScores": {"Aider Polyglot": 60.0},
            },
            {
                "source": "aider-polyglot",
                "family": "Qwen3 32B (chat)",
                "canonicalFamily": "qwen3 32b",
                "publishedScores": {"Aider Polyglot": 55.0},
            },
        ]
        selected = radar.shortlist(leads)
        self.assertEqual(1, len(selected))
        self.assertEqual("Qwen3 32B (diff)", selected[0]["family"])
        self.assertEqual(
            radar.canonical_family("GLM-4.6 (FC thinking)"),
            radar.canonical_family("GLM-4.6 (Prompt)"),
        )
        self.assertNotEqual(
            radar.canonical_family("DeepSeek R1 (0528)"),
            radar.canonical_family("DeepSeek R1 (0120)"),
        )

    def test_aider_retains_legacy_family_key_and_ledger_identity(self):
        leads = radar.aider_leads(
            [["", "DeepSeek R1 (0528)", "71.4%"], ["", "DeepSeek R1 (0120)", "70.0%"]],
            "aider-polyglot",
            "https://example.invalid/leaderboard",
        )
        self.assertEqual(
            ["deepseek r1", "deepseek r1"], [x["canonicalFamily"] for x in leads]
        )
        selected = radar.shortlist(leads)
        self.assertEqual(["DeepSeek R1 (0528)"], [x["family"] for x in selected])
        candidate = selected[0] | {"revision": "v1", "artifact": "Q4.gguf"}
        result = {"host": "terra", "alias": "code", "fingerprint": "abc"}
        marker = "<!-- llm-radar identity=DeepSeek R1 (0528)|v1|Q4.gguf|terra|code fingerprint=abc -->"
        self.assertEqual(marker, radar.issue_marker(candidate, result))
        self.assertTrue(radar.is_duplicate(marker, [{"body": marker}]))

    def test_composite_leaderboard_rows_are_not_self_hosting_candidates(self):
        self.assertFalse(radar.likely_open_weight("DeepSeek R1 + Claude Sonnet"))

    def test_evidence_uses_the_declared_complete_shard_set(self):
        candidate = {
            "family": "Example",
            "revision": "v1",
            "roles": ["coding"],
            "primaryRepo": "org/example",
            "artifactRepo": "org/example-GGUF",
            "artifactFiles": [
                "example-00001-of-00002.gguf",
                "example-00002-of-00002.gguf",
            ],
            "sourceUrl": "https://example.invalid/scores",
            "publishedScores": {"ExampleBench": 99},
        }
        with patch.object(
            radar,
            "fetch_json",
            side_effect=[
                {"num_hidden_layers": 1, "num_key_value_heads": 1, "head_dim": 1},
                [
                    {"type": "file", "path": "example-00001-of-00002.gguf", "size": 4},
                    {"type": "file", "path": "example-00002-of-00002.gguf", "size": 6},
                ],
            ],
        ):
            materialized = radar.materialize_evidence(candidate)
        self.assertEqual(10, materialized["weightBytes"])

    def test_sliding_window_is_not_rejected_by_full_attention_math(self):
        candidate = {
            "config": {
                "num_hidden_layers": 24,
                "num_key_value_heads": 8,
                "head_dim": 128,
                "sliding_window": 128,
            },
            "weightBytes": 12 * 1024**3,
        }
        result = radar.assess(candidate, "terra", "text", TARGET, 15360)
        self.assertEqual("manual-review", result["disposition"])

    def test_moe_is_not_rejected_by_weights_alone(self):
        candidate = {
            "config": {
                "num_hidden_layers": 48,
                "num_key_value_heads": 4,
                "head_dim": 128,
                "num_local_experts": 128,
            },
            "weightBytes": 17 * 1024**3,
        }
        result = radar.assess(candidate, "terra", "code", TARGET, 15360)
        self.assertEqual("manual-review", result["disposition"])

    def test_marker_dedupes_a_replay_but_target_change_reconsiders(self):
        candidate = {"family": "Example", "revision": "v1", "artifact": "Q4.gguf"}
        first = radar.assess(
            {
                "config": {
                    "num_hidden_layers": 1,
                    "num_key_value_heads": 1,
                    "head_dim": 1,
                },
                "weightBytes": 1,
            },
            "terra",
            "text",
            TARGET,
            15360,
        )
        marker = radar.issue_marker(candidate, first)
        self.assertTrue(radar.is_duplicate(marker, [{"body": marker}]))
        changed = radar.assess(
            {
                "config": {
                    "num_hidden_layers": 1,
                    "num_key_value_heads": 1,
                    "head_dim": 1,
                },
                "weightBytes": 1,
            },
            "terra",
            "text",
            TARGET | {"cacheTypeK": "f16"},
            15360,
        )
        self.assertFalse(
            radar.is_duplicate(
                radar.issue_marker(candidate, changed), [{"body": marker}]
            )
        )


if __name__ == "__main__":
    unittest.main()
