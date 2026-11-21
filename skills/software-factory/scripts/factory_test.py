#!/usr/bin/env python3
"""Behavioral checks using disposable repositories; no network or host access."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


CLI = Path(__file__).with_name("factory.py")


class FactoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo with spaces"
        subprocess.run(
            ["git", "init", "--quiet", str(self.repo)], check=True, capture_output=True
        )

    def call(self, *args, owner="supervisor-a", repo=None, ok=True):
        process = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "--repo",
                str(repo or self.repo),
                "--owner",
                owner,
                *args,
            ],
            capture_output=True,
            text=True,
        )
        if ok:
            self.assertEqual(process.returncode, 0, process.stderr)
            return json.loads(process.stdout)
        self.assertNotEqual(process.returncode, 0, process.stdout)
        return process.stderr

    def prepare(self, *issues, active=2):
        self.call("init", "--max-active", str(active))
        for issue in issues:
            self.call("task", str(issue), "--status", "ready")
            self.call("claim", f"issue:{issue}")

    def test_show_does_not_initialize(self):
        state = self.call("show")
        self.assertIsNone(state["supervisor"])
        self.assertFalse(Path(state["database"]).exists())

    def test_owner_takeover_preserves_work_and_rejects_stale_writer(self):
        self.prepare(1)
        self.call("claim", "worker:one", "--issue", "1")
        self.call("claim", "validation", "--issue", "1")
        self.call("init", owner="other", ok=False)
        self.call("takeover", "--previous-owner", "wrong", owner="new", ok=False)
        state = self.call("takeover", "--previous-owner", "supervisor-a", owner="new")
        self.assertEqual(len(state["claims"]), 3)
        self.call("release", "validation", ok=False)
        self.call("release", "validation", owner="new")

    def test_issue_and_worker_caps_rollback_failed_claims(self):
        self.prepare(1, active=1)
        self.call("task", "2")
        self.call("claim", "issue:2", ok=False)
        self.call("claim", "worker:a", "--issue", "1")
        self.call("claim", "worker:b", "--issue", "1")
        self.call("claim", "worker:c", "--issue", "1", ok=False)
        state = self.call("show")
        self.assertEqual(
            {claim["resource"] for claim in state["claims"]},
            {"issue:1", "worker:a", "worker:b"},
        )
        self.call("limits", "--max-active", "2", "--max-workers", "1", ok=False)
        self.call("limits", "--max-active", "2", "--max-workers", "2")
        self.call("claim", "issue:2")

    def test_resources_need_issue_and_prevent_premature_release(self):
        self.call("init")
        self.call("claim", "issue:1", ok=False)
        self.call("task", "1")
        self.call("claim", "build", "--issue", "1", ok=False)
        self.call("claim", "issue:1")
        self.call("claim", "build", "--issue", "1")
        self.call("claim", "build", "--issue", "1", ok=False)
        self.call("release", "issue:1", ok=False)
        self.call("release", "build")
        self.call("release", "issue:1")

    def test_validation_is_exclusive_even_across_supervisor_restart(self):
        self.prepare(1, 2)
        self.call("claim", "validation", "--issue", "1")
        self.call("claim", "validation", "--issue", "1", ok=False)
        self.call("claim", "validation", "--issue", "2", ok=False)
        state = self.call("show")
        self.assertIn({"resource": "validation", "issue": 1}, state["claims"])
        self.call("release", "validation")
        self.call("claim", "validation", "--issue", "2")

    def test_concurrent_claims_have_one_winner(self):
        self.prepare(1, 2)

        def reserve(issue):
            return subprocess.run(
                [
                    sys.executable,
                    str(CLI),
                    "--repo",
                    str(self.repo),
                    "--owner",
                    "supervisor-a",
                    "claim",
                    "validation",
                    "--issue",
                    str(issue),
                ],
                capture_output=True,
            ).returncode

        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(reserve, (1, 2))), [0, 1])
        self.assertEqual(
            sum(c["resource"] == "validation" for c in self.call("show")["claims"]),
            1,
        )

    def test_task_metadata_and_waiting_condition_survive_updates(self):
        self.prepare(1)
        data = self.root / "packet.json"
        data.write_text(json.dumps({"packet": {"scope": "fixture"}}))
        self.call("task", "1", "--status", "implementing", "--data-file", str(data))
        data.write_text(json.dumps({"waiting": {"resume": "operator confirms login"}}))
        state = self.call(
            "task", "1", "--status", "awaiting_manual", "--data-file", str(data)
        )
        task = state["tasks"][0]
        self.assertEqual(task["data"]["packet"]["scope"], "fixture")
        self.assertEqual(task["data"]["waiting"]["resume"], "operator confirms login")
        self.assertEqual(len(state["events"]), 5)
        data.write_text("[]")
        self.call("task", "1", "--data-file", str(data), ok=False)
        self.assertEqual(self.call("show")["tasks"][0], task)

    def test_batch_order_and_authority_survive_takeover(self):
        self.call("init")
        plan = self.root / "plan.json"
        plan.write_text(json.dumps({"issues": [2, 1], "authority": "no host changes"}))
        self.call("plan", "--data-file", str(plan))
        state = self.call("takeover", "--previous-owner", "supervisor-a", owner="new")
        self.assertEqual(state["supervisor"]["data"]["issues"], [2, 1])
        self.assertEqual(state["supervisor"]["data"]["authority"], "no host changes")

    def test_incompatible_schema_fails_clearly_and_preserves_state(self):
        path = Path(self.call("show")["database"])
        path.parent.mkdir(parents=True)
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE supervisor (owner TEXT)")
            db.execute("INSERT INTO supervisor VALUES ('old-owner')")
        error = self.call("show", ok=False)
        self.assertIn("unsupported state schema", error)
        self.assertNotIn("Traceback", error)
        self.call("init", ok=False)
        with sqlite3.connect(path) as db:
            self.assertEqual(
                db.execute("SELECT * FROM supervisor").fetchall(), [("old-owner",)]
            )

    def test_linked_worktree_shares_database_and_caps(self):
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--allow-empty",
                "-m",
                "fixture",
            ],
            check=True,
            capture_output=True,
        )
        worktree = self.root / "linked worktree"
        subprocess.run(
            ["git", "-C", str(self.repo), "worktree", "add", "--detach", str(worktree)],
            check=True,
            capture_output=True,
        )
        self.prepare(1, active=1)
        state = self.call("show", repo=worktree)
        self.assertEqual(state["database"], self.call("show")["database"])
        self.call("task", "2", repo=worktree)
        self.call("claim", "issue:2", repo=worktree, ok=False)


if __name__ == "__main__":
    unittest.main()
