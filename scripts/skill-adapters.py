#!/usr/bin/env python3
"""Check the discovery adapters against the canonical skill catalog (#1033).

    skill-adapters.py [ROOT]

ROOT defaults to the repository root (the parent of scripts/). Offline and
read-only: no network, credentials, hosts or model calls.

The canonical workflows live in skills/<name>/SKILL.md. Two thin adapter sets
make them discoverable, and each must exist for every canonical skill:

  .claude/skills/<name>/SKILL.md  the canonical frontmatter block copied
                                  verbatim, then one `@` import line that
                                  forwards to ../../../skills/<name>/SKILL.md
  .agents/skills/<name>           a directory symlink to ../../skills/<name>

A directory under skills/ is a workflow only if it holds a SKILL.md; others
(e.g. `_shared`) are shared reference material and need no adapter. Exits 0
when consistent, 1 with one actionable line per problem otherwise. Static
validation cannot prove that Claude or Codex discovers the skills at runtime.
"""

import os
import sys
from pathlib import Path

CLAUDE_DIR = Path(".claude/skills")
AGENTS_DIR = Path(".agents/skills")
SKILLS_DIR = Path("skills")


def canonical_skills(root):
    base = root / SKILLS_DIR
    if not base.is_dir():
        return []
    return sorted(p.name for p in base.iterdir() if (p / "SKILL.md").is_file())


def split_frontmatter(text):
    """Return (frontmatter block incl. both `---` lines, remainder) or None."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            return "\n".join(lines[: i + 1]), "\n".join(lines[i + 1 :])
    return None


def check_claude(root, name, problems):
    adapter = root / CLAUDE_DIR / name / "SKILL.md"
    rel = CLAUDE_DIR / name / "SKILL.md"
    canonical = root / SKILLS_DIR / name / "SKILL.md"
    if not adapter.is_file():
        problems.append(
            f"{name}: missing Claude adapter {rel}; create it with the "
            f"frontmatter copied from {SKILLS_DIR / name / 'SKILL.md'} followed "
            f"by `@../../../skills/{name}/SKILL.md`"
        )
        return
    want = split_frontmatter(canonical.read_text())
    if want is None:
        problems.append(
            f"{name}: {SKILLS_DIR / name / 'SKILL.md'} has no `---` frontmatter block"
        )
        return
    have = split_frontmatter(adapter.read_text())
    if have is None:
        problems.append(
            f"{name}: {rel} has no `---` frontmatter block; copy it from "
            f"{SKILLS_DIR / name / 'SKILL.md'}"
        )
        return
    if have[0] != want[0]:
        problems.append(
            f"{name}: {rel} frontmatter is stale; replace it with the "
            f"frontmatter of {SKILLS_DIR / name / 'SKILL.md'} (name/description "
            f"must match verbatim)"
        )
    body = [ln for ln in have[1].split("\n") if ln.strip()]
    expected = f"@../../../skills/{name}/SKILL.md"
    if body != [expected]:
        got = " | ".join(body) if body else "(nothing)"
        problems.append(
            f"{name}: {rel} must contain exactly one import line after the "
            f"frontmatter, `{expected}`; found {got} (never copy the body)"
        )
    elif not (adapter.parent / expected[1:]).resolve().is_file():
        problems.append(f"{name}: {rel} import `{expected}` does not resolve")


def check_agents(root, name, problems):
    link = root / AGENTS_DIR / name
    rel = AGENTS_DIR / name
    expected = f"../../skills/{name}"
    if not link.is_symlink():
        if link.exists():
            problems.append(
                f"{name}: {rel} must be a directory symlink to {expected}, "
                f"not a real file or directory (remove it and `ln -s {expected} {rel}`)"
            )
        else:
            problems.append(
                f"{name}: missing Codex adapter {rel}; run `ln -s {expected} {rel}`"
            )
        return
    target = os.readlink(link)
    if target != expected:
        problems.append(
            f"{name}: {rel} points to `{target}`, expected `{expected}`; "
            f"recreate it with `ln -sfn {expected} {rel}`"
        )
    elif not (link / "SKILL.md").is_file():
        problems.append(f"{name}: {rel} is a broken symlink (no SKILL.md behind it)")


def check_orphans(root, skills, problems):
    known = set(skills)
    for adapter_dir, hint in (
        (CLAUDE_DIR, "remove the directory"),
        (AGENTS_DIR, "remove the symlink"),
    ):
        base = root / adapter_dir
        if not base.is_dir():
            continue
        for entry in sorted(base.iterdir(), key=lambda p: p.name):
            if entry.name not in known:
                problems.append(
                    f"{entry.name}: orphaned adapter {adapter_dir / entry.name} "
                    f"has no canonical {SKILLS_DIR / entry.name / 'SKILL.md'}; "
                    f"{hint}, or restore/rename the canonical skill"
                )


def check(root):
    root = Path(root)
    problems = []
    skills = canonical_skills(root)
    for name in skills:
        check_claude(root, name, problems)
        check_agents(root, name, problems)
    check_orphans(root, skills, problems)
    return problems


def main(argv):
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(argv[1]) if len(argv) == 2 else Path(__file__).resolve().parent.parent
    problems = check(root)
    for p in problems:
        print(f"skill-adapters: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"skill-adapters: {len(canonical_skills(root))} skills, adapters consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
