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


def chat_response(content: str = "", calls: list | None = None, finish="stop") -> dict:
    tool_calls = [
        {
            "function": {
                "name": n,
                "arguments": a if isinstance(a, str) else json.dumps(a),
            }
        }
        for n, a in calls or []
    ]
    return {
        "choices": [
            {
                "message": {"content": content, "tool_calls": tool_calls},
                "finish_reason": finish,
            }
        ]
    }


ROUTE = {
    "tools": {"must": ["get_income"], "must_not": ["record_activity"]},
    "args": {
        "get_income.period": {"want": ["YTD"], "may_be_empty": True},
        "search.query|symbol": {"want": ["ACME"]},
    },
}
ANSWER = {
    "tools": {"may_be_empty": True},
    "reply": {
        "must": ["ACME"],
        "must_not": ["WIDGETCO"],
        "numbers": {"total": {"any": [1234.56]}, "rate": {"any": [7.31234, 3.3]}},
    },
}


class ScoreTrace(unittest.TestCase):
    def test_route_pass(self):
        r = llm_eval.score_case(
            ROUTE,
            chat_response(
                calls=[
                    ("get_income", {"period": "YTD"}),
                    ("search", {"symbol": "acme"}),
                ]
            ),
        )
        self.assertEqual(failed(r), set())

    def test_route_defaulted_arg_passes_wrong_tool_fails(self):
        r = llm_eval.score_case(ROUTE, chat_response(calls=[("get_income", {})]))
        self.assertEqual(failed(r), {"search.query|symbol:want"})
        r = llm_eval.score_case(
            ROUTE,
            chat_response(
                calls=[("record_activity", {}), ("get_income", {"period": "ALL"})]
            ),
        )
        self.assertIn("tools:must_not:record_activity", failed(r))
        self.assertIn("get_income.period:want-or-empty", failed(r))

    def test_clarifying_question_instead_of_a_call_fails(self):
        r = llm_eval.score_case(ROUTE, chat_response("Which account do you mean?"))
        self.assertIn("tools:must:get_income", failed(r))
        self.assertNotIn("*:complete", failed(r))

    def test_answer_numbers_tolerate_formatting(self):
        r = llm_eval.score_case(
            ANSWER, chat_response("**ACME** paid about $1.23k, a return of 7.3% (-$12)")
        )
        self.assertEqual(failed(r), set())
        r = llm_eval.score_case(ANSWER, chat_response("ACME paid $1,234.56, up 3.30%."))
        self.assertEqual(failed(r), set())
        # gpt-oss typography: U+202F thousands separator, U+2011 hyphen.
        r = llm_eval.score_case(
            ANSWER, chat_response("A‑CME? No: ACME paid 1 234.56, up 3.3 %.")
        )
        self.assertEqual(failed(r), set())

    def test_typographic_hyphen_matches_ascii_name(self):
        rule = {"reply": {"must_not": ["WIDGET-CO"], "want": ["aren't any"]}}
        r = llm_eval.score_case(rule, chat_response("WIDGET‑CO: there aren’t any"))
        self.assertEqual(failed(r), {"reply:must_not:WIDGET-CO"})

    def test_answer_wrong_figure_or_extra_call_fails(self):
        r = llm_eval.score_case(
            ANSWER,
            chat_response("ACME and WIDGETCO paid $7,100.", [("get_holdings", {})]),
        )
        self.assertEqual(
            failed(r),
            {
                "tools:empty",
                "reply:must_not:WIDGETCO",
                "reply:number:total",
                "reply:number:rate",
            },
        )

    def test_same_total_whatever_the_reply(self):
        good = llm_eval.score_case(ANSWER, chat_response("ACME $1,234.56 7.3%"))
        empty = llm_eval.score_case(ANSWER, chat_response("", finish="length"))
        self.assertEqual(good["total"], empty["total"])
        self.assertIn("*:complete", failed(empty))

    def test_accepts_mirrors_per_action_schema(self):
        rule = {
            "tools": {"must": ["stats"]},
            "accepts": {"stats": {"summary": ["start"], "review": ["days"]}},
        }
        ok = [("stats", {"action": "review", "days": 7})]
        self.assertEqual(
            failed(llm_eval.score_case(rule, chat_response(calls=ok))), set()
        )
        # `start` is valid on a sibling action, so only the call it bled into fails.
        bled = ok + [("stats", {"action": "review", "start": "2026-01-01"})]
        r = llm_eval.score_case(rule, chat_response(calls=bled))
        self.assertEqual(failed(r), {"stats:accepts"})
        detail = next(c["detail"] for c in r["checks"] if c["check"] == "accepts")
        self.assertEqual(detail, "review: start")
        sibling = [("stats", {"action": "summary", "start": "2026-01-01"})]
        self.assertEqual(
            failed(llm_eval.score_case(rule, chat_response(calls=sibling))), set()
        )

    def test_accepts_wildcard_unlisted_action_and_uncalled_tool(self):
        rule = {
            "tools": {"want": ["a", "b"]},
            "accepts": {"a": {"*": ["q"]}, "b": {"x": []}},
        }
        r = llm_eval.score_case(
            rule, chat_response(calls=[("a", {"q": 1}), ("b", {"action": "y", "z": 1})])
        )
        self.assertEqual(failed(r), set())
        r = llm_eval.score_case(rule, chat_response(calls=[("a", {"q": 1, "r": 2})]))
        self.assertEqual(failed(r), {"a:accepts"})
        # Same denominator whether or not the tool was called.
        answered = llm_eval.score_case(rule, chat_response("no call"))
        self.assertEqual(answered["total"], r["total"])

    def test_accepts_bad_shape_is_an_error(self):
        with self.assertRaises(ValueError):
            llm_eval.score_case(
                {"tools": {}, "accepts": {"a": ["q"]}}, chat_response("x")
            )

    def test_unparseable_tool_arguments(self):
        r = llm_eval.score_case(ROUTE, chat_response(calls=[("get_income", "{nope")]))
        self.assertIn("*:parses", failed(r))

    def test_unknown_keys_are_errors(self):
        with self.assertRaises(ValueError):
            llm_eval.score_case({"tools": {}, "bogus": 1}, chat_response("x"))
        with self.assertRaises(ValueError):
            llm_eval.score_case(
                {"reply": {"numbers": {"x": {"any": [1], "pct": 1}}}},
                chat_response("1"),
            )

    def test_audit_sees_reply_values_and_numbers_not_tool_names(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            case = Path(tmp) / "app-chat" / "income"
            case.mkdir(parents=True)
            (case / "expected.json").write_text(json.dumps({**ROUTE, **ANSWER}))
            hits, _ = llm_eval.audit(
                "get_income was called; ACME paid 1,234.56 (YTD)", Path(tmp)
            )
        self.assertLessEqual({"ACME", "1,234.56", "YTD"}, set(hits))
        self.assertFalse({"get_income", "record_activity"} & set(hits))


class Compare(unittest.TestCase):
    def run_of(self, trials: list[dict]) -> dict:
        return {
            "host": "terra",
            "model": "text",
            "resolved_model": "org/model-GGUF:Q4_K_M",
            "trials": len(trials),
            "started": "2026-11-19T00:00Z",
            "fixtures_commit": "abc1234",
            "cases": [
                {"feature": "paperless-classify", "case": "widget", "trials": trials}
            ],
        }

    def test_public_render_never_contains_expected_values(self):
        miss = llm_eval.score_case(EXPECTED, tool_response({"title": "x", "tags": []}))
        broken = llm_eval.score_case(EXPECTED, tool_response("{not json"))
        run = self.run_of([miss, broken])

        private = llm_eval.render([run])
        public = llm_eval.render([run], public=True)

        self.assertIn("must:home-office", private)
        for value in ("home-office", "Manual", "Guide", "Customer"):
            self.assertNotIn(value, public)
        self.assertIn("`tags:must`", public)
        self.assertIn("`tags:link`", public)
        self.assertIn("`document_types:link`", public)
        # Scores and speed are unchanged by redaction.
        self.assertEqual(private.split("## Failed")[0], public.split("## Failed")[0])
        self.assertEqual(private.split("## Speed")[1], public.split("## Speed")[1])

    def test_public_labels_count_distinct_checks_per_rule_kind(self):
        record = {
            "trials": [
                {
                    "checks": [
                        {
                            "field": "tags",
                            "check": "must:a",
                            "pass": False,
                            "detail": "",
                        },
                        {
                            "field": "tags",
                            "check": "must:b",
                            "pass": False,
                            "detail": "",
                        },
                        {
                            "field": "*",
                            "check": "parses",
                            "pass": False,
                            "detail": "bad",
                        },
                    ]
                },
                {
                    "checks": [
                        {
                            "field": "tags",
                            "check": "must:a",
                            "pass": False,
                            "detail": "",
                        }
                    ]
                },
            ]
        }
        self.assertEqual(
            llm_eval.failed_labels(record, public=True),
            ["*:parses (bad)", "tags:must ×2"],
        )
        self.assertEqual(
            llm_eval.failed_labels(record, public=False),
            ["*:parses (bad)", "tags:must:a", "tags:must:b"],
        )


class CompareCaseSets(unittest.TestCase):
    def test_warns_when_runs_cover_different_cases(self):
        trial = llm_eval.score_case(EXPECTED, tool_response({"title": "x"}))

        def run(cases: list[str], alias: str | None) -> dict:
            return {
                "host": "terra",
                "model": "m",
                "resolved_model": "m",
                "trials": 1,
                "started": "s",
                "fixtures_commit": "c",
                "filter": {"alias": alias, "feature": None},
                "cases": [
                    {"feature": "f", "case": c, "trials": [trial]} for c in cases
                ],
            }

        same = llm_eval.render([run(["a"], "text"), run(["a"], "text")])
        differ = llm_eval.render([run(["a"], "text"), run(["a", "b"], None)])
        self.assertNotIn("Warning", same)
        self.assertIn("Warning", differ)


TEXT_EXPECTED = {
    "recover": {
        "vendor": ["Acme Widget Co"],
        "total": ["123.45"],
        "date": ["Jan 2/27", "2027-01-02"],
    }
}


def text_response(content: str | None, finish: str = "stop") -> dict:
    return {"choices": [{"message": {"content": content}, "finish_reason": finish}]}


class ScoreTextCase(unittest.TestCase):
    def test_layout_and_punctuation_do_not_count(self):
        r = llm_eval.score_case(
            TEXT_EXPECTED,
            text_response("ACME widget co.\nDate: Jan 2/27\nTOTAL 123\n45\n"),
        )
        self.assertEqual(failed(r), set())
        self.assertEqual(r["total"], 5)

    def test_any_spelling_passes(self):
        r = llm_eval.score_case(
            TEXT_EXPECTED, text_response("Acme Widget Co 2027-01-02 123.45")
        )
        self.assertEqual(failed(r), set())

    def test_whole_word_only(self):
        r = llm_eval.score_case(
            TEXT_EXPECTED, text_response("Acme Widget Corp 9123.456 Jan 2/27")
        )
        self.assertEqual(failed(r), {"vendor:recovered", "total:recovered"})

    def test_empty_answer_fails_every_check_with_same_total(self):
        for response in (text_response(None), text_response(""), {}):
            r = llm_eval.score_case(TEXT_EXPECTED, response)
            self.assertEqual(r["passed"], 0)
            self.assertEqual(r["total"], 5)

    def test_truncation_is_its_own_failure(self):
        r = llm_eval.score_case(
            TEXT_EXPECTED, text_response("Acme Widget Co Jan 2/27", "length")
        )
        self.assertEqual(failed(r), {"*:complete", "total:recovered"})


class Audit(unittest.TestCase):
    def setUp(self):
        import tempfile

        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Path(self.tmp.name)
        for name, expected in [
            ("widget-manual", EXPECTED),
            ("widget", {"tags": {"must": ["Blue Widget", "HR"]}}),
            ("receipt", TEXT_EXPECTED),
        ]:
            case = self.fx / "paperless-classify" / name
            case.mkdir(parents=True)
            (case / "expected.json").write_text(json.dumps(expected))

    def tearDown(self):
        self.tmp.cleanup()

    def hits(self, text: str) -> list[str]:
        return llm_eval.audit(text, self.fx)[0]

    def test_qualified_case_ids_are_public(self):
        clean = "paperless-classify/widget-manual: 8.0/10, `tags:must` ×2"
        self.assertEqual(self.hits(clean), [])
        self.assertEqual(self.hits("paperless-classify/widget 3/3"), [])

    def test_matches_names_the_way_the_scorer_does(self):
        for text in ("missed home-office", "missed Home Office", "missed home_office"):
            self.assertEqual(self.hits(text), ["home-office"], text)
        self.assertEqual(self.hits("no MANUAL type"), ["Manual"])
        # Word-bounded: a value inside a longer word isn't a hit.
        self.assertEqual(self.hits("Manually re-run"), [])

    def test_bare_case_name_does_not_mask_a_value(self):
        # `widget` is a case name; "Blue Widget" is still a value.
        self.assertEqual(self.hits("it missed Blue Widget"), ["Blue Widget"])

    def test_recovered_text_values_are_checked(self):
        self.assertEqual(self.hits("it read Acme Widget Co fine"), ["Acme Widget Co"])
        # Field labels are public; only the spellings are fixture content.
        self.assertEqual(self.hits("vendor:recovered failed"), [])

    def test_short_values_are_checked(self):
        self.assertEqual(self.hits("tagged it HR"), ["HR"])
        self.assertEqual(self.hits("HRM"), [])


if __name__ == "__main__":
    unittest.main()
