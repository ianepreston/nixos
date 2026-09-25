import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.environ["RESTIC_REPOSITORY"]
PWF = os.environ["RESTIC_PASSWORD_FILE"]
OUT = os.environ["TEXTFILE_OUT"]
HOST = os.environ["RESTIC_HOST"]

# `snapshots`, `stats` and `ls` each take a *read* lock on the
# repo, which blocks the nightly `forget --prune`'s exclusive
# lock and is blocked by it. restic retries zero times by
# default, so whichever of the two asks second dies with exit
# 11 rather than waiting a few seconds (#676). Both sides now
# wait; see the `pruneOpts` note below for the sizing.
#
# The budget is per-invocation, and this script runs three
# locking commands (`snapshots`, `stats`, then the `ls`
# walk), so against a lock nobody ever releases the unit can
# sit in `activating` for ~30m rather than 10m. Harmless —
# it holds nothing anyone else needs and TimeoutStartSec is
# infinity — but the nightly ExecStartPost `systemctl
# --no-block start` merges into that job instead of running
# a fresh post-backup refresh, so the .prom is stale until
# the next grid tick.
RETRY_LOCK = "10m"


def restic(*args):
    cmd = ["restic", "-r", REPO, "-p", PWF, "--retry-lock", RETRY_LOCK, "--json", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    return r.stdout


# `--latest 1 --host <h>` does NOT return a single snapshot:
# restic groups by (host, paths-set) and returns the latest
# for each group. Repos that have evolved their `paths`
# list over time (app modules contribute their own state
# dirs, so the set changes whenever an app is added or
# removed) end up with many groups and many "latest"
# results. Listing all snapshots for the host and picking
# the chronologically newest is the only robust way to find
# the actually-latest backup.
#
# The same default grouping governs `restic forget`, where
# it silently fragmented the retention policy into one
# never-expiring budget per paths-set — hence the explicit
# `--group-by host` in `pruneOpts` below (#568). Nothing
# analogous exists for `snapshots`, so this loop stays.
snapshots = json.loads(restic("snapshots", "--host", HOST))
if not snapshots:
    sys.stderr.write(f"no snapshots for host {HOST}\n")
    sys.exit(1)
latest = max(snapshots, key=lambda s: s["time"])
snap_id = latest["short_id"]
snap_ts = datetime.datetime.fromisoformat(
    latest["time"].replace("Z", "+00:00")
).timestamp()

# Single repo-wide stats call. raw-data mode returns
# total_size + total_blob_count + snapshots_count. We
# deliberately avoid `--mode restore-size` (and per-snapshot
# stats calls) — each walks every blob/snapshot and adds
# minutes on an NFS-backed repo. Snapshot size / file count
# are derived from the `restic ls` stream below for free.
repo = json.loads(restic("stats", "--mode", "raw-data"))


def classify(path):
    parts = path.split("/")
    # parts[0] is "" because path starts with "/"; first real
    # segment is parts[1].
    #
    # No explicit denylist is needed for podman's own dirs
    # under /var/lib/containers (`storage`, `cache`) — before
    # #567 they were swept in by a blanket backup path and
    # showed up here as bogus app="storage" / app="cache"
    # series. The paths are now enumerated per app from
    # `myContainerApp.<app>.stateDirs`, so nothing that isn't
    # an app can reach this branch.
    if path.startswith("/var/lib/containers/") and len(parts) >= 5:
        return (parts[4], "container_state")
    if path.startswith("/var/lib/private/") and len(parts) >= 5:
        return (parts[4], "state")
    if path.startswith("/var/lib/") and len(parts) >= 4:
        return (parts[3], "state")
    if path.startswith("/var/backup/postgresql/") and len(parts) >= 5:
        m = re.match(r"^([^/]+?)(\.prev)?\.sql\.gz$", parts[4])
        if m:
            return (m.group(1), "postgres_dump")
    if path.startswith("/var/backup/mysql/") and len(parts) >= 5:
        m = re.match(r"^([^/]+?)(\.prev)?\.gz$", parts[4])
        if m:
            return (m.group(1), "mysql_dump")
    if path.startswith("/var/backup/sqlite/") and len(parts) >= 5:
        return (parts[4], "sqlite_staging")
    return None


sizes = {}
snap_total_size = 0
snap_file_count = 0
# --recursive is required: without it, restic 0.18+ only
# walks the first 1-2 directory levels under each backup
# root and silently emits a fraction of the snapshot's file
# nodes. The snapshot summary's total_files_processed is
# the truth check — they must match (modulo dirs/symlinks).
proc = subprocess.Popen(
    [
        "restic",
        "-r",
        REPO,
        "-p",
        PWF,
        "--retry-lock",
        RETRY_LOCK,
        "ls",
        "--long",
        "--recursive",
        "--json",
        snap_id,
    ],
    stdout=subprocess.PIPE,
    text=True,
)
assert proc.stdout is not None
for line in proc.stdout:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    # First message is the snapshot header (message_type=snapshot).
    # File entries come as struct_type/message_type=node with
    # type=file.
    if obj.get("type") != "file":
        continue
    size = int(obj.get("size", 0))
    snap_total_size += size
    snap_file_count += 1
    cls = classify(obj.get("path", ""))
    if cls is None:
        continue
    sizes[cls] = sizes.get(cls, 0) + size
proc.wait()
if proc.returncode != 0:
    sys.stderr.write(f"restic ls exited {proc.returncode}\n")
    sys.exit(proc.returncode)

out_dir = os.path.dirname(OUT)
fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".restic.prom.")
try:
    with os.fdopen(fd, "w") as f:
        f.write(
            "# HELP restic_repo_size_bytes Deduplicated size of restic repo (raw-data).\n"
        )
        f.write("# TYPE restic_repo_size_bytes gauge\n")
        f.write(f"restic_repo_size_bytes {repo.get('total_size', 0)}\n")

        f.write("# HELP restic_repo_blob_count Blob count in the restic repo.\n")
        f.write("# TYPE restic_repo_blob_count gauge\n")
        f.write(f"restic_repo_blob_count {repo.get('total_blob_count', 0)}\n")

        f.write(
            "# HELP restic_repo_snapshot_count Snapshot count in the restic repo.\n"
        )
        f.write("# TYPE restic_repo_snapshot_count gauge\n")
        f.write(f"restic_repo_snapshot_count {repo.get('snapshots_count', 0)}\n")

        f.write(
            "# HELP restic_snapshot_size_bytes Raw size of the latest snapshot (sum of file sizes from `restic ls`).\n"
        )
        f.write("# TYPE restic_snapshot_size_bytes gauge\n")
        f.write(f"restic_snapshot_size_bytes {snap_total_size}\n")

        f.write(
            "# HELP restic_snapshot_file_count File count in the latest snapshot.\n"
        )
        f.write("# TYPE restic_snapshot_file_count gauge\n")
        f.write(f"restic_snapshot_file_count {snap_file_count}\n")

        f.write(
            "# HELP restic_snapshot_timestamp_seconds Unix timestamp of the latest snapshot for this host.\n"
        )
        f.write("# TYPE restic_snapshot_timestamp_seconds gauge\n")
        f.write(f"restic_snapshot_timestamp_seconds {snap_ts}\n")

        f.write(
            "# HELP restic_app_size_bytes Restic-tracked size per app/component in the latest snapshot.\n"
        )
        f.write("# TYPE restic_app_size_bytes gauge\n")
        for (app, component), size in sorted(sizes.items()):
            f.write(
                f'restic_app_size_bytes{{app="{app}",component="{component}"}} {size}\n'
            )
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
