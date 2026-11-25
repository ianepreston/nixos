#!/usr/bin/env python3
"""Offline tests for blueprint-ready.sh against a local fixture HTTP server."""

import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SCRIPT = Path(__file__).with_name("blueprint-ready.sh")
TOKEN = 'to"k\\en'  # quote and backslash survive untouched


def instance(path, status):
    return {"path": path, "status": status, "name": path}


class Fixture:
    """Serves /api/v3/managed/blueprints/ with a scripted behaviour."""

    def __init__(self, mode, instances):
        self.mode = mode
        self.instances = instances
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                url = urlparse(self.path)
                q = parse_qs(url.query)
                outer.requests.append(
                    {
                        "path": url.path,
                        "query": q,
                        "auth": self.headers.get("Authorization"),
                    }
                )
                if outer.mode == "truncated":
                    # Promise more bytes than are sent, then hang up.
                    self.send_response(200)
                    self.send_header("Content-Length", "10000")
                    self.end_headers()
                    self.wfile.write(json.dumps(outer.results(q)).encode()[:20])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                body = json.dumps(outer.results(q)).encode()
                self.send_response(503 if outer.mode == "503" else 200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def results(self, q):
        wanted = q.get("path", [None])[0]
        rows = [i for i in self.instances if wanted is None or i["path"] == wanted]
        return {"count": len(rows), "results": rows}

    def close(self):
        self.server.shutdown()


class BlueprintReadyTest(unittest.TestCase):
    def run_script(self, fixture, *files, budget=1, env_extra=None, token=TOKEN):
        with tempfile.TemporaryDirectory() as creds:
            if token is not None:
                Path(creds, "bootstrap_token").write_text(token)
            env = {
                **os.environ,
                "AUTHENTIK_HOST": fixture.url,
                "CREDENTIALS_DIRECTORY": creds,
                "BUDGET": str(budget),
            }
            env.update(env_extra or {})
            return subprocess.run(
                ["bash", "-euo", "pipefail", str(SCRIPT), *files],
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )

    def assert_opened(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("WARNING", r.stderr)

    def assert_degraded(self, r):
        # Degrades: exit 0 (never a failed unit) with a journal warning.
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WARNING", r.stderr)

    def test_applied_opens_gate_with_exact_path_filter(self):
        f = Fixture(
            "ok", [instance("a.yaml", "successful"), instance("b.yaml", "orphaned")]
        )
        self.addCleanup(f.close)
        self.assert_opened(self.run_script(f, "a.yaml"))
        self.assertEqual(f.requests[0]["query"]["path"], ["a.yaml"])
        self.assertEqual(f.requests[0]["auth"], f"Bearer {TOKEN}")

    def test_not_successful_degrades(self):
        f = Fixture("ok", [instance("a.yaml", "error")])
        self.addCleanup(f.close)
        self.assert_degraded(self.run_script(f, "a.yaml"))

    def test_suffix_path_does_not_match(self):
        f = Fixture("ok", [instance("sub/a.yaml", "successful")])
        self.addCleanup(f.close)
        # The server filters exactly, so even a loose server cannot open it.
        f.results = lambda q: {"results": f.instances}
        self.assert_degraded(self.run_script(f, "a.yaml"))

    def test_503_with_matching_json_does_not_open(self):
        f = Fixture("503", [instance("a.yaml", "successful")])
        self.addCleanup(f.close)
        self.assert_degraded(self.run_script(f, "a.yaml"))

    def test_truncated_transfer_does_not_open(self):
        f = Fixture("truncated", [instance("a.yaml", "successful")])
        self.addCleanup(f.close)
        self.assert_degraded(self.run_script(f, "a.yaml"))

    def test_proxy_env_is_ignored(self):
        f = Fixture("ok", [instance("a.yaml", "successful")])
        self.addCleanup(f.close)
        dead = {
            "http_proxy": "http://127.0.0.1:9",
            "HTTP_PROXY": "http://127.0.0.1:9",
            "ALL_PROXY": "http://127.0.0.1:9",
            "all_proxy": "http://127.0.0.1:9",
        }
        self.assert_opened(self.run_script(f, "a.yaml", env_extra=dead))

    def test_curlrc_is_ignored(self):
        f = Fixture("ok", [instance("a.yaml", "successful")])
        self.addCleanup(f.close)
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".curlrc").write_text('proxy = "http://127.0.0.1:9"\n')
            self.assert_opened(self.run_script(f, "a.yaml", env_extra={"HOME": home}))

    def test_result_beyond_first_page_is_found(self):
        rows = [instance(f"f{i}.yaml", "successful") for i in range(300)]
        f = Fixture("ok", rows)
        self.addCleanup(f.close)
        self.assert_opened(self.run_script(f, "f299.yaml"))

    def test_all_files_must_be_applied(self):
        f = Fixture(
            "ok", [instance("a.yaml", "successful"), instance("b.yaml", "error")]
        )
        self.addCleanup(f.close)
        self.assert_degraded(self.run_script(f, "a.yaml", "b.yaml"))

    def test_missing_credential_degrades(self):
        f = Fixture("ok", [instance("a.yaml", "successful")])
        self.addCleanup(f.close)
        self.assert_degraded(self.run_script(f, "a.yaml", token=None))

    def test_token_not_logged(self):
        f = Fixture("503", [])
        self.addCleanup(f.close)
        r = self.run_script(f, "a.yaml")
        self.assertNotIn(TOKEN, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
