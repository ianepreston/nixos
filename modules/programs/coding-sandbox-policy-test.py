#!/usr/bin/env python3
"""Small dependency-free regression suite for coding-sandbox-policy.py."""

from __future__ import annotations

import importlib.util
import ipaddress
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


POLICY_PATH = Path(sys.argv.pop(1)).resolve()
SANDBOX_PATH = Path(sys.argv.pop(1)).resolve()
SPEC = importlib.util.spec_from_file_location("coding_sandbox_policy", POLICY_PATH)
assert SPEC and SPEC.loader
POLICY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = POLICY
SPEC.loader.exec_module(POLICY)


class PolicyTest(unittest.TestCase):
    def config(self, text: str) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / ".sandbox.toml").write_text(text)
        return root

    def test_defaults_to_public_without_grants(self) -> None:
        root = self.config("")
        policy = POLICY.render_policy(root, None)
        self.assertEqual(policy["mode"], "public")
        self.assertEqual(policy["grants_v4"], [])
        self.assertEqual(policy["grants_v6"], [])
        self.assertIn("100.64.0.0/10", policy["protected_v4"])
        self.assertIn("fe80::/10", policy["protected_v6"])

    def test_visible_spec_can_deliberately_have_no_host_mounts(self) -> None:
        root = self.config('version = 1\n\n[network]\nmode = "public"\n')
        policy = POLICY.render_policy(root, None)
        self.assertEqual(policy["mounts"], [])
        self.assertEqual(policy["config_path"], str(root / ".sandbox.toml"))

    def test_exact_internal_domain_becomes_literal_grant(self) -> None:
        root = self.config('[network]\ninternal_domains = ["dev.example.internal"]\n')
        original_resolve = POLICY.resolve
        self.addCleanup(setattr, POLICY, "resolve", original_resolve)
        POLICY.resolve = lambda domain: [ipaddress.ip_address("100.64.12.34")]
        policy = POLICY.render_policy(root, None)
        self.assertEqual(policy["internal_domains"], [{"name": "dev.example.internal", "addresses": ["100.64.12.34"]}])
        self.assertEqual(policy["grants_v4"], ["100.64.12.34"])

    def test_rejects_broad_or_public_grants_and_wildcards(self) -> None:
        for text in (
            '[network]\ninternal_cidrs = ["8.8.8.0/24"]\n',
            '[network]\ninternal_domains = ["*.example.internal"]\n',
            '[network]\nunknown = ["no"]\n',
        ):
            with self.subTest(text=text), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(self.config(text), None)

    def test_restricted_public_domains_are_mode_gated(self) -> None:
        root = self.config('[network]\npublic_domains = ["registry.npmjs.org"]\n')
        with self.assertRaises(POLICY.PolicyError):
            POLICY.render_policy(root, None)

        original_resolve = POLICY.resolve
        self.addCleanup(setattr, POLICY, "resolve", original_resolve)
        POLICY.resolve = lambda domain: [ipaddress.ip_address("203.0.113.10")]
        policy = POLICY.render_policy(root, "restricted")
        self.assertIn("registry.npmjs.org", [entry["name"] for entry in policy["strict_domains"]])

    def test_non_git_mount_defaults_read_only_and_resolves_from_spec(self) -> None:
        root = self.config("")
        source = root / "shared"
        source.mkdir()
        (root / ".sandbox.toml").write_text(
            '[[mounts]]\n'
            'path = "shared"\n'
            'mount_point = "/workspace"\n'
        )
        mount = POLICY.render_policy(root, None)["mounts"][0]
        self.assertEqual(mount["source"], str(source.resolve()))
        self.assertEqual(mount["kind"], "path")
        self.assertEqual(mount["access"], "ro")
        self.assertIsNone(mount["branch"])

    def test_git_mount_requires_branch_and_defaults_read_write(self) -> None:
        root = self.config("")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "tracked").write_text("x")
        subprocess.run(["git", "-C", str(root), "add", "tracked"], check=True)
        subprocess.run(
            [
                "git", "-C", str(root), "-c", "core.hooksPath=/dev/null", "-c", "user.name=test",
                "-c", "user.email=test@example.invalid", "commit", "-qm", "initial",
            ],
            check=True,
        )

        (root / ".sandbox.toml").write_text(
            '[[mounts]]\n'
            'path = "."\n'
            'mount_point = "/workspace"\n'
            'branch = "sandbox/test"\n'
        )
        mount = POLICY.render_policy(root, None)["mounts"][0]
        self.assertEqual(mount["kind"], "git")
        self.assertEqual(mount["access"], "rw")
        self.assertEqual(mount["branch"], "sandbox/test")

        (root / ".sandbox.toml").write_text(
            '[[mounts]]\npath = "."\nmount_point = "/workspace"\n'
        )
        with self.assertRaises(POLICY.PolicyError):
            POLICY.render_policy(root, None)

    def test_mounts_reject_unsafe_shape(self) -> None:
        root = self.config("")
        source = root / "shared"
        source.mkdir()
        for text in (
            '[[mounts]]\npath = "shared"\nmount_point = "workspace"\n',
            '[[mounts]]\npath = "shared"\nmount_point = "/workspace"\nbranch = "main"\n',
            '[[mounts]]\npath = "shared"\nmount_point = "/workspace"\naccess = "write"\n',
            '[[mounts]]\npath = "shared"\nmount_point = "/sandbox-spec/data"\n',
        ):
            with self.subTest(text=text):
                (root / ".sandbox.toml").write_text(text)
                with self.assertRaises(POLICY.PolicyError):
                    POLICY.render_policy(root, None)

    def test_profile_files_must_be_under_mounts_and_are_digested(self) -> None:
        root = self.config("")
        source = root / "sandbox"
        source.mkdir()
        module = source / "profile.nix"
        startup = source / "bootstrap.sh"
        module.write_text("{ pkgs, ... }: { home.packages = [ pkgs.hello ]; }\n")
        startup.write_text("#!/usr/bin/env bash\nprintf ready\\n\n")
        (root / ".sandbox.toml").write_text(
            '[[mounts]]\npath = "sandbox"\nmount_point = "/sandbox"\n\n'
            '[profile]\nmodules = ["sandbox/profile.nix"]\n\n'
            '[[startup]]\nname = "bootstrap"\npath = "sandbox/bootstrap.sh"\nargs = ["--quiet"]\n'
        )

        policy = POLICY.render_policy(root, None)
        self.assertEqual(policy["profile"]["modules"][0]["guest_path"], "/sandbox/profile.nix")
        self.assertEqual(policy["startup"][0]["guest_path"], "/sandbox/bootstrap.sh")
        self.assertEqual(policy["startup"][0]["args"], ["--quiet"])
        self.assertTrue(policy["profile"]["digest"].startswith("sha256:"))
        original_digest = policy["profile"]["digest"]
        startup.write_text("#!/usr/bin/env bash\nprintf changed\\n\n")
        self.assertNotEqual(POLICY.render_policy(root, None)["profile"]["digest"], original_digest)

        (root / ".sandbox.toml").write_text('[profile]\nmodules = ["sandbox/profile.nix"]\n')
        with self.assertRaises(POLICY.PolicyError):
            POLICY.render_policy(root, None)

    def test_profile_and_startup_schema_rejects_unsafe_entries(self) -> None:
        root = self.config("")
        source = root / "sandbox"
        source.mkdir()
        (source / "profile.nix").write_text("{ ... }: { }\n")
        (source / "bootstrap.sh").write_text("true\n")
        mount = '[[mounts]]\npath = "sandbox"\nmount_point = "/sandbox"\n\n'
        for text in (
            mount + '[profile]\nunknown = []\n',
            mount + '[profile]\nmodules = "sandbox/profile.nix"\n',
            mount + '[[startup]]\nname = "bad name"\npath = "sandbox/bootstrap.sh"\n',
            mount
            + '[[startup]]\nname = "same"\npath = "sandbox/bootstrap.sh"\n\n'
            + '[[startup]]\nname = "same"\npath = "sandbox/bootstrap.sh"\n',
            mount + '[[startup]]\nname = "bootstrap"\npath = "sandbox/bootstrap.sh"\nargs = [1]\n',
        ):
            with self.subTest(text=text):
                (root / ".sandbox.toml").write_text(text)
                with self.assertRaises(POLICY.PolicyError):
                    POLICY.render_policy(root, None)

    def test_template_composes_and_verifies_selected_profile_sources(self) -> None:
        root = self.config("")
        source = root / "sandbox"
        source.mkdir()
        (source / "profile.nix").write_text("{ pkgs, ... }: { home.packages = [ pkgs.hello ]; }\n")
        (source / "bootstrap.sh").write_text("#!/usr/bin/env bash\nprintf ready\\n")
        (root / ".sandbox.toml").write_text(
            '[[mounts]]\npath = "sandbox"\nmount_point = "/sandbox"\n\n'
            '[profile]\nmodules = ["sandbox/profile.nix"]\n\n'
            '[[startup]]\nname = "bootstrap"\npath = "sandbox/bootstrap.sh"\nargs = ["--quiet"]\n'
        )
        environment = {
            **os.environ,
            "HOME": str(root),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
        }
        template = subprocess.run(
            ["bash", str(SANDBOX_PATH), "template", str(root)],
            check=True,
            capture_output=True,
            env=environment,
            text=True,
        ).stdout
        plan = subprocess.run(
            ["bash", str(SANDBOX_PATH), "plan", str(root)],
            check=True,
            capture_output=True,
            env=environment,
            text=True,
        ).stdout
        self.assertIn('(builtins.toPath "/sandbox/profile.nix")', template)
        self.assertIn('verify_source "$startup_path" "$startup_digest"', template)
        self.assertIn('startup-$startup_name.log', template)
        self.assertIn('switch --impure --flake', template)
        self.assertIn('PATH="$agent_profile_path"', template)
        self.assertIn("Selected profile: sha256:", plan)
        self.assertIn("startup: bootstrap: /sandbox/bootstrap.sh", plan)


if __name__ == "__main__":
    unittest.main()
