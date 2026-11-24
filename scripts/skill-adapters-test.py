#!/usr/bin/env python3
"""Disposable-fixture tests for scripts/skill-adapters.py (#1033).

    skill-adapters-test.py [REPO_ROOT]

Every case builds a throwaway tree under a temp dir; the real tree is only
read by `test_current_tree_passes`. No network, credentials or hosts.
"""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("adapters", HERE / "skill-adapters.py")
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
        self.root = Path(tmp.name)
        (self.root / "skills/_shared").mkdir(parents=True)
        (self.root / "skills/_shared/ref.md").write_text("shared\n")
        self.add_skill("alpha")
        self.add_skill("beta")

    def add_skill(self, name, claude=True, agents=True):
        d = self.root / "skills" / name
        d.mkdir(parents=True)
        (d / "SKILL.md").write_text(front(name) + "\n# Body\n")
        if claude:
            c = self.root / ".claude/skills" / name
            c.mkdir(parents=True)
            (c / "SKILL.md").write_text(
                front(name) + f"\n@../../../skills/{name}/SKILL.md\n"
            )
        if agents:
            a = self.root / ".agents/skills"
            a.mkdir(parents=True, exist_ok=True)
            os.symlink(f"../../skills/{name}", a / name)

    def problems(self):
        return adapters.check(self.root)

    def assertOne(self, *needles):
        got = self.problems()
        self.assertEqual(1, len(got), got)
        for n in needles:
            self.assertIn(n, got[0])


class AdapterTest(Fixture):
    def test_consistent_tree_passes_and_shared_is_ignored(self):
        self.assertEqual([], self.problems())

    def test_missing_claude_adapter(self):
        self.add_skill("gamma", claude=False)
        self.assertOne(
            "gamma", "missing Claude adapter", ".claude/skills/gamma/SKILL.md"
        )

    def test_missing_codex_adapter(self):
        self.add_skill("gamma", agents=False)
        self.assertOne("gamma", "missing Codex adapter", "ln -s ../../skills/gamma")

    def test_new_canonical_skill_without_either_entry(self):
        self.add_skill("gamma", claude=False, agents=False)
        got = self.problems()
        self.assertEqual(2, len(got), got)
        self.assertTrue(all(p.startswith("gamma:") for p in got))

    def test_wrong_symlink_target(self):
        link = self.root / ".agents/skills/alpha"
        link.unlink()
        os.symlink("../../skills/beta", link)
        self.assertOne("alpha", "points to `../../skills/beta`", "ln -sfn")

    def test_absolute_symlink_target_rejected(self):
        link = self.root / ".agents/skills/alpha"
        link.unlink()
        os.symlink(self.root / "skills/alpha", link)
        self.assertOne("alpha", "expected `../../skills/alpha`")

    def test_removing_canonical_skill_orphans_both_adapters(self):
        link = self.root / ".agents/skills/alpha"
        (self.root / "skills/alpha/SKILL.md").rename(self.root / "skills/alpha/X.md")
        self.assertTrue(link.is_symlink())
        # alpha is no longer a workflow, so its adapters are orphans
        got = self.problems()
        self.assertEqual(2, len(got), got)
        self.assertTrue(all("orphaned adapter" in p for p in got))

    def test_symlink_replaced_by_real_directory(self):
        link = self.root / ".agents/skills/alpha"
        link.unlink()
        link.mkdir()
        self.assertOne("alpha", "must be a directory symlink")

    def test_stale_description(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(
            front("alpha", "Old text.") + "\n@../../../skills/alpha/SKILL.md\n"
        )
        self.assertOne("alpha", "frontmatter is stale", "verbatim")

    def test_stale_name(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(
            front("alpha-old") + "\n@../../../skills/alpha/SKILL.md\n"
        )
        self.assertOne("alpha", "frontmatter is stale")

    def test_canonical_description_change_makes_adapter_stale(self):
        (self.root / "skills/alpha/SKILL.md").write_text(
            front("alpha", "New text.") + "\n# Body\n"
        )
        self.assertOne("alpha", "frontmatter is stale")

    def test_missing_frontmatter_in_adapter(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(
            "@../../../skills/alpha/SKILL.md\n"
        )
        self.assertOne("alpha", "no `---` frontmatter block")

    def test_wrong_forwarding_path(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(
            front("alpha") + "\n@../../skills/alpha/SKILL.md\n"
        )
        self.assertOne(
            "alpha", "exactly one import line", "@../../../skills/alpha/SKILL.md"
        )

    def test_forwarding_to_another_skill(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(
            front("alpha") + "\n@../../../skills/beta/SKILL.md\n"
        )
        self.assertOne("alpha", "exactly one import line")

    def test_missing_import(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(front("alpha"))
        self.assertOne("alpha", "found (nothing)")

    def test_copied_body_rejected(self):
        (self.root / ".claude/skills/alpha/SKILL.md").write_text(
            front("alpha") + "\n@../../../skills/alpha/SKILL.md\n\n# Body\n"
        )
        self.assertOne("alpha", "never copy the body")

    def test_orphaned_claude_adapter(self):
        d = self.root / ".claude/skills/ghost"
        d.mkdir()
        (d / "SKILL.md").write_text(front("ghost"))
        self.assertOne("ghost", "orphaned adapter", ".claude/skills/ghost")

    def test_orphaned_codex_adapter(self):
        os.symlink("../../skills/ghost", self.root / ".agents/skills/ghost")
        self.assertOne("ghost", "orphaned adapter", ".agents/skills/ghost")

    def test_shared_directory_needs_no_adapter_but_cannot_have_one(self):
        os.symlink("../../skills/_shared", self.root / ".agents/skills/_shared")
        self.assertOne("_shared", "orphaned adapter")

    def test_main_exit_codes(self):
        self.assertEqual(0, adapters.main(["x", str(self.root)]))
        (self.root / ".agents/skills/alpha").unlink()
        self.assertEqual(1, adapters.main(["x", str(self.root)]))
        self.assertEqual(2, adapters.main(["x", "a", "b"]))


class CurrentTreeTest(unittest.TestCase):
    def test_current_tree_passes(self):
        self.assertEqual([], adapters.check(REPO))
        self.assertGreater(len(adapters.canonical_skills(REPO)), 0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and Path(sys.argv[1]).is_dir():
        REPO = Path(sys.argv.pop(1))
    unittest.main()
