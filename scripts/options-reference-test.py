#!/usr/bin/env python3
"""Tests for scripts/options-reference.py (#1026).

    options-reference-test.py [PATH/TO/options-reference.py]

Synthetic option lists only; no Nix evaluation, network or hosts.
"""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(
    sys.argv.pop(1)
    if len(sys.argv) > 1
    else Path(__file__).with_name("options-reference.py")
)
SPEC = importlib.util.spec_from_file_location("optref", SCRIPT)
assert SPEC and SPEC.loader
optref = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(optref)


def opt(name="myThing.enable", **kw):
    base = {
        "name": name,
        "type": "boolean",
        "description": "Turn the thing on.",
        "default": {"_type": "literalExpression", "text": "false"},
        "example": None,
        "declarations": ["modules/system/thing.nix"],
        "readOnly": False,
    }
    base.update(kw)
    return base


def doc(*options, forbidden=()):
    return {
        "fixture": "fixture-host",
        "groups": [
            {
                "title": "Things & stuff",
                "roots": ["myThing"],
                "intro": "Intro.",
                "options": list(options),
            }
        ],
        "forbidden": list(forbidden),
    }


def run(d):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(d, f)
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = optref.main(["options-reference.py", f.name])
    Path(f.name).unlink()
    return rc, out.getvalue(), err.getvalue()


class RenderTest(unittest.TestCase):
    def test_option_fields(self):
        rc, out, _ = run(doc(opt()))
        self.assertEqual(rc, 0)
        self.assertIn("### `myThing.enable`\n\nTurn the thing on.", out)
        self.assertIn("- **Type:** `boolean`", out)
        self.assertIn("- **Default:** `false`", out)
        self.assertIn(
            "[`modules/system/thing.nix`](../../modules/system/thing.nix)", out
        )
        self.assertIn("- [Things & stuff](#things--stuff): `myThing`", out)

    def test_description_change_changes_output(self):
        _, a, _ = run(doc(opt()))
        _, b, _ = run(doc(opt(description="Turn the thing off.")))
        self.assertNotEqual(a, b)
        self.assertIn("Turn the thing off.", b)

    def test_deterministic(self):
        self.assertEqual(run(doc(opt()))[1], run(doc(opt()))[1])

    def test_required_and_unrenderable_defaults(self):
        _, out, _ = run(
            doc(
                opt(default=None),
                opt("myThing.port", default={"_type": "unrenderable"}),
            )
        )
        self.assertIn("- **Default:** none (required)", out)
        self.assertIn("_computed from other options; see the declaration_", out)

    def test_placeholders_escaped_outside_code(self):
        _, out, _ = run(
            doc(opt(description="Defaults to <name>.<domain>, see `a <b>`."))
        )
        self.assertIn("Defaults to &lt;name&gt;.&lt;domain&gt;, see `a <b>`.", out)

    def test_roles_and_missing_description(self):
        _, out, _ = run(
            doc(
                opt(description="Like {option}`services.x.enable`."),
                opt("myThing.b", description=None),
            )
        )
        self.assertIn("Like `services.x.enable`.", out)
        self.assertIn("_No description._", out)

    def test_multiline_literal_is_fenced(self):
        _, out, _ = run(
            doc(opt(default={"_type": "literalExpression", "text": "{\n  a = 1;\n}"}))
        )
        self.assertIn("- **Default:**\n\n  ```nix\n  {\n    a = 1;\n  }\n  ```", out)

    def test_backticks_in_inline_literal(self):
        self.assertEqual(optref.code("a`b"), "``a`b``")
        self.assertEqual(optref.code("`x`"), "`` `x` ``")

    def test_forbidden_value_fails_without_printing_it(self):
        rc, out, err = run(
            doc(
                opt(
                    default={"_type": "literalExpression", "text": '"app.host.example"'}
                ),
                forbidden=["host.example"],
            )
        )
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("myThing.enable", err)
        self.assertNotIn("host.example", err)

    def test_store_path_fails(self):
        rc, _, err = run(doc(opt(declarations=["/nix/store/abc-source/modules/x.nix"])))
        self.assertEqual(rc, 1)
        self.assertIn("myThing.enable", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
