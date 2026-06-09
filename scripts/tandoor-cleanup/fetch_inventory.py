#!/usr/bin/env python3
"""Fetch full Tandoor inventory via SSH+curl.

Talks to the chosen host's local tandoor (127.0.0.1:8083) with the right
Host header so we don't depend on caddy/TLS. Follows pagination by reading
`next` and rewriting the netloc back to localhost.

`--target` selects the instance (default amos1 — the production cleanup
target). hpp-1 is a dev playground and no longer mirrors prod, so don't
point inventory collection at it expecting prod data.

The bearer token is read from ~/.config/tandoor-cleanup/<target>.token, so
each target needs its own operator-local token file.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse

INV_DIR = Path.home() / "src/tandoor-cleanup/inventory"

TARGETS = {
    "hpp-1": {"ssh": "hpp-1", "host_hdr": "tandoor.dnix.ipreston.net"},
    "amos1": {"ssh": "amos1", "host_hdr": "tandoor.amos.ipreston.net"},
}

ENDPOINTS = [
    "food",
    "unit",
    "supermarket",
    "supermarket-category",
    "keyword",
    "automation",
    "recipe",
    "property-type",
]


def localize(url: str) -> str:
    p = urlparse(url)
    return urlunparse(("http", "127.0.0.1:8083", p.path, p.params, p.query, p.fragment))


def fetch_all(cfg: dict, bearer: str, endpoint: str) -> list:
    url = f"http://127.0.0.1:8083/api/{endpoint}/?page_size=500"
    out = []
    page = 0
    while url:
        page += 1
        cmd = [
            "ssh", cfg["ssh"],
            f"curl -sS -H 'Host: {cfg['host_hdr']}' "
            f"-H 'Authorization: Bearer {bearer}' '{url}'",
        ]
        r = subprocess.run(cmd, capture_output=True, text=True, check=True)
        body = json.loads(r.stdout)
        results = body.get("results", body if isinstance(body, list) else [])
        out.extend(results)
        nxt = body.get("next") if isinstance(body, dict) else None
        if not nxt:
            break
        url = localize(nxt)
    print(f"{endpoint}: collected={len(out)} (pages={page})")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="amos1", choices=list(TARGETS))
    args = ap.parse_args()
    cfg = TARGETS[args.target]
    bearer = (Path.home() / f".config/tandoor-cleanup/{args.target}.token").read_text().strip()

    INV_DIR.mkdir(parents=True, exist_ok=True)
    print(f"=== fetching inventory from {args.target} ===")
    for ep in ENDPOINTS:
        try:
            data = fetch_all(cfg, bearer, ep)
        except subprocess.CalledProcessError as e:
            print(f"{ep}: FAILED stderr={e.stderr}", file=sys.stderr)
            continue
        out = INV_DIR / f"{ep}.json"
        out.write_text(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
