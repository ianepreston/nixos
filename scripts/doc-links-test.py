#!/usr/bin/env python3
"""Disposable-fixture tests for scripts/doc-links.py (#1026).

    doc-links-test.py

Every case writes a throwaway tree (not a Git checkout, so the filesystem walk
is used). No network, credentials or hosts.
"""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(
    sys.argv.pop(1) if len(sys.argv) > 1 else Path(__file__).with_name("doc-links.py")
)
SPEC = importlib.util.spec_from_file_location("doclinks", SCRIPT)
assert SPEC and SPEC.loader
doclinks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(doclinks)


class LinkTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def problems(self):
        return doclinks.check(self.root)

    def test_resolving_links_pass(self):
        self.write(
            "docs/a.md",
            "# A\n\n## Restore runbook (catastrophic rebuild)\n\n## Dup\n\n## Dup\n",
        )
        self.write("modules/x.nix", "{ }\n")
        self.write(
            "README.md",
            "[a](docs/a.md) [r](docs/a.md#restore-runbook-catastrophic-rebuild) "
            "[d](docs/a.md#dup-1) [m](modules/x.nix) [dir](docs/) [ext](https://example.com/x#y) "
            "[self](#top) ![img](docs/a.md)\n\n# Top\n\n[ref]: docs/a.md\n",
        )
        self.assertEqual(self.problems(), [])

    def test_missing_file(self):
        self.write("README.md", "see [gone](docs/gone.md)\n")
        self.assertEqual(self.problems(), ["README.md:1: docs/gone.md: no such file"])

    def test_missing_anchor(self):
        self.write("docs/a.md", "# A\n")
        self.write("docs/b.md", "[x](a.md#moved-section)\n")
        self.assertEqual(
            self.problems(),
            [
                "docs/b.md:1: a.md#moved-section: no heading `#moved-section` in docs/a.md"
            ],
        )

    def test_heading_markup_and_html_anchor(self):
        self.write(
            "a.md",
            '# The `myCaddy.apps` [option](https://x.example)\n\n<a name="custom"></a>\n',
        )
        self.write("b.md", "[1](a.md#the-mycaddyapps-option) [2](a.md#custom)\n")
        self.assertEqual(self.problems(), [])

    def test_code_is_ignored(self):
        self.write(
            "a.md",
            "`[x](nope.md)`\n\n```md\n[y](nope.md)\n# Not a heading\n```\n\n[z](#not-a-heading)\n",
        )
        self.assertEqual(
            self.problems(),
            ["a.md:8: #not-a-heading: no heading `#not-a-heading` in a.md"],
        )

    def test_outside_repository(self):
        self.write("a.md", "[x](../../etc/passwd)\n")
        self.assertEqual(
            self.problems(), ["a.md:1: ../../etc/passwd: points outside the repository"]
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
