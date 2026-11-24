#!/usr/bin/env python3
"""Rename Home Assistant devices and their entities; see ha-rename.md."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import stat
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlsplit


class Refusal(Exception):
    """The requested operation cannot safely proceed."""


# Only these fixed messages can be shown at the CLI boundary. Refusals may
# contain peer-supplied entity IDs or names after a colon; never print them.
SAFE_REFUSALS = (
    "token file must be a regular file with mode 600",
    "token file is empty",
    "URL must be wss://HOST/api/websocket without credentials or query",
    "plan must contain a non-empty devices list",
    "unknown plan fields",
    "each device plan must be an object",
    "unknown device plan fields",
    "device plan requires name, model, area_id, new_name, old_prefix and new_prefix",
    "prefixes must be lowercase entity object IDs",
    "old and new prefixes must differ",
    "Home Assistant connection failed",
    "Home Assistant connection close failed",
    "Home Assistant transport send failed",
    "Home Assistant transport receive failed",
    "unexpected authentication greeting",
    "Home Assistant authentication failed",
    "Home Assistant request failed",
    "device match must be unique",
    "device selected more than once",
    "device target collision",
    "device has no registered entities",
    "entity prefix mismatch",
    "entity target collision",
    "entities overrides must be an object keyed by old entity ID",
    "invalid entity override",
    "invalid entity name",
    "invalid entity labels",
    "unknown entity override",
    "config directory and its .storage directory must exist locally",
    "reference file is a broken symlink",
    "reference path is not a file",
    "unexpected person/list response",
    "person tracker target collision",
    "YAML-managed person tracker references must be updated before applying",
    "references found; update them first or explicitly use --force",
    "verification failed: live entity registry does not match plan",
    "verification failed: live device registry does not match plan",
    "verification failed: unexpected person/list response",
    "verification failed: person tracker list or live tracker state",
)


def safe_refusal(exc):
    detail = exc.args[0] if exc.args and isinstance(exc.args[0], str) else ""
    return next(
        (
            message
            for message in SAFE_REFUSALS
            if detail == message or detail.startswith(message + ": ")
        ),
        "operation refused",
    )


def token_from_file(path: Path) -> str:
    # Open first and inspect that exact file, rather than stat then follow a link.
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
            raise Refusal("token file must be a regular file with mode 600")
        token = stream.read().strip()
    if not token:
        raise Refusal("token file is empty")
    return token


class Client:
    def __init__(self, socket):
        self.socket = socket
        self.sequence = 0

    async def send(self, payload):
        try:
            await self.socket.send(json.dumps(payload))
        except Exception:
            # Websocket exceptions can include a peer-supplied close reason.
            raise Refusal("Home Assistant transport send failed") from None

    async def receive(self):
        try:
            return json.loads(await self.socket.recv())
        except Exception:
            raise Refusal("Home Assistant transport receive failed") from None

    async def authenticate(self, token):
        message = await self.receive()
        if message.get("type") != "auth_required":
            raise Refusal("unexpected authentication greeting")
        await self.send({"type": "auth", "access_token": token})
        if (await self.receive()).get("type") != "auth_ok":
            raise Refusal("Home Assistant authentication failed")

    async def call(self, kind, **fields):
        self.sequence += 1
        await self.send({"id": self.sequence, "type": kind, **fields})
        reply = await self.receive()
        if reply.get("id") != self.sequence or not reply.get("success"):
            # Never propagate server messages: they can contain sensitive input.
            raise Refusal(f"Home Assistant request failed: {kind}")
        return reply["result"]


def build_changes(plan, devices, entities, states):
    if (
        not isinstance(plan, dict)
        or not isinstance(plan.get("devices"), list)
        or not plan["devices"]
    ):
        raise Refusal("plan must contain a non-empty devices list")
    if set(plan) != {"devices"}:
        raise Refusal("unknown plan fields")
    device_changes, entity_changes = [], []
    selected_devices, targets = set(), set()
    existing_ids = {entity["entity_id"] for entity in entities} | {
        state["entity_id"] for state in states
    }
    for item in plan["devices"]:
        if not isinstance(item, dict):
            raise Refusal("each device plan must be an object")
        required = ("name", "model", "area_id", "new_name", "old_prefix", "new_prefix")
        if set(item) - (set(required) | {"entities"}):
            raise Refusal("unknown device plan fields")
        if any(not isinstance(item.get(key), str) or not item[key] for key in required):
            raise Refusal(
                "device plan requires name, model, area_id, new_name, old_prefix and new_prefix"
            )
        old_prefix, new_prefix = item["old_prefix"], item["new_prefix"]
        if not all(
            re.fullmatch(r"[a-z0-9_]+", value) for value in (old_prefix, new_prefix)
        ):
            raise Refusal("prefixes must be lowercase entity object IDs")
        if old_prefix == new_prefix:
            raise Refusal("old and new prefixes must differ")
        matches = [
            device
            for device in devices
            if (device.get("name_by_user") or device.get("name")) == item["name"]
            and device.get("model") == item["model"]
            and device.get("area_id") == item["area_id"]
        ]
        if len(matches) != 1:
            raise Refusal(f"device match must be unique: {item['name']}")
        device = matches[0]
        if device["id"] in selected_devices:
            raise Refusal(f"device selected more than once: {item['name']}")
        selected_devices.add(device["id"])
        if any(
            other["id"] != device["id"]
            and (other.get("name_by_user") or other.get("name")) == item["new_name"]
            for other in devices
        ) or any(change["new_name"] == item["new_name"] for change in device_changes):
            raise Refusal(f"device target collision: {item['new_name']}")
        device_changes.append(
            {
                "id": device["id"],
                "old_name": item["name"],
                "old_name_by_user": device.get("name_by_user"),
                "new_name": item["new_name"],
            }
        )
        overrides = item.get("entities", {})
        if not isinstance(overrides, dict):
            raise Refusal("entities overrides must be an object keyed by old entity ID")
        device_entities = [
            entity for entity in entities if entity.get("device_id") == device["id"]
        ]
        if not device_entities:
            raise Refusal(f"device has no registered entities: {item['name']}")
        for entity in device_entities:
            old_id = entity["entity_id"]
            domain, separator, obj = old_id.partition(".")
            if not separator or not (
                obj == old_prefix or obj.startswith(old_prefix + "_")
            ):
                raise Refusal(f"entity prefix mismatch: {old_id}")
            new_id = f"{domain}.{new_prefix}{obj[len(old_prefix) :]}"
            if new_id in existing_ids or new_id in targets:
                raise Refusal(f"entity target collision: {new_id}")
            targets.add(new_id)
            override = overrides.get(old_id, {})
            if not isinstance(override, dict) or set(override) - {"name", "labels"}:
                raise Refusal(f"invalid entity override: {old_id}")
            if "name" in override and not (
                override["name"] is None or isinstance(override["name"], str)
            ):
                raise Refusal(f"invalid entity name: {old_id}")
            if "labels" in override and not (
                isinstance(override["labels"], list)
                and all(isinstance(label, str) for label in override["labels"])
            ):
                raise Refusal(f"invalid entity labels: {old_id}")
            entity_changes.append(
                {
                    "old_id": old_id,
                    "new_id": new_id,
                    "device_id": device["id"],
                    "old_name": entity.get("name"),
                    "old_labels": entity.get("labels", []),
                    "updates": override,
                }
            )
        unknown = set(overrides) - {entity["entity_id"] for entity in device_entities}
        if unknown:
            raise Refusal(f"unknown entity override: {sorted(unknown)[0]}")
    return device_changes, entity_changes


def find_references(config_dir, old_ids):
    if not config_dir.is_dir() or not (config_dir / ".storage").is_dir():
        raise Refusal("config directory and its .storage directory must exist locally")
    paths = [
        config_dir / name
        for name in ("automations.yaml", "scripts.yaml", "scenes.yaml")
    ]
    paths += sorted(
        path
        for path in (config_dir / ".storage").iterdir()
        if path.name == "lovelace" or path.name.startswith("lovelace.")
    )
    references = []
    patterns = {
        old: re.compile(r"(?<![a-zA-Z0-9_])" + re.escape(old) + r"(?![a-zA-Z0-9_])")
        for old in old_ids
    }
    for path in paths:
        if path.is_symlink() and not path.exists():
            raise Refusal(f"reference file is a broken symlink: {path}")
        if not path.exists():
            continue
        if not path.is_file():
            raise Refusal(f"reference path is not a file: {path}")
        contents = path.read_text(encoding="utf-8")
        references.extend(
            {"file": str(path), "entity_id": old}
            for old, pattern in patterns.items()
            if pattern.search(contents)
        )
    return references


def people_changes(people, mapping):
    if not isinstance(people, dict) or not all(
        isinstance(people.get(key), list) for key in ("storage", "config")
    ):
        raise Refusal("unexpected person/list response")
    changes = []
    yaml_references = []
    for person in people["config"]:
        for tracker in person.get("device_trackers", []):
            if tracker in mapping:
                yaml_references.append(
                    {"person_id": person["id"], "entity_id": tracker}
                )
    for person in people["storage"]:
        old = person.get("device_trackers", [])
        new = [mapping.get(tracker, tracker) for tracker in old]
        if old != new:
            if len(new) != len(set(new)):
                raise Refusal(f"person tracker target collision: {person['id']}")
            changes.append(
                {"id": person["id"], "old_trackers": old, "new_trackers": new}
            )
    return changes, yaml_references


def write_log(path, record):
    # Exclusive creation protects the reversal record from accidental overwrite.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(record, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


async def run(client, plan, config_dir, log_path, apply=False, force=False):
    devices = await client.call("config/device_registry/list")
    entities = await client.call("config/entity_registry/list")
    people = await client.call("person/list")
    states = await client.call("get_states")
    device_changes, entity_changes = build_changes(plan, devices, entities, states)
    mapping = {change["old_id"]: change["new_id"] for change in entity_changes}
    references = find_references(config_dir, mapping)
    person_changes, yaml_people = people_changes(people, mapping)
    record = {
        "devices": device_changes,
        "entities": entity_changes,
        "people": person_changes,
        "yaml_people": yaml_people,
        "references": references,
    }
    write_log(log_path, record)
    for change in device_changes:
        print(f"device: {change['old_name']} -> {change['new_name']}")
    for change in entity_changes:
        print(f"entity: {change['old_id']} -> {change['new_id']}")
        if change["updates"]:
            print(f"  metadata: {change['updates']}")
    for ref in references:
        print(f"reference: {ref['file']}: {ref['entity_id']}")
    for person in person_changes:
        print(
            f"person: {person['id']}: {person['old_trackers']} -> {person['new_trackers']}"
        )
    for reference in yaml_people:
        print(f"YAML person: {reference['person_id']}: {reference['entity_id']}")
    print(f"reversal log: {log_path}")
    if not apply:
        print("dry run; no changes applied")
        return
    if yaml_people:
        raise Refusal(
            "YAML-managed person tracker references must be updated before applying"
        )
    if references and not force:
        raise Refusal("references found; update them first or explicitly use --force")
    for change in device_changes:
        await client.call(
            "config/device_registry/update",
            device_id=change["id"],
            name_by_user=change["new_name"],
        )
    for change in entity_changes:
        await client.call(
            "config/entity_registry/update",
            entity_id=change["old_id"],
            new_entity_id=change["new_id"],
            **change["updates"],
        )
    for change in person_changes:
        await client.call(
            "person/update",
            person_id=change["id"],
            device_trackers=change["new_trackers"],
        )
    updated_devices = await client.call("config/device_registry/list")
    updated_entities = await client.call("config/entity_registry/list")
    updated_people = await client.call("person/list")
    states = await client.call("get_states")
    current_entities = {entity["entity_id"]: entity for entity in updated_entities}
    state_ids = {state["entity_id"] for state in states}
    current_devices = {device["id"]: device for device in updated_devices}
    if not isinstance(updated_people, dict) or not isinstance(
        updated_people.get("storage"), list
    ):
        raise Refusal("verification failed: unexpected person/list response")
    current_people = {person["id"]: person for person in updated_people["storage"]}
    if any(
        change["old_id"] in current_entities
        or change["new_id"] not in current_entities
        or current_entities[change["new_id"]].get("device_id") != change["device_id"]
        or any(
            (
                set(current_entities[change["new_id"]].get(field, [])) != set(value)
                if field == "labels"
                else current_entities[change["new_id"]].get(field) != value
            )
            for field, value in change["updates"].items()
        )
        for change in entity_changes
    ):
        raise Refusal("verification failed: live entity registry does not match plan")
    if any(
        current_devices.get(change["id"], {}).get("name_by_user") != change["new_name"]
        for change in device_changes
    ):
        raise Refusal("verification failed: live device registry does not match plan")
    for change in person_changes:
        actual = current_people.get(change["id"], {}).get("device_trackers")
        if actual != change["new_trackers"] or any(
            mapping[old] not in state_ids
            for old in change["old_trackers"]
            if old in mapping
        ):
            raise Refusal(
                "verification failed: person tracker list or live tracker state"
            )
    print("verified live device and entity registries and affected person trackers")


@asynccontextmanager
async def open_socket(url):
    try:
        from websockets.asyncio.client import connect

        connection = connect(url)
        socket = await connection.__aenter__()
    except Exception:
        raise Refusal("Home Assistant connection failed") from None
    try:
        yield socket
    finally:
        try:
            await connection.__aexit__(*sys.exc_info())
        except Exception:
            raise Refusal("Home Assistant connection close failed") from None


async def connect_and_run(args):
    url = urlsplit(args.url)
    if (
        url.scheme != "wss"
        or not url.hostname
        or url.username
        or url.password
        or url.query
        or url.fragment
        or url.path != "/api/websocket"
    ):
        raise Refusal(
            "URL must be wss://HOST/api/websocket without credentials or query"
        )
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    token = token_from_file(args.token_file)
    async with open_socket(args.url) as socket:
        client = Client(socket)
        await client.authenticate(token)
        await run(client, plan, args.config_dir, args.log, args.apply, args.force)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="wss://HOST/api/websocket")
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument(
        "--config-dir",
        required=True,
        type=Path,
        help="local, current HA config copy, including .storage",
    )
    parser.add_argument("--log", required=True, type=Path, help="new reversal log path")
    parser.add_argument(
        "--apply", action="store_true", help="apply changes; default is dry run"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="apply despite file references (does not rewrite them)",
    )
    args = parser.parse_args()
    try:
        asyncio.run(connect_and_run(args))
    except Refusal as exc:
        # Refusal details can contain untrusted registry data. Show only a
        # fixed message, never its dynamic suffix or a traceback.
        print(f"error: {safe_refusal(exc)}", file=sys.stderr)
        return 1
    except Exception:
        # Other exception text can contain the token or peer-supplied data.
        print("error: operation failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
