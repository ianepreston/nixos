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
        self.assertOne("gamma", "missing Codex adapter", "ln -sfn ../../skills/gamma")

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
        self.assertOne("alpha", "frontmatter is stale", "byte for byte")

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


class MalformedMetadataTest(Fixture):
    def both(self, name, text):
        for rel in (f"skills/{name}/SKILL.md", f".claude/skills/{name}/SKILL.md"):
            (self.root / rel).write_bytes(text)

    def wrapper(self, name, data):
        (self.root / f".claude/skills/{name}/SKILL.md").write_bytes(data)

    def test_matching_empty_frontmatter_fails(self):
        self.both("alpha", b"---\n---\n\n@../../../skills/alpha/SKILL.md\n")
        got = self.problems()
        self.assertTrue(any("no `name` field" in p for p in got), got)

    def test_missing_description_fails(self):
        self.both(
            "alpha", b"---\nname: alpha\n---\n\n@../../../skills/alpha/SKILL.md\n"
        )
        self.assertTrue(any("no `description` field" in p for p in self.problems()))

    def test_empty_value_fails(self):
        self.both("alpha", b"---\nname: alpha\ndescription:\n---\n")
        self.assertTrue(any("`description` is empty" in p for p in self.problems()))

    def test_unclosed_quote_in_matching_files_fails(self):
        text = b'---\nname: alpha\ndescription: "never closed\n---\n'
        self.both("alpha", text)
        got = self.problems()
        self.assertTrue(any("unclosed quote" in p for p in got), got)

    def test_closed_quotes_pass(self):
        fm = '---\nname: alpha\ndescription: "it\'s \\"ok\\""\n---\n'
        self.both("alpha", (fm + "\n@../../../skills/alpha/SKILL.md\n").encode())
        self.assertEqual([], self.problems())

    def test_block_scalar_with_content_passes(self):
        fm = "---\nname: alpha\ndescription: >\n  folded text\n---\n"
        self.both("alpha", (fm + "\n@../../../skills/alpha/SKILL.md\n").encode())
        self.assertEqual([], self.problems())

    def test_non_utf8_canonical_is_reported_and_scan_continues(self):
        (self.root / "skills/alpha/SKILL.md").write_bytes(
            b"---\nname: alpha\ndescription: bad \xff byte\n---\n"
        )
        (self.root / ".agents/skills/beta").unlink()
        got = self.problems()
        self.assertTrue(any("alpha" in p and "not valid UTF-8" in p for p in got), got)
        self.assertTrue(
            any("beta" in p and "missing Codex adapter" in p for p in got), got
        )

    def test_non_utf8_wrapper_is_reported_and_scan_continues(self):
        self.wrapper("alpha", b"---\nname: alpha\ndescription: bad \xff\n---\n\n@x\n")
        (self.root / ".agents/skills/beta").unlink()
        got = self.problems()
        self.assertTrue(
            any(".claude/skills/alpha" in p and "UTF-8" in p for p in got), got
        )
        self.assertTrue(any("beta" in p for p in got), got)

    def test_crlf_wrapper_against_lf_canonical_fails(self):
        self.wrapper(
            "alpha",
            b"---\r\nname: alpha\r\ndescription: Does a thing.\r\n---\r\n"
            b"\r\n@../../../skills/alpha/SKILL.md\r\n",
        )
        self.assertOne("alpha", "line endings differ")

    def test_trailing_space_on_wrapper_delimiters_is_a_byte_difference(self):
        self.wrapper(
            "alpha",
            b"---  \nname: alpha\ndescription: Does a thing.\n---  \n"
            b"\n@../../../skills/alpha/SKILL.md\n",
        )
        self.assertOne("alpha", "trailing whitespace differs")

    def test_identical_delimiters_with_trailing_spaces_are_recognised(self):
        fm = b"---  \nname: alpha\ndescription: Does a thing.\n---\t\n"
        self.both("alpha", fm + b"\n@../../../skills/alpha/SKILL.md\n")
        self.assertEqual([], self.problems())

    def test_trailing_whitespace_after_import_is_tolerated(self):
        self.wrapper(
            "alpha",
            front("alpha").encode() + b"\n@../../../skills/alpha/SKILL.md  \t\n",
        )
        self.assertEqual([], self.problems())

    def test_leading_whitespace_before_import_is_rejected(self):
        self.wrapper(
            "alpha", front("alpha").encode() + b"\n @../../../skills/alpha/SKILL.md\n"
        )
        self.assertOne("alpha", "exactly one import line")


class SymlinkSafetyTest(Fixture):
    def outside(self, text):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        f = d / "SKILL.md"
        f.write_text(text)
        return f

    def test_external_canonical_skill_md_is_rejected(self):
        f = self.outside(front("alpha") + "\n# Body\n")
        p = self.root / "skills/alpha/SKILL.md"
        p.unlink()
        os.symlink(f, p)
        got = self.problems()
        self.assertTrue(
            any("skills/alpha/SKILL.md is a symlink" in x for x in got), got
        )

    def test_external_claude_wrapper_is_rejected(self):
        f = self.outside(front("alpha") + "\n@../../../skills/alpha/SKILL.md\n")
        p = self.root / ".claude/skills/alpha/SKILL.md"
        p.unlink()
        os.symlink(f, p)
        self.assertOne("alpha", ".claude/skills/alpha/SKILL.md is a symlink")

    def test_symlinked_claude_wrapper_directory_is_rejected(self):
        # alpha's wrapper directory is beta's: the import resolves to beta.
        import shutil

        shutil.rmtree(self.root / ".claude/skills/alpha")
        os.symlink("beta", self.root / ".claude/skills/alpha")
        got = self.problems()
        self.assertTrue(
            any(x.startswith("alpha:") and "is a symlink" in x for x in got), got
        )

    def test_symlinked_codex_directory_to_other_workflow_is_rejected(self):
        # .agents/skills is itself a symlink onto a copy that points elsewhere.
        import shutil

        shutil.rmtree(self.root / ".agents/skills")
        (self.root / ".agents").mkdir(exist_ok=True)
        os.symlink("../.claude/skills", self.root / ".agents/skills")
        got = self.problems()
        self.assertTrue(
            any("is a symlink; it must be a real directory" in x for x in got), got
        )

    def test_codex_link_to_other_workflow_is_rejected(self):
        link = self.root / ".agents/skills/alpha"
        link.unlink()
        os.symlink("../../skills/beta", link)
        self.assertOne("alpha", "points to `../../skills/beta`")

    def test_self_loop_under_skills_is_not_zero_workflows(self):
        os.symlink("loop", self.root / "skills/loop")
        got = self.problems()
        self.assertTrue(any("skills/loop is a symlink" in x for x in got), got)

    def test_self_loop_codex_adapter_fails(self):
        link = self.root / ".agents/skills/alpha"
        link.unlink()
        os.symlink("alpha", link)
        self.assertOne("alpha", "points to `alpha`")

    def test_symlinked_canonical_directory_is_rejected(self):
        import shutil

        shutil.rmtree(self.root / "skills/alpha")
        os.symlink("beta", self.root / "skills/alpha")
        got = self.problems()
        self.assertTrue(any("skills/alpha is a symlink" in x for x in got), got)

    def test_symlink_problem_gives_main_exit_1(self):
        os.symlink("loop", self.root / "skills/loop")
        self.assertEqual(1, adapters.main(["x", str(self.root)]))


class BrokenLinkOfLiveWorkflowTest(Fixture):
    def test_dangling_codex_link_for_existing_workflow(self):
        link = self.root / ".agents/skills/alpha"
        link.unlink()
        os.symlink("../../skills/does-not-exist", link)
        self.assertOne("alpha", "points to `../../skills/does-not-exist`", "ln -sfn")
        self.assertTrue((self.root / "skills/alpha/SKILL.md").is_file())

    def test_correct_target_but_canonical_skill_md_gone_is_not_a_live_workflow(self):
        (self.root / "skills/alpha/SKILL.md").unlink()
        got = self.problems()
        self.assertTrue(all("orphaned adapter" in x for x in got), got)


class OddNameTest(Fixture):
    NAME = "two words [draft]"

    def test_odd_name_passes_when_consistent(self):
        self.add_skill(self.NAME)
        self.assertEqual([], self.problems())

    def test_repair_command_is_shell_quoted(self):
        import shlex

        self.add_skill(self.NAME, agents=False)
        (msg,) = self.problems()
        cmd = msg.split("run `", 1)[1].rsplit("`", 1)[0]
        self.assertEqual(
            [
                "ln",
                "-sfn",
                f"../../skills/{self.NAME}",
                f".agents/skills/{self.NAME}",
            ],
            shlex.split(cmd),
        )

    def test_repair_command_for_wrong_target_is_quoted(self):
        import shlex

        self.add_skill(self.NAME)
        link = self.root / ".agents/skills" / self.NAME
        link.unlink()
        os.symlink("../../skills/alpha", link)
        (msg,) = self.problems()
        cmd = msg.split("run `", 1)[1].rsplit("`", 1)[0]
        self.assertEqual(f".agents/skills/{self.NAME}", shlex.split(cmd)[-1])


class CurrentTreeTest(unittest.TestCase):
    def test_current_tree_passes(self):
        self.assertEqual([], adapters.check(REPO))
        self.assertGreater(len(adapters.canonical_skills(REPO)), 0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and Path(sys.argv[1]).is_dir():
        REPO = Path(sys.argv.pop(1))
    unittest.main()
