#!/usr/bin/env python3
"""Pre-fill recommendations into mapping.yaml's foods.review_merges bucket.

`build_mapping.py` emits review_merges rows with a ranked candidate list and a
blank dst_id for the operator to fill. This script makes a first-pass *guess*
per row — set dst_id to merge, or leave it blank to rename — so the human review
starts from a populated file instead of 168 empty decisions.

It is heuristic and deliberately conservative: it only commits a merge (fills
dst_id) when a candidate is clearly the *same food* (high token overlap, or a
recipe-context hint confirms a fresh/dried/leaf/seed variant). Everything else
is left as a rename with a `rec:` note carrying the best guess, so a wrong call
degrades to a reversible rename rather than a merge.

Re-runnable: it rewrites the review_merges block in place. Run it after every
`build_mapping.py` (which regenerates the file and drops these annotations).

    python3 recommend.py            # rewrites ~/src/tandoor-cleanup/mapping.yaml
"""
from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apply as ap          # parse_row, MAPPING path
import build_mapping as bm  # normalize, content_tokens, MATCH_DESCRIPTORS

MAPPING = ap.MAPPING

# Inverse-document-frequency over canonical content tokens. A token shared by
# many canonicals ("juice", "sauce", "bean", "pepper") carries little signal;
# a rare one ("lemon", "soy", "shiitake") is what actually identifies the food.
# Scoring shared tokens by IDF stops "lemon juice" from matching "Apple juice"
# on the worthless "juice" token.
_IDF: dict[str, float] = {}
_MAX_IDF = 1.0


def build_idf() -> None:
    foods = json.loads((bm.INV / "food.json").read_text())
    canon = [f for f in foods if f.get("fdc_id") or f.get("open_data_slug")]
    n = len(canon)
    df: dict[str, int] = {}
    for f in canon:
        for t in bm.content_tokens(bm.normalize(f["name"])):
            df[t] = df.get(t, 0) + 1
    global _IDF, _MAX_IDF
    _IDF = {t: math.log(n / c) for t, c in df.items()}
    _MAX_IDF = math.log(n)  # a token seen on a single canonical (or unseen)


def idf(token: str) -> float:
    return _IDF.get(token, _MAX_IDF)

# Recipe-context keywords that disambiguate a fresh vs. dried/ground vs.
# leaf vs. seed canonical. When a candidate's distinctive token (the word it
# adds over the junk name) matches the recipe context, it's a strong signal.
FRESH_HINTS = {
    "fresh", "grated", "grate", "peeled", "peel", "minced", "mince",
    "chopped", "chop", "sliced", "slice", "julienne", "knob", "thumb",
    "raw", "leaf", "leaves", "cilantro", "sprig", "stalk", "root",
}
DRY_HINTS = {"ground", "powder", "powdered", "dried", "dry", "seed", "seeds"}

# Content words that are really a *form* of the head noun, not a different
# food: "Ginger root", "Coriander leaf", "Ginger paste". A candidate that adds
# one of these is still a variant (mergeable); a candidate that adds a genuine
# food word ("Peanut" Butter, "Almond" Butter) is a different food.
FORM_WORDS = {
    "root", "leaf", "leaves", "sprig", "stalk", "stalks", "clove", "cloves",
    "head", "bulb", "raw", "paste", "whole",
}

COLORS = {"red", "green", "black", "brown", "white", "yellow"}
# Distinguishing descriptors: if the junk and the canonical disagree on any of
# these (and the recipe doesn't justify it), they're different *variants* of the
# same head noun — block the auto-merge ("green onion" ≠ "Dried Onion Flakes",
# "smoked paprika" ≠ "Paprika"). Pure prep words ("ripe", "chopped") are not
# here — they don't distinguish a canonical, so they don't block.
# Fat-content / form descriptors that separate canonicals of the same head
# noun ("Milk Whole" vs "Milk Lowfat", "Onion Powder" vs fresh onion).
FORM = {"lowfat", "nonfat", "whole", "reduced", "fat", "powder",
        "flake", "flakes", "clarified"}
# "ripe" is excluded — it's a ripeness/prep note, not a distinct canonical
# (we want "ripe banana" → Banana, "ripe tomato" → Tomato).
DISTINGUISH = (bm.SEMANTIC_DESCRIPTORS - {"ripe"}) | COLORS | FORM


def norm_tokens(name: str) -> set:
    return set(bm.normalize(name).split())


def parse_candidates(s: str) -> list[tuple[int, str]]:
    out = []
    for part in str(s).split("|"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        cid, cname = part.split("=", 1)
        if cid.strip().isdigit():
            out.append((int(cid.strip()), cname.strip()))
    return out


def recommend(row: dict) -> tuple[int, str, str]:
    """Return (dst_id, dst_name, rec_note). dst_id 0 == recommend rename."""
    jname = row["new_name"]
    jt = bm.content_tokens(bm.normalize(jname))
    jfull = norm_tokens(jname)
    if not jt:
        return 0, "", "rename (no content token)"
    cands = parse_candidates(row.get("candidates", ""))
    if not cands:
        return 0, "", "rename (no candidate)"
    hint = f"{row.get('old_name', '')} {row.get('used_in', '')}".lower()
    hint_fresh = any(re.search(rf"\b{re.escape(w)}", hint) for w in FRESH_HINTS)
    hint_dry = any(re.search(rf"\b{re.escape(w)}", hint) for w in DRY_HINTS)

    j_total = sum(idf(t) for t in jt)
    # The junk's own "first content word" — used to break ties toward the
    # candidate built on the same head noun ("garlic clove" → Garlic, not Clove).
    jfirst = next((t for t in bm.normalize(jname).split() if t in jt), "")

    jdesc = jfull & DISTINGUISH
    jhead_idf = max(idf(t) for t in jt)
    scored = []
    for cid, cname in cands:
        ct = bm.content_tokens(bm.normalize(cname))
        cfull = norm_tokens(cname)
        inter = jt & ct
        if not inter:
            continue
        shared = sum(idf(t) for t in inter)
        extra = sum(idf(t) for t in ct - jt)       # info the canonical adds
        coverage = shared / j_total if j_total else 0.0     # junk recall
        precision = shared / (shared + extra) if shared + extra else 0.0
        score = 0.7 * coverage + 0.3 * precision
        # Descriptor compatibility. A canonical that *adds* a distinguishing
        # descriptor is allowed only if the recipe text justifies it; a
        # canonical that *drops* one the junk carries is a variant mismatch.
        cdesc = cfull & DISTINGUISH
        added = {d for d in cdesc - jdesc if not re.search(rf"\b{d}", hint)}
        dropped = jdesc - cdesc
        # A candidate that adds a *food* word more specific than the junk's
        # head ("peanut" over "butter") is a different food, not a variant.
        diff_food = any(
            t not in FORM_WORDS and idf(t) >= jhead_idf for t in ct - jt
        )
        desc_ok = not added and not dropped and not diff_food
        if jdesc and jdesc == cdesc:
            score += 0.2                     # exact variant match — prefer it
        # Recipe-context: a fresh/dried/leaf/seed token that distinguishes this
        # candidate and matches the recipe wording is a strong confirmation.
        distinct = cfull ^ jfull
        if hint_fresh and distinct & FRESH_HINTS:
            score += 0.15
        if hint_dry and distinct & DRY_HINTS:
            score += 0.15
        if jfirst and jfirst in ct:
            score += 0.05
        scored.append((desc_ok, score, coverage, precision, len(ct), cid, cname))

    if not scored:
        return 0, "", "rename (no shared content)"
    # Closest overall (any descriptor) — used for the rename note.
    scored.sort(key=lambda t: (-t[1], -t[2], t[4]))
    closest = scored[0]
    # Confident merge: descriptor-compatible AND most identifying info matched.
    eligible = [s for s in scored if s[0]]
    if eligible:
        _, score, cov, prec, _, cid, cname = eligible[0]
        if cov >= 0.6 and score >= 0.55:
            return cid, cname, f"merge → {cname} (cov={cov:.2f} p={prec:.2f})"
    # Otherwise lean rename, but record the closest guess for the human.
    return 0, "", f"rename? closest {closest[6]} (cov={closest[2]:.2f})"


def emit_row(r: dict) -> str:
    return (
        f"    - {{ id: {r['id']:4d}, old_name: {r['old_name']!r}, "
        f"new_name: {r['new_name']!r}, dst_id: {r['dst_id']:4d}, "
        f"dst_name: {r['dst_name']!r}, candidates: {r['candidates']!r}, "
        f"rec: {r['rec']!r}, used_in: {r['used_in']!r} }}"
    )


def main():
    build_idf()
    lines = MAPPING.read_text().splitlines()
    out: list[str] = []
    in_block = False
    n_merge = n_rename = n_kept = 0
    for line in lines:
        # Block runs from "  review_merges:" until the next "  <key>:".
        if re.match(r"^  review_merges:", line):
            in_block = True
            out.append(line)
            continue
        if in_block and re.match(r"^  \w[\w_-]*:", line):
            in_block = False
        if in_block and line.strip().startswith("- {"):
            row = ap.parse_row(line)
            # Respect a pre-filled high-confidence suggestion from build_mapping.
            if row.get("dst_id") or 0:
                row.setdefault("rec", "prefilled (high-confidence)")
                n_kept += 1
            else:
                dst_id, dst_name, rec = recommend(row)
                row["dst_id"], row["dst_name"], row["rec"] = dst_id, dst_name, rec
                if dst_id:
                    n_merge += 1
                else:
                    n_rename += 1
            row.setdefault("rec", "")
            out.append(emit_row(row))
            continue
        out.append(line)

    MAPPING.write_text("\n".join(out) + "\n")
    print(f"review_merges annotated in {MAPPING}")
    print(f"  kept pre-filled:     {n_kept}")
    print(f"  recommended merge:   {n_merge}")
    print(f"  recommended rename:  {n_rename}")


if __name__ == "__main__":
    main()
