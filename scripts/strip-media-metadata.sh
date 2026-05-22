#!/usr/bin/env bash
#
# Discover (and optionally delete) Jellyfin/*arr-style metadata files
# (.nfo, posters, fanart, thumbnails) under /mnt/content/{Movies,TV} on a
# remote host. Subtitles and media files are left untouched.
#
# Dry-run by default: lists what would be removed without touching anything.
# Pass --apply to actually delete (with an interactive confirmation prompt).

set -euo pipefail

HOST="hpp-1"
DRY_RUN=1
ROOTS=(/mnt/content/Movies /mnt/content/TV)
AS_USER=""  # auto-discovered (server-* user) at apply time unless set

# Allowlist of extensions we treat as deletable metadata. Matched
# case-insensitively. Subtitle (.srt, .sub, .idx, .ass, .ssa, .vtt, .sup,
# .smi) and media extensions are intentionally absent.
EXTS=(nfo jpg jpeg png webp gif bmp tbn xml)

# Path globs to exclude from the sweep. Jellyfin's *.trickplay/ scrubbing
# thumbnails are technically metadata, but they're transcoded locally from
# the media — much more expensive to regenerate than redownloading posters.
EXCLUDE_PATHS=('*/*.trickplay/*')

usage() {
	cat <<EOF
Usage: $0 [--host HOST] [--apply] [--as-user USER]

Discover .nfo + image metadata under /mnt/content/{Movies,TV} on HOST.

  --host HOST       Target host (default: hpp-1)
  --apply           Prompt and then delete (default: dry-run, list only)
  --as-user USER    Remote user that owns the NFS files; deletion is run
                    via sudo -u USER. Default: auto-discovered (first
                    server-* user in /etc/passwd on HOST).
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case $1 in
		--host)
			HOST="$2"
			shift 2
			;;
		--apply)
			DRY_RUN=0
			shift
			;;
		--as-user)
			AS_USER="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

# Build the find -iname '*.ext' -o ... clause.
ext_clause=""
for ext in "${EXTS[@]}"; do
	ext_clause+=" -iname '*.${ext}' -o"
done
ext_clause="${ext_clause% -o}"

# Build the path-exclusion prune clause.
prune_clause=""
for p in "${EXCLUDE_PATHS[@]}"; do
	prune_clause+=" ! -path '${p}'"
done

remote_cmd="find ${ROOTS[*]} -type f${prune_clause} \\( ${ext_clause} \\) -print0"

echo "Host:    ${HOST}"
echo "Mode:    $([[ $DRY_RUN -eq 1 ]] && echo 'dry-run' || echo 'apply')"
echo "Roots:   ${ROOTS[*]}"
echo "Exts:    ${EXTS[*]}"
echo "Exclude: ${EXCLUDE_PATHS[*]}"
echo

# -n: don't let ssh consume our script's stdin (otherwise it eats the
# read -p response below).
mapfile -d '' -t FILES < <(ssh -n "$HOST" "$remote_cmd")

if [[ ${#FILES[@]} -eq 0 ]]; then
	echo "No metadata files found."
	exit 0
fi

for f in "${FILES[@]}"; do
	printf '  %s\n' "$f"
done

echo
echo "Total: ${#FILES[@]} files"

# Per-extension breakdown so you can sanity-check the counts before nuking.
echo
echo "By extension:"
for f in "${FILES[@]}"; do
	printf '%s\n' "${f##*.}"
done | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -rn | sed 's/^/  /'

if [[ $DRY_RUN -eq 1 ]]; then
	echo
	echo "(dry-run; re-run with --apply to delete)"
	exit 0
fi

# /mnt/content is an NFS share that enforces UID-based access; the files
# are owned by a server-* user that varies per host (server-dev on hpp-1,
# etc.). Login users don't have write access, so route rm through
# sudo -u <server-user>.
if [[ -z "$AS_USER" ]]; then
	AS_USER=$(ssh -n "$HOST" "getent passwd | awk -F: '/^server-/ {print \$1; exit}'")
fi
if [[ -z "$AS_USER" ]]; then
	echo "Could not discover a server-* user on $HOST." >&2
	echo "Pass --as-user USER to override." >&2
	exit 1
fi

echo
echo "Delete will run as: ${AS_USER} (via sudo on ${HOST})"
read -rp "Delete all ${#FILES[@]} files on ${HOST}? Type 'yes' to confirm: " reply
if [[ "$reply" != "yes" ]]; then
	echo "Aborted."
	exit 1
fi

# Stream the null-delimited list to xargs on the remote so weird filenames
# (spaces, brackets, etc.) survive intact.
printf '%s\0' "${FILES[@]}" | ssh "$HOST" "sudo -n -u ${AS_USER} xargs -0 -r rm -v"
echo "Done."
