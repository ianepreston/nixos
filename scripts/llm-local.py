#!/usr/bin/env python3
"""Dispatch local Darwin model operations using the inference owner's contract.

Linux task bodies remain remote operations. `platform` is their dispatch probe;
evaluation failures are fatal rather than falling back to guessed paths/ports.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


def contract(host: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", host):
        raise ValueError("Invalid flake host name")
    # Discovery reads a public export on the matching platform, never a
    # service's launchd/systemd internals. A remote Linux target still uses
    # the existing SSH implementation in taskfiles/llm.yaml.
    expr = (
        f'hosts: if builtins.hasAttr "{host}" hosts then '
        f'hosts."{host}".config.myLlamaCpp.operator else null'
    )
    result = subprocess.check_output(
        ["nix", "eval", "--json", ".#darwinConfigurations", "--apply", expr],
        text=True,
    )
    result = json.loads(result)
    if result is None:
        result = json.loads(
            subprocess.check_output(
                [
                    "nix",
                    "eval",
                    "--json",
                    f".#nixosConfigurations.{host}.config.myLlamaCpp.operator",
                ],
                text=True,
            )
        )
    return result


def api(target: dict, route: str, body: dict | None = None, timeout: int = 15):
    key = Path(target["apiKeyFile"]).read_text().strip()
    if not key:
        raise ValueError("Local API credential is empty; start the launchd agent first")
    request = urllib.request.Request(
        target["baseUrl"] + route,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    # A localhost request must not follow corporate HTTP proxy settings.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=timeout) as response:
        return json.load(response)


def list_models(target: dict) -> None:
    print("API:", target["baseUrl"])
    print("Cache:", target["cacheDirectory"])
    print("Configured (including idle):", ", ".join(target["models"]))
    try:
        models = api(target, "/models")
        print("Routable:", ", ".join(m["id"] for m in models["data"]))
    except (OSError, ValueError) as error:
        print(f"Router unavailable: {error}")
    cache = Path(target["cacheDirectory"])
    for path in sorted(cache.rglob("*.gguf")):
        print(f"  {path.stat().st_size / 1024**3:.2f} GiB  {path.relative_to(cache)}")


def fetch(target: dict) -> None:
    for name in target["models"]:
        print(
            f"Fetching/loading {name} (one token; may take up to an hour)", flush=True
        )
        api(
            target,
            "/chat/completions",
            {
                "model": name,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1,
            },
            timeout=3600,
        )
        print("  HTTP 200", flush=True)


def prune(target: dict, host: str, apply: bool) -> None:
    subprocess.run(
        [
            "nix",
            "build",
            "--no-link",
            f".#darwinConfigurations.{host}.config.myLlamaCpp.operator.prunePackage",
        ],
        check=True,
    )
    # The shared Linux algorithm reads an EnvironmentFile. Adapt only the
    # credential encoding; mkstemp creates mode 0600 and cleanup is automatic.
    key = Path(target["apiKeyFile"]).read_text().strip()
    if not key or any(c.isspace() for c in key):
        raise ValueError("Local API credential is malformed")
    with tempfile.NamedTemporaryFile(mode="w+", prefix="llama-prune-") as env_file:
        env_file.write(f"LLAMA_API_KEY={key}\n")
        env_file.flush()
        subprocess.run(
            [
                target["prunePackage"] + "/bin/llama-cpp-prune",
                target["cacheDirectory"],
                str(urllib.parse.urlparse(target["baseUrl"]).port),
                env_file.name,
                str(apply).lower(),
                *target["models"],
            ],
            check=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("action", choices=["platform", "models", "fetch", "prune"])
    parser.add_argument("--apply", choices=["true", "false"], default="false")
    args = parser.parse_args()
    target = contract(args.host)
    if args.action == "platform":
        print(target["platform"])
        return
    if target["platform"] != "darwin" or sys.platform != "darwin":
        parser.error(
            "Local operations must run on the serving Mac; Linux uses SSH tasks"
        )
    if Path.home() not in Path(target["cacheDirectory"]).parents:
        parser.error("This Mac's user does not own the configured data directory")
    if args.action == "models":
        list_models(target)
    elif args.action == "fetch":
        fetch(target)
    else:
        prune(target, args.host, args.apply == "true")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
