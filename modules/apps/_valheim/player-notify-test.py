#!/usr/bin/env python3
"""Offline replay of the production Valheim notifier, with a stub journal and webhook."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("player-notify.sh")


class PlayerNotifyTest(unittest.TestCase):
    def run_notifier(self, replay, follow):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "replay").write_text("\n".join(replay) + "\n")
            (root / "follow").write_text("\n".join(follow) + "\n")
            journal = root / "journalctl"
            journal.write_text(
                f"#!{sys.executable}\n"
                + """import json, os, re, sys
from pathlib import Path
root = Path(os.environ["TEST_ROOT"])
with (root / "calls").open("a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
pattern = next(arg.removeprefix("--grep=") for arg in sys.argv if arg.startswith("--grep="))
replay = "--show-cursor" in sys.argv
lines = (root / ("replay" if replay else "follow")).read_text().splitlines()
matched = [line for line in lines if re.search(pattern, line)]
for line in matched:
    print(line)
if replay and matched:
    print("-- cursor: test-cursor")
if replay and not matched:
    sys.exit(1)
"""
            )
            journal.chmod(0o755)
            curl = root / "curl"
            curl.write_text(
                f"#!{sys.executable}\n"
                + """import os, sys
from pathlib import Path
sys.stdin.read()
with (Path(os.environ["TEST_ROOT"]) / "posts").open("a") as f:
    f.write(sys.argv[-1] + "\\n")
"""
            )
            curl.chmod(0o755)
            env = os.environ.copy()
            env.update(
                TEST_ROOT=str(root),
                rundir=str(root),
                roster=str(root / "roster"),
                ready=str(root / "ready"),
                cursorfile=str(root / "cursor"),
                webhook="https://example.invalid/webhook",
                server="Test server",
                awk=shutil.which("gawk") or shutil.which("awk"),
                curl=str(curl),
                jq=shutil.which("jq"),
                journalctl=str(journal),
                sed=shutil.which("sed"),
            )
            result = subprocess.run(
                ["bash", "-e", str(SCRIPT)], env=env, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            posts = root / "posts"
            return (
                (root / "roster").read_text(),
                [json.loads(line) for line in posts.read_text().splitlines()]
                if posts.exists()
                else [],
                [
                    json.loads(line)
                    for line in (root / "calls").read_text().splitlines()
                ],
                result.stdout,
                (root / "ready").exists(),
            )

    def test_issue_replay_and_rejoin_survives_old_destroy(self):
        roster, posts, calls, stdout, ready = self.run_notifier(
            [
                "Got character ZDOID from Player One : 123:1",
                "Got character ZDOID from Player One : 0:0",
                "Keep socket for playfab/example, try to reconnect before timeout",
                "ZRpc timeout detected",
                "[FiresGhettoNetworkMod] [Disconnect] peer=Player One uid=123 connected=298s",
                "Got character ZDOID from Player Two : 456:1",
                "[FiresGhettoNetworkMod] [Disconnect] peer=Player Two uid=456 connected=100s",
                "Destroying abandoned non persistent zdo 456:7448 owner 456",
                "Destroying abandoned non persistent zdo 456:14090 owner 456",
            ],
            [
                "Got character ZDOID from Player One : 789:1",
                "Destroying abandoned non persistent zdo 123:9 owner 123",
                "Destroying abandoned non persistent zdo 456:9 owner 456",
            ],
        )
        self.assertEqual(roster, "789\tPlayer One\n")
        self.assertEqual(
            [post["content"] for post in posts],
            ["**Player One** joined **Test server** — 1 online"],
        )
        self.assertEqual(posts[0]["allowed_mentions"], {"parse": []})
        self.assertIn("roster rebuilt from journal: 0 player(s) online", stdout)
        self.assertTrue(ready)
        self.assertIn("--after-cursor=test-cursor", calls[1])

    def test_live_death_and_disconnect_posts_once(self):
        roster, posts, _, _, _ = self.run_notifier(
            [],
            [
                "Got character ZDOID from Dead Player : -123:1",
                "Got character ZDOID from Dead Player : 0:0",
                "[FiresGhettoNetworkMod] [Disconnect] peer=Dead Player uid=-123 connected=298s",
            ],
        )
        self.assertEqual(roster, "")
        self.assertEqual(
            [post["content"] for post in posts],
            [
                "**Dead Player** joined **Test server** — 1 online",
                "**Dead Player** left **Test server** — 0 online",
            ],
        )

    def test_disconnect_and_destroy_burst_are_deduplicated(self):
        for leaves in (
            [
                "[Disconnect] peer=Player uid=12 connected=10s",
                "Destroying abandoned non persistent zdo 12:2 owner 12",
            ],
            [
                "Destroying abandoned non persistent zdo 12:2 owner 12",
                "[Disconnect] peer=Player uid=12 connected=10s",
            ],
        ):
            with self.subTest(leaves=leaves):
                roster, posts, _, _, _ = self.run_notifier(
                    [], ["Got character ZDOID from Player : 12:1", *leaves]
                )
                self.assertEqual(roster, "")
                self.assertEqual(len(posts), 2)
                self.assertEqual(
                    posts[-1]["content"], "**Player** left **Test server** — 0 online"
                )

    def test_reconnect_and_delayed_old_disconnect(self):
        roster, posts, _, _, _ = self.run_notifier(
            ["Got character ZDOID from Player : 12:1"],
            [
                "Got character ZDOID from Player : 34:1",
                "[Disconnect] peer=Player uid=12 connected=10s",
            ],
        )
        self.assertEqual(roster, "34\tPlayer\n")
        self.assertEqual(
            [post["content"] for post in posts],
            [
                "**Player** joined **Test server** — 2 online",
                "**Player** left **Test server** — 1 online",
            ],
        )

    def test_peer_name_and_invalid_or_unknown_uid(self):
        roster, posts, _, _, _ = self.run_notifier(
            [
                "Got character ZDOID from Other Player : 12:1",
                "Got character ZDOID from Player uid=12 : 34:1",
            ],
            [
                "[Disconnect] peer=Player uid=12 uid=34 connected=10s",
                "[Disconnect] peer=Other Player uid=garbage connected=10s",
                "[Disconnect] peer=Other Player uid=99 connected=10s",
                "Player connection lost server Test server, now 1 player(s)",
            ],
        )
        self.assertEqual(roster, "12\tOther Player\n")
        self.assertEqual(
            [post["content"] for post in posts],
            ["**Player uid=12** left **Test server** — 1 online"],
        )

    def test_respawn_and_server_reset(self):
        roster, posts, calls, _, ready = self.run_notifier(
            [],
            [
                "Got character ZDOID from Player : 12:1",
                "Got character ZDOID from Player : 0:0",
                "Got character ZDOID from Player : 12:2",
                "Game - OnApplicationQuit",
                "New session server started",
            ],
        )
        self.assertEqual(roster, "")
        self.assertEqual(len(posts), 1)
        self.assertIn("--lines=0", calls[1])
        self.assertTrue(ready)


if __name__ == "__main__":
    unittest.main()
