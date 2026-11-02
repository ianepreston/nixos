#!/usr/bin/env python3
"""Credential lifecycle and shared prune safety checks (no model downloads).

Run with Python's stdlib. Set LLAMA_PRUNE_TEST_COMMAND to the built Darwin
operator.prunePackage's bin/llama-cpp-prune to exercise its real GNU runtime.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "serve",
    os.environ.get("LLAMA_SERVE_SOURCE", ROOT / "modules/system/_llama-cpp/serve.py"),
)
serve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(serve)


class CredentialTests(unittest.TestCase):
    def test_restart_preserves_private_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state/api-key"
            first = serve.local_key(path)
            self.assertGreaterEqual(len(first), 32)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(serve.local_key(path), first)

    def test_insecure_or_malformed_existing_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "api-key"
            path.write_text("short")
            path.chmod(0o600)
            with self.assertRaises(RuntimeError):
                serve.local_key(path)
            self.assertEqual(path.read_text(), "short")
            path.write_text("x" * 43)
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                serve.local_key(path)

    def test_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            target.write_text("unchanged")
            path = Path(directory) / "api-key"
            path.symlink_to(target)
            with self.assertRaises(OSError):
                serve.local_key(path)
            self.assertEqual(target.read_text(), "unchanged")


@unittest.skipUnless(
    os.environ.get("LLAMA_PRUNE_TEST_COMMAND"), "GNU prune runtime required"
)
class PruneTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="llama models ")
        self.addCleanup(self.directory.cleanup)
        self.cache = Path(self.directory.name)
        self.names = ["owner/coder:UD-Q4_K_XL", "owner/text:MXFP4"]
        self.routable = list(self.names)
        self.paths = []
        for repo, filename in [
            ("coder", "coder-UD-Q4_K_XL.gguf"),
            ("text", "text-MXFP4.gguf"),
            ("coder", "coder-Q8_0.gguf"),
            ("unused", "unused-Q4_K_M.gguf"),
        ]:
            root = self.cache / f"models--owner--{repo}"
            (root / "refs").mkdir(parents=True, exist_ok=True)
            (root / "refs/main").write_text("current")
            path = root / "snapshots/current" / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("weights")
            self.paths.append(path)
        self.live = self.paths[0]
        self.env = self.cache / "key.env"
        self.env.write_text("LLAMA_API_KEY=" + "x" * 43 + "\n")
        self.env.chmod(0o600)
        owner = self

        class Router(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get("Authorization") != "Bearer " + "x" * 43:
                    self.send_error(401)
                    return
                url = urlparse(self.path)
                if url.path == "/v1/models":
                    body = {"data": [{"id": n} for n in owner.routable]}
                elif parse_qs(url.query).get("model") == [owner.names[0]]:
                    body = {"model_path": str(owner.live)}
                else:
                    self.send_error(400)
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Router)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def prune(self, apply=False):
        return subprocess.run(
            [
                os.environ["LLAMA_PRUNE_TEST_COMMAND"],
                str(self.cache),
                str(self.server.server_port),
                str(self.env),
                str(apply).lower(),
                *self.names,
            ],
            capture_output=True,
            text=True,
        )

    def test_dry_run_and_apply_keep_idle_configured_model(self):
        result = self.prune()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(all(p.exists() for p in self.paths))
        result = self.prune(apply=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.paths[0].exists())
        self.assertTrue(self.paths[1].exists())
        self.assertFalse(self.paths[2].exists())
        self.assertFalse(self.paths[3].exists())

    def test_missing_configured_model_refuses_deletion(self):
        self.routable.pop()
        self.assertNotEqual(self.prune(apply=True).returncode, 0)
        self.assertTrue(all(p.exists() for p in self.paths))

    def test_live_path_in_obsolete_snapshot_refuses_deletion(self):
        self.live = self.paths[0].parent.parent / "old/coder-UD-Q4_K_XL.gguf"
        self.live.parent.mkdir()
        self.live.write_text("live old weights")
        self.assertNotEqual(self.prune(apply=True).returncode, 0)
        self.assertTrue(self.live.exists())
        self.assertTrue(all(p.exists() for p in self.paths))


if __name__ == "__main__":
    unittest.main()
