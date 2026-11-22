#!/usr/bin/env python3
"""Replay private eval fixtures against one llama-server model and score them (#555).

Fixtures live in the private sibling checkout `../nix-eval-fixtures`; see the
Evaluation section of modules/system/_llama-cpp/README.md for the contract.
Each case is `<feature>/<case>/{request.json,expected.json,meta.toml}`.
`request.json` is the app's real captured /v1/chat/completions body. The only
changes made to it are `model` (the model under test) and `stream` (off).

Nothing here prints fixture content. Output goes to the fixtures repo's
`results/` directory, which is private for the same reason the fixtures are.

Subcommands:
  gate     tier-0 pass/fail gates for one model against one alias's target
           (tool-call round trip, input modalities, context, resident VRAM).
           Synthetic probes only, so it needs no fixtures and prints nothing
           private.
  run      replay every case against --model at --endpoint and write a run dir
  rescore  re-score a run's saved responses against the current expected.json
  compare  render a markdown comparison of two or more run dirs; --public
           drops the expected values that check labels carry
  audit    fail if a draft bound for a public issue contains an expected value
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import struct
import time
import tomllib
import urllib.error
import urllib.request
import zlib

LIST_RULE_KEYS = {"must", "must_not", "want", "may_be_empty", "link", "ignore", "note"}
TYPOGRAPHY = str.maketrans({**dict.fromkeys("‐‑‒–—−", "-"), "‘": "'", "’": "'"})


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------


def norm(value: object) -> str:
    """Compare names loosely: case, hyphens/underscores and spacing don't matter.

    "Home Office" and "home-office" are the same *name*. Whether the model
    also linked it to the existing object is a separate `link` check.
    """
    # Models print typographic dashes and apostrophes (gpt-oss writes
    # "ACME‑CORP" with U+2011 and "aren’t" with U+2019); fold them to
    # the ASCII a fixture author types.
    text = str(value).lower().translate(TYPOGRAPHY).replace("-", " ").replace("_", " ")
    return re.sub(r"\s+", " ", text).strip()


def mentions(name: str, names: set[str]) -> bool:
    """Whole-word containment: 'EnerGuide' is satisfied by 'EnerGuide Report'."""
    pattern = re.compile(r"(?<!\w)" + re.escape(norm(name)) + r"(?!\w)")
    return any(pattern.search(n) for n in names)


def singular(field: str) -> str:
    return field[:-1] if field.endswith("s") else field


def extract_arguments(response: dict) -> tuple[dict | None, str | None]:
    """The structured answer: a tool call's arguments, else JSON message content."""
    try:
        message = response["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return None, "no choices[0].message in response"
    raw = None
    calls = message.get("tool_calls") or []
    if calls:
        raw = calls[0].get("function", {}).get("arguments")
    elif message.get("content"):
        raw = message["content"]
    if raw is None:
        return None, "no tool call and no content"
    if isinstance(raw, dict):
        return raw, None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        return None, f"arguments are not JSON: {exc.msg}"
    if not isinstance(parsed, dict):
        return None, "arguments are not a JSON object"
    return parsed, None


def clean_item(item: object) -> bool:
    """One value per list item: no JSON fragments fused into a single string."""
    return isinstance(item, (str, int)) and not re.search(r'["\n]|\\"', str(item))


def check(field: str, name: str, passed: bool, detail: str = "") -> dict:
    return {"field": field, "check": name, "pass": bool(passed), "detail": detail}


def score_list_field(field: str, rule: dict, args: dict) -> list[dict]:
    if rule.get("ignore"):
        return []
    unknown = set(rule) - LIST_RULE_KEYS
    if unknown:
        raise ValueError(f"{field}: unknown rule keys {sorted(unknown)}")

    suggested = [v for v in args.get(field) or [] if v is not None]
    matched = [v for v in args.get(f"matched_{field}") or [] if v is not None]
    ids = args.get(f"{singular(field)}_ids") or []
    names = {norm(v) for v in suggested + matched}
    out = []

    for name in rule.get("must", []):
        out.append(check(field, f"must:{name}", mentions(name, names)))
    for name in rule.get("must_not", []):
        out.append(check(field, f"must_not:{name}", not mentions(name, names)))

    want = rule.get("want", [])
    may_be_empty = rule.get("may_be_empty", False)
    if want or may_be_empty:
        hit = any(mentions(w, names) for w in want)
        if may_be_empty:
            # Empty is right; so is a wanted name. Anything else was invented.
            passed = not names or hit
            label = "want-or-empty" if want else "empty"
        else:
            passed = hit
            label = "want"
        out.append(check(field, label, passed, f"{len(names)} suggested"))

    must = {norm(m) for m in rule.get("must", [])}
    for name, oid in (rule.get("link") or {}).items():
        # Reconciliation is scored for names that are required or that the
        # model chose to suggest. An optional name it didn't suggest is a
        # `want` question, not a linking failure. It still emits a (passing)
        # check so every trial of a case has the same denominator.
        if norm(name) not in must and not mentions(name, names):
            out.append(check(field, f"link:{name}", True, "n/a: not suggested"))
            continue
        linked = norm(name) in {norm(m) for m in matched} and oid in ids
        out.append(check(field, f"link:{name}", linked))
    return out


def text_norm(value: object) -> str:
    """OCR text compares on letters and digits alone: punctuation, case and
    layout don't count, so "240.45" matches a transcription that put dollars
    and cents in separate columns ("240 / 45")."""
    return re.sub(r"[^0-9a-z]+", " ", str(value).lower()).strip()


def score_text_case(expected: dict, response: dict) -> dict:
    """Free-text answers (`image-to-text`): did each field come back?

    `expected["recover"]` maps a field label to its accepted spellings. A
    field passes when any spelling appears, whole-word, in the message
    content after `text_norm`. One check per field, plus `*:non-empty` and
    `*:complete` (not cut off at max_tokens).
    """
    try:
        choice = response["choices"][0]
        content = choice["message"].get("content") or ""
        finish = choice.get("finish_reason")
    except (KeyError, IndexError, TypeError, AttributeError):
        content, finish = "", None
    text = f" {text_norm(content)} "
    # A transcription cut off at max_tokens loses its tail fields. Its own
    # check says so, instead of that reading as misread handwriting.
    checks = [
        check("*", "non-empty", bool(text.strip())),
        check("*", "complete", bool(text.strip()) and finish != "length"),
    ]
    for field, spellings in expected["recover"].items():
        found = any(f" {text_norm(s)} " in text for s in spellings if text_norm(s))
        checks.append(check(field, "recovered", found))
    return summarize(checks)


TRACE_KEYS = {"tools", "args", "accepts", "reply", "note"}
NUMBER_RULE_KEYS = {"any", "rel", "tol"}
# A figure as a chat reply writes it: "$1,234.56", "12 345.67" (U+202F
# thousands separator), "7.30%", "about 1.2k". Sign is ignored ("a loss of
# $1,234" and "-1,234" are the same answer).
THOUSANDS = ",  "
NUMBER_RE = re.compile(
    rf"(?<![\w.])(?:\d{{1,3}}(?:[{THOUSANDS}]\d{{3}})+|\d+)(?:\.\d+)?(?:\s?[kK]\b)?"
)


def numbers_in(text: str) -> list[float]:
    out = []
    for match in NUMBER_RE.finditer(text):
        raw = re.sub(f"[{THOUSANDS}]", "", match.group(0)).strip()
        scale = 1
        if raw[-1] in "kK":
            raw, scale = raw[:-1].strip(), 1000
        try:
            out.append(float(raw) * scale)
        except ValueError:
            continue
    return out


def number_found(rule: dict, found: list[float]) -> bool:
    """Any accepted value appears, within max(tol, rel * value). The default
    0.5% lets "about $1,235" stand for 1,234.56 and "7.3%" for 7.31234%."""
    unknown = set(rule) - NUMBER_RULE_KEYS
    if unknown:
        raise ValueError(f"number rule: unknown keys {sorted(unknown)}")
    rel, tol = rule.get("rel", 0.005), rule.get("tol", 0)
    return any(
        abs(n - abs(v)) <= max(tol, rel * abs(v)) for v in rule["any"] for n in found
    )


def tool_calls_of(message: dict) -> list[tuple[str, dict | None]]:
    calls = []
    for call in message.get("tool_calls") or []:
        fn = call.get("function") or {}
        raw = fn.get("arguments")
        if isinstance(raw, str):
            try:
                raw = json.loads(raw) if raw.strip() else {}
            except json.JSONDecodeError:
                raw = None
        calls.append((fn.get("name") or "", raw if isinstance(raw, dict) else None))
    return calls


def score_accepts(
    tool: str, per_action: dict, calls: list[tuple[str, dict | None]]
) -> dict:
    """Would the app's own per-action schema accept every call to `tool`?

    Apps that publish one flat argument list for a multi-action tool, but
    validate each action strictly, reject a call that carries another
    action's argument (`date` sent with an action that takes none). An
    absent-argument rule can't express that, since the same key is valid on
    a sibling action, so this mirrors the app's schema instead:
    `{"<action>": [allowed keys]}`, with `*` for every action not listed.
    The `action` key itself is always allowed. A call whose action isn't
    listed (and no `*`) isn't judged. One check per tool, passing when the
    tool isn't called, so every trial has the same total.
    """
    bad_shape = not isinstance(per_action, dict) or not all(
        isinstance(keys, list) for keys in per_action.values()
    )
    if bad_shape:
        raise ValueError(f"accepts.{tool}: want {{action: [keys]}}")
    rejected = []
    for name, args in calls:
        if name != tool or args is None:
            continue
        action = args.get("action")
        allowed = per_action.get(action, per_action.get("*"))
        if allowed is None:
            continue
        extra = sorted(set(args) - set(allowed) - {"action"})
        if extra:
            rejected.append(f"{action or '*'}: {', '.join(extra)}")
    return check(tool, "accepts", not rejected, "; ".join(rejected))


def score_trace_case(expected: dict, response: dict) -> dict:
    """One turn of a tool-using chat (`tool-trace`): which tools it called,
    with what arguments, and what its reply says.

    The captured request freezes everything the turn depends on (the app's
    date context, earlier tool results), so expected values are fixed to that
    snapshot. Rules reuse the list-rule vocabulary:

    - `tools`: called tool names. `{"may_be_empty": true}` alone means the
      turn must answer without calling anything.
    - `args`: `"<tool>.<arg>"` (or `"<tool>.<a>|<b>"`: the first present) to
      a list rule over that argument's value in the tool's first call.
    - `accepts`: `{"<tool>": {"<action>": [keys]}}`, the keys the app's
      schema allows per action; see `score_accepts`.
    - `reply`: a list rule matched whole-word against the message content,
      plus `numbers`: `{label: {"any": [values], "rel": 0.005, "tol": 0}}`.
    """
    unknown = set(expected) - TRACE_KEYS
    if unknown:
        raise ValueError(f"tool-trace: unknown keys {sorted(unknown)}")
    try:
        choice = response["choices"][0]
        message = choice["message"] or {}
        finish = choice.get("finish_reason")
    except (KeyError, IndexError, TypeError):
        message, finish = {}, None
    content = message.get("content") or ""
    calls = tool_calls_of(message)
    names = [name for name, _ in calls]
    bad_args = sum(args is None for _, args in calls)
    checks = [
        check("*", "complete", bool(content.strip() or calls) and finish != "length"),
        check(
            "*", "parses", not bad_args, f"{bad_args} unparseable" if bad_args else ""
        ),
    ]

    if "tools" in expected:
        checks.extend(score_list_field("tools", expected["tools"], {"tools": names}))

    for key, rule in (expected.get("args") or {}).items():
        tool, _, arg_names = key.partition(".")
        args = next((a for n, a in calls if n == tool and a is not None), {})
        value = next(
            (args[a] for a in arg_names.split("|") if args.get(a) is not None), None
        )
        values = value if isinstance(value, list) else [] if value is None else [value]
        checks.extend(score_list_field(key, rule, {key: values}))

    for tool, per_action in sorted((expected.get("accepts") or {}).items()):
        checks.append(score_accepts(tool, per_action, calls))

    reply = expected.get("reply")
    if reply is not None:
        unknown = set(reply) - LIST_RULE_KEYS - {"numbers"}
        if unknown:
            raise ValueError(f"reply: unknown rule keys {sorted(unknown)}")
        list_rule = {k: v for k, v in reply.items() if k != "numbers"}
        texts = [content] if content.strip() else []
        checks.extend(score_list_field("reply", list_rule, {"reply": texts}))
        found = numbers_in(content)
        for label_, rule in (reply.get("numbers") or {}).items():
            checks.append(check("reply", f"number:{label_}", number_found(rule, found)))
    return summarize(checks)


def score_case(expected: dict, response: dict) -> dict:
    if "recover" in expected:
        return score_text_case(expected, response)
    if expected.keys() & {"tools", "reply"}:
        return score_trace_case(expected, response)
    args, error = extract_arguments(response)
    finish = ((response.get("choices") or [{}])[0] or {}).get("finish_reason")
    if error and finish == "length":
        # Typically a reasoning model that thought until the context ran out.
        error = f"{error} (finish_reason=length: ran out of tokens)"
    checks = [check("*", "parses", args is not None, error or "")]
    if args is None:
        # Every other check fails too, so a broken answer can't score above
        # an empty-but-valid one by skipping its checks, and its total
        # matches a valid answer's.
        checks.append(check("*", "clean-items", False, "no answer"))
        for field, rule in expected.items():
            if field == "title":
                checks.append(check(field, "present", False))
            elif isinstance(rule, dict) and not rule.get("ignore"):
                checks.extend(
                    {**c, "pass": False} for c in score_list_field(field, rule, {})
                )
        return summarize(checks)

    items = [v for k, val in args.items() if isinstance(val, list) for v in val]
    bad = [v for v in items if not clean_item(v)]
    checks.append(check("*", "clean-items", not bad, f"{len(bad)} malformed"))

    for field, rule in expected.items():
        if field == "title":
            checks.append(
                check(field, "present", bool(str(args.get("title") or "").strip()))
            )
        elif isinstance(rule, dict):
            checks.extend(score_list_field(field, rule, args))
    return summarize(checks)


def summarize(checks: list[dict]) -> dict:
    passed = sum(c["pass"] for c in checks)
    return {"passed": passed, "total": len(checks), "checks": checks}


# --------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------


def load_cases(
    fixtures: Path, feature: str | None, alias: str | None = None
) -> list[dict]:
    cases = []
    for request in sorted(fixtures.glob("*/*/request.json")):
        case_dir = request.parent
        feat = case_dir.parent.name
        if feature and feat != feature:
            continue
        meta_path = case_dir / "meta.toml"
        meta = tomllib.loads(meta_path.read_text()) if meta_path.exists() else {}
        if meta.get("retired"):
            continue
        if alias and meta.get("alias") != alias:
            if not meta.get("alias"):
                print(
                    f"skip {feat}/{case_dir.name}: no alias in meta.toml",
                    file=sys.stderr,
                )
            continue
        expected_path = case_dir / "expected.json"
        if not expected_path.exists():
            print(f"skip {feat}/{case_dir.name}: no expected.json", file=sys.stderr)
            continue
        body = request.read_bytes()
        cases.append(
            {
                "feature": feat,
                "case": case_dir.name,
                "alias": meta.get("alias"),
                "request": json.loads(body),
                "request_sha256": hashlib.sha256(body).hexdigest(),
                "expected": json.loads(expected_path.read_text()),
            }
        )
    return cases


def http_json(url: str, key: str | None, body: dict | None = None, timeout: int = 900):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def model_entry(endpoint: str, key: str | None, model: str) -> dict | None:
    """The router's /v1/models entry for a router name or alias, or None."""
    try:
        listing = http_json(f"{endpoint}/v1/models", key, timeout=30)
    except (urllib.error.URLError, OSError):
        return None
    for entry in listing.get("data", []):
        if model == entry.get("id") or model in (entry.get("aliases") or []):
            return entry
    return None


def resolve_model(endpoint: str, key: str | None, model: str) -> str | None:
    """The GGUF a router name points at, so a result outlives alias moves."""
    return (model_entry(endpoint, key, model) or {}).get("id")


def git_head(path: Path) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "--short", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("_")


def cmd_run(ns: argparse.Namespace) -> int:
    fixtures = Path(ns.fixtures)
    if not fixtures.is_dir():
        print(f"warning: no fixtures checkout at {fixtures}; skipping", file=sys.stderr)
        return 0
    cases = load_cases(fixtures, ns.feature, ns.alias)
    if not cases:
        print("no cases matched", file=sys.stderr)
        return 1

    key = os.environ.get("LLAMA_API_KEY") or None
    endpoint = ns.endpoint.rstrip("/")
    resolved = resolve_model(endpoint, key, ns.model)
    if resolved is None:
        print(f"model {ns.model!r} is not routable at {endpoint}", file=sys.stderr)
        return 1

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%MZ")
    run_dir = fixtures / "results" / f"{stamp}-{slug(ns.host)}-{slug(ns.model)}"
    (run_dir / "responses").mkdir(parents=True)

    run = {
        "host": ns.host,
        "model": ns.model,
        "resolved_model": resolved,
        "endpoint": endpoint,
        "trials": ns.trials,
        "filter": {"alias": ns.alias, "feature": ns.feature},
        "started": stamp,
        "fixtures_commit": git_head(fixtures),
        "harness_commit": git_head(Path(__file__).resolve().parent),
        "cases": [],
    }
    for case in cases:
        # cache_prompt off: replays repeat the same prompt back to back, and a
        # cache hit would report a near-zero prefill instead of the real one.
        body = dict(case["request"], model=ns.model, stream=False, cache_prompt=False)
        record = {
            "feature": case["feature"],
            "case": case["case"],
            "request_sha256": case["request_sha256"],
            "trials": [],
        }
        for trial in range(1, ns.trials + 1):
            started = time.monotonic()
            try:
                response = http_json(f"{endpoint}/v1/chat/completions", key, body)
                error = None
            except urllib.error.HTTPError as exc:
                response, error = {}, f"HTTP {exc.code}"
            except (urllib.error.URLError, OSError) as exc:
                response, error = {}, f"{type(exc).__name__}: {exc}"
            wall = round(time.monotonic() - started, 2)
            name = f"{case['feature']}--{case['case']}--t{trial}.json"
            (run_dir / "responses" / name).write_text(
                json.dumps(response, indent=2) + "\n"
            )
            result = score_case(case["expected"], response)
            timings = response.get("timings") or {}
            record["trials"].append(
                {
                    **result,
                    "error": error,
                    "wall_s": wall,
                    "prompt_tokens": (response.get("usage") or {}).get("prompt_tokens"),
                    "completion_tokens": (response.get("usage") or {}).get(
                        "completion_tokens"
                    ),
                    "prompt_tok_s": timings.get("prompt_per_second"),
                    "gen_tok_s": timings.get("predicted_per_second"),
                }
            )
            print(
                f"{case['feature']}/{case['case']} t{trial}: "
                f"{result['passed']}/{result['total']}"
                + (f" ({error})" if error else "")
                + f" in {wall}s"
            )
        run["cases"].append(record)

    (run_dir / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    (run_dir / "summary.md").write_text(render([run]))
    print(f"\nwrote {run_dir}")
    return 0


# --------------------------------------------------------------------------
# Tier-0 gates
# --------------------------------------------------------------------------

# Every probe is synthetic, so gate output is safe to paste into a public
# issue. They test the deployment (this build, template, grammar, context
# and VRAM), not how clever the model is.
WEATHER_TOOL = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name"},
                "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
            },
            "required": ["city", "unit"],
        },
    },
}
WEATHER_ASK = (
    "What's the weather in Calgary right now, in celsius? Use the get_weather tool."
)
WEATHER_RESULT = {"city": "Calgary", "temperature": -17, "unit": "celsius"}
NEEDLE = "7319-KESTREL"
NEEDLE_ASK = (
    "What is the vault code mentioned in the log above? Reply with the code only."
)
FILLER_LINE = "Archive entry {n:05d}: routine maintenance log, nothing to report.\n"
CALIBRATION_LINES = 200
# The context probe is about whether the context holds, not about how long
# the model thinks; ask templates that support it to keep reasoning short.
QUIET = {"chat_template_kwargs": {"enable_thinking": False, "reasoning_effort": "low"}}


def gate(name: str, passed: bool, detail: str = "") -> dict:
    return {"gate": name, "pass": bool(passed), "detail": detail}


def message_of(response: dict) -> dict:
    try:
        return response["choices"][0]["message"] or {}
    except (KeyError, IndexError, TypeError):
        return {}


def finish_of(response: dict) -> str | None:
    try:
        return response["choices"][0].get("finish_reason")
    except (KeyError, IndexError, TypeError, AttributeError):
        return None


def check_tool_call(response: dict) -> tuple[dict, dict | None]:
    """First leg: a parseable get_weather call that honours the schema."""
    calls = message_of(response).get("tool_calls") or []
    if not calls:
        return gate(
            "tool-call", False, f"no tool_calls (finish_reason={finish_of(response)})"
        ), None
    call = calls[0]
    fn = call.get("function") or {}
    if fn.get("name") != WEATHER_TOOL["function"]["name"]:
        return gate("tool-call", False, f"called {fn.get('name')!r}"), None
    raw = fn.get("arguments")
    try:
        args = raw if isinstance(raw, dict) else json.loads(raw or "")
    except json.JSONDecodeError as exc:
        return gate("tool-call", False, f"arguments are not JSON: {exc.msg}"), None
    if not isinstance(args, dict):
        return gate("tool-call", False, "arguments are not a JSON object"), None
    if "calgary" not in norm(args.get("city", "")):
        return gate("tool-call", False, f"city={args.get('city')!r}"), None
    if args.get("unit") != "celsius":
        return gate("tool-call", False, f"unit={args.get('unit')!r}"), None
    return gate("tool-call", True, f"{len(calls)} call(s)"), call


def check_round_trip(response: dict) -> dict:
    """Second leg: the tool result goes back in and an answer comes out."""
    message = message_of(response)
    if message.get("tool_calls"):
        return gate(
            "tool-round-trip", False, "called a tool again instead of answering"
        )
    content = message.get("content") or ""
    if not content.strip():
        return gate(
            "tool-round-trip",
            False,
            f"no answer (finish_reason={finish_of(response)})",
        )
    if not re.search(r"(?<!\d)17(?!\d)", content):
        return gate("tool-round-trip", False, "answer doesn't use the tool result")
    return gate("tool-round-trip", True)


def check_image(response: dict) -> dict:
    content = message_of(response).get("content") or ""
    if not content.strip():
        return gate(
            "image-input", False, f"no answer (finish_reason={finish_of(response)})"
        )
    if not re.search(r"\b(red|crimson|scarlet)\b", content.lower()):
        return gate("image-input", False, "didn't name the colour of a solid red image")
    return gate("image-input", True)


def check_modalities(entry: dict | None, required: list[str]) -> dict:
    declared = ((entry or {}).get("architecture") or {}).get("input_modalities")
    if declared is None:
        return gate("modalities", False, "router reports no input_modalities")
    missing = sorted(set(required) - set(declared))
    if missing:
        return gate("modalities", False, f"missing {', '.join(missing)}")
    return gate("modalities", True, ", ".join(declared))


def context_prompt(lines: int) -> str:
    """Filler with the needle a tenth of the way in, then the question."""
    depth = lines // 10
    head = "".join(FILLER_LINE.format(n=i) for i in range(depth))
    tail = "".join(FILLER_LINE.format(n=i) for i in range(depth, lines))
    return f"{head}Note: the vault code is {NEEDLE}.\n{tail}\n{NEEDLE_ASK}"


def context_plan(ctx: int, base_tokens: int, calib_tokens: int) -> tuple[int, int]:
    """Filler lines to reach the target prompt size, and the answer budget.

    The answer gets max(2048, ctx/10) tokens; the prompt gets the rest.
    """
    headroom = max(2048, ctx // 10)
    per_line = (calib_tokens - base_tokens) / CALIBRATION_LINES
    if per_line <= 0:
        raise ValueError("calibration measured no tokens per filler line")
    lines = int((ctx - headroom - base_tokens) / per_line)
    return max(lines, 0), headroom


def check_context(response: dict, ctx: int, target_prompt: int) -> dict:
    usage = response.get("usage") or {}
    prompt = usage.get("prompt_tokens") or 0
    detail = f"{prompt}/{ctx} tokens"
    if prompt < 0.95 * target_prompt:
        return gate("context", False, f"{detail}: under the {target_prompt} aimed for")
    content = message_of(response).get("content") or ""
    if NEEDLE.lower() not in content.lower():
        return gate(
            "context",
            False,
            f"{detail}: needle not recalled (finish_reason={finish_of(response)})",
        )
    return gate("context", True, detail)


def gpu_usage(nvidia_csv: str, ps_out: str, model_id: str) -> int | None:
    """MiB held by the llama-server child serving model_id, or None.

    The router spawns one child per loaded model with `--alias <id>`;
    nvidia-smi reports memory per pid.
    """
    pids = set()
    for line in ps_out.splitlines():
        parts = line.split()
        if len(parts) < 2 or "llama-server" not in line:
            continue
        for flag, value in zip(parts, parts[1:]):
            if flag == "--alias" and value == model_id:
                pids.add(parts[0])
    used = None
    for line in nvidia_csv.splitlines():
        cols = [c.strip() for c in line.split(",")]
        if len(cols) >= 2 and cols[0] in pids and cols[1].isdigit():
            used = (used or 0) + int(cols[1])
    return used


def check_vram(
    used: int | None, budget: int, served_ctx: int | None, target_ctx: int
) -> dict:
    """Resident memory against the budget, valid only at the target context.

    The KV cache is allocated for the served context at load, so a model
    served smaller than the alias needs would under-report what it costs.
    """
    if used is None:
        return gate("vram", False, "no GPU process found for the model")
    detail = f"{used}/{budget} MiB"
    if served_ctx is None:
        return gate("vram", False, f"{detail}, but the served context is unknown")
    if served_ctx < target_ctx:
        return gate(
            "vram", False, f"{detail}, but served at {served_ctx} < {target_ctx} tokens"
        )
    return gate("vram", used <= budget, detail)


def solid_png(rgb: tuple[int, int, int], size: int = 64) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    row = b"\x00" + bytes(rgb) * size
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * size))
        + chunk(b"IEND", b"")
    )


def post(
    endpoint: str, key: str | None, body: dict, timeout: int = 900
) -> tuple[dict, str | None]:
    try:
        return http_json(f"{endpoint}/v1/chat/completions", key, body, timeout), None
    except urllib.error.HTTPError as exc:
        # llama-server's error bodies are its own messages, not prompt text.
        text = exc.read().decode(errors="replace")[:200]
        return {}, f"HTTP {exc.code}: {text}"
    except (urllib.error.URLError, OSError) as exc:
        return {}, f"{type(exc).__name__}: {exc}"


def probe(ssh: str | None, argv: list[str]) -> str:
    cmd = (["ssh", "-n", ssh] if ssh else []) + argv
    return subprocess.check_output(cmd, text=True, timeout=60)


def cmd_gate(ns: argparse.Namespace) -> int:
    contract = json.loads(ns.targets)
    target = contract["targets"].get(ns.alias)
    if target is None:
        print(
            f"{ns.alias!r} is not an eval target on {ns.host}; "
            f"targets: {', '.join(sorted(contract['targets']))}",
            file=sys.stderr,
        )
        return 1
    model = ns.model or target["incumbent"]
    key = os.environ.get("LLAMA_API_KEY") or None
    endpoint = ns.endpoint.rstrip("/")
    resolved = resolve_model(endpoint, key, model)
    if resolved is None:
        print(f"model {model!r} is not routable at {endpoint}", file=sys.stderr)
        return 1
    # Address the model by its resolved id throughout, so an alias moving
    # mid-run can't switch what is being measured.
    base = {"model": resolved, "stream": False, "cache_prompt": False}
    gates = []

    def say(g: dict) -> None:
        gates.append(g)
        print(f"{g['gate']}: {'pass' if g['pass'] else 'FAIL'} {g['detail']}".rstrip())

    # Tool call, sent the way an app sends it: no reasoning overrides.
    ask = [{"role": "user", "content": WEATHER_ASK}]
    response, error = post(
        endpoint, key, {**base, "messages": ask, "tools": [WEATHER_TOOL]}
    )
    first, call = (
        (gate("tool-call", False, error), None) if error else check_tool_call(response)
    )
    say(first)
    if call is None:
        say(gate("tool-round-trip", False, "skipped: no tool call to answer"))
    else:
        message = message_of(response)
        history = ask + [
            {
                "role": "assistant",
                "content": message.get("content") or "",
                "tool_calls": message["tool_calls"],
            },
            {
                "role": "tool",
                "tool_call_id": call.get("id", ""),
                "content": json.dumps(WEATHER_RESULT),
            },
        ]
        response, error = post(
            endpoint, key, {**base, "messages": history, "tools": [WEATHER_TOOL]}
        )
        say(
            gate("tool-round-trip", False, error)
            if error
            else check_round_trip(response)
        )

    if "image" in target["modalities"]:
        # 256 px, not smaller: at 64 px the image is ~16 tokens and
        # Qwen3-VL-4B answered "Black" for solid red (2026-11-20, #986),
        # failing a deployment that reads handwriting fine. 256 px costs
        # 85 prompt tokens and both vision incumbents answer "Red".
        image = (
            "data:image/png;base64,"
            + base64.b64encode(solid_png((220, 20, 20), size=256)).decode()
        )
        content = [
            {"type": "text", "text": "What colour is this image? Answer in one word."},
            {"type": "image_url", "image_url": {"url": image}},
        ]
        response, error = post(
            endpoint,
            key,
            {
                **base,
                **QUIET,
                "max_tokens": 512,
                "messages": [{"role": "user", "content": content}],
            },
        )
        say(gate("image-input", False, error) if error else check_image(response))

    # Context: calibrate tokens per filler line, then fill the alias's
    # whole context minus answer headroom and ask for the needle.
    ctx = target["contextTokens"]
    speed = {}
    sizes = []
    for lines in (0, CALIBRATION_LINES):
        msgs = [{"role": "user", "content": context_prompt(lines)}]
        response, error = post(
            endpoint, key, {**base, **QUIET, "max_tokens": 1, "messages": msgs}
        )
        sizes.append((response.get("usage") or {}).get("prompt_tokens"))
        if error or sizes[-1] is None:
            break
    if None in sizes or len(sizes) < 2:
        say(gate("context", False, f"calibration failed: {error or 'no usage'}"))
    else:
        lines, headroom = context_plan(ctx, sizes[0], sizes[1])
        target_prompt = ctx - headroom
        msgs = [{"role": "user", "content": context_prompt(lines)}]
        response, error = post(
            endpoint,
            key,
            {**base, **QUIET, "max_tokens": headroom // 2, "messages": msgs},
            # terra's CPU-offloaded `code` takes ~2.5 min at 118k tokens;
            # leave room for a slower challenger before calling it a failure.
            timeout=3600,
        )
        say(
            gate("context", False, error)
            if error
            else check_context(response, ctx, target_prompt)
        )
        timings = response.get("timings") or {}
        speed = {
            "prompt_tokens": (response.get("usage") or {}).get("prompt_tokens"),
            "prompt_tok_s": timings.get("prompt_per_second"),
            "gen_tok_s": timings.get("predicted_per_second"),
        }

    # Measured last, after the largest request, while the model is resident.
    entry = model_entry(endpoint, key, resolved)
    if entry is None:
        say(gate("modalities", False, "router listing unavailable"))
    else:
        say(check_modalities(entry, target["modalities"]))
    status = ((entry or {}).get("status") or {}).get("value")
    if status != "loaded":
        say(gate("vram", False, f"model is {status!r}, not loaded, when measured"))
    else:
        try:
            nvidia = probe(
                ns.ssh,
                [
                    "nvidia-smi",
                    "--query-compute-apps=pid,used_memory",
                    "--format=csv,noheader,nounits",
                ],
            )
            procs = probe(ns.ssh, ["ps", "-eo", "pid,args"])
            say(
                check_vram(
                    gpu_usage(nvidia, procs, resolved),
                    contract["residentBudgetMiB"],
                    ((entry or {}).get("meta") or {}).get("n_ctx"),
                    ctx,
                )
            )
        except (subprocess.SubprocessError, OSError) as exc:
            say(gate("vram", False, f"probe failed: {exc}"))

    result = {
        "host": ns.host,
        "alias": ns.alias,
        "model": model,
        "resolved_model": resolved,
        "incumbent": target["incumbent"],
        "context_tokens": ctx,
        "resident_budget_mib": contract["residentBudgetMiB"],
        "at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%MZ"),
        "harness_commit": git_head(Path(__file__).resolve().parent),
        "speed_at_context": speed,
        "gates": gates,
    }
    print()
    sys.stdout.write(render_gates(result))
    if ns.json:
        Path(ns.json).write_text(json.dumps(result, indent=2) + "\n")
    return 0 if all(g["pass"] for g in gates) else 1


def render_gates(result: dict) -> str:
    passed = sum(g["pass"] for g in result["gates"])
    role = (
        "incumbent" if result["resolved_model"] == result["incumbent"] else "challenger"
    )
    speed = result["speed_at_context"]
    lines = [
        f"## Tier-0 gates: {result['host']} `{result['alias']}`",
        "",
        f"- model: `{result['resolved_model']}` ({role})",
        f"- target: {result['context_tokens']} tokens context, "
        f"{result['resident_budget_mib']} MiB resident budget",
        f"- {passed}/{len(result['gates'])} gates passed, {result['at']}, "
        f"harness `{result['harness_commit']}`",
    ]
    if speed.get("prompt_tok_s") is not None:
        lines.append(
            f"- at {speed['prompt_tokens']} tokens: "
            f"{speed['prompt_tok_s']:.0f} prompt tok/s, "
            f"{speed['gen_tok_s'] or 0:.1f} gen tok/s"
        )
    lines += ["", "| gate | result | detail |", "| --- | --- | --- |"]
    for g in result["gates"]:
        lines.append(
            f"| {g['gate']} | {'pass' if g['pass'] else '**FAIL**'} | {g['detail']} |"
        )
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def label(run: dict) -> str:
    return f"{run['host']} `{run['model']}`"


def case_score(record: dict) -> tuple[float, int]:
    trials = record["trials"]
    passed = sum(t["passed"] for t in trials) / len(trials)
    return passed, trials[0]["total"] if trials else 0


def failed_labels(record: dict, public: bool) -> list[str]:
    """Distinct failed checks across a case's trials.

    A list rule's check label embeds the expected value (`must:<name>`,
    `link:<name>`), which is fixture content. `public` keeps only the field
    and the rule kind, with a count, so the output can go in a public issue.
    """
    failed = {
        (c["field"], c["check"], c["detail"] if c["check"] == "parses" else "")
        for t in record["trials"]
        for c in t["checks"]
        if not c["pass"]
    }
    if not public:
        return sorted(
            f"{field}:{name}" + (f" ({detail})" if detail else "")
            for field, name, detail in failed
        )
    counts: dict[str, int] = {}
    for field, name, detail in failed:
        # A parse error's detail is the harness's own message, not fixture text.
        key = f"{field}:{name.split(':', 1)[0]}" + (f" ({detail})" if detail else "")
        counts[key] = counts.get(key, 0) + 1
    return [f"{k} ×{n}" if n > 1 else k for k, n in sorted(counts.items())]


def render(runs: list[dict], public: bool = False) -> str:
    lines = ["# " + " vs ".join(label(r) for r in runs), ""]
    for r in runs:
        lines.append(
            f"- {label(r)} = `{r['resolved_model']}`, {r['trials']} trial(s), "
            f"started {r['started']}, fixtures `{r['fixtures_commit']}`"
        )
    case_sets = {frozenset((c["feature"], c["case"]) for c in r["cases"]) for r in runs}
    if len(case_sets) > 1:
        # Totals are each run's own denominator, so they aren't comparable.
        lines += [
            "",
            "> **Warning:** these runs cover different cases (filters: "
            + ", ".join(
                f"{label(r)} {json.dumps(r.get('filter') or {}, sort_keys=True)}"
                for r in runs
            )
            + "). Compare per-case rows, not totals; re-run with the same "
            "`ALIAS`/`FEATURE`.",
        ]
    lines += ["", "## Scores", ""]
    lines.append("| case | " + " | ".join(label(r) for r in runs) + " |")
    lines.append("| --- |" + " --- |" * len(runs))
    keys = sorted({(c["feature"], c["case"]) for r in runs for c in r["cases"]})
    totals = [[0.0, 0] for _ in runs]
    for key in keys:
        row = [f"{key[0]}/{key[1]}"]
        for i, r in enumerate(runs):
            rec = next(
                (c for c in r["cases"] if (c["feature"], c["case"]) == key), None
            )
            if rec is None:
                row.append("—")
                continue
            passed, total = case_score(rec)
            totals[i][0] += passed
            totals[i][1] += total
            row.append(f"{passed:.1f}/{total}")
        lines.append("| " + " | ".join(row) + " |")
    lines.append(
        "| **total** | "
        + " | ".join(
            f"**{p:.1f}/{t}** ({100 * p / t:.0f}%)" if t else "—" for p, t in totals
        )
        + " |"
    )

    lines += ["", "## Failed checks", ""]
    for key in keys:
        cells = []
        for r in runs:
            rec = next(
                (c for c in r["cases"] if (c["feature"], c["case"]) == key), None
            )
            if rec is None:
                continue
            failed = failed_labels(rec, public)
            cells.append(
                f"  - {label(r)}: " + (", ".join(f"`{f}`" for f in failed) or "none")
            )
        lines.append(f"- **{key[0]}/{key[1]}**")
        lines.extend(cells)

    lines += ["", "## Speed (mean over cases and trials)", ""]
    lines.append("| run | prompt tok/s | gen tok/s | wall s/case |")
    lines.append("| --- | --- | --- | --- |")
    for r in runs:
        ts = [t for c in r["cases"] for t in c["trials"] if not t.get("error")]

        def mean(field: str) -> str:
            vals = [t[field] for t in ts if t.get(field) is not None]
            return f"{sum(vals) / len(vals):.1f}" if vals else "—"

        lines.append(
            f"| {label(r)} | {mean('prompt_tok_s')} | {mean('gen_tok_s')} | {mean('wall_s')} |"
        )
    return "\n".join(lines) + "\n"


def cmd_rescore(ns: argparse.Namespace) -> int:
    """Re-score saved responses against the current expected.json, in place.

    Correcting an expected answer, or changing the scorer, shouldn't need the
    GPU. Responses are the evidence; scores are derived from them.
    """
    fixtures = Path(ns.fixtures)
    for run_dir in map(Path, ns.runs):
        run = json.loads((run_dir / "run.json").read_text())
        for record in run["cases"]:
            case_dir = fixtures / record["feature"] / record["case"]
            expected = json.loads((case_dir / "expected.json").read_text())
            for n, trial in enumerate(record["trials"], start=1):
                name = f"{record['feature']}--{record['case']}--t{n}.json"
                response = json.loads((run_dir / "responses" / name).read_text())
                trial.update(score_case(expected, response))
        run["rescored_fixtures_commit"] = git_head(fixtures)
        (run_dir / "run.json").write_text(json.dumps(run, indent=2) + "\n")
        (run_dir / "summary.md").write_text(render([run]))
        print(f"rescored {run_dir}")
    return 0


def cmd_compare(ns: argparse.Namespace) -> int:
    runs = [json.loads((Path(d) / "run.json").read_text()) for d in ns.runs]
    sys.stdout.write(render(runs, public=ns.public))
    return 0


def expected_values(fixtures: Path) -> tuple[set[str], list[str]]:
    """Every name an expected.json scores against, and the public case IDs.

    The names are fixture content by definition. Case IDs are returned as
    `<feature>/<case>`, the only form the audit treats as public.
    """
    values: set[str] = set()
    idents = []
    for path in fixtures.glob("*/*/expected.json"):
        idents.append(f"{path.parent.parent.name}/{path.parent.name}")
        expected = json.loads(path.read_text())
        for spellings in (expected.get("recover") or {}).values():
            values.update(str(v) for v in spellings)
        for field, rule in expected.items():
            # Tool names, and the argument keys `accepts` lists, come from
            # the app's own tool schema, not the fixture.
            if field in ("recover", "tools", "accepts") or not isinstance(rule, dict):
                continue
            # `args` nests one list rule per argument.
            for r in rule.values() if field == "args" else [rule]:
                for key in ("must", "must_not", "want", "examples"):
                    values.update(str(v) for v in r.get(key) or [])
                values.update(str(v) for v in r.get("link") or {})
                for number in (r.get("numbers") or {}).values():
                    for v in number["any"]:
                        values.update(number_spellings(v))
    # One-character names can't be told apart from ordinary text.
    return {v for v in values if len(norm(v)) > 1}, idents


def number_spellings(value: float) -> set[str]:
    """How an expected figure would likely be written in a draft."""
    out = {f"{value:,.2f}", f"{value:.2f}"}
    if abs(value) >= 100:
        out |= {f"{value:,.0f}", f"{value:.0f}"}
    return out


def loose_pattern(value: str) -> re.Pattern:
    """Match value the way norm() compares names: case, `-`, `_` and spacing
    are interchangeable, so "Home Office" finds `home-office`."""
    words = [re.escape(w) for w in norm(value).split(" ")]
    return re.compile(r"(?<![^\W_])" + r"[\s_-]+".join(words) + r"(?![^\W_])", re.I)


def audit(text: str, fixtures: Path) -> tuple[list[str], int]:
    """Expected values present in text meant for a public issue, and how many
    values were checked.

    Only fully qualified case IDs (`paperless-classify/furnace-invoice-handwritten`)
    are masked first: they're public by the fixtures contract and often share
    a word with an expected value. A bare case name in prose is not masked,
    because it can't be told apart from the same words used as a value.
    """
    values, idents = expected_values(fixtures)
    for ident in sorted(idents, key=len, reverse=True):
        text = re.sub(
            r"(?<![\w/-])" + re.escape(ident) + r"(?![\w-])", " ", text, flags=re.I
        )
    hits = sorted(v for v in values if loose_pattern(v).search(text))
    return hits, len(values)


def cmd_audit(ns: argparse.Namespace) -> int:
    fixtures = Path(ns.fixtures)
    if not fixtures.is_dir():
        print(f"no fixtures checkout at {fixtures}; cannot audit", file=sys.stderr)
        return 2
    hits, checked = audit(Path(ns.file).read_text(), fixtures)
    if hits:
        # Printed locally only: this is the operator's terminal, not the issue.
        print(f"{ns.file}: {len(hits)} expected value(s) present:", file=sys.stderr)
        for hit in hits:
            print(f"  {hit}", file=sys.stderr)
        return 1
    print(f"{ns.file}: clean against {checked} expected values")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    gt = sub.add_parser("gate")
    gt.add_argument("--targets", required=True, help="myLlamaCpp.evalTargets JSON")
    gt.add_argument("--alias", required=True, help="eval target to gate against")
    gt.add_argument("--model", help="router name to test (default: the incumbent)")
    gt.add_argument("--endpoint", required=True, help="llama-server base URL, no /v1")
    gt.add_argument("--host", required=True, help="label for the results")
    gt.add_argument(
        "--ssh",
        default=os.environ.get("LLM_EVAL_SSH") or None,
        help="run the nvidia-smi/ps probes over ssh to this host (default: local)",
    )
    gt.add_argument("--json", help="also write the result as JSON here")
    gt.set_defaults(func=cmd_gate)
    run = sub.add_parser("run")
    run.add_argument("--fixtures", required=True)
    run.add_argument("--endpoint", required=True, help="llama-server base URL, no /v1")
    run.add_argument("--host", required=True, help="label for the results")
    run.add_argument("--model", required=True, help="router name or alias to test")
    run.add_argument("--feature")
    run.add_argument("--alias", help="only cases whose meta.toml targets this alias")
    run.add_argument("--trials", type=int, default=1)
    run.set_defaults(func=cmd_run)
    rescore = sub.add_parser("rescore")
    rescore.add_argument("--fixtures", required=True)
    rescore.add_argument("runs", nargs="+", help="run directories")
    rescore.set_defaults(func=cmd_rescore)
    cmp = sub.add_parser("compare")
    cmp.add_argument("runs", nargs="+", help="run directories")
    cmp.add_argument(
        "--public",
        action="store_true",
        help="redact expected values from failed-check labels, for issue comments",
    )
    cmp.set_defaults(func=cmd_compare)
    aud = sub.add_parser("audit")
    aud.add_argument("--fixtures", required=True)
    aud.add_argument("file", help="draft text bound for a public issue or PR")
    aud.set_defaults(func=cmd_audit)
    ns = parser.parse_args(argv)
    return ns.func(ns)


if __name__ == "__main__":
    sys.exit(main())
