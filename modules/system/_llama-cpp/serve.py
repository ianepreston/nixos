"""Initialize a private local credential and exec the Metal router.

The key is read at each launch and inherited by router children through the
environment. Neither the launchd plist nor server argv contains its value.
"""

import argparse
import fcntl
import os
from pathlib import Path
import secrets
import stat


def local_key(path: Path) -> str:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "r+") as credential:
        fcntl.flock(credential, fcntl.LOCK_EX)
        info = os.fstat(credential.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError("Credential must be a user-owned regular file")
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise RuntimeError("Local API credential must have mode 0600")
        key = credential.read().strip()
        if not key:
            key = secrets.token_urlsafe(32)
            credential.write(key + "\n")
            credential.flush()
            os.fsync(credential.fileno())
        if len(key) < 32 or any(c.isspace() for c in key):
            raise RuntimeError("Malformed credential; refusing to start")
        return key


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a server command is required after --")
    os.umask(0o077)
    key = local_key(args.key_file)
    args.cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(LLAMA_API_KEY=key, LLAMA_CACHE=str(args.cache_dir))
    os.execvpe(command[0], command, env)


if __name__ == "__main__":
    main()
