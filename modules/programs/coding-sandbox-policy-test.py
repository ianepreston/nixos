#!/usr/bin/env python3
"""Small dependency-free regression suite for coding-sandbox-policy.py."""

from __future__ import annotations

import base64
import importlib.util
import ipaddress
import json
import os
import re
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

# What coding-sandbox.nix exports for each host platform.
VZ_BACKEND = {
    "SANDBOX_VM_TYPE": "vz",
    "SANDBOX_VM_ARCH": "aarch64",
    "SANDBOX_VM_MOUNT_TYPE": "virtiofs",
    "SANDBOX_VM_DESCRIPTION": "Apple Virtualization (VZ)",
}
QEMU_BACKEND = {
    "SANDBOX_VM_TYPE": "qemu",
    "SANDBOX_VM_ARCH": "x86_64",
    "SANDBOX_VM_MOUNT_TYPE": "9p",
    "SANDBOX_VM_DESCRIPTION": "QEMU/KVM",
}


def bundle_catalog(uv_digest: str = "a", uv_path: str = "uv-0.13.7") -> dict:
    """The shape coding-sandbox.nix renders into SANDBOX_BUNDLE_CATALOG."""
    return {
        "pins": {
            "nixpkgs": {"rev": "b349185bb79c7cf7ad8e", "narHash": "sha256-x"},
            "nixpkgs-unstable": {"rev": "d5cc6833999746cffdfe", "narHash": "sha256-y"},
            "home-manager": {"rev": "6eb2d33d1d0c95a37ef6", "narHash": "sha256-z"},
        },
        "bundles": {
            "uv": {
                "description": "uv Python tool manager",
                "commands": ["uv", "uvx"],
                "digest": f"sha256:{uv_digest}",
                "packages": [
                    {"name": "uv", "version": "0.13.7", "path": f"/nix/store/{uv_path}"}
                ],
            },
            "agent-pi": {
                "description": "Pi coding-agent client only",
                "commands": ["pi"],
                "digest": "sha256:b",
                "packages": [
                    {
                        "name": "pi-coding-agent",
                        "version": "1.5.2",
                        "path": "/nix/store/pi-coding-agent-1.5.2",
                    }
                ],
            },
        },
    }


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
        self.assertEqual(policy["callbacks"]["port_ranges"], [])
        self.assertEqual(policy["environment"], {})
        self.assertEqual(policy["storage"]["nix_store"], "instance")
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
        self.assertEqual(
            policy["internal_domains"],
            [{"name": "dev.example.internal", "addresses": ["100.64.12.34"]}],
        )
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
        self.assertIn(
            "registry.npmjs.org", [entry["name"] for entry in policy["strict_domains"]]
        )

    def test_nix_store_lifecycle_is_explicit_and_strict(self) -> None:
        root = self.config('[storage]\nnix_store = "persistent"\n')
        self.assertEqual(
            POLICY.render_policy(root, None)["storage"]["nix_store"], "persistent"
        )
        for text in (
            '[storage]\nnix_store = "shared"\n',
            "[storage]\nunknown = true\n",
            'storage = "persistent"\n',
        ):
            with self.subTest(text=text), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(self.config(text), None)

    def test_callback_ranges_are_strict_and_normalized(self) -> None:
        root = self.config("[callbacks]\nport_ranges = [[8080, 8080], [8020, 8040]]\n")
        self.assertEqual(
            POLICY.render_policy(root, None)["callbacks"]["port_ranges"],
            [[8020, 8040], [8080, 8080]],
        )

        for text in (
            "[callbacks]\nport_ranges = true\n",
            "[callbacks]\nport_ranges = [[8020]]\n",
            "[callbacks]\nport_ranges = [[true, 8040]]\n",
            '[callbacks]\nport_ranges = [["8020", 8040]]\n',
            "[callbacks]\nport_ranges = [[1023, 8040]]\n",
            "[callbacks]\nport_ranges = [[8040, 8020]]\n",
            "[callbacks]\nport_ranges = [[8020, 8040], [8040, 8050]]\n",
            "[callbacks]\nport_ranges = [[8020, 8040], [8020, 8040]]\n",
            "[callbacks]\nunknown = []\n",
        ):
            with self.subTest(text=text), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(self.config(text), None)

    def test_environment_is_literal_and_validated(self) -> None:
        policy = POLICY.render_policy(
            self.config(
                "[environment]\n"
                'UV_INDEX_URL = "https://pypi-proxy.cloud.databricks.com/simple"\n'
                'BROWSER = "none"\n'
            ),
            None,
        )
        self.assertEqual(
            policy["environment"],
            {
                "BROWSER": "none",
                "UV_INDEX_URL": "https://pypi-proxy.cloud.databricks.com/simple",
            },
        )
        for text in (
            'environment = "no"\n',
            '[environment]\nBAD-NAME = "no"\n',
            "[environment]\nVALUE = true\n",
        ):
            with self.subTest(text=text), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(self.config(text), None)

    def test_non_git_mount_defaults_read_only_and_resolves_from_spec(self) -> None:
        root = self.config("")
        source = root / "shared"
        source.mkdir()
        (root / ".sandbox.toml").write_text(
            '[[mounts]]\npath = "shared"\nmount_point = "/workspace"\n'
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
                "git",
                "-C",
                str(root),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "initial",
            ],
            check=True,
        )

        (root / ".sandbox.toml").write_text(
            "[[mounts]]\n"
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
        self.assertEqual(
            policy["profile"]["modules"][0]["guest_path"], "/sandbox/profile.nix"
        )
        self.assertEqual(policy["startup"][0]["guest_path"], "/sandbox/bootstrap.sh")
        self.assertEqual(policy["startup"][0]["args"], ["--quiet"])
        self.assertTrue(policy["profile"]["digest"].startswith("sha256:"))
        original_digest = policy["profile"]["digest"]
        startup.write_text("#!/usr/bin/env bash\nprintf changed\\n\n")
        self.assertNotEqual(
            POLICY.render_policy(root, None)["profile"]["digest"], original_digest
        )

        (root / ".sandbox.toml").write_text(
            '[profile]\nmodules = ["sandbox/profile.nix"]\n'
        )
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
            mount + "[profile]\nunknown = []\n",
            mount + '[profile]\nmodules = "sandbox/profile.nix"\n',
            mount + '[[startup]]\nname = "bad name"\npath = "sandbox/bootstrap.sh"\n',
            mount
            + '[[startup]]\nname = "same"\npath = "sandbox/bootstrap.sh"\n\n'
            + '[[startup]]\nname = "same"\npath = "sandbox/bootstrap.sh"\n',
            mount
            + '[[startup]]\nname = "bootstrap"\npath = "sandbox/bootstrap.sh"\nargs = [1]\n',
        ):
            with self.subTest(text=text):
                (root / ".sandbox.toml").write_text(text)
                with self.assertRaises(POLICY.PolicyError):
                    POLICY.render_policy(root, None)

    def test_bundles_resolve_only_from_the_platform_catalog(self) -> None:
        catalog = bundle_catalog()
        root = self.config('[profile]\nbundles = ["agent-pi", "uv"]\n')
        policy = POLICY.render_policy(root, None, catalog)
        self.assertEqual(
            [bundle["name"] for bundle in policy["profile"]["bundles"]],
            ["agent-pi", "uv"],
        )
        self.assertEqual(policy["profile"]["bundles"][1]["commands"], ["uv", "uvx"])
        self.assertEqual(policy["guest_pins"], catalog["pins"])

        for value in (
            '"unknown"',
            '"uv", "uv"',
            '"./bundles/uv.nix"',
            '"/nix/store/uv-0.13.7"',
            '"https://example.com/uv.nix"',
            '"pkgs.uv"',
            '"github:astral-sh/uv"',
            "1",
        ):
            with self.subTest(value=value), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(
                    self.config(f"[profile]\nbundles = [{value}]\n"), None, catalog
                )
        with self.assertRaises(POLICY.PolicyError):
            POLICY.render_policy(
                self.config('[profile]\nbundles = "uv"\n'), None, catalog
            )
        # Without a catalog (an older launcher), no name is accepted.
        with self.assertRaises(POLICY.PolicyError):
            POLICY.render_policy(root, None)

    def test_restricted_mode_requires_declared_bundle_fetch_domains(self) -> None:
        catalog = bundle_catalog()
        catalog["bundles"]["uv"]["fetch_domains"] = ["proxy.golang.org"]
        original_resolve = POLICY.resolve
        self.addCleanup(setattr, POLICY, "resolve", original_resolve)
        POLICY.resolve = lambda domain: [ipaddress.ip_address("203.0.113.10")]

        root = self.config('[profile]\nbundles = ["uv"]\n')
        POLICY.render_policy(root, None, catalog)  # public: nothing to declare
        with self.assertRaisesRegex(POLICY.PolicyError, "proxy.golang.org"):
            POLICY.render_policy(root, "restricted", catalog)

        root = self.config(
            '[network]\npublic_domains = ["proxy.golang.org"]\n\n'
            '[profile]\nbundles = ["uv"]\n'
        )
        policy = POLICY.render_policy(root, "restricted", catalog)
        self.assertIn(
            "proxy.golang.org", [entry["name"] for entry in policy["strict_domains"]]
        )

    def test_bundle_source_digest_is_policy_but_store_paths_are_not(self) -> None:
        root = self.config('[profile]\nbundles = ["uv"]\n')
        digest = POLICY.render_policy(root, None, bundle_catalog())["profile"]["digest"]
        self.assertEqual(
            POLICY.render_policy(root, None, bundle_catalog(uv_path="uv-0.14.0"))[
                "profile"
            ]["digest"],
            digest,
        )
        self.assertNotEqual(
            POLICY.render_policy(root, None, bundle_catalog(uv_digest="changed"))[
                "profile"
            ]["digest"],
            digest,
        )

    def test_no_bundle_profiles_keep_their_recorded_shape(self) -> None:
        root = self.config('[network]\nmode = "public"\n')
        without = POLICY.render_policy(root, None)
        with_catalog = POLICY.render_policy(root, None, bundle_catalog())
        self.assertNotIn("bundles", with_catalog["profile"])
        self.assertEqual(with_catalog["profile"], without["profile"])
        self.assertEqual(
            {key: value for key, value in with_catalog.items() if key != "guest_pins"},
            without,
        )

    def test_existing_vm_rejects_changed_bundle_source_only(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        project = base / "project"
        project.mkdir()
        (project / ".sandbox.toml").write_text('[profile]\nbundles = ["uv"]\n')
        catalog = base / "catalog.json"
        environment = {
            **os.environ,
            "HOME": str(base),
            "XDG_STATE_HOME": str(base / "state"),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            "SANDBOX_BUNDLE_CATALOG": str(catalog),
            **QEMU_BACKEND,
        }

        def run(step: str) -> subprocess.CompletedProcess[str]:
            harness = (
                f"source <(sed '$d' \"{SANDBOX_PATH}\")\n"
                f'parse_target "{project}"\n{step}\n'
            )
            return subprocess.run(
                ["bash", "-c", harness],
                capture_output=True,
                env=environment,
                text=True,
            )

        catalog.write_text(json.dumps(bundle_catalog()))
        recorded = run("record_policy")
        self.assertEqual(recorded.returncode, 0, recorded.stderr)

        # A flake.lock bump moves pins and store paths: the VM keeps its own.
        moved = bundle_catalog(uv_path="uv-0.14.0")
        moved["pins"]["nixpkgs"]["rev"] = "0123456789abcdef0123"
        catalog.write_text(json.dumps(moved))
        result = run(
            'policy_matches_instance; jq -r ".profile.bundles[0].packages[0].path" <<<"$policy_json"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/nix/store/uv-0.13.7")

        # A changed bundle definition is a policy change.
        catalog.write_text(json.dumps(bundle_catalog(uv_digest="changed")))
        result = run("policy_matches_instance")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("effective policy changed", result.stderr)

    def test_start_fails_when_guest_provisioning_did_not_finish(self) -> None:
        root = self.config("")
        environment = {
            **os.environ,
            "HOME": str(root),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            **QEMU_BACKEND,
        }

        def check(guest_state: str) -> subprocess.CompletedProcess[str]:
            # limactl stand-in: answers the readiness probe, `sudo cat` and
            # `sudo tail` from the named guest state.
            harness = (
                f"source <(sed '$d' \"{SANDBOX_PATH}\")\n"
                f'parse_target "{root}"\n'
                "limactl() {\n"
                f"  [[ {guest_state!r} != unreachable ]] || return 255\n"
                "  shift 4; shift  # shell --workdir DIR INSTANCE sudo\n"
                '  case "$1 $2" in\n'
                f'    "sh -c") [[ {guest_state!r} == ready ]] && echo ready || echo pending ;;\n'
                f'    "cat "*) [[ {guest_state!r} == startup ]] && echo bootstrap || return 1 ;;\n'
                '    "tail -n") echo "log tail for ${@: -1}" ;;\n'
                "  esac\n"
                "}\n"
                "check_provisioned\n"
            )
            return subprocess.run(
                ["bash", "-c", harness], capture_output=True, env=environment, text=True
            )

        self.assertEqual(check("ready").returncode, 0)
        failed = check("activation")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("activation did not complete", failed.stderr)
        self.assertIn("home-manager.log", failed.stderr)
        self.assertIn("did not finish provisioning", failed.stderr)
        failed = check("startup")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("startup entry bootstrap failed", failed.stderr)
        self.assertIn("startup-bootstrap.log", failed.stderr)
        # A transport failure is not reported as a broken guest.
        failed = check("unreachable")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("cannot inspect", failed.stderr)
        self.assertNotIn("destroy and recreate", failed.stderr)

    def test_template_composes_and_verifies_selected_profile_sources(self) -> None:
        root = self.config("")
        source = root / "sandbox"
        source.mkdir()
        (source / "profile.nix").write_text(
            "{ pkgs, ... }: { home.packages = [ pkgs.hello ]; }\n"
        )
        (source / "bootstrap.sh").write_text("#!/usr/bin/env bash\nprintf ready\\n")
        (root / ".sandbox.toml").write_text(
            '[[mounts]]\npath = "sandbox"\nmount_point = "/sandbox"\n\n'
            '[environment]\nUV_INDEX_URL = "https://pypi-proxy.cloud.databricks.com/simple"\n\n'
            '[storage]\nnix_store = "persistent"\n\n'
            '[profile]\nmodules = ["sandbox/profile.nix"]\n\n'
            '[[startup]]\nname = "bootstrap"\npath = "sandbox/bootstrap.sh"\nargs = ["--quiet"]\n'
        )
        environment = {
            **os.environ,
            "HOME": str(root),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            **VZ_BACKEND,
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
        self.assertIn("startup-$startup_name.log", template)
        self.assertIn("switch --impure --flake", template)
        self.assertIn('PATH="$agent_profile_path"', template)
        self.assertIn("additionalDisks:", template)
        self.assertIn("format: true", template)
        self.assertIn("persistent_nix_root=/mnt/lima-s", template)
        self.assertIn('mount --bind "$persistent_nix_root/store" /nix/store', template)
        self.assertIn(
            "apt-get install -y ca-certificates curl git jq nftables unzip", template
        )
        # Tools come only from pinned bundles: no latest-at-boot installer.
        self.assertNotIn("databricks/setup-cli", template)
        self.assertNotIn("astral.sh/uv/install.sh", template)
        self.assertNotIn("github:nix-community/home-manager", template)
        self.assertIn('nix run "$profile#home-manager" -- switch', template)
        self.assertIn("sandbox-bundles.json", template)
        self.assertIn(
            "export UV_INDEX_URL='https://pypi-proxy.cloud.databricks.com/simple'",
            template,
        )
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', template)
        self.assertLess(
            template.index("ct state established,related accept"),
            template.index("ip daddr @protected_v4 drop"),
        )
        self.assertIn("Selected profile: sha256:", plan)
        self.assertIn("bundles: none", plan)
        self.assertIn("Guest pins:   not recorded", plan)
        self.assertIn("startup: bootstrap: /sandbox/bootstrap.sh", plan)
        self.assertIn("Nix store:    persistent Lima disk", plan)
        self.assertIn(
            'UV_INDEX_URL="https://pypi-proxy.cloud.databricks.com/simple"', plan
        )

    def test_plan_and_template_show_and_verify_selected_bundles(self) -> None:
        root = self.config('[profile]\nbundles = ["uv", "agent-pi"]\n')
        catalog = root / "catalog.json"
        catalog.write_text(json.dumps(bundle_catalog()))
        environment = {
            **os.environ,
            "HOME": str(root),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            "SANDBOX_BUNDLE_CATALOG": str(catalog),
            **QEMU_BACKEND,
        }

        def launcher(command: str) -> str:
            return subprocess.run(
                ["bash", str(SANDBOX_PATH), command, str(root)],
                check=True,
                capture_output=True,
                env=environment,
                text=True,
            ).stdout

        plan = launcher("plan")
        self.assertIn(
            "Guest pins:   home-manager 6eb2d33d1d0c, nixpkgs b349185bb79c,"
            " nixpkgs-unstable d5cc68339997",
            plan,
        )
        self.assertIn("    bundle: uv [sha256:a]\n", plan)
        self.assertIn("      commands: uv, uvx\n", plan)
        self.assertIn("      uv 0.13.7 /nix/store/uv-0.13.7\n", plan)
        self.assertIn(
            "      pi-coding-agent 1.5.2 /nix/store/pi-coding-agent-1.5.2\n", plan
        )
        self.assertLess(plan.index("bundle: uv"), plan.index("bundle: agent-pi"))

        template = launcher("template")
        self.assertIn('"/nix/store/uv-0.13.7"', template)
        self.assertIn("bundle store path missing from the agent profile", template)
        self.assertIn(".local/state/nix/profiles/home-manager", template)

        # A NixOS (qemu) host seeds the selected bundles from its own store
        # through a read-only mount, imported before the profile switch.
        self.assertIn(
            "  Guest packages: bundles pre-seeded from this host's store", plan
        )
        self.assertIn("-> /mnt/sandbox-seed [ro]", plan)
        seed_dir = str(root / ".local/state/coding-sandbox")
        self.assertRegex(
            template,
            rf'- location: "{re.escape(seed_dir)}/coding-sandbox-[^"]+\.seed"\n'
            r"  mountPoint: /mnt/sandbox-seed\n  writable: false\n",
        )
        self.assertLess(
            template.index("cp -a /mnt/sandbox-seed/."),
            template.index('nix run "$profile#home-manager"'),
        )

        # A macOS (VZ) host cannot build Linux paths: no seed is rendered.
        environment.update(VZ_BACKEND)
        vz_plan = launcher("plan")
        vz_template = launcher("template")
        self.assertIn(
            "  Guest packages: bundles substituted or built in the guest", vz_plan
        )
        self.assertNotIn("sandbox-seed", vz_plan + vz_template)

    def test_template_allows_only_declared_loopback_callback_ranges(self) -> None:
        root = self.config("")
        environment = {
            **os.environ,
            "HOME": str(root),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            **VZ_BACKEND,
        }

        template_without_callbacks = subprocess.run(
            ["bash", str(SANDBOX_PATH), "template", str(root)],
            check=True,
            capture_output=True,
            env=environment,
            text=True,
        ).stdout
        self.assertIn("guestPortRange: [1, 65535]", template_without_callbacks)
        self.assertIn("proto: any\n  ignore: true", template_without_callbacks)
        self.assertNotIn('hostIP: "127.0.0.1"', template_without_callbacks)

        (root / ".sandbox.toml").write_text(
            "[callbacks]\nport_ranges = [[8080, 8080], [8020, 8040]]\n"
        )
        template_with_callbacks = subprocess.run(
            ["bash", str(SANDBOX_PATH), "template", str(root)],
            check=True,
            capture_output=True,
            env=environment,
            text=True,
        ).stdout
        deny_index = template_with_callbacks.index("guestPortRange: [1, 65535]")
        first_callback_index = template_with_callbacks.index(
            "guestPortRange: [8020, 8040]"
        )
        second_callback_index = template_with_callbacks.index(
            "guestPortRange: [8080, 8080]"
        )
        self.assertLess(first_callback_index, second_callback_index)
        self.assertLess(second_callback_index, deny_index)
        self.assertEqual(template_with_callbacks.count('hostIP: "127.0.0.1"'), 2)
        self.assertIn(
            "guestPortRange: [8020, 8040]\n"
            '  hostIP: "127.0.0.1"\n'
            "  hostPortRange: [8020, 8040]\n"
            "  proto: tcp",
            template_with_callbacks,
        )
        self.assertIn(
            "Browser callbacks: dynamic TCP forwarding on host loopback only",
            subprocess.run(
                ["bash", str(SANDBOX_PATH), "plan", str(root)],
                check=True,
                capture_output=True,
                env=environment,
                text=True,
            ).stdout,
        )

    def test_template_follows_the_build_time_vm_backend(self) -> None:
        root = self.config("")
        rendered = {}
        for backend in (VZ_BACKEND, QEMU_BACKEND):
            environment = {
                **os.environ,
                "HOME": str(root),
                "XDG_STATE_HOME": str(root / "state"),
                "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
                "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
                **backend,
            }
            rendered[backend["SANDBOX_VM_TYPE"]] = tuple(
                subprocess.run(
                    ["bash", str(SANDBOX_PATH), command, str(root)],
                    check=True,
                    capture_output=True,
                    env=environment,
                    text=True,
                ).stdout
                for command in ("template", "plan")
            )

        vz_template, vz_plan = rendered["vz"]
        qemu_template, qemu_plan = rendered["qemu"]
        self.assertIn("vmType: vz\narch: aarch64\nmountType: virtiofs\n", vz_template)
        self.assertIn("rosetta:", vz_template)
        self.assertIn("Ubuntu aarch64 under Apple Virtualization (VZ)", vz_plan)
        self.assertIn("vmType: qemu\narch: x86_64\nmountType: 9p\n", qemu_template)
        self.assertNotIn("rosetta", qemu_template)
        self.assertNotIn("vmOpts:", qemu_template)
        self.assertIn("Ubuntu x86_64 under QEMU/KVM", qemu_plan)
        # 9p checks access against the host uid, so the agent takes it and the
        # privileged transport account moves aside; VZ keeps Lima's defaults.
        self.assertIn("  uid: 64000\n", qemu_template)
        self.assertIn(f"--shell /bin/bash --uid {os.getuid()} agent", qemu_template)
        self.assertNotIn("uid: 64000", vz_template)
        self.assertIn("--shell /bin/bash  agent", vz_template)
        self.assertNotIn("agent_uid_flag", vz_template + qemu_template)
        # Open mode renders its own provision script; it must map the uid too.
        qemu_open = subprocess.run(
            ["bash", str(SANDBOX_PATH), "template", "--network", "open", str(root)],
            check=True,
            capture_output=True,
            env=environment,
            text=True,
        ).stdout
        self.assertIn(f"--shell /bin/bash --uid {os.getuid()} agent", qemu_open)
        self.assertIn("fec0::/10 (site-local)", qemu_plan)
        for template in (vz_template, qemu_template):
            # DNS goes only to the resolver(s) discovered on the default-route
            # link, never to the gateway by assumption.
            self.assertIn("ip daddr { $resolver_set } udp dport 53 accept", template)
            self.assertIn("ip daddr { $resolver_set } tcp dport 53 accept", template)
            self.assertNotIn("ip daddr $gateway", template)
            # QEMU's site-local fec0::2 gateway reaches the host's loopback.
            self.assertIn("elements = { fc00::/7, fec0::/10, fe80::/10 }", template)

    def test_failed_worktree_creation_stops_the_launcher(self) -> None:
        # Two network modes of one project are separate instances wanting the
        # same branch; Git refuses the second worktree. That failure happens
        # inside a command substitution and must stop the launcher rather
        # than render an empty directory as the /workspace mount.
        root = self.config("")
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        subprocess.run([*git, "init", "-q", str(root)], check=True)
        subprocess.run(
            [*git, "-C", str(root), "commit", "-q", "--allow-empty", "-m", "init"],
            check=True,
        )
        (root / ".sandbox.toml").write_text(
            '[[mounts]]\npath = "."\nbranch = "sandbox/shared"\nmount_point = "/workspace"\n'
        )
        environment = {
            **os.environ,
            "HOME": str(root),
            "XDG_STATE_HOME": str(root / "state"),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            **QEMU_BACKEND,
        }

        def template(mode: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                ["bash", str(SANDBOX_PATH), "template", "--network", mode, str(root)],
                capture_output=True,
                env=environment,
                text=True,
            )

        first = template("public")
        self.assertEqual(first.returncode, 0, first.stderr)
        second = template("open")
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("sandbox/shared", second.stderr)
        self.assertNotIn("mountPoint: /workspace", second.stdout)

    def test_github_grant_is_strict_normalized_and_optional(self) -> None:
        self.assertNotIn("github", POLICY.render_policy(self.config(""), None))
        root = self.config(
            '[github]\nrepository = "ianepreston/nixos"\n\n'
            '[github.permissions]\npull_requests = "write"\ncontents = "read"\n'
        )
        self.assertEqual(
            POLICY.render_policy(root, None)["github"],
            {
                "repository": "ianepreston/nixos",
                "permissions": {"contents": "read", "pull_requests": "write"},
            },
        )
        for text in (
            'github = "ianepreston/nixos"\n',
            '[github]\nrepository = "ianepreston/nixos"\n',
            '[github]\nrepository = "ianepreston/nixos"\npermissions = {}\n',
            '[github]\nrepository = "ianepreston"\npermissions = { contents = "read" }\n',
            '[github]\nrepository = "a/b/c"\npermissions = { contents = "read" }\n',
            '[github]\nrepository = "-bad/repo"\npermissions = { contents = "read" }\n',
            '[github]\nrepository = "'
            + "-".join("abcdefghijklmnopqrstu")
            + '/r"\npermissions = { contents = "read" }\n',
            '[github]\nrepository = "owner/.."\npermissions = { contents = "read" }\n',
            '[github]\nrepository = "o/r"\npermissions = { issues = "write" }\n',
            '[github]\nrepository = "o/r"\npermissions = { administration = "read" }\n',
            '[github]\nrepository = "o/r"\npermissions = { contents = "admin" }\n',
            '[github]\nrepository = "o/r"\ntoken = "x"\npermissions = { contents = "read" }\n',
        ):
            with self.subTest(text=text), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(self.config(text), None)

    def test_github_grant_reserves_credential_environment_names(self) -> None:
        grant = '[github]\nrepository = "o/r"\npermissions = { contents = "read" }\n'
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GIT_CONFIG_COUNT"):
            with self.subTest(name=name), self.assertRaises(POLICY.PolicyError):
                POLICY.render_policy(
                    self.config(f'{grant}\n[environment]\n{name} = "x"\n'), None
                )
        # Without a grant the names stay ordinary literal environment.
        self.assertEqual(
            POLICY.render_policy(
                self.config('[environment]\nGH_HOST = "github.com"\n'), None
            )["environment"],
            {"GH_HOST": "github.com"},
        )

    def test_github_session_token_reaches_only_the_new_agent_process(self) -> None:
        sentinel = "ghs_SENTINELtoken0123456789"
        installation = "918273645"
        bash = subprocess.run(
            ["sh", "-c", "command -v bash"], capture_output=True, text=True, check=True
        ).stdout.strip()

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        bin_dir, logs, shm, agent_home, project = (
            base / "bin",
            base / "logs",
            base / "shm",
            base / "agent",
            base / "project",
        )
        for directory in (bin_dir, logs, shm, agent_home, project):
            directory.mkdir()
        (agent_home / ".config/coding-sandbox").mkdir(parents=True)
        (agent_home / ".config/coding-sandbox/environment.sh").write_text("")
        key, app_id = base / "app.pem", base / "app-id"
        subprocess.run(
            ["openssl", "genrsa", "-out", str(key), "2048"],
            check=True,
            capture_output=True,
        )
        app_id.write_text("123456\n")

        # limactl stand-in: runs the guest command locally with /dev/shm and
        # /home/agent mapped into the test directory, and logs every argv.
        (bin_dir / "limactl").write_text(
            f"""#!{bash}
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_LOGS/argv"
case "$1" in
  list) printf '%s\\n' "$FAKE_INSTANCE" ;;
  shell)
    shift 3
    while [[ "$1" != -- ]]; do shift; done
    shift
    args=()
    for arg in "$@"; do
      case "$arg" in
        /dev/shm) arg=$FAKE_SHM ;;
        /dev/shm/*) arg="$FAKE_SHM/${{arg#/dev/shm/}}" ;;
        /home/agent) arg=$FAKE_AGENT_HOME ;;
      esac
      args+=("$arg")
    done
    HOME=$FAKE_AGENT_HOME "${{args[@]}}" | sed "s#$FAKE_SHM#/dev/shm#g"
    exit "${{PIPESTATUS[0]}}"
    ;;
  *) exit 1 ;;
esac
"""
        )
        # curl stand-in: answers from its stdin config, and logs argv/config.
        (bin_dir / "curl").write_text(
            f"""#!{bash}
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_LOGS/argv"
config=$(cat)
printf '%s\\n' "$config" >>"$FAKE_LOGS/curl-config"
case "$config" in
  *'/repos/ianepreston/nixos/installation"'*) printf '{{"id":{installation}}}' ;;
  *'/app/installations/{installation}/access_tokens"'*) cat "$FAKE_TOKEN_RESPONSE" ;;
  *) printf '{{"message":"Not Found"}}'; exit 22 ;;
esac
"""
        )
        for tool in ("limactl", "curl"):
            (bin_dir / tool).chmod(0o755)

        (project / ".sandbox.toml").write_text(
            '[github]\nrepository = "ianepreston/nixos"\n\n'
            '[github.permissions]\ncontents = "write"\npull_requests = "write"\n'
        )

        def token_response(permissions: dict[str, str]) -> Path:
            path = base / "token.json"
            path.write_text(
                json.dumps(
                    {
                        "token": sentinel,
                        "expires_at": "2026-11-16T13:00:00Z",
                        "permissions": {"metadata": "read", **permissions},
                        "repositories": [{"full_name": "ianepreston/nixos"}],
                    }
                )
            )
            return path

        environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "HOME": str(base),
            "XDG_STATE_HOME": str(base / "state"),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            "SANDBOX_GITHUB_APP_ID_FILE": str(app_id),
            "SANDBOX_GITHUB_APP_KEY_FILE": str(key),
            "FAKE_LOGS": str(logs),
            "FAKE_SHM": str(shm),
            "FAKE_AGENT_HOME": str(agent_home),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "false",
            "SSH_ASKPASS": "false",
            **QEMU_BACKEND,
        }
        # Run the real launcher functions with only the host-platform probe
        # stubbed, recording the policy as `sandbox start` would.
        harness = (
            f"source <(sed '$d' \"{SANDBOX_PATH}\")\n"
            "host_platform_check() { :; }\n"
            'parse_target "$2"; export FAKE_INSTANCE="$instance"; record_policy\n'
            'main "$@"\n'
        )
        guest_command = [
            "bash",
            "-c",
            'printf "token=%s\\n" "${GH_TOKEN-unset}"; '
            'printf "protocol=https\\nhost=github.com\\n\\n" | git credential fill; '
            "exit 7",
        ]

        def launch(*arguments: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [bash, "-c", harness, "sandbox-test", *arguments],
                capture_output=True,
                env=environment,
                text=True,
            )

        environment["FAKE_TOKEN_RESPONSE"] = str(
            token_response({"contents": "write", "pull_requests": "write"})
        )
        result = launch("exec", str(project), "--", *guest_command)
        self.assertEqual(result.returncode, 7, result.stderr + result.stdout)
        self.assertIn(f"token={sentinel}\n", result.stdout)
        self.assertIn(f"password={sentinel}\n", result.stdout)
        self.assertIn("username=x-access-token\n", result.stdout)
        self.assertEqual(list(shm.iterdir()), [], "staged credential was not removed")

        # The App JWT is RS256-signed by the host key, for this App, and
        # short-lived; it travelled only inside curl's stdin config.
        config = (logs / "curl-config").read_text()
        jwt = re.search(r"Authorization: Bearer ([^\"]+)", config).group(1)
        header, payload, signature = jwt.split(".")
        claims = json.loads(base64.urlsafe_b64decode(payload + "=="))
        self.assertEqual(claims["iss"], 123456)
        self.assertLessEqual(claims["exp"] - claims["iat"], 600)
        public_key, signed, signature_file = (
            base / "app.pub",
            base / "signed",
            base / "sig",
        )
        subprocess.run(
            ["openssl", "rsa", "-in", str(key), "-pubout", "-out", str(public_key)],
            check=True,
            capture_output=True,
        )
        signed.write_text(f"{header}.{payload}")
        signature_file.write_bytes(base64.urlsafe_b64decode(signature + "=="))
        subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(public_key),
                "-signature",
                str(signature_file),
                str(signed),
            ],
            check=True,
            capture_output=True,
        )
        self.assertIn(
            '"repositories":["nixos"]', config.replace('\\"', '"').replace(" ", "")
        )

        # No secret in any process argument, the policy record, or output.
        argv = (logs / "argv").read_text()
        for secret in (sentinel, jwt, installation):
            self.assertNotIn(secret, argv)
            self.assertNotIn(secret, result.stderr)
        for record in (base / "state/coding-sandbox").iterdir():
            self.assertNotIn(sentinel, record.read_text())
        for subcommand in ("plan", "template"):
            output = subprocess.run(
                ["bash", str(SANDBOX_PATH), subcommand, str(project)],
                capture_output=True,
                env=environment,
                text=True,
                check=True,
            ).stdout
            self.assertNotIn(sentinel, output)
            self.assertNotIn(str(key), output)
        plan = subprocess.run(
            ["bash", str(SANDBOX_PATH), "plan", str(project)],
            capture_output=True,
            env=environment,
            text=True,
            check=True,
        ).stdout
        self.assertIn("repository: ianepreston/nixos", plan)
        self.assertIn("permissions: contents:write, pull_requests:write", plan)
        self.assertIn("expiry: one hour; guest renewal unavailable", plan)
        self.assertNotIn("NOT READY", plan)

        # A token broader than the reviewed grant is refused before any
        # guest session starts.
        (logs / "argv").write_text("")
        environment["FAKE_TOKEN_RESPONSE"] = str(
            token_response(
                {"contents": "write", "pull_requests": "write", "issues": "write"}
            )
        )
        refused = launch("exec", str(project), "--", "true")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("does not match the declared grant", refused.stderr)
        self.assertNotIn("sandbox-agent-exec", (logs / "argv").read_text())

        # A credential-free sandbox never contacts GitHub or stages anything.
        (logs / "argv").write_text("")
        (logs / "curl-config").unlink()
        (project / ".sandbox.toml").write_text("")
        free = launch("exec", str(project), "--", *guest_command)
        self.assertEqual(free.returncode, 7, free.stderr)
        self.assertIn("token=unset\n", free.stdout)
        argv = (logs / "argv").read_text()
        self.assertFalse((logs / "curl-config").exists())
        self.assertNotIn("sandbox-session-stage", argv)

        # Without provisioned App credentials, a grant fails closed.
        (project / ".sandbox.toml").write_text(
            '[github]\nrepository = "ianepreston/nixos"\n'
            'permissions = { contents = "read" }\n'
        )
        del environment["SANDBOX_GITHUB_APP_KEY_FILE"]
        missing = launch("exec", str(project), "--", "true")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("does not provision GitHub App credentials", missing.stderr)

    def secret_catalog(self, file: str | None = None) -> dict:
        """The shape coding-sandbox.nix renders into SANDBOX_SECRET_CATALOG."""
        return {
            "llm": {
                "description": "llama.cpp API key",
                "env": "LLAMA_API_KEY",
                "domains": ["llm.example.internal", "llm-two.example.internal"],
                "file": file,
            },
            "other": {
                "description": "another service",
                "env": "OTHER_API_KEY",
                "domains": [],
                "file": None,
            },
        }

    def test_secret_grants_resolve_only_from_the_host_catalog(self) -> None:
        catalog = self.secret_catalog()
        original_resolve = POLICY.resolve
        self.addCleanup(setattr, POLICY, "resolve", original_resolve)
        POLICY.resolve = lambda domain: [ipaddress.ip_address("100.64.12.34")]

        root = self.config(
            '[secrets]\ngrants = ["llm"]\n\n'
            '[network]\ninternal_domains = ["llm.example.internal"]\n'
        )
        self.assertNotIn(
            "coverage", POLICY.render_policy(root, None, None, catalog)["secrets"][0]
        )
        policy = POLICY.render_policy(root, None, None, catalog, coverage=True)
        (secret,) = policy["secrets"]
        self.assertEqual(secret["name"], "llm")
        self.assertEqual(secret["env"], "LLAMA_API_KEY")
        self.assertNotIn("file", secret)
        self.assertEqual(
            secret["coverage"],
            {
                "llm.example.internal": "granted",
                "llm-two.example.internal": "NOT GRANTED",
            },
        )
        # A CIDR covering every resolved address also counts; open mode
        # reaches everything.
        root = self.config(
            '[secrets]\ngrants = ["llm"]\n\n[network]\ninternal_cidrs = ["100.64.12.0/24"]\n'
        )
        coverage = POLICY.render_policy(root, None, None, catalog, coverage=True)[
            "secrets"
        ][0]["coverage"]
        self.assertEqual(set(coverage.values()), {"granted by internal_cidrs"})
        coverage = POLICY.render_policy(root, "open", None, catalog, coverage=True)[
            "secrets"
        ][0]["coverage"]
        self.assertEqual(set(coverage.values()), {"open network"})

        # A domain that resolves publicly is reachable in public mode, and
        # in restricted mode through public_domains.
        POLICY.resolve = lambda domain: [ipaddress.ip_address("203.0.113.10")]
        public_catalog = self.secret_catalog()
        public_catalog["llm"]["domains"] = ["api.example.com"]
        root = self.config('[secrets]\ngrants = ["llm"]\n')
        self.assertEqual(
            POLICY.render_policy(root, None, None, public_catalog, coverage=True)[
                "secrets"
            ][0]["coverage"],
            {"api.example.com": "public internet"},
        )
        root = self.config(
            '[secrets]\ngrants = ["llm"]\n\n'
            '[network]\npublic_domains = ["api.example.com"]\n'
        )
        self.assertEqual(
            POLICY.render_policy(
                root, "restricted", None, public_catalog, coverage=True
            )["secrets"][0]["coverage"],
            {"api.example.com": "granted by public_domains"},
        )

        # Absent or empty means undeclared: the recorded shape is unchanged.
        for text in ("", "[secrets]\n", "[secrets]\ngrants = []\n"):
            with self.subTest(text=text):
                policy = POLICY.render_policy(self.config(text), None, None, catalog)
                self.assertNotIn("secrets", policy)

        for text, message in (
            ('[secrets]\ngrants = ["missing"]\n', "not a session secret"),
            ('[secrets]\ngrants = ["llm", "llm"]\n', "duplicates"),
            ("[secrets]\ngrants = [1]\n", "secret name string"),
            ('[secrets]\ngrants = ["/run/secret"]\n', "not a session secret"),
            ('[secrets]\ngrants = "llm"\n', "array of secret names"),
            ('[secrets]\nsource = "x"\n', "unknown secrets key"),
            (
                '[secrets]\ngrants = ["llm"]\n\n[environment]\nLLAMA_API_KEY = "x"\n',
                "environment must not set LLAMA_API_KEY",
            ),
        ):
            with (
                self.subTest(text=text),
                self.assertRaisesRegex(POLICY.PolicyError, message),
            ):
                POLICY.render_policy(self.config(text), None, None, catalog)

        # A catalog entry can never claim the GitHub credential, and two
        # grants can never set the same variable.
        for name, env, message in (
            ("llm", "GH_TOKEN", "may not set GH_TOKEN"),
            ("llm", "GIT_CONFIG_COUNT", "may not set GIT_CONFIG_COUNT"),
            ("other", "LLAMA_API_KEY", "both set LLAMA_API_KEY"),
        ):
            bad = self.secret_catalog()
            bad[name]["env"] = env
            with (
                self.subTest(env=env),
                self.assertRaisesRegex(POLICY.PolicyError, message),
            ):
                POLICY.render_policy(
                    self.config('[secrets]\ngrants = ["llm", "other"]\n'),
                    None,
                    None,
                    bad,
                )

    def test_session_secrets_reach_only_the_new_agent_process(self) -> None:
        sentinel = "sk-SENTINELsecret0123456789"
        bash = subprocess.run(
            ["sh", "-c", "command -v bash"], capture_output=True, text=True, check=True
        ).stdout.strip()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        bin_dir, logs, shm, agent_home, project = (
            base / "bin",
            base / "logs",
            base / "shm",
            base / "agent",
            base / "project",
        )
        for directory in (bin_dir, logs, shm, agent_home, project):
            directory.mkdir()
        (agent_home / ".config/coding-sandbox").mkdir(parents=True)
        (agent_home / ".config/coding-sandbox/environment.sh").write_text("")
        secret_file = base / "llm-secret"
        secret_file.write_text(sentinel)
        catalog = base / "secrets.json"
        catalog.write_text(json.dumps(self.secret_catalog(str(secret_file))))

        # The same limactl stand-in as the GitHub test: the guest command
        # runs locally with /dev/shm and /home/agent mapped into the test
        # directory, and every argv is logged.
        (bin_dir / "limactl").write_text(
            f"""#!{bash}
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_LOGS/argv"
case "$1" in
  list) printf '%s\\n' "${{FAKE_INSTANCE-}}" ;;
  shell)
    shift 3
    while [[ "$1" != -- ]]; do shift; done
    shift
    args=()
    for arg in "$@"; do
      case "$arg" in
        /dev/shm) arg=$FAKE_SHM ;;
        /dev/shm/*) arg="$FAKE_SHM/${{arg#/dev/shm/}}" ;;
        /home/agent) arg=$FAKE_AGENT_HOME ;;
      esac
      args+=("$arg")
    done
    HOME=$FAKE_AGENT_HOME "${{args[@]}}" | sed "s#$FAKE_SHM#/dev/shm#g"
    exit "${{PIPESTATUS[0]}}"
    ;;
  *) exit 1 ;;
esac
"""
        )
        (bin_dir / "limactl").chmod(0o755)
        (project / ".sandbox.toml").write_text('[secrets]\ngrants = ["llm"]\n')
        environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "HOME": str(base),
            "XDG_STATE_HOME": str(base / "state"),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            "SANDBOX_SECRET_CATALOG": str(catalog),
            "FAKE_LOGS": str(logs),
            "FAKE_SHM": str(shm),
            "FAKE_AGENT_HOME": str(agent_home),
            **QEMU_BACKEND,
        }
        harness = (
            f"source <(sed '$d' \"{SANDBOX_PATH}\")\n"
            "host_platform_check() { :; }\n"
            'parse_target "$2"; export FAKE_INSTANCE="$instance"; record_policy\n'
            'main "$@"\n'
        )
        guest_command = [
            "bash",
            "-c",
            'printf "key=%s\\n" "${LLAMA_API_KEY-unset}"; '
            'printf "gh=%s\\n" "${GH_TOKEN-unset}"; '
            'printf "helper=%s\\n" "${GIT_CONFIG_COUNT-unset}"; exit 7',
        ]

        def launch(*arguments: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [bash, "-c", harness, "sandbox-test", *arguments],
                capture_output=True,
                env=environment,
                text=True,
            )

        result = launch("exec", str(project), "--", *guest_command)
        self.assertEqual(result.returncode, 7, result.stderr + result.stdout)
        self.assertIn(f"key={sentinel}\n", result.stdout)
        # No GitHub grant: no token and no credential helper.
        self.assertIn("gh=unset\n", result.stdout)
        self.assertIn("helper=unset\n", result.stdout)
        self.assertIn("session secrets: llm (LLAMA_API_KEY)", result.stderr)
        self.assertEqual(list(shm.iterdir()), [], "staged secret was not removed")

        # Never in an argument, the policy record, or output.
        self.assertNotIn(sentinel, (logs / "argv").read_text())
        self.assertNotIn(sentinel, result.stderr)
        for record in (base / "state/coding-sandbox").iterdir():
            self.assertNotIn(sentinel, record.read_text())
            self.assertNotIn(str(secret_file), record.read_text())
        plan = subprocess.run(
            ["bash", str(SANDBOX_PATH), "plan", str(project)],
            capture_output=True,
            env=environment,
            text=True,
            check=True,
        ).stdout
        self.assertNotIn(sentinel, plan)
        self.assertIn("llm: LLAMA_API_KEY - llama.cpp API key", plan)
        self.assertIn("llm.example.internal (NOT GRANTED", plan)
        self.assertNotIn("NOT READY", plan)

        # A secret this host does not provision fails closed before any
        # guest session or staging.
        (logs / "argv").write_text("")
        catalog.write_text(json.dumps(self.secret_catalog(None)))
        missing = launch("exec", str(project), "--", "true")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn(
            "session secret llm: this host does not provision it", missing.stderr
        )
        argv = (logs / "argv").read_text()
        self.assertNotIn("sandbox-session-stage", argv)
        self.assertNotIn("sandbox-agent-exec", argv)
        plan = subprocess.run(
            ["bash", str(SANDBOX_PATH), "plan", str(project)],
            capture_output=True,
            env=environment,
            text=True,
            check=True,
        ).stdout
        self.assertIn("host: NOT READY: this host does not provision it", plan)

    def test_policy_changes_are_listed_on_refusal_and_next_start(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        project = base / "project"
        project.mkdir()
        catalog = base / "secrets.json"
        catalog.write_text(json.dumps(self.secret_catalog()))
        spec = project / ".sandbox.toml"
        spec.write_text('[environment]\nBROWSER = "none"\n')
        environment = {
            **os.environ,
            "HOME": str(base),
            "XDG_STATE_HOME": str(base / "state"),
            "SANDBOX_GUEST_PROFILE": "/nix/store/fixed-sandbox-profile",
            "SANDBOX_POLICY_HELPER": str(POLICY_PATH),
            "SANDBOX_SECRET_CATALOG": str(catalog),
            **QEMU_BACKEND,
        }

        def run(step: str) -> subprocess.CompletedProcess[str]:
            harness = (
                f"source <(sed '$d' \"{SANDBOX_PATH}\")\n"
                f'parse_target "{project}"\n{step}\n'
            )
            return subprocess.run(
                ["bash", "-c", harness],
                capture_output=True,
                env=environment,
                text=True,
            )

        self.assertEqual(run("record_policy").returncode, 0)
        # An edit the guest could make through its writable worktree.
        spec.write_text(
            '[environment]\nBROWSER = "w3m"\n\n[secrets]\ngrants = ["llm"]\n\n'
            '[network]\ninternal_cidrs = ["10.1.2.3/32"]\n'
        )
        refused = run("policy_matches_instance")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("effective policy changed", refused.stderr)
        self.assertIn("  + secrets[llm].name: llm\n", refused.stderr)
        self.assertIn("  + secrets[llm].env: LLAMA_API_KEY\n", refused.stderr)
        # Catalog-owned text is not the project's policy.
        self.assertNotIn("description", refused.stderr)
        self.assertNotIn("domains", refused.stderr)
        self.assertIn("  + internal_cidrs: 10.1.2.3/32\n", refused.stderr)
        self.assertIn("  ~ environment.BROWSER: none -> w3m\n", refused.stderr)
        # Render-time observations are not policy changes.
        self.assertNotIn("coverage", refused.stderr)

        # After destroy, the next start's confirmation shows the same lines
        # against the destroyed VM's policy; a fresh record clears it.
        shown = run(
            'mv "$policy_record" "$previous_policy_record"; show_previous_policy_changes'
        )
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn("Policy changes since the previous VM", shown.stdout)
        self.assertIn("  + secrets[llm].name: llm\n", shown.stdout)
        cleared = run(
            'record_policy; test ! -e "$previous_policy_record"; show_previous_policy_changes'
        )
        self.assertEqual(cleared.returncode, 0, cleared.stderr)
        self.assertEqual(cleared.stdout, "")

        # Rewording or extending the host catalog is not a project change.
        changed = self.secret_catalog()
        changed["llm"]["description"] = "reworded"
        changed["llm"]["domains"].append("llm-three.example.internal")
        catalog.write_text(json.dumps(changed))
        self.assertEqual(run("policy_matches_instance").returncode, 0)

        # A pure reorder is still refused, and says what moved.
        spec.write_text(
            '[environment]\nBROWSER = "w3m"\n\n[secrets]\ngrants = ["llm"]\n\n'
            '[network]\ninternal_cidrs = ["10.1.2.3/32", "10.9.9.9/32"]\n'
        )
        self.assertEqual(run("record_policy").returncode, 0)
        spec.write_text(
            '[environment]\nBROWSER = "w3m"\n\n[secrets]\ngrants = ["llm"]\n\n'
            '[network]\ninternal_cidrs = ["10.9.9.9/32", "10.1.2.3/32"]\n'
        )
        reordered = run("policy_matches_instance")
        self.assertNotEqual(reordered.returncode, 0)
        self.assertIn("  ~ internal_cidrs: ", reordered.stderr)

    def test_launcher_requires_the_wrapper_backend(self) -> None:
        root = self.config("")
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("SANDBOX_VM_")
        }
        environment.update(
            HOME=str(root),
            SANDBOX_GUEST_PROFILE="/nix/store/fixed-sandbox-profile",
            SANDBOX_POLICY_HELPER=str(POLICY_PATH),
        )
        result = subprocess.run(
            ["bash", str(SANDBOX_PATH), "plan", str(root)],
            capture_output=True,
            env=environment,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SANDBOX_VM_TYPE", result.stderr)


if __name__ == "__main__":
    unittest.main()
