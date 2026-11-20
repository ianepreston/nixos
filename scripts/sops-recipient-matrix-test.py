#!/usr/bin/env python3
"""Regression cases for the sops recipient matrix's assertion logic."""

import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "matrix", Path(__file__).with_name("sops-recipient-matrix.py")
)
assert SPEC and SPEC.loader
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)

OPS = {"yk1": "age1op"}
ANCHORS = {"a": "age1a", "b": "age1b"}


def ident(key, hosts, source="live"):
    return {"key": key, "hosts": hosts, "source": source}


class MatrixTest(unittest.TestCase):
    def run_eval(self, files, consumers, identities=None, anchors=ANCHORS):
        identities = identities or {
            "a": ident("age1a", ["a"]),
            "b": ident("age1b", ["b"]),
        }
        return matrix.evaluate(files, consumers, identities, OPS, anchors)[1]

    def test_exact_match_passes(self):
        files = {"x.yaml": {"age1op", "age1a"}, "y.yaml": {"age1op", "age1b"}}
        self.assertEqual([], self.run_eval(files, {"a": {"x.yaml"}, "b": {"y.yaml"}}))

    def test_a_host_missing_from_a_file_it_reads_fails(self):
        files = {"x.yaml": {"age1op"}}
        problems = self.run_eval(files, {"a": {"x.yaml"}, "b": set()})
        self.assertEqual(["a cannot decrypt x.yaml"], problems)

    def test_a_host_on_a_file_it_does_not_read_fails(self):
        files = {"x.yaml": {"age1op", "age1a", "age1b"}}
        problems = self.run_eval(files, {"a": {"x.yaml"}, "b": set()})
        self.assertEqual(["b over-granted x.yaml"], problems)

    def test_shared_yaml_over_grant_is_excepted_until_retired(self):
        files = {"shared.yaml": {"age1op", "age1a", "age1b"}}
        self.assertEqual([], self.run_eval(files, {"a": set(), "b": set()}))

    def test_reading_a_file_that_does_not_exist_fails(self):
        problems = self.run_eval({}, {"a": {"gone.yaml"}, "b": set()})
        self.assertEqual(["a reads gone.yaml, which does not exist"], problems)

    def test_missing_operator_fails(self):
        problems = self.run_eval({"x.yaml": {"age1a"}}, {"a": {"x.yaml"}, "b": set()})
        self.assertEqual(["operator yk1 is not a recipient of x.yaml"], problems)

    def test_unknown_recipient_fails(self):
        files = {"x.yaml": {"age1op", "age1a", "age1zzzzzzzzzzzzzzzz"}}
        problems = self.run_eval(files, {"a": {"x.yaml"}, "b": set()})
        self.assertEqual(1, len(problems))
        self.assertIn("matches no host or operator", problems[0])

    def test_live_key_differing_from_its_anchor_fails(self):
        files = {"x.yaml": {"age1op", "age1new"}}
        identities = {"a": ident("age1new", ["a"])}
        problems = matrix.evaluate(
            files, {"a": {"x.yaml"}}, identities, OPS, {"a": "age1a"}
        )[1]
        self.assertEqual(
            ["a: .sops.yaml anchor differs from the live host key"], problems
        )

    def test_vm_hosts_sharing_a_key_need_the_union_of_their_files(self):
        files = {"x.yaml": {"age1op", "age1vm"}, "y.yaml": {"age1op", "age1vm"}}
        identities = {
            "tests-vm": ident("age1vm", ["tests-desktop", "tests-server"], "vm-key")
        }
        consumers = {"tests-desktop": {"x.yaml"}, "tests-server": {"y.yaml"}}
        problems = matrix.evaluate(
            files, consumers, identities, OPS, {"tests-vm": "age1vm"}
        )[1]
        self.assertEqual([], problems)

    def test_parse_anchors_splits_users_from_hosts(self):
        text = "keys:\n  users:\n    - &yk1 age1op\n  hosts:\n    - &a age1a\ncreation_rules:\n  - x\n"
        self.assertEqual(
            ({"yk1": "age1op"}, {"a": "age1a"}), matrix.parse_anchors(text)
        )


if __name__ == "__main__":
    unittest.main()
