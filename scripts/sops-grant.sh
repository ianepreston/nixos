#!/usr/bin/env bash
# Add `- *ANCHOR` to the creation_rule of each named sops file in
# nix-secrets' .sops.yaml, after that rule's last `- *x` entry.
#
# Usage: scripts/sops-grant.sh SOPS_YAML ANCHOR FILE...
#
# Prints each file it changed, one per line, on stdout, which is the list
# the caller must `sops updatekeys`. Progress goes to stderr. Fails, and
# leaves .sops.yaml untouched, if any file has no creation_rule or a rule
# with no `- *x` entry to insert after. It never reports a grant it did
# not make.
#
# Shared by bootstrap:secrets and vm:sops-authorize. #508 replaces this
# hand-editing with a .sops.yaml generator.
set -euo pipefail

sops_yaml=$1
anchor=$2
shift 2

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp "$sops_yaml" "$tmp"

changed=()
for f in "$@"; do
  stem=${f%.yaml}
  # ENVIRON, not awk -v: -v would turn the regex's `\.` into `.`.
  rc=0
  HDR="  - path_regex: ${stem}\\.yaml\$" ENTRY="          - *${anchor}" awk '
		{ line[NR] = $0 }
		$0 == ENVIRON["HDR"] { start = NR }
		END {
			if (!start) exit 2
			last = 0; seen = 0
			for (i = start + 1; i <= NR; i++) {
				if (line[i] ~ /^  - path_regex:/ || line[i] ~ /^[^ ]/) break
				entry = line[i]; sub(/[[:space:]]*#.*$/, "", entry)
				if (entry == ENVIRON["ENTRY"]) seen = 1
				if (entry ~ /^ +- \*/) last = i
			}
			if (seen) exit 4
			if (!last) exit 3
			for (i = 1; i <= NR; i++) { print line[i]; if (i == last) print ENVIRON["ENTRY"] }
		}
	' "$tmp" >"$tmp.new" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp.new"
    case $rc in
      4)
        echo "[~] *${anchor} already in $f" >&2
        continue
        ;;
      2) echo "[!] $sops_yaml has no creation_rule for $f" >&2 ;;
      3) echo "[!] $f's creation_rule has no '- *x' entry to insert after" >&2 ;;
      *) echo "[!] awk failed ($rc) on $f" >&2 ;;
    esac
    exit 1
  fi
  mv "$tmp.new" "$tmp"
  echo "[+] *${anchor} added to $f" >&2
  changed+=("$f")
done

cp "$tmp" "$sops_yaml"
printf '%s\n' "${changed[@]+"${changed[@]}"}"
