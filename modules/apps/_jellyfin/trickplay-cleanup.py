import argparse
import shutil
import sys
from pathlib import Path

VIDEO_EXTS = {
    ".mkv",
    ".mp4",
    ".m4v",
    ".avi",
    ".mov",
    ".ts",
    ".webm",
    ".mpg",
    ".mpeg",
    ".wmv",
    ".flv",
}


def find_orphans(roots):
    for root in roots:
        root_path = Path(root)
        if not root_path.is_dir():
            print(f"warning: skipping missing root {root}", file=sys.stderr)
            continue
        for trickplay in root_path.rglob("*.trickplay"):
            if not trickplay.is_dir():
                continue
            stem = trickplay.name[: -len(".trickplay")]
            parent = trickplay.parent
            has_video = any((parent / f"{stem}{ext}").is_file() for ext in VIDEO_EXTS)
            if not has_video:
                yield trickplay


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--dry-run", action="store_true", help="print orphans without deleting"
    )
    ap.add_argument("roots", nargs="+")
    args = ap.parse_args()

    orphans = 0
    errors = 0
    for orphan in find_orphans(args.roots):
        print(f"orphan: {orphan}", flush=True)
        orphans += 1
        if args.dry_run:
            continue
        try:
            shutil.rmtree(orphan)
        except OSError as e:
            print(f"  rm failed: {e}", file=sys.stderr, flush=True)
            errors += 1

    mode = "dry-run" if args.dry_run else "delete"
    print(f"done. mode={mode} orphans={orphans} errors={errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
