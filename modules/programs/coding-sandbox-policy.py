#!/usr/bin/env python3
"""Parse and render the network portion of a coding-sandbox policy.

This runs on the macOS host.  It intentionally uses only the Python standard
library: a worktree-owned TOML file is data, never shell input.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import socket
import sys
import tomllib
from pathlib import Path
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


def parse_config(worktree: Path) -> dict[str, Any]:
    config_path = worktree / ".sandbox.toml"
    if not config_path.exists():
        return {"version": 1, "network": {}}
    try:
        with config_path.open("rb") as config_file:
            config = tomllib.load(config_file)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {config_path}: {error}")
    if not isinstance(config, dict):
        fail(".sandbox.toml must contain a table")
    unknown = set(config) - {"version", "network"}
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
    return {"version": 1, "network": network}


def render_policy(worktree: Path, override_mode: str | None) -> dict[str, Any]:
    config = parse_config(worktree)
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
        "config_path": str(worktree / ".sandbox.toml") if (worktree / ".sandbox.toml").exists() else None,
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
    parser.add_argument("worktree", type=Path)
    parser.add_argument("--network", choices=("public", "restricted", "open"))
    arguments = parser.parse_args()
    try:
        policy = render_policy(arguments.worktree.resolve(), arguments.network)
    except PolicyError as error:
        print(f"sandbox policy: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(json.dumps(policy, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
