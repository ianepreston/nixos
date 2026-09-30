#!/usr/bin/env python3
"""Regression cases for the model-radar sizing and issue-deduplication policy."""

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

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


class RadarTest(unittest.TestCase):
    def test_collection_reports_a_source_that_changes_out_from_under_the_adapter(self):
        with (
            patch.object(radar, "SOURCES", {"test": "https://example.invalid"}),
            patch.object(
                radar, "fetch", return_value="<html><body>no table</body></html>"
            ),
        ):
            leads = radar.collect()
        self.assertEqual("no-machine-readable-leads", leads[0]["status"])

    def test_evidence_uses_the_declared_complete_shard_set(self):
        candidate = {
            "family": "Example",
            "revision": "v1",
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
