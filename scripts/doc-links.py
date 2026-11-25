#!/usr/bin/env python3
"""Check that relative links in the repository's Markdown resolve (#1026).

Usage: doc-links.py [ROOT]

Every tracked `*.md` file is scanned (`git ls-files`, or a filesystem walk when
ROOT is not a Git checkout, as in the flake-check sandbox copy). For each
inline link, image or reference definition whose target is relative, the
target path must exist under ROOT, and a `#fragment` pointing into a Markdown
file must name one of that file's headings (GitHub's anchor rules) or an
explicit `<a name|id="...">` anchor. External URLs (any `scheme:`) are not
fetched. Links inside fenced code blocks and inline code spans are ignored.

Offline and read-only; exits 1 and lists every broken link if any are found.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
INLINE_CODE = re.compile(r"(`+)(.+?)\1")
# [text](target) and ![alt](target); the text may itself hold an image.
INLINE_LINK = re.compile(
    r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(<[^>]*>|[^)\s]*)[^)]*\)"
)
REF_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
HTML_ANCHOR = re.compile(r"<a\s[^>]*\b(?:name|id)=[\"']([^\"']+)[\"']", re.I)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
SKIP_DIRS = {".git", "node_modules", ".direnv"}


def markdown_files(root: Path) -> list[Path]:
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--", "*.md"],
            check=True,
            capture_output=True,
        ).stdout
        files = [root / f for f in out.decode().split("\0") if f]
        return sorted(f for f in files if f.is_file())
    except (OSError, subprocess.CalledProcessError):
        found = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(
                d for d in dirnames if d not in SKIP_DIRS and not d.startswith("result")
            )
            found += [Path(dirpath) / f for f in filenames if f.endswith(".md")]
        return sorted(found)


def prose_lines(text: str):
    """Yield (line number, line) outside fenced code blocks."""
    fence = None
    for n, line in enumerate(text.split("\n"), 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        yield n, line


def slug(heading: str) -> str:
    """GitHub's heading anchor: rendered text, lower-cased, punctuation dropped."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    text = INLINE_CODE.sub(lambda m: m.group(2), text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[^\w\- ]", "", text.lower())
    return text.replace(" ", "-")


def anchors(text: str) -> set[str]:
    seen: dict[str, int] = {}
    out = set()
    for _, line in prose_lines(text):
        m = HEADING.match(line)
        if m:
            base = slug(m.group(2))
            count = seen.get(base, 0)
            seen[base] = count + 1
            out.add(base if count == 0 else f"{base}-{count}")
        out.update(HTML_ANCHOR.findall(line))
    return out


def link_targets(text: str):
    for n, line in prose_lines(text):
        m = REF_DEF.match(line)
        if m:
            yield n, m.group(1)
            continue
        stripped = INLINE_CODE.sub("", line)
        for m in INLINE_LINK.finditer(stripped):
            yield n, m.group(1)


def check(root: Path) -> list[str]:
    root = root.resolve()
    cache: dict[Path, set[str]] = {}

    def anchors_of(path: Path) -> set[str]:
        if path not in cache:
            cache[path] = anchors(path.read_text(encoding="utf-8"))
        return cache[path]

    problems = []
    for md in markdown_files(root):
        rel = md.relative_to(root)
        for n, raw in link_targets(md.read_text(encoding="utf-8")):
            target = raw[1:-1] if raw.startswith("<") else raw
            if not target or SCHEME.match(target) or target.startswith("//"):
                continue
            path_part, _, fragment = target.partition("#")
            if path_part:
                base = root if path_part.startswith("/") else md.parent
                dest = (base / path_part.lstrip("/")).resolve()
                if not dest.is_relative_to(root):
                    problems.append(
                        f"{rel}:{n}: {target}: points outside the repository"
                    )
                    continue
                if not dest.exists():
                    problems.append(f"{rel}:{n}: {target}: no such file")
                    continue
            else:
                dest = md
            if fragment and dest.suffix == ".md" and dest.is_file():
                if fragment.lower() not in anchors_of(dest):
                    where = dest.relative_to(root)
                    problems.append(
                        f"{rel}:{n}: {target}: no heading `#{fragment}` in {where}"
                    )
    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path.cwd()
    problems = check(root)
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        print(f"doc-links: {len(problems)} broken link(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
