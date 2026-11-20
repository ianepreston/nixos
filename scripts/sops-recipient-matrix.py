#!/usr/bin/env python3
"""Check every nix-secrets sops file's recipients against what each host reads.

For each host identity, the files it can decrypt must be exactly the files
its evaluated NixOS and home-manager config references. Missing access is a
"cannot decrypt" failure, which breaks sops-install-secrets on the next
switch. Extra access is "over-granted", the drift the recipient-narrowing
series (#503-#510) removes. The operator identities (the `users` anchors in
.sops.yaml) must be recipients of every file.

The check uses public keys only, so no private key leaves a host. An age
recipient that is not in a file's sops metadata cannot unwrap that file's
data key, so comparing recipient lists answers "can this host decrypt X"
exactly. Each host's key is its live SSH host key, from ssh-keyscan (no
authentication needed), so a stale anchor in .sops.yaml shows up as anchor
drift instead of passing on a copied value. Hosts that do not answer fall
back to their .sops.yaml anchor, marked unverified.

Usage: sops-recipient-matrix.py --secrets-dir DIR --consumers consumers.json
       [--vm-pubkey PATH] [--offline]

consumers.json maps host -> list of sops file basenames, as produced by
`task secrets:matrix` (one nix eval over every nixosConfiguration).
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# Hosts that run as the shared quickemu VM (taskfiles/vm.yaml). They boot
# with the same persistent host key, so they are one identity and its
# consumer set is the union of theirs.
VM_HOSTS = {"tests-server", "tests-desktop"}

# Known, tracked departures from "recipients == consumers". Each entry is
# (file, anchor) and names the issue that removes it. "*" matches any.
# Keep this short: an entry here is a hole someone has decided to live
# with for now, not a way to make the check pass.
EXCEPTIONS = {
    # Still encrypted to the whole fleet and read by nothing; retired in
    # phase 4.
    ("shared.yaml", "*"): "#507 retires shared.yaml",
    # The `tests-server` anchor matches no key the drill VM boots with
    # (that is `tests-vm`); it is left from an earlier VM.
    ("*", "tests-server"): "#510 stale drill anchor",
}

ANCHOR_RE = re.compile(r"^\s*-\s*&([A-Za-z0-9_-]+)\s+(age1[0-9a-z]+)\s*$")


def parse_anchors(sops_yaml_text):
    """Return ({anchor: recipient} for users, same for hosts) from .sops.yaml."""
    users, hosts, section = {}, {}, None
    for line in sops_yaml_text.splitlines():
        stripped = line.strip()
        if stripped == "users:":
            section = users
        elif stripped == "hosts:":
            section = hosts
        elif stripped.startswith("creation_rules:"):
            break
        else:
            match = ANCHOR_RE.match(line)
            if match and section is not None:
                section[match.group(1)] = match.group(2)
    return users, hosts


def file_recipients(path):
    """Age recipients from a sops file's own metadata, via yq."""
    out = subprocess.run(
        ["yq", "-o=json", ".sops.age // [] | map(.recipient)", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return set(json.loads(out))


def ssh_to_age(pubkey_line):
    out = subprocess.run(
        ["ssh-to-age"], input=pubkey_line, check=True, capture_output=True, text=True
    ).stdout
    return out.strip()


def live_host_key(host):
    """The host's ed25519 key as an age recipient, or None if it won't answer.

    ssh-keyscan does not read ssh_config, so resolve the real address and
    port with `ssh -G` (which parses config without connecting).
    """
    # A broken ssh_config stanza for one host falls back to its anchor
    # rather than aborting the run. ssh-keyscan has no ProxyJump, so a
    # host reachable only through a jump host also falls back (flagged).
    g = subprocess.run(["ssh", "-G", host], capture_output=True, text=True)
    if g.returncode != 0:
        return None
    cfg = g.stdout
    opts = dict(line.split(" ", 1) for line in cfg.splitlines() if " " in line)
    scan = subprocess.run(
        [
            "ssh-keyscan",
            "-T",
            "5",
            "-t",
            "ed25519",
            "-p",
            opts.get("port", "22"),
            opts.get("hostname", host),
        ],
        capture_output=True,
        text=True,
    )
    for line in scan.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "ssh-ed25519":
            return ssh_to_age(" ".join(parts[1:3]))
    return None


def excepted(file, anchor):
    for (f, a), why in EXCEPTIONS.items():
        if f in (file, "*") and a in (anchor, "*"):
            return why
    return None


def evaluate(files, consumers, identities, operators, anchors):
    """Pure core: compare recipients against consumers.

    files: {basename: set(recipient)}
    consumers: {host: set(basename)}
    identities: {identity name: {"key": recipient, "hosts": [host], "source": str}}
    operators: {anchor: recipient}
    anchors: {anchor: recipient} for hosts

    Returns (rows, problems): rows are (identity, file, wants, has, status),
    and problems is the list of failing rows' descriptions.
    """
    rows, problems = [], []
    key_to_anchor = {v: k for k, v in anchors.items()}

    for name, ident in sorted(identities.items()):
        wants = set().union(*(consumers.get(h, set()) for h in ident["hosts"]))
        anchor = key_to_anchor.get(ident["key"], name)
        for file in sorted(files):
            want, has = file in wants, ident["key"] in files[file]
            if want == has:
                status = "ok"
            elif want:
                status = "CANNOT DECRYPT"
            else:
                why = excepted(file, anchor)
                status = f"excepted ({why})" if why else "OVER-GRANTED"
            rows.append((name, file, want, has, status))
            if status in ("CANNOT DECRYPT", "OVER-GRANTED"):
                problems.append(f"{name} {status.lower()} {file}")
        for missing in sorted(wants - set(files)):
            problems.append(f"{name} reads {missing}, which does not exist")

    for file, recips in sorted(files.items()):
        for op, key in sorted(operators.items()):
            if key not in recips:
                problems.append(f"operator {op} is not a recipient of {file}")

    known = set(operators.values()) | {i["key"] for i in identities.values()}
    for file, recips in sorted(files.items()):
        for key in sorted(recips - known):
            anchor = key_to_anchor.get(key, key[:16] + "…")
            why = excepted(file, anchor)
            if why:
                rows.append((anchor, file, False, True, f"excepted ({why})"))
            else:
                problems.append(
                    f"{file} has recipient {anchor} that matches no host or operator"
                )

    for name, ident in sorted(identities.items()):
        expected = anchors.get(name)
        if ident["source"] == "live" and expected and expected != ident["key"]:
            why = excepted("*", name)
            if not why:
                problems.append(
                    f"{name}: .sops.yaml anchor differs from the live host key"
                )
    return rows, problems


def build_identities(hosts, anchors, vm_pubkey, offline):
    identities = {}
    vm_key = None
    if vm_pubkey and Path(vm_pubkey).exists():
        vm_key = ssh_to_age(Path(vm_pubkey).read_text())
    vm_members = sorted(h for h in hosts if h in VM_HOSTS)
    if vm_members:
        if vm_key:
            identities["tests-vm"] = {
                "key": vm_key,
                "hosts": vm_members,
                "source": "vm-key",
            }
        elif "tests-vm" in anchors:
            identities["tests-vm"] = {
                "key": anchors["tests-vm"],
                "hosts": vm_members,
                "source": "anchor",
            }
        else:
            print(
                f"[!] {', '.join(vm_members)}: no VM key file and no tests-vm anchor;"
                " their reads are unchecked",
                file=sys.stderr,
            )
    for host in sorted(set(hosts) - VM_HOSTS):
        key = None if offline else live_host_key(host)
        if key:
            identities[host] = {"key": key, "hosts": [host], "source": "live"}
        elif host in anchors:
            identities[host] = {
                "key": anchors[host],
                "hosts": [host],
                "source": "anchor",
            }
        else:
            print(f"[!] {host}: unreachable and no .sops.yaml anchor", file=sys.stderr)
    return identities


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--secrets-dir", required=True, type=Path)
    ap.add_argument("--consumers", required=True, type=Path)
    ap.add_argument("--vm-pubkey")
    ap.add_argument("--offline", action="store_true", help="anchors only, no keyscan")
    args = ap.parse_args()

    consumers = {h: set(fs) for h, fs in json.loads(args.consumers.read_text()).items()}
    operators, anchors = parse_anchors((args.secrets_dir / ".sops.yaml").read_text())
    files = {
        p.name: file_recipients(p)
        for p in sorted((args.secrets_dir / "sops").glob("*.yaml"))
    }
    identities = build_identities(consumers, anchors, args.vm_pubkey, args.offline)

    rows, problems = evaluate(files, consumers, identities, operators, anchors)
    covered = {h for i in identities.values() for h in i["hosts"]}
    problems += [
        f"{h} has no key to check (unreachable, no anchor)"
        for h in sorted(set(consumers) - covered)
    ]

    for name, ident in sorted(identities.items()):
        src = {
            "live": "live key",
            "vm-key": "VM key file",
            "anchor": "ANCHOR, unverified",
        }
        print(f"{name} ({src[ident['source']]}; hosts: {', '.join(ident['hosts'])})")
        for ident_name, file, want, has, status in rows:
            if ident_name == name and (want or has):
                print(
                    f"  {file:24} {'reads' if want else '-':6} {'can' if has else 'cannot':7} {status}"
                )
    others = [r for r in rows if r[0] not in identities]
    if others:
        print("recipients matching no host")
        for name, file, _, _, status in others:
            print(f"  {name:16} {file:24} {status}")
    print()
    if problems:
        print(f"FAIL: {len(problems)} problem(s)")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("PASS: every host decrypts exactly what it reads")
    return 0


if __name__ == "__main__":
    sys.exit(main())
