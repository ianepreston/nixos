#!/usr/bin/env python3
"""Local, worktree-shared task records and reservations; no external actions."""

import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys


STATUSES = (
    "queued",
    "ready",
    "implementing",
    "reviewing",
    "awaiting_validation",
    "validating",
    "awaiting_decision",
    "awaiting_manual",
    "blocked",
    "ready_to_merge",
    "merged",
    "rolled_out",
    "obsolete",
)
SCHEMA = """
CREATE TABLE IF NOT EXISTS supervisor (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    owner TEXT NOT NULL,
    max_active INTEGER NOT NULL,
    max_workers INTEGER NOT NULL,
    data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
    issue INTEGER PRIMARY KEY,
    status TEXT NOT NULL,
    data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS claims (
    resource TEXT PRIMARY KEY,
    issue INTEGER NOT NULL REFERENCES tasks(issue)
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    owner TEXT NOT NULL,
    command TEXT NOT NULL,
    data TEXT NOT NULL
);
"""


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("issue must be a positive integer")
    return number


def database_path(repo):
    common = subprocess.check_output(
        [
            "git",
            "-C",
            str(repo),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        text=True,
        stderr=subprocess.PIPE,
    ).strip()
    return Path(common) / "software-factory" / "state.sqlite3"


def snapshot(db):
    supervisor = db.execute("SELECT * FROM supervisor").fetchone()
    return {
        "supervisor": (
            {**dict(supervisor), "data": json.loads(supervisor["data"])}
            if supervisor
            else None
        ),
        "tasks": [
            {
                "issue": row["issue"],
                "status": row["status"],
                "data": json.loads(row["data"]),
            }
            for row in db.execute("SELECT * FROM tasks ORDER BY issue")
        ],
        "claims": [
            dict(row) for row in db.execute("SELECT * FROM claims ORDER BY resource")
        ],
        "events": [
            {**dict(row), "data": json.loads(row["data"])}
            for row in db.execute("SELECT * FROM events ORDER BY id DESC LIMIT 20")
        ][::-1],
    }


def count_claims(db, prefix):
    return db.execute(
        "SELECT count(*) FROM claims WHERE resource LIKE ?", (prefix + ":%",)
    ).fetchone()[0]


def check_limits(db, max_active, max_workers):
    if count_claims(db, "issue") > max_active:
        raise ValueError("active issue claims exceed the requested limit")
    if count_claims(db, "worker") > max_workers:
        raise ValueError("worker claims exceed the requested limit")


def claim(db, args, supervisor):
    resource = args.resource
    issue_match = re.fullmatch(r"issue:([1-9][0-9]*)", resource)
    worker_match = re.fullmatch(r"worker:[A-Za-z0-9_.-]+", resource)
    if not (issue_match or worker_match or resource in {"validation", "build"}):
        raise ValueError(
            "resource must be issue:<number>, worker:<token>, build or validation"
        )
    issue = int(issue_match[1]) if issue_match else args.issue
    if issue is None or (args.issue is not None and args.issue != issue):
        raise ValueError("claim needs a matching --issue")
    if not db.execute("SELECT 1 FROM tasks WHERE issue = ?", (issue,)).fetchone():
        raise ValueError("record the task before claiming it")
    existing = db.execute(
        "SELECT issue FROM claims WHERE resource = ?", (resource,)
    ).fetchone()
    if existing:
        raise ValueError(f"{resource} is already reserved for issue {existing[0]}")
    if (
        not issue_match
        and not db.execute(
            "SELECT 1 FROM claims WHERE resource = ?", (f"issue:{issue}",)
        ).fetchone()
    ):
        raise ValueError("claim the issue before its workers/build/validation")
    db.execute("INSERT INTO claims VALUES (?, ?)", (resource, issue))
    check_limits(db, supervisor["max_active"], supervisor["max_workers"])
    return {"resource": resource, "issue": issue}


def mutate(db, args):
    if not args.owner or not args.owner.strip():
        raise ValueError(
            "mutations require --owner with a unique supervisor/session ID"
        )
    supervisor = db.execute("SELECT * FROM supervisor").fetchone()
    if args.command == "init":
        if supervisor:
            if (
                supervisor["owner"],
                supervisor["max_active"],
                supervisor["max_workers"],
            ) != (
                args.owner,
                args.max_active,
                args.max_workers,
            ):
                raise ValueError(
                    "already initialized; inspect state before takeover or limits"
                )
        else:
            db.execute(
                "INSERT INTO supervisor VALUES (1, ?, ?, ?, '{}')",
                (args.owner, args.max_active, args.max_workers),
            )
        return {"initialized": True}
    if not supervisor:
        raise ValueError("initialize the supervisor first")
    if args.command == "takeover":
        if supervisor["owner"] != args.previous_owner:
            raise ValueError("previous owner no longer matches; reread state")
        db.execute("UPDATE supervisor SET owner = ? WHERE id = 1", (args.owner,))
        return {"previous_owner": args.previous_owner, "owner": args.owner}
    if supervisor["owner"] != args.owner:
        raise ValueError("not the recorded supervisor; inspect state before takeover")
    if args.command == "limits":
        check_limits(db, args.max_active, args.max_workers)
        db.execute(
            "UPDATE supervisor SET max_active = ?, max_workers = ? WHERE id = 1",
            (args.max_active, args.max_workers),
        )
        return {"max_active": args.max_active, "max_workers": args.max_workers}
    if args.command in {"plan", "task"}:
        incoming = json.loads(args.data_file.read_text()) if args.data_file else {}
        if not isinstance(incoming, dict):
            raise ValueError("data must be a JSON object")
        if args.command == "plan":
            data = json.loads(supervisor["data"])
            data.update(incoming)
            db.execute(
                "UPDATE supervisor SET data = ? WHERE id = 1", (json.dumps(data),)
            )
            return incoming
        existing = db.execute(
            "SELECT * FROM tasks WHERE issue = ?", (args.issue,)
        ).fetchone()
        data = json.loads(existing["data"]) if existing else {}
        data.update(incoming)
        status = args.status or (existing["status"] if existing else "queued")
        db.execute(
            "INSERT INTO tasks VALUES (?, ?, ?) ON CONFLICT(issue) DO UPDATE SET "
            "status = excluded.status, data = excluded.data",
            (args.issue, status, json.dumps(data)),
        )
        return {"issue": args.issue, "status": status, "data": incoming}
    if args.command == "claim":
        return claim(db, args, supervisor)
    if args.command == "release":
        existing = db.execute(
            "SELECT issue FROM claims WHERE resource = ?", (args.resource,)
        ).fetchone()
        if not existing:
            raise ValueError("resource is not reserved")
        if (
            args.resource.startswith("issue:")
            and db.execute(
                "SELECT 1 FROM claims WHERE issue = ? AND resource != ?",
                (existing[0], args.resource),
            ).fetchone()
        ):
            raise ValueError("issue still has worker/build/validation claims")
        db.execute("DELETE FROM claims WHERE resource = ?", (args.resource,))
        return {"resource": args.resource, "issue": existing[0]}
    raise ValueError("unknown command")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", type=Path, default=Path.cwd())
    result.add_argument("--owner")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("show", help="read a consistent snapshot; no initialization")
    for name in ("init", "limits"):
        command = commands.add_parser(name)
        command.add_argument("--max-active", type=int, choices=(1, 2), default=1)
        command.add_argument("--max-workers", type=int, choices=(1, 2), default=2)
    takeover = commands.add_parser(
        "takeover", help="preserve claims; first reconcile runtime"
    )
    takeover.add_argument("--previous-owner", required=True)
    commands.add_parser("plan").add_argument("--data-file", type=Path, required=True)
    task = commands.add_parser("task")
    task.add_argument("issue", type=positive)
    task.add_argument("--status", choices=STATUSES)
    task.add_argument("--data-file", type=Path)
    acquire = commands.add_parser("claim")
    acquire.add_argument("resource")
    acquire.add_argument("--issue", type=positive)
    commands.add_parser("release").add_argument("resource")
    return result


def run(args):
    path = database_path(args.repo)
    if args.command == "show" and not path.exists():
        return {
            "database": str(path),
            "supervisor": None,
            "tasks": [],
            "claims": [],
            "events": [],
        }
    if args.command != "init" and not path.exists():
        raise ValueError("initialize the supervisor first")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=5, isolation_level=None) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("BEGIN IMMEDIATE" if args.command != "show" else "BEGIN")
        try:
            version = db.execute("PRAGMA user_version").fetchone()[0]
            has_tables = db.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table'"
            ).fetchone()
            if version == 0 and not has_tables and args.command == "init":
                for statement in SCHEMA.split(";"):
                    if statement.strip():
                        db.execute(statement)
                db.execute("PRAGMA user_version = 1")
            elif version != 1:
                raise ValueError(
                    f"unsupported state schema {version}; preserve the database and "
                    "reconcile with its originating helper before continuing"
                )
            if args.command != "show":
                event = mutate(db, args)
                db.execute(
                    "INSERT INTO events (owner, command, data) VALUES (?, ?, ?)",
                    (args.owner, args.command, json.dumps(event)),
                )
            state = {"database": str(path), **snapshot(db)}
            db.execute("COMMIT")
            return state
        except BaseException:
            db.execute("ROLLBACK")
            raise


def main():
    args = parser().parse_args()
    os.umask(0o077)
    try:
        print(json.dumps(run(args), indent=2))
    except (ValueError, OSError, sqlite3.Error, subprocess.CalledProcessError) as error:
        print(f"factory: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
