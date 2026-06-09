#!/usr/bin/env python3
"""Fetch full recipe detail and build reverse indices.

For every (food_id, unit_id) used in any recipe ingredient, emit a list
of (recipe_id, recipe_name, ingredient_quote) so we can show usage
context next to the delete/review proposals.

`--target` selects the instance (default amos1). Run fetch_inventory.py
against the *same* target first — this reads its recipe.json index.
"""
import argparse
import json
import subprocess
from collections import defaultdict
from pathlib import Path

INV = Path.home() / "src/tandoor-cleanup/inventory"
OUT = Path.home() / "src/tandoor-cleanup/usage.json"

TARGETS = {
    "hpp-1": {"ssh": "hpp-1", "host_hdr": "tandoor.dnix.ipreston.net"},
    "amos1": {"ssh": "amos1", "host_hdr": "tandoor.amos.ipreston.net"},
}


def fetch(cfg: dict, bearer: str, url: str) -> dict:
    r = subprocess.run(
        ["ssh", cfg["ssh"],
         f"curl -sS -H 'Host: {cfg['host_hdr']}' "
         f"-H 'Authorization: Bearer {bearer}' '{url}'"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="amos1", choices=list(TARGETS))
    args = ap.parse_args()
    cfg = TARGETS[args.target]
    bearer = (Path.home() / f".config/tandoor-cleanup/{args.target}.token").read_text().strip()

    recipes_idx = json.loads((INV / "recipe.json").read_text())
    food_uses = defaultdict(list)  # food_id -> [{recipe_id, name, quote}]
    unit_uses = defaultdict(list)

    print(f"=== building usage from {args.target} ({len(recipes_idx)} recipes) ===")
    full = []
    for i, r in enumerate(recipes_idx):
        rid = r["id"]
        print(f"  [{i+1:3d}/{len(recipes_idx)}] recipe {rid}: {r['name'][:50]}")
        detail = fetch(cfg, bearer, f"http://127.0.0.1:8083/api/recipe/{rid}/")
        full.append(detail)
        for step in detail.get("steps") or []:
            for ing in step.get("ingredients") or []:
                food = ing.get("food") or {}
                unit = ing.get("unit") or {}
                amount = ing.get("amount")
                note = ing.get("note") or ""
                quote = (
                    f"{amount or ''} "
                    f"{(unit.get('name') or '').strip()} "
                    f"{(food.get('name') or '').strip()}"
                    + (f"  // {note}" if note else "")
                ).strip()
                if food.get("id"):
                    food_uses[food["id"]].append({
                        "recipe_id": rid, "recipe_name": detail["name"],
                        "quote": quote,
                    })
                if unit.get("id"):
                    unit_uses[unit["id"]].append({
                        "recipe_id": rid, "recipe_name": detail["name"],
                        "quote": quote,
                    })

    (INV / "recipe-detail.json").write_text(json.dumps(full, indent=2))
    OUT.write_text(json.dumps({
        "food": {str(k): v for k, v in food_uses.items()},
        "unit": {str(k): v for k, v in unit_uses.items()},
    }, indent=2))
    print(f"\nfood usages: {sum(len(v) for v in food_uses.values())} "
          f"across {len(food_uses)} foods")
    print(f"unit usages: {sum(len(v) for v in unit_uses.values())} "
          f"across {len(unit_uses)} units")


if __name__ == "__main__":
    main()
