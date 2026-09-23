#!/usr/bin/env python3
"""Parse and render a coding-sandbox project policy.

This runs on the macOS host.  It intentionally uses only the Python standard
library plus Git: a project-owned TOML file is data, never shell input.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import socket
import subprocess
import sys
import tomllib
from pathlib import Path, PurePosixPath
from typing import Any


PROTECTED_V4 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),  # CGNAT and Tailscale.
    ipaddress.ip_network("169.254.0.0/16"),
)
PROTECTED_V6 = (
    ipaddress.ip_network("fc00::/7"),  # Unique local addresses.
    ipaddress.ip_network("fe80::/10"),  # Link-local addresses.
)
BASE_RESTRICTED_DOMAINS = (
    "cache.nixos.org",
    "nix-community.cachix.org",
    "install.determinate.systems",
    "github.com",
    "api.github.com",
    "codeload.github.com",
)
RESERVED_MOUNT_POINTS = (PurePosixPath("/sandbox-spec"), PurePosixPath("/mnt/sandbox-profile"))
DOMAIN_RE = re.compile(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}\Z")


class PolicyError(Exception):
    pass


def fail(message: str) -> None:
    raise PolicyError(message)


def protected_networks(version: int) -> tuple[ipaddress._BaseNetwork, ...]:
    return PROTECTED_V4 if version == 4 else PROTECTED_V6


def is_protected(address: ipaddress._BaseAddress) -> bool:
    return any(address in network for network in protected_networks(address.version))


def normalize_domain(value: Any, field: str) -> str:
    if not isinstance(value, str):
        fail(f"{field} entries must be strings")
    domain = value.lower().rstrip(".")
    if "*" in domain or not DOMAIN_RE.fullmatch(domain):
        fail(f"{field} entry {value!r} must be one exact DNS name (no wildcard or suffix)")
    return domain


def string_array(network: dict[str, Any], key: str) -> list[str]:
    value = network.get(key, [])
    if not isinstance(value, list):
        fail(f"network.{key} must be an array")
    return value


def unique(items: list[str]) -> list[str]:
    return list(dict.fromkeys(items))


def resolve(domain: str) -> list[ipaddress._BaseAddress]:
    try:
        results = socket.getaddrinfo(domain, None, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        fail(f"cannot resolve {domain}: {error}")

    addresses: set[ipaddress._BaseAddress] = set()
    for result in results:
        addresses.add(ipaddress.ip_address(result[4][0]))
    if not addresses:
        fail(f"cannot resolve {domain}")
    return sorted(addresses, key=lambda address: (address.version, int(address)))


def find_config_path(project: Path) -> Path | None:
    """Find the visible project specification from the selected directory."""
    for candidate in (project, *project.parents):
        config_path = candidate / ".sandbox.toml"
        if config_path.is_file():
            return config_path
    return None


def mount_error(index: int, message: str) -> None:
    fail(f"mounts[{index}]: {message}")


def git_root(path: Path) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        return None
    return Path(result.stdout.strip()).resolve()


def parse_mounts(value: Any, config_root: Path) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list):
        fail("mounts must be an array of tables")

    mounts: list[dict[str, Any]] = []
    mount_points: list[PurePosixPath] = []
    for index, entry in enumerate(value):
        if not isinstance(entry, dict):
            mount_error(index, "must be a table")
        unknown = set(entry) - {"path", "mount_point", "access", "branch"}
        if unknown:
            mount_error(index, f"unknown key(s): {', '.join(sorted(unknown))}")

        path_value = entry.get("path")
        if not isinstance(path_value, str) or not path_value:
            mount_error(index, "path must be a non-empty string")
        source = Path(path_value)
        if not source.is_absolute():
            source = config_root / source
        try:
            source = source.resolve(strict=True)
        except OSError as error:
            mount_error(index, f"cannot resolve path {path_value!r}: {error}")
        if not source.is_dir():
            mount_error(index, f"path {path_value!r} must name a directory")

        mount_point = entry.get("mount_point")
        if not isinstance(mount_point, str) or not mount_point:
            mount_error(index, "mount_point must be a non-empty absolute guest path")
        guest_path = PurePosixPath(mount_point)
        if (
            not guest_path.is_absolute()
            or str(guest_path) != mount_point
            or mount_point == "/"
            or ".." in guest_path.parts
        ):
            mount_error(index, "mount_point must be a normalized absolute guest path other than /")
        if any(existing == guest_path or existing in guest_path.parents or guest_path in existing.parents for existing in mount_points):
            mount_error(index, f"mount_point {mount_point!r} overlaps another mount")
        if any(
            reserved == guest_path or reserved in guest_path.parents or guest_path in reserved.parents
            for reserved in RESERVED_MOUNT_POINTS
        ):
            mount_error(index, f"mount_point {mount_point!r} overlaps a launcher-reserved path")
        mount_points.append(guest_path)

        repository_root = git_root(source)
        is_git = repository_root == source
        branch = entry.get("branch")
        if is_git:
            if not isinstance(branch, str) or not branch:
                mount_error(index, "branch is required when path names a Git repository")
            check_branch = subprocess.run(
                ["git", "check-ref-format", "--branch", branch], capture_output=True, check=False, text=True
            )
            if check_branch.returncode != 0:
                mount_error(index, f"branch {branch!r} is not a valid Git branch name")
        elif branch is not None:
            mount_error(index, "branch is valid only when path names a Git repository root")

        access = entry.get("access", "rw" if is_git else "ro")
        if access not in {"ro", "rw"}:
            mount_error(index, 'access must be "ro" or "rw"')
        mounts.append(
            {
                "source": str(source),
                "source_path": path_value,
                "mount_point": mount_point,
                "access": access,
                "access_source": "explicit" if "access" in entry else "default",
                "kind": "git" if is_git else "path",
                "branch": branch if is_git else None,
            }
        )
    return mounts


def parse_config(project: Path) -> dict[str, Any]:
    config_path = find_config_path(project)
    if config_path is None:
        return {"version": 1, "network": {}, "mounts": [], "config_path": None, "config_root": project}
    try:
        with config_path.open("rb") as config_file:
            config = tomllib.load(config_file)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {config_path}: {error}")
    if not isinstance(config, dict):
        fail(".sandbox.toml must contain a table")
    unknown = set(config) - {"version", "network", "mounts"}
    if unknown:
        fail(f"unknown top-level key(s): {', '.join(sorted(unknown))}")
    if config.get("version", 1) != 1:
        fail("version must be 1")
    network = config.get("network", {})
    if not isinstance(network, dict):
        fail("network must be a table")
    unknown = set(network) - {"mode", "internal_domains", "internal_cidrs", "public_domains"}
    if unknown:
        fail(f"unknown network key(s): {', '.join(sorted(unknown))}")
    return {
        "version": 1,
        "network": network,
        "mounts": parse_mounts(config.get("mounts"), config_path.parent),
        "config_path": config_path,
        "config_root": config_path.parent,
    }


def render_policy(project: Path, override_mode: str | None) -> dict[str, Any]:
    config = parse_config(project)
    network = config["network"]
    requested_mode = network.get("mode", "public")
    if requested_mode not in {"public", "restricted", "open"}:
        fail("network.mode must be public, restricted, or open")
    mode = override_mode or requested_mode

    internal_domains = unique(
        [normalize_domain(value, "network.internal_domains") for value in string_array(network, "internal_domains")]
    )
    public_domains = unique(
        [normalize_domain(value, "network.public_domains") for value in string_array(network, "public_domains")]
    )
    if public_domains and mode != "restricted":
        fail("network.public_domains is valid only when the effective network mode is restricted")

    grants_v4: set[str] = set()
    grants_v6: set[str] = set()
    resolved_internal_domains: list[dict[str, Any]] = []
    for domain in internal_domains:
        addresses = resolve(domain)
        public_addresses = [str(address) for address in addresses if not is_protected(address)]
        if public_addresses:
            fail(
                f"network.internal_domains entry {domain} resolved to public address(es): "
                + ", ".join(public_addresses)
                + "; use network.public_domains only in restricted mode"
            )
        for address in addresses:
            (grants_v4 if address.version == 4 else grants_v6).add(str(address))
        resolved_internal_domains.append({"name": domain, "addresses": [str(address) for address in addresses]})

    normalized_cidrs: list[str] = []
    for value in string_array(network, "internal_cidrs"):
        if not isinstance(value, str):
            fail("network.internal_cidrs entries must be strings")
        try:
            cidr = ipaddress.ip_network(value, strict=True)
        except ValueError as error:
            fail(f"invalid network.internal_cidrs entry {value!r}: {error}")
        if not any(cidr.subnet_of(protected) for protected in protected_networks(cidr.version)):
            fail(f"network.internal_cidrs entry {cidr} is not wholly within a protected range")
        normalized_cidrs.append(str(cidr))
        (grants_v4 if cidr.version == 4 else grants_v6).add(str(cidr))

    strict_domains: list[dict[str, Any]] = []
    if mode == "restricted":
        for domain in unique([*BASE_RESTRICTED_DOMAINS, *public_domains, *internal_domains]):
            addresses = resolve(domain)
            if domain not in internal_domains and any(is_protected(address) for address in addresses):
                fail(f"restricted public domain {domain} resolved to a protected address")
            strict_domains.append({"name": domain, "addresses": [str(address) for address in addresses]})

    strict_v4 = sorted(
        {
            address
            for domain in strict_domains
            for address in domain["addresses"]
            if ipaddress.ip_address(address).version == 4
        },
        key=lambda address: int(ipaddress.ip_address(address)),
    )
    strict_v6 = sorted(
        {
            address
            for domain in strict_domains
            for address in domain["addresses"]
            if ipaddress.ip_address(address).version == 6
        },
        key=lambda address: int(ipaddress.ip_address(address)),
    )

    return {
        "version": 1,
        "mode": mode,
        "mode_source": "command line" if override_mode else (".sandbox.toml" if "mode" in network else "default"),
        "config_path": str(config["config_path"]) if config["config_path"] else None,
        "config_root": str(config["config_root"]),
        "mounts": config["mounts"],
        "protected_v4": [str(network) for network in PROTECTED_V4],
        "protected_v6": [str(network) for network in PROTECTED_V6],
        "internal_domains": resolved_internal_domains,
        "internal_cidrs": unique(normalized_cidrs),
        "grants_v4": sorted(grants_v4, key=lambda address: (ipaddress.ip_network(address, strict=False).prefixlen, int(ipaddress.ip_network(address, strict=False).network_address))),
        "grants_v6": sorted(grants_v6, key=lambda address: (ipaddress.ip_network(address, strict=False).prefixlen, int(ipaddress.ip_network(address, strict=False).network_address))),
        "strict_domains": strict_domains,
        "strict_v4": strict_v4,
        "strict_v6": strict_v6,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--network", choices=("public", "restricted", "open"))
    arguments = parser.parse_args()
    try:
        policy = render_policy(arguments.project.resolve(), arguments.network)
    except PolicyError as error:
        print(f"sandbox policy: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(json.dumps(policy, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
