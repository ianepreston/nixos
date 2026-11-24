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

Which files count:
  * In a git work tree whose top is ROOT, only git-tracked paths under
    skills/, .claude/ and .agents/ are considered (`git ls-files`, so
    intent-to-add entries count). Untracked or ignored files on disk (e.g.
    .DS_Store, or a copy left after `git rm --cached`) neither fail nor
    satisfy the check. A new workflow or adapter is invisible until it is
    tracked: `git add -N` it, as AGENTS.md already requires for flake
    evaluation.
  * Without git, or when ROOT is not the top of a work tree (the Nix sandbox
    copy), the filesystem is walked instead, ignoring .DS_Store.

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
    that is exactly `---`. Delimiters must start at column 0. Inside the
    block every byte must match the canonical file exactly, so LF vs CRLF or
    a trailing space is a stale copy.
  * The canonical block must be closed, non-empty and have top-level (column
    0) `name:` and `description:` lines. The first `name:` value must equal
    the directory name after a line rule: a trailing ` # comment` (`#` after
    whitespace, outside quotes) and one pair of matching quotes are stripped,
    and for a block scalar indicator (>, >-, |, |-) the first non-empty
    indented line is used. Nothing else is parsed: metadata value syntax
    (YAML quoting, escapes, duplicate keys) is NOT validated; it is the
    canonical file's responsibility, and the wrapper only has to copy it.
  * After the block the wrapper must hold exactly one non-blank line, the
    import line. Any other content (e.g. a copied body) is rejected.

Tolerated differences (exactly these):
  * Delimiter lines: trailing spaces and a CR (`---` + [ \r]*).
  * Import line: trailing spaces, tabs and CR; blank lines around it.

Known limits:
  * core.autocrlf: checking out only one of the two files can leave CRLF in
    one and LF in the other, so the metadata reports as stale ("line endings
    differ"). Check both files out again.
  * Case-insensitive filesystems (macOS default) can hide case-only path
    mistakes locally; the Linux CI run of this check catches them.
  * Only paths below ROOT are validated: a symlinked ROOT, or a symlink in a
    parent of ROOT, is not rejected.
  * A permission error ends that workflow's checks early; it is still
    reported and the exit status is non-zero.

Exits 0 when consistent, 1 with one actionable line per problem otherwise. An
unexpected OS or decoding error is reported against the path being checked
rather than aborting the scan. Static validation cannot prove that Claude or
Codex discovers the skills at runtime.
"""

import os
import re
import shlex
import stat
import subprocess
import sys
from pathlib import Path

SKILLS = "skills"
CLAUDE = ".claude/skills"
AGENTS = ".agents/skills"
ROOTS = (SKILLS, ".claude", CLAUDE, ".agents", AGENTS)
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*")
DELIM = re.compile(rb"---[ \r]*\n?")
BLOCK_INDICATORS = (">", ">-", "|", "|-")
# Filesystem fallback only: macOS Finder metadata, never a skill or adapter.
JUNK = {".DS_Store"}


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


def tracked_files(root):
    """Git-tracked paths below ROOT (intent-to-add included), or None.

    None means "use the filesystem": git is missing, ROOT is not a work tree,
    or ROOT is not the top of its work tree (e.g. the Nix sandbox copy).
    """
    try:
        top = subprocess.run(
            ["git", "-C", root, "rev-parse", "--show-prefix"], capture_output=True
        )
        if top.returncode != 0 or top.stdout.strip():
            return None
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--", SKILLS, ".claude", ".agents"],
            capture_output=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return {os.fsdecode(p) for p in out.split(b"\0") if p}


class Tree:
    """ROOT seen through the git index when available, else the filesystem.

    With git, a path that is not tracked (and has no tracked path below it)
    is "missing" even if it exists on disk, so untracked files can neither
    fail nor satisfy the check. Tracked paths are still classified by lstat.
    """

    def __init__(self, root, tracked):
        self.root = root
        self.tracked = tracked
        self.dirs = set()
        for p in tracked or ():
            parts = p.split("/")
            for i in range(1, len(parts)):
                self.dirs.add("/".join(parts[:i]))

    def path(self, rel):
        return os.path.join(self.root, rel)

    def kind(self, rel):
        if self.tracked is not None and rel not in self.tracked | self.dirs:
            return "missing"
        return kind(self.path(rel))

    def listdir(self, rel):
        if self.tracked is None:
            return sorted(e for e in os.listdir(self.path(rel)) if e not in JUNK)
        prefix = rel + "/"
        return sorted(
            {
                p[len(prefix) :].split("/")[0]
                for p in self.tracked
                if p.startswith(prefix)
            }
        )


def check_roots(root, problems):
    """The ROOTS that are real directories reached through real directories."""
    ok = set()
    for rel in ROOTS:
        parent = os.path.dirname(rel)
        if parent and parent not in ok:
            continue
        k = root.kind(rel)
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


def strip_comment(v):
    """Drop a trailing `# comment` (whitespace before `#`, outside quotes)."""
    start = 0
    if v[:1] in ("'", '"'):
        close = v.find(v[0], 1)
        start = close + 1 if close > 0 else len(v)
    m = re.search(r"\s#", v[start:])
    return v if m is None else v[: start + m.start()]


def name_value(block):
    """The first top-level `name:` value, by a line rule (not a YAML parser).

    Strips a trailing comment and one pair of matching quotes; for a block
    scalar indicator (>, >-, |, |-) takes the first non-empty indented line.
    """
    lines = block.decode("utf-8", "replace").splitlines()
    i = next(i for i, ln in enumerate(lines) if ln.startswith("name:"))
    v = strip_comment(lines[i][len("name:") :].strip()).strip()
    if v in BLOCK_INDICATORS:
        for ln in lines[i + 1 :]:
            if ln.strip():
                return ln.strip() if ln[:1] in (" ", "\t") else ""
        return ""
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
    workflows, reported = [], set()
    for entry in root.listdir(SKILLS):
        k = root.kind(f"{SKILLS}/{entry}")
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
        sk = root.kind(f"{rel}/SKILL.md")
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
    for p, want_kind, what in (
        (f"{CLAUDE}/{name}", "directory", "a real directory"),
        (rel, "file", "a regular file"),
    ):
        k = root.kind(p)
        if k == "missing":
            problems.append(f"{name}: missing Claude adapter {rel}; {create}")
            return
        if k != want_kind:
            problems.append(f"{name}: {p} is a {k}, not {what}; remove it and {create}")
            return
    with open(root.path(rel), "rb") as f:
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
    link = root.path(rel)
    expected = f"../../skills/{name}"
    fix = f"ln -sfn {q(expected)} {q(rel)}"
    k = root.kind(rel)
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
    if os.path.realpath(link) != os.path.realpath(root.path(f"{SKILLS}/{name}")):
        problems.append(
            f"{name}: {rel} does not resolve to the canonical {SKILLS}/{name}; "
            f"run `{fix}`"
        )


def check_orphans(root, rel, known, hint, problems):
    for entry in root.listdir(rel):
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
    with open(root.path(canon), "rb") as f:
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
    """Append every problem to problems; return the workflow names.

    root is a Tree, or a path (then the git index is used when available).
    """
    if not isinstance(root, Tree):
        root = Tree(root, tracked_files(root))
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
    tree = Tree(root, tracked_files(root))
    problems = []
    workflows = check_tree(tree, problems)
    for p in problems:
        print(f"skill-adapters: {p}", file=sys.stderr)
    if problems:
        return 1
    source = "filesystem" if tree.tracked is None else "git-tracked files"
    print(f"skill-adapters: {len(workflows)} skills, adapters consistent ({source})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
