#!/usr/bin/env python3
"""Offline tests for Home Assistant rename; the websocket is an in-process stub."""

import copy
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "ha_rename", Path(__file__).with_name("ha-rename.py")
)
assert SPEC and SPEC.loader
rename = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rename)

PLAN = {
    "devices": [
        {
            "name": "Sample",
            "model": "Model A",
            "area_id": "test_room",
            "new_name": "New sample",
            "old_prefix": "sample",
            "new_prefix": "new_sample",
        }
    ]
}
DEVICES = [
    {
        "id": "device-1",
        "name": "Sample",
        "name_by_user": None,
        "model": "Model A",
        "area_id": "test_room",
    }
]
ENTITIES = [
    {
        "entity_id": "sensor.sample_temperature",
        "device_id": "device-1",
        "name": None,
        "labels": [],
    },
    {
        "entity_id": "device_tracker.sample",
        "device_id": "device-1",
        "name": None,
        "labels": [],
    },
]
PEOPLE = [
    {
        "id": "person-1",
        "device_trackers": ["device_tracker.sample", "device_tracker.other"],
    }
]


class Socket:
    def __init__(self):
        self.devices = copy.deepcopy(DEVICES)
        self.entities = copy.deepcopy(ENTITIES)
        self.people = copy.deepcopy(PEOPLE)
        self.yaml_people = []
        self.states = ["device_tracker.sample", "device_tracker.other"]
        self.calls = []
        self.pending = {"type": "auth_required"}
        self.broken_registry = False
        self.broken_state = False
        self.fail_on_kind = None
        self.on_update = None

    async def send(self, data):
        request = json.loads(data)
        if request["type"] == "auth":
            self.pending = {"type": "auth_ok"}
            return
        self.calls.append(request)
        kind = request["type"]
        if kind.endswith("/update") and self.on_update:
            self.on_update()
        if kind == self.fail_on_kind:
            raise OSError("fixture-token")
        result = None
        if kind == "config/device_registry/list":
            result = copy.deepcopy(self.devices)
        elif kind == "config/entity_registry/list":
            result = copy.deepcopy(self.entities)
            if self.broken_registry and any(
                call["type"] == "config/entity_registry/update" for call in self.calls
            ):
                result[0]["entity_id"] = "sensor.sample_temperature"
        elif kind == "person/list":
            result = {
                "storage": copy.deepcopy(self.people),
                "config": copy.deepcopy(self.yaml_people),
            }
        elif kind == "get_states":
            result = [
                {"entity_id": state}
                for state in self.states
                if not self.broken_state or state != "device_tracker.new_sample"
            ]
        elif kind == "config/device_registry/update":
            next(
                device
                for device in self.devices
                if device["id"] == request["device_id"]
            )["name_by_user"] = request["name_by_user"]
        elif kind == "config/entity_registry/update":
            entity = next(
                entity
                for entity in self.entities
                if entity["entity_id"] == request["entity_id"]
            )
            old_id = entity["entity_id"]
            entity["entity_id"] = request["new_entity_id"]
            for field in ("name", "labels"):
                if field in request:
                    entity[field] = request[field]
            self.states = [
                request["new_entity_id"] if state == old_id else state
                for state in self.states
            ]
        elif kind == "person/update":
            next(
                person for person in self.people if person["id"] == request["person_id"]
            )["device_trackers"] = request["device_trackers"]
        else:
            raise AssertionError(kind)
        self.pending = {
            "id": request["id"],
            "type": "result",
            "success": True,
            "result": result,
        }

    async def recv(self):
        return json.dumps(self.pending)


class RenameTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".storage").mkdir()
        self.log = self.root / "log.json"
        self.socket = Socket()
        self.client = rename.Client(self.socket)
        self.output = StringIO()
        self.plan = copy.deepcopy(PLAN)

    async def run_plan(self, **kwargs):
        with redirect_stdout(self.output):
            await rename.run(self.client, self.plan, self.root, self.log, **kwargs)

    def mutations(self):
        return [call for call in self.socket.calls if call["type"].endswith("/update")]

    async def test_dry_run_prints_and_logs_without_mutations(self):
        await self.run_plan()
        self.assertFalse(self.mutations())
        self.assertIn(
            "sensor.sample_temperature -> sensor.new_sample_temperature",
            self.output.getvalue(),
        )
        self.assertIn("dry run", self.output.getvalue())
        log = json.loads(self.log.read_text())
        self.assertEqual(log["entities"][0]["old_id"], "sensor.sample_temperature")
        self.assertEqual(log["entities"][0]["new_id"], "sensor.new_sample_temperature")
        self.assertEqual(os.stat(self.log).st_mode & 0o777, 0o600)

    async def test_entity_collision_refused(self):
        self.socket.entities.append(
            {"entity_id": "sensor.new_sample_temperature", "device_id": "other"}
        )
        with self.assertRaisesRegex(rename.Refusal, "target collision"):
            await self.run_plan()
        self.assertFalse(self.mutations())

    async def test_unregistered_live_state_target_collision_refused(self):
        self.socket.states.append("sensor.new_sample_temperature")
        with self.assertRaisesRegex(rename.Refusal, "target collision"):
            await self.run_plan(apply=True)
        self.assertFalse(self.mutations())

    async def test_duplicate_targets_refused(self):
        self.socket.devices.append(
            {
                "id": "device-2",
                "name": "Other",
                "model": "Model B",
                "area_id": "test_room",
            }
        )
        self.socket.entities.append(
            {"entity_id": "sensor.other_temperature", "device_id": "device-2"}
        )
        self.plan["devices"].append(
            {
                "name": "Other",
                "model": "Model B",
                "area_id": "test_room",
                "new_name": "Another",
                "old_prefix": "other",
                "new_prefix": "new_sample",
            }
        )
        with self.assertRaisesRegex(rename.Refusal, "entity target collision"):
            await self.run_plan()

    async def test_device_target_collision_refused(self):
        self.socket.devices.append(
            {"id": "device-2", "name": "New sample", "model": "X", "area_id": "other"}
        )
        with self.assertRaisesRegex(rename.Refusal, "device target collision"):
            await self.run_plan()

    def add_second_device(self, new_name, new_prefix):
        self.socket.devices.append(
            {
                "id": "device-2",
                "name": "Other",
                "model": "Model B",
                "area_id": "test_room",
            }
        )
        self.socket.entities.append(
            {"entity_id": "sensor.other_temperature", "device_id": "device-2"}
        )
        self.plan["devices"].append(
            {
                "name": "Other",
                "model": "Model B",
                "area_id": "test_room",
                "new_name": new_name,
                "old_prefix": "other",
                "new_prefix": new_prefix,
            }
        )

    async def test_entity_target_vacated_by_another_rename_refused(self):
        # Keep only sensors so no tracker state or person reference can collide.
        self.socket.entities = [self.socket.entities[0]]
        self.socket.states = []
        self.socket.people = []
        self.plan["devices"][0]["new_prefix"] = "other"
        self.add_second_device("Another", "future")
        with self.assertRaisesRegex(
            rename.Refusal, r"entity target collision: sensor\.other_temperature$"
        ):
            await self.run_plan()
        self.assertFalse(self.mutations())

    async def test_duplicate_device_targets_refused(self):
        self.add_second_device("New sample", "future")
        with self.assertRaisesRegex(rename.Refusal, "device target collision"):
            await self.run_plan(apply=True)
        self.assertFalse(self.mutations())

    async def test_prefix_mismatch_refused(self):
        self.socket.entities[0]["entity_id"] = "sensor.unrelated"
        with self.assertRaisesRegex(rename.Refusal, "prefix mismatch"):
            await self.run_plan()

    async def test_device_match_must_be_unique(self):
        self.socket.devices.append(self.socket.devices[0] | {"id": "device-2"})
        with self.assertRaisesRegex(rename.Refusal, "unique"):
            await self.run_plan()

    async def test_reference_refusal_logs_without_mutations(self):
        (self.root / "automations.yaml").write_text(
            "entity_id: sensor.sample_temperature\n"
        )
        with self.assertRaisesRegex(rename.Refusal, "references found"):
            await self.run_plan(apply=True)
        self.assertTrue(self.log.exists())
        self.assertFalse(self.mutations())

    async def test_reference_check_covers_all_files_and_word_boundaries(self):
        for name in (
            "automations.yaml",
            "scripts.yaml",
            "scenes.yaml",
            ".storage/lovelace",
            ".storage/lovelace.dashboard",
        ):
            (self.root / name).write_text("sensor.sample_temperature\n")
        (self.root / ".storage/lovelace.other").write_text(
            "sensor.sample_temperature_extra\n"
        )
        await self.run_plan()
        refs = json.loads(self.log.read_text())["references"]
        self.assertEqual(len(refs), 5)

    async def test_force_keeps_file_and_repoints_person(self):
        path = self.root / "scripts.yaml"
        path.write_text("entity_id: sensor.sample_temperature\n")
        await self.run_plan(apply=True, force=True)
        self.assertEqual(path.read_text(), "entity_id: sensor.sample_temperature\n")
        self.assertEqual(
            self.socket.people[0]["device_trackers"],
            ["device_tracker.new_sample", "device_tracker.other"],
        )
        self.assertIn("verified live", self.output.getvalue())

    async def test_apply_repoints_person_and_overrides_entity_metadata(self):
        self.plan["devices"][0]["entities"] = {
            "sensor.sample_temperature": {
                "name": "Temperature",
                "labels": ["test_label"],
            }
        }
        await self.run_plan(apply=True)
        self.assertEqual(self.socket.entities[0]["name"], "Temperature")
        self.assertEqual(self.socket.entities[0]["labels"], ["test_label"])
        self.assertEqual(
            self.socket.people[0]["device_trackers"][0], "device_tracker.new_sample"
        )
        self.assertIn("get_states", [call["type"] for call in self.socket.calls])

    async def test_live_registry_verification_failure(self):
        self.socket.broken_registry = True
        with self.assertRaisesRegex(rename.Refusal, "live entity registry"):
            await self.run_plan(apply=True)
        self.assertTrue(self.log.exists())

    async def test_missing_tracker_state_fails_verification(self):
        self.socket.broken_state = True
        with self.assertRaisesRegex(rename.Refusal, "tracker state"):
            await self.run_plan(apply=True)

    async def test_missing_storage_refused(self):
        with self.assertRaisesRegex(rename.Refusal, "config directory"):
            rename.find_references(self.root / "missing", ["sensor.sample_temperature"])

    async def test_existing_log_refused_before_mutations(self):
        self.log.write_text("existing")
        with self.assertRaises(FileExistsError):
            await self.run_plan(apply=True)
        self.assertEqual(self.log.read_text(), "existing")
        self.assertFalse(self.mutations())

    async def test_update_failure_leaves_complete_reversal_log(self):
        self.socket.fail_on_kind = "config/entity_registry/update"
        seen = []

        def check_log_before_update():
            log = json.loads(self.log.read_text())
            self.assertEqual(
                log["entities"][0]["new_id"], "sensor.new_sample_temperature"
            )
            seen.append(True)

        self.socket.on_update = check_log_before_update
        with self.assertRaisesRegex(rename.Refusal, "transport send failed"):
            await self.run_plan(apply=True)
        self.assertEqual(len(seen), 2)
        self.assertEqual(self.socket.devices[0]["name_by_user"], "New sample")
        log = json.loads(self.log.read_text())
        self.assertEqual(log["devices"][0]["old_name"], "Sample")
        self.assertIsNone(log["devices"][0]["old_name_by_user"])
        self.assertEqual(log["devices"][0]["new_name"], "New sample")
        self.assertEqual(log["entities"][0]["old_id"], "sensor.sample_temperature")
        self.assertEqual(log["entities"][0]["new_id"], "sensor.new_sample_temperature")
        self.assertEqual(log["people"][0]["old_trackers"], PEOPLE[0]["device_trackers"])

    async def test_auth_uses_websocket_without_printing_token(self):
        with redirect_stdout(self.output):
            await self.client.authenticate("fixture-token")
            await self.run_plan()
        self.assertNotIn("fixture-token", self.output.getvalue())

    async def test_token_permission_refusal(self):
        path = self.root / "fixture-token"
        path.write_text("fixture-token")
        path.chmod(0o644)
        with self.assertRaisesRegex(rename.Refusal, "mode 600"):
            rename.token_from_file(path)
        path.chmod(0o600)
        self.assertEqual(rename.token_from_file(path), "fixture-token")

    async def test_token_group_only_and_world_only_permissions_refused(self):
        path = self.root / "fixture-token"
        path.write_text("fixture-token")
        for mode in (0o640, 0o604):
            with self.subTest(mode=mode):
                path.chmod(mode)
                with self.assertRaisesRegex(rename.Refusal, "mode 600"):
                    rename.token_from_file(path)

    async def test_token_symlink_refused(self):
        token = self.root / "fixture-token"
        token.write_text("fixture-token")
        token.chmod(0o600)
        link = self.root / "link"
        link.symlink_to(token)
        with self.assertRaises(OSError):
            rename.token_from_file(link)

    async def test_person_tracker_collision_refused(self):
        self.socket.people[0]["device_trackers"].append("device_tracker.new_sample")
        with self.assertRaisesRegex(rename.Refusal, "person tracker target collision"):
            await self.run_plan(apply=True)
        self.assertFalse(self.mutations())

    async def test_yaml_person_reference_refused_even_with_force(self):
        self.socket.yaml_people.append(
            {"id": "yaml-person", "device_trackers": ["device_tracker.sample"]}
        )
        with self.assertRaisesRegex(rename.Refusal, "YAML-managed person"):
            await self.run_plan(apply=True, force=True)
        self.assertTrue(self.log.exists())
        self.assertFalse(self.mutations())

    async def test_person_response_shape_is_checked(self):
        with self.assertRaisesRegex(rename.Refusal, "person/list"):
            rename.people_changes([], {})

    async def test_connection_entrypoint_with_fake_websocket(self):
        token_path = self.root / "fixture-token"
        token_path.write_text("fixture-token")
        token_path.chmod(0o600)
        plan_path = self.root / "plan.json"
        plan_path.write_text(json.dumps(self.plan))
        socket = self.socket

        class Connection:
            async def __aenter__(self):
                return socket

            async def __aexit__(self, *args):
                return False

        def connect(url):
            self.assertEqual(url, "wss://example.invalid/api/websocket")
            return Connection()

        modules = {
            "websockets": types.ModuleType("websockets"),
            "websockets.asyncio": types.ModuleType("websockets.asyncio"),
            "websockets.asyncio.client": types.SimpleNamespace(connect=connect),
        }
        args = types.SimpleNamespace(
            url="wss://example.invalid/api/websocket",
            token_file=token_path,
            plan=plan_path,
            config_dir=self.root,
            log=self.log,
            apply=True,
            force=False,
        )
        with patch.dict(sys.modules, modules), redirect_stdout(self.output):
            await rename.connect_and_run(args)
        self.assertEqual(
            self.socket.people[0]["device_trackers"][0], "device_tracker.new_sample"
        )
        self.assertNotIn("fixture-token", self.output.getvalue())

    async def test_server_error_does_not_expose_its_message(self):
        class ErrorSocket:
            async def send(self, data):
                pass

            async def recv(self):
                return json.dumps(
                    {"id": 1, "success": False, "error": {"message": "fixture-token"}}
                )

        with self.assertRaises(rename.Refusal) as error:
            await rename.Client(ErrorSocket()).call("person/list")
        self.assertNotIn("fixture-token", str(error.exception))


class CliErrorTest(unittest.TestCase):
    """Exercise the real CLI boundary with a socket that never uses a network."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".storage").mkdir()
        token = self.root / "credentials"
        token.write_text("fixture-token")
        token.chmod(0o600)
        self.plan = self.root / "plan.json"
        self.plan.write_text(json.dumps(PLAN))
        self.argv = [
            "ha-rename",
            "--url",
            "wss://example.invalid/api/websocket",
            "--token-file",
            str(token),
            "--plan",
            str(self.plan),
            "--config-dir",
            str(self.root),
            "--log",
            str(self.root / "log.json"),
        ]

    def invoke(self, stage):
        class ConnectionClosedError(Exception):
            def __str__(self):
                return "received 1008 (policy violation) fixture-token; no close frame sent"

        class InvalidStatus(Exception):
            pass

        class InvalidHandshake(Exception):
            pass

        class ErrorSocket(Socket):
            def __init__(self):
                super().__init__()
                self.receives = 0

            async def send(self, data):
                kind = json.loads(data)["type"]
                if (stage == "auth_send" and kind == "auth") or (
                    stage == "call_send" and kind != "auth"
                ):
                    raise ConnectionClosedError()
                if stage == "timeout" and kind == "auth":
                    raise TimeoutError("fixture-token")
                await super().send(data)

            async def recv(self):
                self.receives += 1
                if (stage == "auth_recv" and self.receives == 1) or (
                    stage == "call_recv" and self.receives == 3
                ):
                    raise ConnectionClosedError()
                if stage == "bad_json" and self.receives == 1:
                    return '"fixture-token'
                if stage == "oserror" and self.receives == 1:
                    raise OSError("fixture-token")
                return await super().recv()

        class Connection:
            async def __aenter__(self):
                if stage == "handshake":
                    raise ConnectionClosedError()
                if stage == "invalid_status":
                    raise InvalidStatus("fixture-token")
                if stage == "invalid_handshake":
                    raise InvalidHandshake("fixture-token")
                return ErrorSocket()

            async def __aexit__(self, *args):
                if stage == "close":
                    raise ConnectionClosedError()
                return False

        def connect(url):
            if stage == "connect":
                raise OSError("fixture-token")
            return Connection()

        modules = {
            "websockets": types.ModuleType("websockets"),
            "websockets.asyncio": types.ModuleType("websockets.asyncio"),
            "websockets.asyncio.client": types.SimpleNamespace(connect=connect),
        }
        stdout, stderr = StringIO(), StringIO()
        with (
            patch.dict(sys.modules, modules),
            patch.object(sys, "argv", self.argv),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            status = rename.main()
        self.assertNotEqual(status, 0)
        for output in (stdout.getvalue(), stderr.getvalue()):
            self.assertNotIn("fixture-token", output)
            self.assertNotIn("Traceback", output)
        self.assertIn("error:", stderr.getvalue())
        if stage == "refusal":
            self.assertIn("device match must be unique", stderr.getvalue())

    def test_token_bearing_close_during_auth_receive(self):
        self.invoke("auth_recv")

    def test_token_bearing_close_during_auth_send(self):
        self.invoke("auth_send")

    def test_token_bearing_close_during_request_send(self):
        self.invoke("call_send")

    def test_token_bearing_close_during_request_receive(self):
        self.invoke("call_recv")

    def test_token_bearing_handshake_failure(self):
        self.invoke("handshake")

    def test_token_bearing_invalid_status(self):
        self.invoke("invalid_status")

    def test_token_bearing_invalid_handshake(self):
        self.invoke("invalid_handshake")

    def test_token_bearing_connect_failure(self):
        self.invoke("connect")

    def test_token_bearing_close_failure(self):
        self.invoke("close")

    def test_token_bearing_timeout(self):
        self.invoke("timeout")

    def test_token_bearing_oserror(self):
        self.invoke("oserror")

    def test_token_bearing_malformed_peer_json(self):
        self.invoke("bad_json")

    def test_token_bearing_unexpected_exception_is_sanitized(self):
        async def fail(_args):
            raise RuntimeError("fixture-token")

        stdout, stderr = StringIO(), StringIO()
        with (
            patch.object(rename, "connect_and_run", fail),
            patch.object(sys, "argv", self.argv),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            status = rename.main()
        self.assertNotEqual(status, 0)
        self.assertNotIn("fixture-token", stdout.getvalue())
        self.assertNotIn("fixture-token", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_token_bearing_refusal_is_sanitized(self):
        plan = copy.deepcopy(PLAN)
        plan["devices"][0]["name"] = "fixture-token"
        self.plan.write_text(json.dumps(plan))
        self.invoke("refusal")


if __name__ == "__main__":
    unittest.main()
