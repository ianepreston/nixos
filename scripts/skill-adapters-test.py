#!/usr/bin/env python3
"""Disposable-fixture tests for scripts/skill-adapters.py (#1033).

    skill-adapters-test.py [REPO_ROOT]

Every case builds a throwaway tree under a temp dir; the real tree is only
read by `CurrentTreeTest`. No network, credentials or hosts.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "skill-adapters.py"
SPEC = importlib.util.spec_from_file_location("adapters", SCRIPT)
assert SPEC and SPEC.loader
adapters = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapters)

REPO = HERE.parent


def front(name, desc="Does a thing."):
    return f"---\nname: {name}\ndescription: {desc}\n---\n"


class Fixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "repo"
        self.outside = Path(tmp.name) / "outside"
        (self.root / "skills/_shared").mkdir(parents=True)
        (self.root / "skills/_shared/ref.md").write_text("shared\n")
        (self.root / "skills/README.md").write_text("not a workflow\n")
        (self.root / ".claude/skills").mkdir(parents=True)
        (self.root / ".agents/skills").mkdir(parents=True)
        self.add_skill("alpha")
        self.add_skill("beta")

    def add_skill(self, name, claude=True, agents=True, fm=None):
        fm = front(name) if fm is None else fm
        d = self.root / "skills" / name
        d.mkdir(parents=True)
        (d / "SKILL.md").write_bytes(fm.encode() + b"\n# Body\n")
        if claude:
            self.write_wrapper(name, fm)
        if agents:
            os.symlink(f"../../skills/{name}", self.root / ".agents/skills" / name)

    def write_wrapper(self, name, fm, tail=None):
        c = self.root / ".claude/skills" / name
        c.mkdir(parents=True, exist_ok=True)
        tail = f"\n@../../../skills/{name}/SKILL.md\n" if tail is None else tail
        (c / "SKILL.md").write_bytes(fm.encode() + tail.encode())

    def wrapper(self, name="alpha"):
        return self.root / ".claude/skills" / name / "SKILL.md"

    def codex(self, name="alpha"):
        return self.root / ".agents/skills" / name

    def problems(self):
        return adapters.check(self.root)

    def assertClean(self):
        self.assertEqual([], self.problems())

    def assertOne(self, *needles):
        got = self.problems()
        self.assertEqual(1, len(got), got)
        for n in needles:
            self.assertIn(n, got[0])
        return got[0]


class CatalogTest(Fixture):
    def test_consistent_tree_passes_and_shared_and_files_are_ignored(self):
        self.assertClean()

    def test_missing_claude_adapter(self):
        self.add_skill("gamma", claude=False)
        self.assertOne(
            "gamma", "missing Claude adapter", ".claude/skills/gamma/SKILL.md"
        )

    def test_missing_claude_skill_md_in_existing_dir(self):
        self.wrapper().unlink()
        self.assertOne("alpha", "missing Claude adapter")

    def test_missing_codex_adapter(self):
        self.add_skill("gamma", agents=False)
        self.assertOne("gamma", "missing Codex adapter", "ln -sfn ../../skills/gamma")

    def test_new_canonical_skill_without_either_entry(self):
        self.add_skill("gamma", claude=False, agents=False)
        got = self.problems()
        self.assertEqual(2, len(got), got)
        self.assertTrue(all(p.startswith("gamma: missing") for p in got), got)

    def test_orphaned_adapters(self):
        self.write_wrapper("old", front("old"))
        os.symlink("../../skills/old", self.codex("old"))
        got = self.problems()
        self.assertEqual(2, len(got), got)
        self.assertTrue(all("orphaned adapter" in p for p in got), got)

    def test_missing_adapter_root(self):
        os.unlink(self.codex("alpha"))
        os.unlink(self.codex("beta"))
        os.rmdir(self.root / ".agents/skills")
        self.assertOne(".agents/skills: missing")


class ClaudeWrapperTest(Fixture):
    def test_stale_description(self):
        self.write_wrapper("alpha", front("alpha", "Old text."))
        self.assertOne("alpha", "stale", "content differs")

    def test_copied_body_is_rejected(self):
        self.write_wrapper(
            "alpha", front("alpha"), "\n@../../../skills/alpha/SKILL.md\n# Body\n"
        )
        self.assertOne("exactly one line", "never copy the body")

    def test_wrong_import_path(self):
        self.write_wrapper("alpha", front("alpha"), "\n@../../skills/alpha/SKILL.md\n")
        self.assertOne("@../../../skills/alpha/SKILL.md")

    def test_no_frontmatter(self):
        self.wrapper().write_text("@../../../skills/alpha/SKILL.md\n")
        self.assertOne("alpha", "no closed `---` frontmatter")

    def test_crlf_copy_of_lf_canonical_is_stale(self):
        self.write_wrapper("alpha", front("alpha").replace("\n", "\r\n"))
        self.assertOne("line endings differ")

    def test_trailing_space_inside_block_is_stale(self):
        self.write_wrapper("alpha", front("alpha", "Does a thing. "))
        self.assertOne("trailing whitespace differs")

    def test_delimiter_and_import_trailing_space_and_cr_are_tolerated(self):
        fm = front("alpha")
        self.write_wrapper(
            "alpha",
            fm.replace("---\n", "--- \r\n", 1)[:-4] + "---  \r\n",
            "\r\n@../../../skills/alpha/SKILL.md \t\r\n\r\n",
        )
        self.assertClean()

    def test_crlf_canonical_with_crlf_copy_passes(self):
        self.add_skill("gamma", fm=front("gamma").replace("\n", "\r\n"))
        self.assertClean()

    def test_indented_delimiter_is_content(self):
        # Previously an indented `---` ended the block early.
        fm = "---\nname: gamma\ndescription: |\n  one\n  ---\n  two\n---\n"
        self.add_skill("gamma", fm=fm)
        self.assertClean()
        self.write_wrapper("gamma", fm.replace("two", "TWO"))
        self.assertOne("gamma", "stale")

    def test_wrapper_dir_symlink(self):
        d = self.root / ".claude/skills/alpha"
        self.wrapper().unlink()
        d.rmdir()
        os.symlink("../../skills/alpha", d)
        self.assertOne("alpha", ".claude/skills/alpha is a symlink")

    def test_wrapper_file_symlink(self):
        self.wrapper().unlink()
        os.symlink("../../../skills/alpha/SKILL.md", self.wrapper())
        self.assertOne("alpha", "SKILL.md is a symlink, not a regular file")


class CanonicalMetadataTest(Fixture):
    VALID = {
        "multiline double-quoted": 'description: "Does a\n  thing: really."\n',
        "multiline single-quoted": "description: 'It''s\n  multiline'\n",
        "quoted with comment": 'description: "Does a thing."  # note\n',
        "quoted key": '"description": x\ndescription: y\n',
        "block scalar with --- and #": "description: >-\n  a\n  ---\n  # b\n",
    }

    def test_valid_yaml_shapes_pass_when_copied(self):
        # Each was rejected by the previous hand-written YAML validation.
        for i, (label, desc) in enumerate(self.VALID.items()):
            with self.subTest(label):
                name = f"v{i}"
                self.add_skill(name, fm=f"---\nname: {name}\n{desc}---\n")
                self.assertClean()

    def test_quoted_name_matches_directory(self):
        self.add_skill("gamma", fm="---\nname: 'gamma'\ndescription: x\n---\n")
        self.assertClean()

    def test_empty_frontmatter(self):
        self.add_skill("gamma", fm="---\n---\n")
        self.assertOne("gamma", "empty frontmatter")

    def test_unclosed_frontmatter(self):
        self.add_skill("gamma", fm="---\nname: gamma\ndescription: x\n")
        got = self.problems()
        self.assertIn("gamma: skills/gamma/SKILL.md has no closed", got[0])

    def test_missing_fields(self):
        for i, (body, key) in enumerate(
            (
                ("description: x\n", "name:"),
                ("name: {n}\n", "description:"),
                ("name: {n}\n  description: x\n", "description:"),
            )
        ):
            with self.subTest(key=key, body=body):
                n = f"m{i}"
                self.add_skill(n, fm="---\n" + body.format(n=n) + "---\n")
                self.assertOne(
                    f"{n}: skills/{n}/SKILL.md frontmatter has no top-level `{key}`"
                )
                # Repair it so the next case is checked on its own.
                (self.root / "skills" / n / "SKILL.md").write_text(front(n))
                self.write_wrapper(n, front(n))

    def test_name_mismatch(self):
        self.add_skill("gamma", fm=front("delta"))
        self.assertOne("gamma", "'delta' does not match the directory name")

    def test_canonical_skill_md_symlink(self):
        p = self.root / "skills/alpha/SKILL.md"
        p.rename(self.root / "skills/alpha/real.md")
        os.symlink("real.md", p)
        # One problem: its adapters are not also reported as orphans.
        self.assertOne("alpha", "skills/alpha/SKILL.md is a symlink")

    def test_canonical_dir_symlink(self):
        os.symlink("alpha", self.root / "skills/gamma")
        self.assertOne("gamma", "skills/gamma is a symlink")


class CodexAdapterTest(Fixture):
    def test_wrong_targets(self):
        for target in (
            "../../skills/beta",
            "../../skills/alpha/",
            str(self.root / "skills/alpha"),
            "../skills/alpha",
        ):
            with self.subTest(target=target):
                self.codex().unlink()
                os.symlink(target, self.codex())
                self.assertOne("alpha", "expected `../../skills/alpha`")

    def test_real_directory_instead_of_symlink(self):
        self.codex().unlink()
        self.codex().mkdir()
        self.assertOne("alpha", "is a directory, not a symlink")

    def test_printed_fix_repairs_the_tree(self):
        self.codex().unlink()
        os.symlink("../../skills/beta", self.codex())
        msg = self.assertOne("alpha")
        cmd = msg.split("run `", 1)[1].rsplit("`", 1)[0]
        subprocess.run(cmd, shell=True, cwd=self.root, check=True)
        self.assertClean()


class PathSafetyTest(Fixture):
    def make_outside(self):
        (self.outside / "external").mkdir(parents=True)
        (self.outside / "external/SKILL.md").write_text(front("external"))
        return self.outside

    def test_symlinked_skills_root_is_not_enumerated(self):
        out = self.make_outside()
        (self.root / "skills").rename(out / "skills")
        os.symlink(out / "skills", self.root / "skills")
        self.assertOne("skills: is a symlink")

    def test_looping_roots(self):
        for rel in ("skills", ".claude/skills", ".agents/skills", ".claude", ".agents"):
            with self.subTest(rel=rel):
                path = self.root / rel
                moved = self.root / f"moved-{rel.replace('/', '-')}"
                path.rename(moved)
                os.symlink(Path(rel).name, path)  # self-loop
                try:
                    self.assertOne(f"{rel}: is a symlink")
                finally:
                    path.unlink()
                    moved.rename(path)

    def test_adapter_root_linked_to_external_dir(self):
        out = self.make_outside()
        for rel in (".claude", ".agents/skills"):
            with self.subTest(rel=rel):
                path = self.root / rel
                moved = self.root / "moved"
                path.rename(moved)
                os.symlink(out, path)
                try:
                    msg = self.assertOne(f"{rel}: is a symlink")
                    self.assertNotIn("external", msg)
                finally:
                    path.unlink()
                    moved.rename(path)

    def test_other_adapter_set_still_checked_when_one_root_is_bad(self):
        (self.root / ".claude").rename(self.root / "moved")
        os.symlink("moved", self.root / ".claude")
        self.codex().unlink()
        got = self.problems()
        self.assertEqual(2, len(got), got)

    def test_unsupported_names_are_reported(self):
        for bad in ("two words", "-flag"):
            with self.subTest(bad=bad):
                (self.root / "skills" / bad).mkdir()
                try:
                    self.assertOne(repr(bad), "unsupported name")
                finally:
                    (self.root / "skills" / bad).rmdir()

    def test_surrogate_escaped_name_on_disk(self):
        # Previously aborted the scan with UnicodeEncodeError.
        bad = os.fsdecode(b"bad\xff")
        made = []
        for parent in ("skills", ".claude/skills", ".agents/skills"):
            try:
                (self.root / parent / bad).mkdir()
            except OSError as e:
                self.skipTest(f"filesystem rejects non-UTF-8 names ({e})")
            made.append(parent)
            (self.root / parent / bad / "SKILL.md").write_text(front("x"))
        got = self.problems()
        self.assertEqual(3, len(got), got)
        self.assertTrue(all("unsupported name" in p for p in got), got)
        self.assertTrue(all("'bad\\ufffd'" in p for p in got), got)

    def test_surrogate_escaped_name_from_listing(self):
        # Same as above for filesystems (APFS) that refuse such names.
        bad = os.fsdecode(b"bad\xff")
        real = os.listdir
        with mock.patch.object(adapters.os, "listdir", lambda p: real(p) + [bad]):
            got = self.problems()
        self.assertEqual(3, len(got), got)
        self.assertTrue(all("unsupported name" in p for p in got), got)

    def test_unexpected_os_error_is_reported_not_raised(self):
        real = open

        def fake(path, *a, **k):
            if "alpha" in os.fspath(path):
                raise PermissionError(13, "Permission denied", path)
            return real(path, *a, **k)

        with mock.patch.object(adapters, "open", fake, create=True):
            self.assertOne("alpha: could not be checked (PermissionError")


class MainTest(Fixture):
    def run_script(self):
        return subprocess.run(
            [sys.executable, SCRIPT, self.root], capture_output=True, text=True
        )

    def test_exit_status(self):
        r = self.run_script()
        self.assertEqual((0, ""), (r.returncode, r.stderr), r)
        self.assertIn("2 skills, adapters consistent", r.stdout)
        self.codex().unlink()
        r = self.run_script()
        self.assertEqual(1, r.returncode, r)
        self.assertIn("skill-adapters: alpha: missing Codex adapter", r.stderr)


class CurrentTreeTest(unittest.TestCase):
    def test_current_tree_passes(self):
        problems = []
        workflows = adapters.check_tree(os.fspath(REPO), problems)
        self.assertEqual([], problems)
        self.assertGreater(len(workflows), 0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and Path(sys.argv[1]).is_dir():
        REPO = Path(sys.argv.pop(1))
    unittest.main()
