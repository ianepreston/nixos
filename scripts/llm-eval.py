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
  compare  render a markdown comparison of two or more run dirs
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


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------


def norm(value: object) -> str:
    """Compare names loosely: case, hyphens/underscores and spacing don't matter.

    "36 Riverwood" and "36-riverwood" are the same *name*. Whether the model
    also linked it to the existing object is a separate `link` check.
    """
    text = str(value).lower().replace("-", " ").replace("_", " ")
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


def score_case(expected: dict, response: dict) -> dict:
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


def load_cases(fixtures: Path, feature: str | None) -> list[dict]:
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
    cases = load_cases(fixtures, ns.feature)
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
        image = (
            "data:image/png;base64,"
            + base64.b64encode(solid_png((220, 20, 20))).decode()
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


def render(runs: list[dict]) -> str:
    lines = ["# " + " vs ".join(label(r) for r in runs), ""]
    for r in runs:
        lines.append(
            f"- {label(r)} = `{r['resolved_model']}`, {r['trials']} trial(s), "
            f"started {r['started']}, fixtures `{r['fixtures_commit']}`"
        )
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
            failed = sorted(
                {
                    f"{c['field']}:{c['check']}"
                    + (f" ({c['detail']})" if c["check"] == "parses" else "")
                    for t in rec["trials"]
                    for c in t["checks"]
                    if not c["pass"]
                }
            )
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
    sys.stdout.write(render(runs))
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
    run.add_argument("--trials", type=int, default=1)
    run.set_defaults(func=cmd_run)
    rescore = sub.add_parser("rescore")
    rescore.add_argument("--fixtures", required=True)
    rescore.add_argument("runs", nargs="+", help="run directories")
    rescore.set_defaults(func=cmd_rescore)
    cmp = sub.add_parser("compare")
    cmp.add_argument("runs", nargs="+", help="run directories")
    cmp.set_defaults(func=cmd_compare)
    ns = parser.parse_args(argv)
    return ns.func(ns)


if __name__ == "__main__":
    sys.exit(main())
