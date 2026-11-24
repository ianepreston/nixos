#!/usr/bin/env python3
"""Check the discovery adapters against the canonical skill catalog (#1033).

    skill-adapters.py [ROOT]

ROOT defaults to the repository root (the parent of scripts/). Offline and
read-only: no network, credentials, hosts or model calls.

The canonical workflows live in skills/<name>/SKILL.md. Two thin adapter sets
make them discoverable, and each must exist for every canonical workflow:

  .claude/skills/<name>/SKILL.md  the canonical frontmatter block copied byte
                                  for byte, then exactly one line
                                  `@../../../skills/<name>/SKILL.md`
  .agents/skills/<name>           a symlink whose target is exactly
                                  `../../skills/<name>`

Rules:
  * Paths are checked with lstat before anything is read or listed.
    `skills`, `.claude`, `.claude/skills`, `.agents` and `.agents/skills` must
    be real directories (not symlinks). Workflow and wrapper directories must
    be real directories and their SKILL.md regular files. A symlink anywhere
    else is reported and never followed or listed; the scan moves on.
  * A real directory under skills/ is a workflow only if it holds a SKILL.md;
    others (e.g. `_shared`) are reference material and need no adapter.
    Regular files directly under skills/ are ignored.
  * Entry names must match [A-Za-z0-9_][A-Za-z0-9._-]*. Anything else
    (including names that are not valid UTF-8) is reported and skipped.
  * Frontmatter is the bytes between a first line `---` and the next line
    that is exactly `---`. Delimiters must start at column 0; trailing spaces
    and CR are allowed on the delimiter lines only. An indented `---` is
    content. Inside the block every byte counts, so LF vs CRLF or a trailing
    space is a stale copy.
  * The canonical block must be closed, non-empty and have top-level (column
    0) `name:` and `description:` lines, and the `name:` value (whitespace and
    one pair of matching quotes stripped) must equal the directory name.
    Metadata value syntax (YAML quoting, escapes, block scalars, duplicate
    keys) is NOT validated: it is the canonical file's responsibility, and the
    wrapper only has to copy it exactly.
  * The import line may carry trailing spaces, tabs or CR; blank lines around
    it are ignored. Any other content (e.g. a copied body) is rejected.

Exits 0 when consistent, 1 with one actionable line per problem otherwise. An
unexpected OS or decoding error is reported against the path being checked
rather than aborting the scan. Static validation cannot prove that Claude or
Codex discovers the skills at runtime.
"""

import os
import re
import shlex
import stat
import sys
from pathlib import Path

SKILLS = "skills"
CLAUDE = ".claude/skills"
AGENTS = ".agents/skills"
ROOTS = (SKILLS, ".claude", CLAUDE, ".agents", AGENTS)
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*")
DELIM = re.compile(rb"---[ \r]*\n?")


def q(path):
    return shlex.quote(str(path))


def show(name):
    """A printable, ASCII-safe rendering of a directory entry name."""
    if NAME.fullmatch(name):
        return name
    return ascii(name.encode("utf-8", "surrogateescape").decode("utf-8", "replace"))


def kind(path):
    """'missing', 'symlink', 'dir', 'file' or 'other', never following links."""
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return "missing"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "file"
    return "special file"


def check_roots(root, problems):
    """The ROOTS that are real directories reached through real directories."""
    ok = set()
    for rel in ROOTS:
        parent = os.path.dirname(rel)
        if parent and parent not in ok:
            continue
        k = kind(os.path.join(root, rel))
        if k == "directory":
            ok.add(rel)
        elif k == "missing":
            problems.append(f"{rel}: missing; create the directory")
        else:
            problems.append(
                f"{rel}: is a {k}, not a real directory; replace it with a real "
                f"directory (it is not followed or listed)"
            )
    return ok


def frontmatter(data):
    """(bytes between the `---` lines, bytes after), or (None, None)."""
    lines = data.splitlines(keepends=True)
    if not lines or not DELIM.fullmatch(lines[0]):
        return None, None
    for i in range(1, len(lines)):
        if DELIM.fullmatch(lines[i]):
            return b"".join(lines[1:i]), b"".join(lines[i + 1 :])
    return None, None


def name_value(block):
    v = re.search(rb"^name:(.*)$", block, re.M).group(1)
    v = v.decode("utf-8", "replace").strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    return v


def canonical_problem(name, data):
    """Why the canonical SKILL.md frontmatter is unusable, or None."""
    block, _ = frontmatter(data)
    if block is None:
        return "has no closed `---` frontmatter block at the top"
    if not block.strip():
        return "has an empty frontmatter block"
    for key in (b"name:", b"description:"):
        if not re.search(rb"^" + key, block, re.M):
            return f"frontmatter has no top-level `{key.decode()}` line"
    got = name_value(block)
    if got != name:
        return f"frontmatter name {got!r} does not match the directory name"
    return None


def describe_difference(want, have):
    if want.replace(b"\r\n", b"\n") == have.replace(b"\r\n", b"\n"):
        return "line endings differ (CRLF vs LF)"

    def strip(b):
        return [ln.rstrip(b" \t\r") for ln in b.replace(b"\r\n", b"\n").split(b"\n")]

    if strip(want) == strip(have):
        return "trailing whitespace differs"
    return "content differs"


def scan_skills(root, problems):
    """(workflow names, names under skills/ already reported as broken)."""
    base = os.path.join(root, SKILLS)
    workflows, reported = [], set()
    for entry in sorted(os.listdir(base)):
        path = os.path.join(base, entry)
        k = kind(path)
        if k == "file":
            continue
        if not NAME.fullmatch(entry):
            problems.append(
                f"{show(entry)}: unsupported name under {SKILLS}/ (allowed: "
                f"{NAME.pattern}); rename or remove it"
            )
            continue
        rel = f"{SKILLS}/{entry}"
        if k != "directory":
            problems.append(
                f"{entry}: {rel} is a {k}; canonical workflows must be real "
                f"directories (replace it with the directory, or delete it)"
            )
            reported.add(entry)
            continue
        sk = kind(os.path.join(path, "SKILL.md"))
        if sk == "missing":
            continue
        if sk != "file":
            problems.append(
                f"{entry}: {rel}/SKILL.md is a {sk}; it must be a regular file"
            )
            reported.add(entry)
            continue
        workflows.append(entry)
    return workflows, reported


def check_claude(root, name, want, problems):
    """want: canonical frontmatter bytes, or None when the canonical is bad."""
    canon = f"{SKILLS}/{name}/SKILL.md"
    rel = f"{CLAUDE}/{name}/SKILL.md"
    expected = f"@../../../skills/{name}/SKILL.md"
    create = (
        f"create {rel} with the frontmatter block of {canon} copied byte for "
        f"byte, then one line `{expected}`"
    )
    path = os.path.join(root, rel)
    for p, want_kind, what in (
        (os.path.join(root, CLAUDE, name), "directory", "a real directory"),
        (path, "file", "a regular file"),
    ):
        k = kind(p)
        if k == "missing":
            problems.append(f"{name}: missing Claude adapter {rel}; {create}")
            return
        if k != want_kind:
            shown = os.path.relpath(p, root)
            problems.append(
                f"{name}: {shown} is a {k}, not {what}; remove it and {create}"
            )
            return
    with open(path, "rb") as f:
        have, rest = frontmatter(f.read())
    if have is None:
        problems.append(
            f"{name}: {rel} has no closed `---` frontmatter block at the top; {create}"
        )
        return
    if want is not None and have != want:
        problems.append(
            f"{name}: {rel} frontmatter is stale ({describe_difference(want, have)}); "
            f"replace it with the frontmatter block of {canon}, copied byte for byte"
        )
    body = [ln.rstrip(b" \t\r") for ln in rest.split(b"\n") if ln.strip(b" \t\r")]
    if body != [expected.encode()]:
        got = " | ".join(b.decode("utf-8", "replace") for b in body[:3]) or "(nothing)"
        if len(body) > 3:
            got += f" | ... ({len(body)} lines)"
        problems.append(
            f"{name}: {rel} must contain exactly one line after the frontmatter, "
            f"`{expected}`; found {got}; never copy the body"
        )


def check_agents(root, name, problems):
    rel = f"{AGENTS}/{name}"
    link = os.path.join(root, rel)
    expected = f"../../skills/{name}"
    fix = f"ln -sfn {q(expected)} {q(rel)}"
    k = kind(link)
    if k == "missing":
        problems.append(f"{name}: missing Codex adapter {rel}; run `{fix}`")
        return
    if k != "symlink":
        problems.append(
            f"{name}: {rel} is a {k}, not a symlink to {expected}; remove it and "
            f"run `{fix}`"
        )
        return
    target = os.readlink(link)
    if target != expected:
        problems.append(
            f"{name}: {rel} points to {target!r}, expected `{expected}`; run `{fix}`"
        )
        return
    if os.path.realpath(link) != os.path.realpath(os.path.join(root, SKILLS, name)):
        problems.append(
            f"{name}: {rel} does not resolve to the canonical {SKILLS}/{name}; "
            f"run `{fix}`"
        )


def check_orphans(root, rel, known, hint, problems):
    for entry in sorted(os.listdir(os.path.join(root, rel))):
        if not NAME.fullmatch(entry):
            problems.append(f"{show(entry)}: unsupported name under {rel}/; {hint}")
        elif entry not in known:
            problems.append(
                f"{entry}: orphaned adapter {rel}/{entry} has no canonical "
                f"{SKILLS}/{entry}/SKILL.md; {hint}, or restore/rename the "
                f"canonical workflow"
            )


def guarded(problems, label, fn, *args):
    """Run fn; an unexpected OS/decoding error becomes a problem for label."""
    try:
        return fn(*args)
    except (OSError, UnicodeError, ValueError) as e:
        problems.append(f"{label}: could not be checked ({type(e).__name__}: {e})")
        return None


def check_workflow(root, name, roots, problems):
    canon = f"{SKILLS}/{name}/SKILL.md"
    with open(os.path.join(root, canon), "rb") as f:
        data = f.read()
    why = canonical_problem(name, data)
    want = None
    if why:
        problems.append(f"{name}: {canon} {why}")
    else:
        want = frontmatter(data)[0]
    if CLAUDE in roots:
        label = f"{name}: {CLAUDE}/{name}"
        guarded(problems, label, check_claude, root, name, want, problems)
    if AGENTS in roots:
        label = f"{name}: {AGENTS}/{name}"
        guarded(problems, label, check_agents, root, name, problems)


def check_tree(root, problems):
    """Append every problem to problems; return the workflow names."""
    roots = guarded(problems, "repository", check_roots, root, problems) or set()
    if SKILLS not in roots:
        return []
    found = guarded(problems, SKILLS, scan_skills, root, problems)
    if found is None:
        return []
    workflows, reported = found
    for name in workflows:
        guarded(problems, name, check_workflow, root, name, roots, problems)
    known = set(workflows) | reported
    for rel, hint in (
        (CLAUDE, "remove the directory"),
        (AGENTS, "remove the symlink"),
    ):
        if rel in roots:
            guarded(problems, rel, check_orphans, root, rel, known, hint, problems)
    return workflows


def check(root):
    """List of problems (empty when consistent). Never raises for tree content."""
    problems = []
    check_tree(os.fspath(root), problems)
    return problems


def main(argv):
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = argv[1] if len(argv) == 2 else str(Path(__file__).resolve().parent.parent)
    problems = []
    workflows = check_tree(root, problems)
    for p in problems:
        print(f"skill-adapters: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"skill-adapters: {len(workflows)} skills, adapters consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
