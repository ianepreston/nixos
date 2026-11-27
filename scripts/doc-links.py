#!/usr/bin/env python3
"""Check that relative links in the repository's Markdown resolve (#1026).

Usage: doc-links.py [ROOT]

Every tracked `*.md` file is scanned (`git ls-files`, or a filesystem walk when
ROOT is not a Git checkout, as in the flake-check sandbox copy). For each
inline link (also one wrapped over several lines), image (also one nested in
a link's text) or reference definition whose target is relative, the
percent-decoded target path must exist under ROOT, and a `#fragment` pointing
into a Markdown file must name one of that file's ATX or setext headings
(GitHub's anchor rules) or an explicit `<a name|id="...">` anchor. External
URLs (any `scheme:`) are not fetched. Links inside fenced code blocks and
inline code spans are ignored.

Offline and read-only; exits 1 and lists every broken link if any are found.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
SETEXT = re.compile(r"^ {0,3}(=+|-+)\s*$")
# A code span cannot cross a blank line (paragraph boundary), so a stray
# backtick must not blank the prose up to a later one and hide real links.
INLINE_CODE = re.compile(r"(`+)((?:(?!\n[ \t]*\n).)+?)\1", re.S)
# [text](target) and ![alt](target), possibly spanning lines. The text may
# hold one level of brackets, e.g. an image inside a link; it is scanned too.
INLINE_LINK = re.compile(
    r"!?\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\(\s*(<[^>]*>|[^)\s]*)[^)]*\)"
)
REF_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)", re.M)
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


def strip_fences(text: str) -> list[str]:
    """The file's lines with fenced code blocks (fences included) blanked."""
    out, fence = [], None
    for line in text.split("\n"):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            out.append("")
            continue
        if m:
            fence = m.group(1)
            out.append("")
            continue
        out.append(line)
    return out


def prose(text: str) -> str:
    """Text outside code, same length and line breaks, for link scanning."""
    joined = "\n".join(strip_fences(text))
    return INLINE_CODE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), joined)


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

    def add(heading: str) -> None:
        base = slug(heading)
        count = seen.get(base, 0)
        seen[base] = count + 1
        out.add(base if count == 0 else f"{base}-{count}")

    paragraph: list[str] = []
    for line in strip_fences(text):
        out.update(HTML_ANCHOR.findall(line))
        m = HEADING.match(line)
        if m:
            add(m.group(2))
            paragraph = []
        elif SETEXT.match(line) and paragraph:
            # `Title` underlined with === or --- (a bare --- is a rule).
            add(" ".join(s.strip() for s in paragraph))
            paragraph = []
        elif line.strip():
            paragraph.append(line)
        else:
            paragraph = []
    return out


def link_targets(text: str):
    body = prose(text)

    def line_of(pos: int) -> int:
        return body.count("\n", 0, pos) + 1

    for m in REF_DEF.finditer(body):
        yield line_of(m.start(1)), m.group(1)

    def scan(start: int, end: int):
        for m in INLINE_LINK.finditer(body, start, end):
            yield line_of(m.start(2)), m.group(2)
            yield from scan(m.start(1), m.end(1))

    yield from scan(0, len(body))


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
            path_part, fragment = unquote(path_part), unquote(fragment)
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
