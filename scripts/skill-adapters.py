#!/usr/bin/env python3
"""Check the discovery adapters against the canonical skill catalog (#1033).

    skill-adapters.py [ROOT]

ROOT defaults to the repository root (the parent of scripts/). Offline and
read-only: no network, credentials, hosts or model calls.

The canonical workflows live in skills/<name>/SKILL.md. Two thin adapter sets
make them discoverable, and each must exist for every canonical skill:

  .claude/skills/<name>/SKILL.md  the canonical frontmatter copied byte for
                                  byte, then one `@` import line that
                                  forwards to ../../../skills/<name>/SKILL.md
  .agents/skills/<name>           a directory symlink to ../../skills/<name>

Rules:
  * A directory under skills/ is a workflow only if it holds a SKILL.md; others
    (e.g. `_shared`) are shared reference material and need no adapter.
  * Canonical entries and Claude wrappers must be regular files in real
    directories (no symlinks anywhere on the path) that stay inside ROOT.
  * Files must be UTF-8. Frontmatter must have non-empty `name` and
    `description` fields, and quoted values must be closed.
  * The wrapper's frontmatter is compared as raw bytes: line endings (LF vs
    CRLF) and trailing whitespace are part of the copy. Trailing spaces, tabs
    and CR are tolerated only when *recognising* a `---` delimiter line or the
    import line; they do not excuse a byte difference inside the copied block.
  * Every problem is reported; a bad file never aborts the scan.

Exits 0 when consistent, 1 with one actionable line per problem otherwise.
Static validation cannot prove that Claude or Codex discovers the skills at
runtime.
"""

import os
import shlex
import sys
from pathlib import Path

CLAUDE_DIR = Path(".claude/skills")
AGENTS_DIR = Path(".agents/skills")
SKILLS_DIR = Path("skills")
BLANKS = b" \t\r\n"
BLOCK_SCALARS = {">", "|", ">-", "|-", ">+", "|+"}


class Bad(Exception):
    """A file that cannot be validated; the message names the defect."""


def q(path):
    return shlex.quote(str(path))


def symlink_on_path(root, rel):
    """First component of rel (below root) that is a symlink, else None."""
    cur = Path(root)
    for part in Path(rel).parts:
        cur = cur / part
        if cur.is_symlink():
            return cur.relative_to(root)
    return None


def inside(root, path):
    real = os.path.realpath(path)
    base = os.path.realpath(root)
    return real == base or real.startswith(base + os.sep)


def regular_file_problem(root, rel):
    """Why rel is not a regular file in real directories inside root, or None."""
    link = symlink_on_path(root, rel)
    if link is not None:
        return f"{link} is a symlink; it must be a regular file or real directory"
    path = Path(root) / rel
    if not inside(root, path):
        return f"{rel} resolves outside the repository"
    try:
        if not path.is_file():
            return f"{rel} is not a regular file"
    except OSError as e:
        return f"{rel} is unreadable ({e.strerror})"
    return None


def split_frontmatter(data):
    """(frontmatter bytes incl. both delimiter lines, rest bytes) or None."""
    lines = data.splitlines(keepends=True)
    if not lines or lines[0].strip(BLANKS) != b"---":
        return None
    for i in range(1, len(lines)):
        if lines[i].strip(BLANKS) == b"---":
            return b"".join(lines[: i + 1]), b"".join(lines[i + 1 :])
    return None


def quote_problem(value):
    """Describe a malformed quoted scalar, or None if it is closed properly."""
    c = value[0]
    body = value[1:]
    i = 0
    while i < len(body):
        if c == '"' and body[i] == "\\":
            i += 2
            continue
        if body[i] == c:
            if c == "'" and body[i + 1 : i + 2] == "'":
                i += 2
                continue
            return None if i == len(body) - 1 else "has text after the closing quote"
        i += 1
    return "has an unclosed quote"


def validate_fields(fm):
    """Require well-formed `name` and `description`; raises Bad."""
    fields = {}
    key = None
    for ln in fm.decode("utf-8").splitlines()[1:-1]:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if ln[0] in " \t":
            if key is None:
                raise Bad("frontmatter has an indented line before any field")
            fields[key]["cont"] = True
            continue
        k, sep, v = ln.partition(":")
        if not sep or not k.strip():
            raise Bad(f"frontmatter line is not `key: value`: {ln.strip()!r}")
        key = k.strip()
        fields[key] = {"value": v.strip(), "cont": False}
    for need in ("name", "description"):
        f = fields.get(need)
        if f is None:
            raise Bad(f"frontmatter has no `{need}` field")
        v = f["value"]
        if not v and not f["cont"]:
            raise Bad(f"frontmatter `{need}` is empty")
        if v in BLOCK_SCALARS and not f["cont"]:
            raise Bad(f"frontmatter `{need}` block scalar has no content")
        if v[:1] in ("'", '"'):
            why = quote_problem(v)
            if why:
                raise Bad(f"frontmatter `{need}` {why}")


def load(root, rel):
    """(frontmatter bytes, rest bytes) of a validated file; raises Bad."""
    why = regular_file_problem(root, rel)
    if why:
        raise Bad(why)
    try:
        data = (Path(root) / rel).read_bytes()
    except OSError as e:
        raise Bad(f"cannot be read ({e.strerror})") from e
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise Bad(f"is not valid UTF-8 (bad byte at offset {e.start})") from e
    parts = split_frontmatter(data)
    if parts is None:
        raise Bad("has no `---` frontmatter block")
    validate_fields(parts[0])
    return parts


def canonical_skills(root, problems=None):
    """Names of real directories under skills/ holding a SKILL.md."""
    base = Path(root) / SKILLS_DIR
    names = []
    if not base.is_dir():
        return names
    for p in sorted(base.iterdir(), key=lambda p: p.name):
        if p.is_symlink():
            if problems is not None:
                problems.append(
                    f"{p.name}: {SKILLS_DIR / p.name} is a symlink; canonical "
                    f"skills must be real directories (replace it with the "
                    f"directory, or delete it)"
                )
            continue
        if os.path.lexists(p / "SKILL.md"):
            names.append(p.name)
    return names


def describe_difference(want, have):
    if want.replace(b"\r\n", b"\n") == have.replace(b"\r\n", b"\n"):
        return "line endings differ (CRLF vs LF)"

    def strip(b):
        lines = b.replace(b"\r\n", b"\n").split(b"\n")
        return b"\n".join(ln.rstrip(BLANKS) for ln in lines)

    if strip(want) == strip(have):
        return "trailing whitespace differs"
    return "name/description differ"


def check_claude(root, name, problems):
    canon_rel = SKILLS_DIR / name / "SKILL.md"
    rel = CLAUDE_DIR / name / "SKILL.md"
    expected = f"@../../../skills/{name}/SKILL.md"
    try:
        want = load(root, canon_rel)[0]
    except Bad as e:
        problems.append(f"{name}: {canon_rel}: {e}")
        want = None
    if not os.path.lexists(Path(root) / rel):
        problems.append(
            f"{name}: missing Claude adapter {rel}; create it with the "
            f"frontmatter copied from {canon_rel} followed by `{expected}`"
        )
        return
    try:
        have, rest = load(root, rel)
    except Bad as e:
        problems.append(f"{name}: {rel}: {e}; fix it to match {canon_rel}")
        return
    if want is not None and have != want:
        problems.append(
            f"{name}: {rel} frontmatter is stale ({describe_difference(want, have)}); "
            f"replace it with the frontmatter of {canon_rel}, copied byte for byte"
        )
    body = [ln.rstrip(BLANKS) for ln in rest.splitlines() if ln.strip(BLANKS)]
    if body != [expected.encode()]:
        got = " | ".join(b.decode("utf-8", "replace") for b in body) or "(nothing)"
        problems.append(
            f"{name}: {rel} must contain exactly one import line after the "
            f"frontmatter, `{expected}` (trailing whitespace is ignored); "
            f"found {got}; never copy the body"
        )
        return
    target = Path(root) / rel.parent / expected[1:]
    if os.path.realpath(target) != os.path.realpath(Path(root) / canon_rel):
        problems.append(
            f"{name}: {rel} import `{expected}` does not resolve to {canon_rel}"
        )


def check_agents(root, name, problems):
    rel = AGENTS_DIR / name
    link = Path(root) / rel
    expected = f"../../skills/{name}"
    fix = f"ln -sfn {q(expected)} {q(rel)}"
    if not os.path.lexists(link):
        problems.append(f"{name}: missing Codex adapter {rel}; run `{fix}`")
        return
    parent = symlink_on_path(root, AGENTS_DIR)
    if parent is not None:
        problems.append(f"{name}: {parent} is a symlink; it must be a real directory")
        return
    if not link.is_symlink():
        problems.append(
            f"{name}: {rel} must be a directory symlink to {expected}, not a real "
            f"file or directory; remove it and run `{fix}`"
        )
        return
    target = os.readlink(link)
    if target != expected:
        problems.append(
            f"{name}: {rel} points to `{target}`, expected `{expected}`; run `{fix}`"
        )
        return
    real = os.path.realpath(link)
    canon = os.path.realpath(Path(root) / SKILLS_DIR / name)
    if real != canon or not os.path.isfile(link / "SKILL.md"):
        problems.append(
            f"{name}: {rel} does not resolve to the canonical {SKILLS_DIR / name} "
            f"(broken link, loop or redirected path); run `{fix}`"
        )


def check_orphans(root, skills, problems):
    known = set(skills)
    for adapter_dir, hint in (
        (CLAUDE_DIR, "remove the directory"),
        (AGENTS_DIR, "remove the symlink"),
    ):
        base = Path(root) / adapter_dir
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
    skills = canonical_skills(root, problems)
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
