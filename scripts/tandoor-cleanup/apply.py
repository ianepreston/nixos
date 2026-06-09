#!/usr/bin/env python3
"""Apply mapping.yaml to a Tandoor instance via its REST API.

Usage:
    python3 apply.py --target hpp-1 --phase units             # dry-run
    python3 apply.py --target hpp-1 --phase units --apply
    python3 apply.py --target amos1 --phase units --apply

Phases:
    units         — unit merges then deletes
    food-merges   — high-confidence food merges
    food-renames  — rename food rows (no canonical match)
    supermarkets  — delete default supermarkets
    all           — units → food-merges → supermarkets (no renames)

The script is idempotent: skips ops where the source no longer exists
(already-merged / already-deleted).
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

MAPPING = Path.home() / "src/tandoor-cleanup/mapping.yaml"
TOKEN = (Path.home() / ".config/tandoor-cleanup/amos1.token").read_text().strip()

# Order for generated aliases. Tandoor runs automations ascending (lower
# first); the operator's existing guard rules (never-unit / transpose) sit
# at order 0. We place aliases at Tandoor's UI default of 1000 so they run
# after those guards and leave room for higher-order explicit Replace rules
# to override an alias later.
ALIAS_ORDER = 1000

TARGETS = {
    "hpp-1": {"ssh": "hpp-1", "host_hdr": "tandoor.dnix.ipreston.net"},
    "amos1": {"ssh": "amos1", "host_hdr": "tandoor.amos.ipreston.net"},
}


# --- Lightweight YAML one-row parser ---------------------------------------
# mapping.yaml is generated and uses one-flow-mapping-per-line — we don't
# need a full YAML library to read it back.

ROW_RE = re.compile(r"\{\s*(.*?)\s*\}\s*$")


def parse_row(line: str) -> dict | None:
    m = ROW_RE.search(line.strip())
    if not m:
        return None
    body = m.group(1)
    out: dict = {}
    # Split top-level k: v pairs, respecting quoted strings.
    i = 0
    while i < len(body):
        # skip whitespace + comma
        while i < len(body) and body[i] in " ,":
            i += 1
        # read key
        kstart = i
        while i < len(body) and body[i] != ":":
            i += 1
        key = body[kstart:i].strip()
        if i >= len(body):
            break
        i += 1  # consume :
        while i < len(body) and body[i] == " ":
            i += 1
        # read value (string-quoted or bare)
        if i < len(body) and body[i] in "\"'":
            quote = body[i]
            i += 1
            vstart = i
            while i < len(body):
                if body[i] == "\\" and i + 1 < len(body):
                    i += 2
                    continue
                if body[i] == quote:
                    break
                i += 1
            val = body[vstart:i].replace(f"\\{quote}", quote).replace("\\\\", "\\")
            i += 1
        else:
            vstart = i
            while i < len(body) and body[i] != ",":
                i += 1
            val = body[vstart:i].strip()
        # numeric coerce for integer-like values
        if val.isdigit():
            val = int(val)
        out[key] = val
    return out


def load_section(name: str, subname: str) -> list[dict]:
    """Return rows under e.g. units.merges in document order."""
    text = MAPPING.read_text().splitlines()
    rows: list[dict] = []
    in_section = False
    in_sub = False
    for line in text:
        if not line.startswith(" "):
            in_section = line.rstrip(":").strip() == name
            in_sub = False
            continue
        if in_section and re.match(r"^\s\s\w[\w_-]*:", line):
            in_sub = line.strip().split(":")[0] == subname
            continue
        if in_sub:
            row = parse_row(line)
            if row:
                rows.append(row)
    return rows


# --- HTTP plumbing ---------------------------------------------------------

@dataclass
class Result:
    ok: bool
    status: int
    body: str


def call(target: str, method: str, path: str, payload: dict | None = None) -> Result:
    cfg = TARGETS[target]
    base = (
        f"curl -sS -o /tmp/_tandoor_resp -w '%{{http_code}}' "
        f"-X {method} "
        f"-H 'Host: {cfg['host_hdr']}' "
        f"-H 'Authorization: Bearer {TOKEN}' "
        f"-H 'Content-Type: application/json' "
    )
    url = f"'http://127.0.0.1:8083{path}'"
    if payload is not None:
        # base64 the JSON body so it survives the ssh/curl shell wrapping
        # untouched (b64 alphabet has no shell-special chars); decode it
        # into a temp file on the host and POST it with --data-binary.
        b64 = base64.b64encode(json.dumps(payload).encode()).decode()
        remote = (
            f"echo {b64} | base64 -d > /tmp/_tandoor_payload.json && "
            + base
            + f"--data-binary @/tmp/_tandoor_payload.json {url} "
            + "&& cat /tmp/_tandoor_resp"
        )
    else:
        remote = base + f"{url} && cat /tmp/_tandoor_resp"
    cmd = ["ssh", cfg["ssh"], remote]
    r = subprocess.run(cmd, capture_output=True, text=True, check=False)
    out = r.stdout
    # Last line(s) = body; first 3 chars = status (curl -w format)
    if len(out) >= 3 and out[:3].isdigit():
        status = int(out[:3])
        body = out[3:]
    else:
        status = 0
        body = out
    return Result(ok=200 <= status < 300, status=status, body=body)


def exists_unit(target: str, uid: int) -> bool:
    return call(target, "GET", f"/api/unit/{uid}/").ok


def exists_food(target: str, fid: int) -> bool:
    return call(target, "GET", f"/api/food/{fid}/").ok


def exists_supermarket(target: str, sid: int) -> bool:
    return call(target, "GET", f"/api/supermarket/{sid}/").ok


# --- Phase runners ---------------------------------------------------------

def run_unit_merges(target: str, apply: bool) -> tuple[int, int]:
    rows = load_section("units", "merges")
    done = skipped = 0
    for r in rows:
        src, dst = r["src_id"], r["dst_id"]
        label = f"unit merge {src}({r['src_name']}) → {dst}({r['dst_name']})"
        if not exists_unit(target, src):
            print(f"  SKIP  {label}  (source already gone)")
            skipped += 1
            continue
        if not apply:
            print(f"  PLAN  {label}")
            done += 1
            continue
        res = call(target, "PUT", f"/api/unit/{src}/merge/{dst}/")
        if res.ok:
            print(f"  OK    {label}")
            done += 1
        else:
            print(f"  FAIL  {label}  status={res.status} body={res.body[:200]}")
            sys.exit(2)
    return done, skipped


def run_unit_deletes(target: str, apply: bool) -> tuple[int, int]:
    rows = load_section("units", "deletes")
    done = skipped = 0
    for r in rows:
        uid = r["id"]
        label = f"unit delete {uid}({r['name']})"
        if not exists_unit(target, uid):
            print(f"  SKIP  {label}  (already gone)")
            skipped += 1
            continue
        if not apply:
            print(f"  PLAN  {label}")
            done += 1
            continue
        res = call(target, "DELETE", f"/api/unit/{uid}/")
        if res.ok:
            print(f"  OK    {label}")
            done += 1
        else:
            print(f"  FAIL  {label}  status={res.status} body={res.body[:200]}")
            sys.exit(2)
    return done, skipped


def run_food_merges(target: str, apply: bool) -> tuple[int, int]:
    rows = load_section("foods", "merges")
    done = skipped = 0
    for r in rows:
        src, dst = r["src_id"], r["dst_id"]
        label = f"food merge {src}({r['src_name']}) → {dst}({r['dst_name']})"
        if not exists_food(target, src):
            print(f"  SKIP  {label}  (source already gone)")
            skipped += 1
            continue
        if not apply:
            print(f"  PLAN  {label}")
            done += 1
            continue
        res = call(target, "PUT", f"/api/food/{src}/merge/{dst}/")
        if res.ok:
            print(f"  OK    {label}")
            done += 1
        else:
            print(f"  FAIL  {label}  status={res.status} body={res.body[:200]}")
            sys.exit(2)
    return done, skipped


def run_supermarket_deletes(target: str, apply: bool) -> tuple[int, int]:
    rows = load_section("supermarkets", "deletes")
    done = skipped = 0
    for r in rows:
        sid = r["id"]
        label = f"supermarket delete {sid}({r['name']})"
        if not exists_supermarket(target, sid):
            print(f"  SKIP  {label}  (already gone)")
            skipped += 1
            continue
        if not apply:
            print(f"  PLAN  {label}")
            done += 1
            continue
        res = call(target, "DELETE", f"/api/supermarket/{sid}/")
        if res.ok:
            print(f"  OK    {label}")
            done += 1
        else:
            print(f"  FAIL  {label}  status={res.status} body={res.body[:200]}")
            sys.exit(2)
    return done, skipped


def fetch_automations(target: str) -> list[dict]:
    res = call(target, "GET", "/api/automation/?page_size=500")
    if not res.ok:
        print(f"  ERROR fetching automations: status={res.status} "
              f"body={res.body[:200]}", file=sys.stderr)
        sys.exit(2)
    body = json.loads(res.body)
    return body.get("results", body) if isinstance(body, dict) else body


def _run_aliases(target: str, apply: bool, *, section: str, alias_type: str,
                 label_kind: str) -> tuple[int, int]:
    """Create <alias_type> automations from a merges section (param_1 = source
    name → param_2 = target name). Idempotent: skips when an automation of the
    same type already matches param_1 (case-insensitive)."""
    rows = load_section(section, "merges")
    existing = fetch_automations(target)
    have = {
        (a["type"], (a.get("param_1") or "").strip().lower())
        for a in existing
    }
    done = skipped = 0
    for r in rows:
        src, dst = r["src_name"], r["dst_name"]
        key = (alias_type, src.strip().lower())
        label = f"{label_kind} alias {src!r} → {dst!r}"
        if key in have:
            print(f"  SKIP  {label}  (alias already exists)")
            skipped += 1
            continue
        if not apply:
            print(f"  PLAN  {label}")
            done += 1
            continue
        payload = {
            "type": alias_type,
            "name": f"{label_kind} alias: {src} → {dst}",
            "param_1": src,
            "param_2": dst,
            "order": ALIAS_ORDER,
            "disabled": False,
        }
        res = call(target, "POST", "/api/automation/", payload)
        if res.ok:
            print(f"  OK    {label}")
            done += 1
            have.add(key)  # guard against dupes within this same run
        else:
            print(f"  FAIL  {label}  status={res.status} body={res.body[:200]}")
            sys.exit(2)
    return done, skipped


def run_unit_aliases(target: str, apply: bool) -> tuple[int, int]:
    return _run_aliases(target, apply, section="units",
                        alias_type="UNIT_ALIAS", label_kind="Unit")


def run_food_aliases(target: str, apply: bool) -> tuple[int, int]:
    return _run_aliases(target, apply, section="foods",
                        alias_type="FOOD_ALIAS", label_kind="Food")


PHASES = {
    "unit-merges": [("Unit merges", run_unit_merges)],
    "unit-deletes": [("Unit deletes", run_unit_deletes)],
    "units": [("Unit merges", run_unit_merges), ("Unit deletes", run_unit_deletes)],
    "food-merges": [("Food merges", run_food_merges)],
    "supermarkets": [("Supermarket deletes", run_supermarket_deletes)],
    # Forward-looking alias automations, generated from the same merge rows.
    # Deliberately standalone (not in "all") so they're run as a separate
    # motion — after the corresponding merges are applied and verified.
    "unit-aliases": [("Unit aliases", run_unit_aliases)],
    "food-aliases": [("Food aliases", run_food_aliases)],
    "all": [
        ("Unit merges", run_unit_merges),
        ("Unit deletes", run_unit_deletes),
        ("Food merges", run_food_merges),
        ("Supermarket deletes", run_supermarket_deletes),
    ],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, choices=list(TARGETS))
    ap.add_argument("--phase", required=True, choices=list(PHASES))
    ap.add_argument("--apply", action="store_true",
                    help="Actually execute. Default: dry-run.")
    args = ap.parse_args()

    mode = "APPLY" if args.apply else "DRY-RUN"
    print(f"=== {mode} on {args.target} — phase={args.phase} ===")
    for label, fn in PHASES[args.phase]:
        print(f"\n--- {label} ---")
        done, skipped = fn(args.target, args.apply)
        verb = "applied" if args.apply else "planned"
        print(f"  ({label}: {done} {verb}, {skipped} skipped)")


if __name__ == "__main__":
    main()
