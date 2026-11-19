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

    def test_broken_answer_has_the_same_total_as_a_valid_one(self):
        valid = llm_eval.score_case(EXPECTED, tool_response({"title": "x"}))
        broken = llm_eval.score_case(EXPECTED, tool_response("{not json"))
        self.assertEqual(valid["total"], broken["total"])

    def test_out_of_tokens_is_explained(self):
        resp = {
            "choices": [
                {
                    "finish_reason": "length",
                    "message": {"content": "", "reasoning_content": "..."},
                }
            ]
        }
        r = llm_eval.score_case(EXPECTED, resp)
        parses = next(c for c in r["checks"] if c["check"] == "parses")
        self.assertIn("finish_reason=length", parses["detail"])

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


def chat(content: str = "", tool_calls=None, finish: str = "stop", usage=None) -> dict:
    message = {"content": content}
    if tool_calls is not None:
        message["tool_calls"] = tool_calls
    out = {"choices": [{"message": message, "finish_reason": finish}]}
    if usage is not None:
        out["usage"] = usage
    return out


def weather_call(args) -> list[dict]:
    raw = args if isinstance(args, str) else json.dumps(args)
    return [{"id": "c1", "function": {"name": "get_weather", "arguments": raw}}]


class Gates(unittest.TestCase):
    def test_tool_call_pass(self):
        g, call = llm_eval.check_tool_call(
            chat(tool_calls=weather_call({"city": "Calgary, AB", "unit": "celsius"}))
        )
        self.assertTrue(g["pass"], g)
        self.assertEqual(call["id"], "c1")

    def test_tool_call_failures(self):
        cases = {
            "no tool_calls": chat("It is cold.", finish="stop"),
            "not JSON": chat(tool_calls=weather_call('{"city": "Calgary"')),
            "unit=": chat(tool_calls=weather_call({"city": "Calgary", "unit": "C"})),
            "called": chat(
                tool_calls=[{"function": {"name": "lookup", "arguments": "{}"}}]
            ),
        }
        for why, response in cases.items():
            g, call = llm_eval.check_tool_call(response)
            self.assertFalse(g["pass"], why)
            self.assertIn(why, g["detail"])
            self.assertIsNone(call)

    def test_round_trip(self):
        ok = llm_eval.check_round_trip(chat("It's -17°C and snowing in Calgary."))
        self.assertTrue(ok["pass"])
        self.assertFalse(llm_eval.check_round_trip(chat("It's 170 degrees."))["pass"])
        again = llm_eval.check_round_trip(chat(tool_calls=weather_call({})))
        self.assertIn("again", again["detail"])
        empty = llm_eval.check_round_trip(chat("", finish="length"))
        self.assertIn("finish_reason=length", empty["detail"])

    def test_modalities(self):
        entry = {"architecture": {"input_modalities": ["text"]}}
        self.assertTrue(llm_eval.check_modalities(entry, ["text"])["pass"])
        missing = llm_eval.check_modalities(entry, ["text", "image"])
        self.assertEqual(missing["detail"], "missing image")
        self.assertFalse(llm_eval.check_modalities({}, ["text"])["pass"])

    def test_context_plan_leaves_headroom(self):
        # 50 tokens of question, 15 tokens per filler line.
        lines, headroom = llm_eval.context_plan(16384, 50, 50 + 15 * 200)
        self.assertEqual(headroom, 2048)
        self.assertLessEqual(50 + lines * 15, 16384 - 2048)
        self.assertGreater(50 + (lines + 1) * 15, 16384 - 2048)
        _, big = llm_eval.context_plan(131072, 50, 3050)
        self.assertEqual(big, 13107)

    def test_context_prompt_places_needle(self):
        text = llm_eval.context_prompt(100)
        self.assertEqual(text.count(llm_eval.NEEDLE), 1)
        self.assertLess(text.index(llm_eval.NEEDLE), len(text) // 5)
        self.assertTrue(text.endswith(llm_eval.NEEDLE_ASK))

    def test_check_context(self):
        usage = {"prompt_tokens": 14000}
        ok = chat(f"The code is {llm_eval.NEEDLE}.", usage=usage)
        self.assertTrue(llm_eval.check_context(ok, 16384, 14336)["pass"])
        miss = llm_eval.check_context(chat("unknown", usage=usage), 16384, 14336)
        self.assertIn("needle not recalled", miss["detail"])
        short = chat(llm_eval.NEEDLE, usage={"prompt_tokens": 9000})
        self.assertIn(
            "under the", llm_eval.check_context(short, 16384, 14336)["detail"]
        )

    def test_gpu_usage_matches_the_model_child(self):
        ps = (
            "  PID ARGS\n"
            " 1360 /nix/store/x/bin/llama-server --port 8091 --models-preset p.ini\n"
            " 2001 /nix/store/x/bin/llama-server --port 5 --alias org/a-GGUF:Q4_K_M --ctx-size 1\n"
            " 2002 /nix/store/x/bin/llama-server --port 6 --alias org/b-GGUF:Q8_0\n"
            " 3000 electron --type=gpu-process\n"
        )
        csv = "2001, 6208\n2002, 900\n3000, 45\n"
        self.assertEqual(llm_eval.gpu_usage(csv, ps, "org/a-GGUF:Q4_K_M"), 6208)
        self.assertIsNone(llm_eval.gpu_usage(csv, ps, "org/c-GGUF:Q4_K_M"))
        self.assertFalse(llm_eval.check_vram(6208, 6200, 16384, 16384)["pass"])
        self.assertTrue(llm_eval.check_vram(6000, 6200, 16384, 16384)["pass"])
        self.assertFalse(llm_eval.check_vram(6000, 6200, None, 16384)["pass"])
        small = llm_eval.check_vram(4000, 6200, 8192, 16384)
        self.assertFalse(small["pass"])
        self.assertIn("served at 8192", small["detail"])

    def test_image_colour(self):
        self.assertTrue(llm_eval.check_image(chat("Crimson."))["pass"])
        self.assertTrue(llm_eval.check_image(chat("Red"))["pass"])
        self.assertFalse(llm_eval.check_image(chat("Reddish-blue? No: blue."))["pass"])

    def test_solid_png_is_a_png(self):
        png = llm_eval.solid_png((255, 0, 0), size=4)
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertTrue(png.endswith(b"IEND\xaeB`\x82"))


if __name__ == "__main__":
    unittest.main()
