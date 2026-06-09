#!/usr/bin/env python3
"""Propose foods + units consolidation mapping for Tandoor cleanup.

Inputs:
  ~/src/tandoor-cleanup/inventory/{food,unit,supermarket}.json
Output:
  ~/src/tandoor-cleanup/mapping.yaml

Strategy:
  * Units: hand-curated table of merge targets, plus delete-list for
    units that are clearly parse-junk (e.g. "to", "-").
  * Foods: for each junk food (no fdc_id / no properties), normalize its
    name (strip qty/unit parens, leading punctuation, prep adjectives,
    plural) and look it up against the canonical set (391 ODP foods).
    Buckets:
      - merge:          normalized name == canonical name (high confidence)
      - review_merges:  no exact hit, but cleaned name shares a content token
                        with canonical(s) — ranked candidates for the operator
                        to confirm (high-confidence singles ship pre-filled)
      - rename:         no canonical candidate at all; pure name cleanup
      - manual_review:  ambiguous / parser breakage / unrecognized
"""
import json
import re
from pathlib import Path

INV = Path.home() / "src/tandoor-cleanup/inventory"
OUT = Path.home() / "src/tandoor-cleanup/mapping.yaml"
USAGE_PATH = Path.home() / "src/tandoor-cleanup/usage.json"


def load_usage():
    if not USAGE_PATH.exists():
        return {"food": {}, "unit": {}}
    return json.loads(USAGE_PATH.read_text())


def usage_summary(uses: list, max_quotes: int = 3) -> str:
    """Format `used_in` field: 'N use(s) in M recipe(s): "qty unit food" (Recipe Name); ...'"""
    if not uses:
        return "(unused)"
    recipes = {}
    for u in uses:
        recipes.setdefault(u["recipe_name"], []).append(u["quote"])
    parts = []
    for rname, quotes in list(recipes.items())[:max_quotes]:
        # one representative quote per recipe in the sample
        parts.append(f'"{quotes[0]}" in {rname!r}')
    extra = sum(len(v) for v in recipes.values()) - len(parts)
    suffix = f" (+{extra} more)" if extra > 0 else ""
    return f"{len(uses)} use(s) in {len(recipes)} recipe(s): " + " | ".join(parts) + suffix

# --- UNIT MAPPING (hand-curated; only 67 rows total) -----------------------
#
# Targets are the 11 units with base_unit set (Tandoor's conversion graph).
# Anything not in MERGE or DELETE is kept as-is.

UNIT_MERGE = {
    # source name : target name  (resolved to ids below)
    "tablespoon":  "tbsp",
    "tablespoons": "tbsp",
    "tbsp.":       "tbsp",
    "tbs":         "tbsp",
    "Tbls":        "tbsp",
    "teaspoon":    "tsp",
    "teaspoons":   "tsp",
    "tsp.":        "tsp",
    "grams":       "g",
    "Litre":       "l",
    "ounce":       "oz",
    "ounces":      "oz",
    "oz.":         "oz",
    "lb.":         "lb",
    "pound":       "lb",
    "pounds":      "lb",
    "c.":          "cup",
    "cloves":      "clove",  # both kept as countable; collapse plural
    "pounds":      "lb",
}

# Units that are clearly parser garbage (came in from misparsed ingredients).
# Deleting them after merge-out is safe; the Never Unit automation already
# blocks similar tokens going forward.
UNIT_DELETE = {
    "-",
    "to",
    "red",       # never-unit; came from "red onion" misparse
    "dried",     # adjective
    "frozen",    # adjective
    "garlic",    # ingredient leaked into unit
    "jalapeno",  # ingredient leaked into unit
    "lime",
    "shiitake",
    # Note: "whole" is kept as a unit because it's a legitimate countable
    # qualifier ("2 whole chicken") and the Never Unit pattern uses it.
}

# Suspicious but I am NOT auto-merging or deleting these without review.
# They get a manual_review entry so we can decide together.
UNIT_REVIEW = {
    "5-ounce can",       # very specific — keep or merge to 'can'?
    "bulbs (1 to 1 1/2 lb.)",  # garbage from import; delete?
    "dash",  # legit but tiny — Tandoor doesn't have a base for it
    "pinch",  # has base=ml(!) — Tandoor maps it to ~1ml
    "inch",
    "ears",
    "links",
    "ribs",
    "stems",
    "stalks",
    "sprig",
    "slices",
}


# --- FOOD NORMALIZATION ----------------------------------------------------

PREP_ADJECTIVES = {
    # Pure preparation verbs — strip aggressively.
    "chopped", "diced", "sliced", "minced", "crushed", "shredded",
    "melted", "softened", "grated", "peeled", "cooked", "uncooked",
    "halved", "quartered", "thinly", "thickly", "finely", "coarsely",
    "roughly", "lightly", "toasted", "boiled", "steamed", "raw",
    "skinless", "boneless", "pitted", "trimmed", "drained", "rinsed",
    "washed", "warm", "cold", "hot", "room", "temperature",
    "small", "medium", "large", "extra", "your", "favorite", "of",
    # "fresh" is a redundancy descriptor (canonicals are typically the
    # fresh form; "Dried X" is a separate canonical), so strip it.
    "fresh",
    # Note: do NOT strip "ground", "dried", "salted", "unsalted",
    # "sweetened", "unsweetened", "smoked", "ripe", "frozen" — these
    # are semantic descriptors that distinguish canonicals
    # (Butter Salted vs Butter Unsalted; Mint vs Dried Mint).
}

DESCRIPTOR_TRAILERS = {
    "to taste", "for serving", "for garnish", "optional", "as needed",
}


# Unicode vulgar-fraction glyphs that show up in imported quantities
# ("½ tsp", "⅓ cup"). The ascii [\d./] class misses them, so a leading
# "½ tsp () - " survived stripping and leaked into the food name.
FRAC = "¼½¾⅓⅔⅛⅜⅝⅞⅕⅖⅗⅘⅙⅚⅐⅑⅒"
_QTY = rf"[\d./{FRAC}]+(?:\s+[\d./{FRAC}]+)?"


def strip_paren_qty(name: str) -> str:
    """Remove leading / embedded parenthesized quantity-unit groups."""
    # Strip a leading "(...)" that contains digits or unit-like words.
    out = re.sub(r"^\s*\([^)]*\d[^)]*\)\s*", "", name)
    # Also strip leading "- " or "+ " or "*"
    out = re.sub(r"^[\-\+\*\s]+", "", out)
    # Strip a leading "qty [unit]" like "1 stick", "100g", or a bare "½".
    # The unit is optional so a lone fraction/number prefix is also removed.
    out = re.sub(
        rf"^{_QTY}\s*(?:oz|lb|lbs|g|kg|ml|l|tsp|tbsp|cup|cups|"
        r"ounces?|pounds?|grams?|liters?|tablespoons?|teaspoons?|"
        r"stick|sticks|slices?|pieces?|cans?|packages?|bottles?|"
        r"bunches?|cloves?|heads?|handfuls?|pinches?)?\b\.?\s*",
        "", out, flags=re.IGNORECASE,
    )
    # Strip an empty "()" left behind by the import ("½ tsp () - x").
    out = re.sub(r"^\s*\(\s*\)\s*", "", out)
    # Strip a leading bare measure-word with no number ("Big handful x",
    # "Handful of x", "bunch of x"), optionally size-qualified.
    out = re.sub(
        r"^(?:big|small|large|a)?\s*(?:handful|bunch|pinch|dash)s?\s+"
        r"(?:of\s+)?",
        "", out, flags=re.IGNORECASE,
    )
    # Strip leading "- " again (some have double prefix)
    out = re.sub(r"^[\-\+\*\s]+", "", out)
    # Strip parenthetical TRAILERS (descriptors) and a trailing "*".
    out = re.sub(r"\s*\([^)]*\)\s*$", "", out)
    out = re.sub(r"[\*\s]+$", "", out)
    return out.strip()


def strip_prep(name: str) -> str:
    words = re.split(r"[\s,]+", name)
    # remove leading prep adjectives
    while words and words[0].lower().strip(".,") in PREP_ADJECTIVES:
        words = words[1:]
    # remove trailing prep adjectives + trailers
    while words and words[-1].lower().strip(".,") in PREP_ADJECTIVES:
        words = words[:-1]
    return " ".join(words).strip()


def singularize(word: str) -> str:
    w = word.strip().lower()
    if w.endswith("ies") and len(w) > 4:
        return w[:-3] + "y"
    if w.endswith("oes") or w.endswith("ses") or w.endswith("xes"):
        return w[:-2]
    # Latin / mass nouns that merely end in -s are already singular
    # ("hummus", "asparagus", "couscous", "citrus"); don't chop the -s.
    if w.endswith(("us", "is", "ous", "ss", "ics")):
        return w
    if w.endswith("s") and len(w) > 3:
        return w[:-1]
    return w


def normalize(name: str) -> str:
    n = strip_paren_qty(name)
    n = strip_prep(n)
    # remove trailing "Recipe" marker (Tandoor recipe-as-food)
    n = re.sub(r"\s+Recipe\s*$", "", n, flags=re.IGNORECASE)
    # collapse whitespace, lowercase
    n = re.sub(r"\s+", " ", n).strip().lower()
    # singularize word-by-word for matching
    return " ".join(singularize(w) for w in n.split()) if n else ""


# --- MERGE-REVIEW CANDIDATE GENERATION -------------------------------------
#
# A rename row is "junk with no *exact* canonical norm match," but many are a
# less-specific spelling of a real canonical ("baby spinach" -> Spinach,
# "cayenne" -> Cayenne Pepper). We can't auto-merge them — token collisions
# are real ("salted butter" shares "salted" with "Salted Pistachios", "pork
# roast" shares "pork" with "Pork Bacon") — so instead we surface ranked
# canonical candidates for the operator to confirm. The match key is a shared
# *content* token: descriptors / colors / prep words (below) don't count on
# their own, which is what kills the adjective-collision false positives.

MATCH_DESCRIPTORS = {
    "salted", "unsalted", "dried", "fresh", "frozen", "canned", "ground",
    "smoked", "sweetened", "unsweetened", "ripe", "raw", "cooked", "whole",
    "reduced", "fat", "lowfat", "nonfat", "light", "lean", "organic", "baby",
    "red", "green", "black", "brown", "white", "yellow", "blanched",
    "clarified", "fine", "sea", "kosher", "ancient", "hard", "soft", "small",
    "medium", "large", "powder", "flake", "flakes", "of", "or", "and", "cut",
    "into", "leave", "leaves", "stalk", "stalks", "piece", "pieces", "can",
    "cans",
}

# The subset of descriptors that are *semantic* — they distinguish canonicals
# (Butter Salted vs Unsalted; Oregano vs Dried Oregano; Clove vs Clove ground).
# A high-confidence pre-filled suggestion is only emitted when junk and
# canonical agree on these, so we never auto-collapse "smoked paprika" into
# plain "Paprika" or "oregano" into "Dried Oregano".
SEMANTIC_DESCRIPTORS = {
    "salted", "unsalted", "dried", "smoked", "ground", "frozen", "canned",
    "sweetened", "unsweetened", "ripe",
}


def content_tokens(norm: str) -> set:
    return {t for t in norm.split() if t not in MATCH_DESCRIPTORS and len(t) > 2}


def semantic_tokens(norm: str) -> set:
    return {t for t in norm.split() if t in SEMANTIC_DESCRIPTORS}


# --- BUILD MAPPING ---------------------------------------------------------

def main():
    foods = json.loads((INV / "food.json").read_text())
    units = json.loads((INV / "unit.json").read_text())
    supermarkets = json.loads((INV / "supermarket.json").read_text())
    usage = load_usage()
    # Whether usage.json is actually present. Disposition rules that key
    # off "is this unused?" MUST guard on this — a missing/stale usage.json
    # makes everything look unused, which would otherwise delete units that
    # are in fact still referenced by recipes.
    usage_available = USAGE_PATH.exists()
    unit_usage = {int(k): v for k, v in usage["unit"].items()}
    food_usage = {int(k): v for k, v in usage["food"].items()}

    units_by_name = {u["name"]: u for u in units}
    unit_merges = []
    for src_name, dst_name in UNIT_MERGE.items():
        s = units_by_name.get(src_name)
        d = units_by_name.get(dst_name)
        if not s:
            continue  # source not present; skip
        if not d:
            raise RuntimeError(f"unit merge target {dst_name!r} not found")
        unit_merges.append({
            "src_id": s["id"], "src_name": s["name"],
            "dst_id": d["id"], "dst_name": d["name"],
        })
    unit_deletes = [
        {"id": u["id"], "name": u["name"],
         "used_in": usage_summary(unit_usage.get(u["id"], []))}
        for u in units if u["name"] in UNIT_DELETE
    ]

    # UNIT_REVIEW disposition (operator decision): a review unit that is now
    # UNUSED is safe to drop → fold it into the deletes bucket so
    # `apply.py --phase unit-deletes` executes it. One still referenced by a
    # recipe is KEPT as-is (emitted as an informational `keeps` list, not a
    # delete). When usage data is unavailable we can't safely decide, so we
    # leave every review unit in manual_review for a human.
    unit_reviews = []
    unit_keeps = []
    for u in units:
        if u["name"] not in UNIT_REVIEW:
            continue
        uses = unit_usage.get(u["id"], [])
        row = {"id": u["id"], "name": u["name"],
               "used_in": usage_summary(uses)}
        if not usage_available:
            unit_reviews.append(row)
        elif uses:
            unit_keeps.append(row)
        else:
            unit_deletes.append(row)

    # Split foods into canonical (ODP) and junk.
    canonical = [f for f in foods if f.get("fdc_id") or f.get("open_data_slug")]
    junk = [f for f in foods if not (f.get("fdc_id") or f.get("open_data_slug"))]

    # Build canonical name lookup. Critically, multiple canonicals can
    # share a normalized form ("Ginger ground" / "Ginger root" both
    # normalize to "ginger"). Track the SET of canonicals per norm so we
    # can flag ambiguous junk → multiple-canon-candidates for review
    # instead of arbitrary first-wins.
    canon_by_norm: dict[str, list] = {}
    canon_by_name: dict[str, dict] = {}
    for f in canonical:
        canon_by_name[f["name"].lower()] = f
        canon_by_norm.setdefault(normalize(f["name"]), []).append(f)

    food_merges = []
    food_renames = []
    food_review = []

    def review_row(f, **extra):
        return {
            "id": f["id"], "name": f["name"],
            **extra,
            "used_in": usage_summary(food_usage.get(f["id"], [])),
        }

    for f in junk:
        norm = normalize(f["name"])
        if not norm:
            food_review.append(review_row(f, reason="normalized to empty string"))
            continue
        # Exact normalized canonical hit?
        if norm in canon_by_norm:
            cands = canon_by_norm[norm]
            if len(cands) == 1:
                tgt = cands[0]
                food_merges.append({
                    "src_id": f["id"], "src_name": f["name"],
                    "dst_id": tgt["id"], "dst_name": tgt["name"],
                    "via_norm": norm,
                    "used_in": usage_summary(food_usage.get(f["id"], [])),
                })
                continue
            # Ambiguous: route to review with the candidate set listed.
            food_review.append(review_row(
                f,
                candidates=", ".join(f"{c['id']}={c['name']}" for c in cands),
                reason=f"ambiguous canonical (multiple match norm={norm!r})",
            ))
            continue
        # Lowercase-only exact match
        if f["name"].lower() in canon_by_name:
            tgt = canon_by_name[f["name"].lower()]
            food_merges.append({
                "src_id": f["id"], "src_name": f["name"],
                "dst_id": tgt["id"], "dst_name": tgt["name"],
                "via_norm": "lowercase_exact",
            })
            continue
        # No canonical match — rename to cleaned form if it differs.
        if norm and norm != f["name"].strip().lower():
            food_renames.append({
                "id": f["id"], "old_name": f["name"], "new_name": norm,
                "used_in": usage_summary(food_usage.get(f["id"], [])),
            })
        else:
            food_review.append(review_row(
                f, reason="no canonical match, no rename needed",
            ))

    # Dedupe renames: when multiple junk foods normalize to the same
    # new_name, keep ONE as a rename (canonical-ish target) and turn the
    # others into merges into it. This collapses "bell peppers" /
    # "(275g) chopped bell peppers" / "bell peppers, diced" → all into
    # the same surviving food row.
    rename_clusters: dict[str, list] = {}
    for r in food_renames:
        rename_clusters.setdefault(r["new_name"], []).append(r)
    food_renames_final = []
    rename_dedup_merges = []
    for new_name, group in rename_clusters.items():
        # Stable pick: lowest food id wins (oldest / most-likely-referenced)
        group.sort(key=lambda r: r["id"])
        keeper = group[0]
        food_renames_final.append(keeper)
        for other in group[1:]:
            rename_dedup_merges.append({
                "src_id": other["id"], "src_name": other["old_name"],
                "dst_id": keeper["id"], "dst_name": keeper["new_name"],
                "via_norm": f"rename_cluster={new_name!r}",
                "used_in": usage_summary(food_usage.get(other["id"], [])),
            })
    food_merges.extend(rename_dedup_merges)
    food_renames = food_renames_final

    # Split the rename keepers into merge_review (has a plausible canonical to
    # merge into) and plain renames (pure cleanup, no canonical candidate).
    # merge_review rows carry a ranked candidate list plus an empty dst_id the
    # operator fills (or keeps, for the pre-filled high-confidence suggestions)
    # to turn the row into a merge; left blank, the row applies as a rename.
    canon_match = [
        (c["id"], c["name"],
         content_tokens(normalize(c["name"])),
         semantic_tokens(normalize(c["name"])))
        for c in canonical
    ]
    food_review_merges = []
    food_renames_only = []
    for r in food_renames:
        jnorm = r["new_name"]  # already normalized
        jcontent = content_tokens(jnorm)
        jsem = semantic_tokens(jnorm)
        cands = []
        if jcontent:
            for cid, cname, ccontent, csem in canon_match:
                overlap = jcontent & ccontent
                if overlap:
                    cands.append((len(overlap), cid, cname, ccontent, csem))
        if not cands:
            food_renames_only.append(r)
            continue
        # Best overlap first, then name for stable ordering.
        cands.sort(key=lambda t: (-t[0], t[2].lower()))
        dst_id, dst_name = 0, ""
        # Pre-fill a suggestion only when there is exactly one candidate, the
        # junk is a strict less-specific form of it, and they agree on every
        # semantic descriptor (no fresh->dried / smoked->plain collapses).
        if len(cands) == 1:
            _, cid, cname, ccontent, csem = cands[0]
            if jcontent <= ccontent and jsem == csem:
                dst_id, dst_name = cid, cname
        cand_str = " | ".join(
            f"{cid}={cname}" for _, cid, cname, _, _ in cands[:8]
        )
        food_review_merges.append({
            "id": r["id"], "old_name": r["old_name"], "new_name": r["new_name"],
            "dst_id": dst_id, "dst_name": dst_name,
            "candidates": cand_str, "used_in": r["used_in"],
        })
    food_renames = food_renames_only

    # Supermarket bucket — all 47 are seeded defaults the user doesn't use.
    sm_deletes = [{"id": s["id"], "name": s["name"]} for s in supermarkets]

    # Write YAML by hand (no external dep)
    lines = []
    lines.append("# Tandoor cleanup mapping — proposed merges/renames/deletes.")
    lines.append(f"# Generated from 893 foods, 67 units, 47 supermarkets.")
    lines.append("")
    lines.append("units:")
    lines.append(f"  merges: # {len(unit_merges)}")
    for m in unit_merges:
        lines.append(
            f"    - {{ src_id: {m['src_id']:3d}, src_name: {m['src_name']!r}, "
            f"dst_id: {m['dst_id']:3d}, dst_name: {m['dst_name']!r} }}"
        )
    lines.append(f"  deletes: # {len(unit_deletes)}")
    for d in unit_deletes:
        lines.append(
            f"    - {{ id: {d['id']:3d}, name: {d['name']!r}, "
            f"used_in: {d['used_in']!r} }}"
        )
    lines.append(f"  keeps: # {len(unit_keeps)} (review units still used — kept as-is)")
    for r in unit_keeps:
        lines.append(
            f"    - {{ id: {r['id']:3d}, name: {r['name']!r}, "
            f"used_in: {r['used_in']!r} }}"
        )
    lines.append(f"  manual_review: # {len(unit_reviews)}")
    for r in unit_reviews:
        lines.append(
            f"    - {{ id: {r['id']:3d}, name: {r['name']!r}, "
            f"used_in: {r['used_in']!r} }}"
        )
    lines.append("")
    lines.append("foods:")
    lines.append(f"  # canonical (ODP) foods left untouched: {len(canonical)}")
    lines.append(f"  merges: # {len(food_merges)}")
    for m in food_merges:
        lines.append(
            f"    - {{ src_id: {m['src_id']:4d}, "
            f"src_name: {m['src_name']!r}, "
            f"dst_id: {m['dst_id']:4d}, dst_name: {m['dst_name']!r}, "
            f"used_in: {m['used_in']!r} }}"
        )
    suggested = sum(1 for m in food_review_merges if m["dst_id"])
    lines.append(
        f"  review_merges: # {len(food_review_merges)} "
        f"({suggested} pre-filled) — set/keep dst_id to merge, blank to rename"
    )
    for m in food_review_merges:
        lines.append(
            f"    - {{ id: {m['id']:4d}, old_name: {m['old_name']!r}, "
            f"new_name: {m['new_name']!r}, dst_id: {m['dst_id']:4d}, "
            f"dst_name: {m['dst_name']!r}, candidates: {m['candidates']!r}, "
            f"used_in: {m['used_in']!r} }}"
        )
    lines.append(f"  renames: # {len(food_renames)}")
    for r in food_renames:
        lines.append(
            f"    - {{ id: {r['id']:4d}, "
            f"old_name: {r['old_name']!r}, new_name: {r['new_name']!r}, "
            f"used_in: {r['used_in']!r} }}"
        )
    lines.append(f"  manual_review: # {len(food_review)}")
    for r in food_review:
        keys = " ".join(f"{k}: {v!r}" for k, v in r.items())
        lines.append(f"    - {{ {keys} }}")
    lines.append("")
    lines.append("supermarkets:")
    lines.append(f"  deletes: # {len(sm_deletes)} (all seeded defaults)")
    for d in sm_deletes:
        lines.append(f"    - {{ id: {d['id']:3d}, name: {d['name']!r} }}")
    OUT.write_text("\n".join(lines) + "\n")

    print(f"=== UNIT SUMMARY ===")
    print(f"  merges:        {len(unit_merges):4d}")
    print(f"  deletes:       {len(unit_deletes):4d}  (incl. unused review units)")
    print(f"  keeps:         {len(unit_keeps):4d}  (review units still in use)")
    print(f"  manual_review: {len(unit_reviews):4d}  (only when usage data missing)")
    print(f"  unchanged:     {len(units) - len(unit_merges) - len(unit_deletes) - len(unit_keeps) - len(unit_reviews):4d}")
    print(f"=== FOOD SUMMARY ===")
    print(f"  canonical (ODP, untouched): {len(canonical):4d}")
    print(f"  junk total:                 {len(junk):4d}")
    print(f"    merges to canonical:      {len(food_merges):4d}")
    print(f"    review_merges (confirm):  {len(food_review_merges):4d}  "
          f"({sum(1 for m in food_review_merges if m['dst_id'])} pre-filled)")
    print(f"    renames (no candidate):   {len(food_renames):4d}")
    print(f"    manual_review:            {len(food_review):4d}")
    print(f"=== SUPERMARKET SUMMARY ===")
    print(f"  proposed deletes: {len(sm_deletes)} (all defaults)")
    print(f"\nMapping written to {OUT}")


if __name__ == "__main__":
    main()
