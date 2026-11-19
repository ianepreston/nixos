#!/usr/bin/env python3
"""Unit tests for scripts/llm-eval.py's scorer. Synthetic data only: real
fixtures are private and never belong in this repo."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest

_spec = importlib.util.spec_from_file_location(
    "llm_eval", Path(__file__).with_name("llm-eval.py")
)
llm_eval = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(llm_eval)


def tool_response(args: dict | str) -> dict:
    raw = args if isinstance(args, str) else json.dumps(args)
    return {
        "choices": [
            {
                "message": {
                    "content": "",
                    "tool_calls": [{"function": {"arguments": raw}}],
                }
            }
        ]
    }


def failed(result: dict) -> set[str]:
    return {f"{c['field']}:{c['check']}" for c in result["checks"] if not c["pass"]}


EXPECTED = {
    "title": {"examples": ["Widget manual"]},
    "tags": {"must": ["home-office"], "link": {"home-office": 3}, "want": ["Manual"]},
    "correspondents": {"may_be_empty": True, "must_not": ["Customer"]},
    "document_types": {"want": ["Manual", "Guide"], "link": {"Manual": 7}},
    "storage_paths": {"ignore": True},
    "dates": {"may_be_empty": True},
}


class ScoreCase(unittest.TestCase):
    def test_perfect_answer(self):
        r = llm_eval.score_case(
            EXPECTED,
            tool_response(
                {
                    "title": "Widget manual",
                    "tags": ["Home Office", "Manual"],
                    "matched_tags": ["home-office"],
                    "tag_ids": [3],
                    "correspondents": [],
                    "document_types": ["Manual"],
                    "matched_document_types": ["Manual"],
                    "document_type_ids": [7],
                    "storage_paths": ["anything/goes"],
                    "dates": [],
                }
            ),
        )
        self.assertEqual(failed(r), set())
        self.assertEqual(r["passed"], r["total"])

    def test_name_without_reconciliation_fails_only_link(self):
        r = llm_eval.score_case(
            EXPECTED,
            tool_response(
                {
                    "title": "x",
                    "tags": ["home office", "Manual"],
                    "document_types": ["Guide"],
                }
            ),
        )
        self.assertEqual(failed(r), {"tags:link:home-office"})

    def test_optional_link_not_suggested_is_na_and_keeps_denominator(self):
        with_manual = llm_eval.score_case(
            EXPECTED,
            tool_response(
                {"title": "x", "tags": ["home-office"], "document_types": ["Manual"]}
            ),
        )
        with_guide = llm_eval.score_case(
            EXPECTED,
            tool_response(
                {"title": "x", "tags": ["home-office"], "document_types": ["Guide"]}
            ),
        )
        self.assertEqual(with_manual["total"], with_guide["total"])
        self.assertIn("document_types:link:Manual", failed(with_manual))
        self.assertNotIn("document_types:link:Manual", failed(with_guide))

    def test_whole_word_containment(self):
        names = {llm_eval.norm("EnerGuide Report")}
        self.assertTrue(llm_eval.mentions("EnerGuide", names))
        self.assertFalse(llm_eval.mentions("Guide", names))

    def test_may_be_empty_rejects_invented_values(self):
        r = llm_eval.score_case(
            EXPECTED,
            tool_response(
                {"title": "x", "correspondents": ["Customer"], "dates": ["1990-01-01"]}
            ),
        )
        self.assertTrue(
            {"correspondents:must_not:Customer", "correspondents:empty", "dates:empty"}
            <= failed(r)
        )

    def test_fused_list_item_is_malformed(self):
        r = llm_eval.score_case(
            EXPECTED,
            tool_response(
                {
                    "title": "x",
                    "tags": ['A","B","home-office'],
                    "document_types": ["Guide"],
                }
            ),
        )
        self.assertIn("*:clean-items", failed(r))

    def test_unparseable_arguments_fail_every_check(self):
        broken = llm_eval.score_case(EXPECTED, tool_response("{not json"))
        empty = llm_eval.score_case(EXPECTED, tool_response({"title": ""}))
        self.assertEqual(broken["passed"], 0)
        self.assertLess(broken["passed"], empty["passed"])

    def test_missing_response(self):
        r = llm_eval.score_case(EXPECTED, {})
        self.assertEqual(r["passed"], 0)

    def test_content_json_fallback(self):
        resp = {"choices": [{"message": {"content": json.dumps({"title": "t"})}}]}
        args, err = llm_eval.extract_arguments(resp)
        self.assertEqual(args, {"title": "t"})
        self.assertIsNone(err)

    def test_unknown_rule_key_is_an_error(self):
        with self.assertRaises(ValueError):
            llm_eval.score_case(
                {"tags": {"musst": ["x"]}}, tool_response({"title": "t"})
            )


if __name__ == "__main__":
    unittest.main()
