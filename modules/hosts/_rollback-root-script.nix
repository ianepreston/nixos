# Pure builder for the initrd @root rollback script. Kept free of any
# NixOS `config` dependency so it can be imported both by the initrd
# service (./_rollback-root.nix) and by its regression test
# (../flake/checks-rollback-root.nix), which runs this exact text
# against a scratch btrfs. Leading-underscore filename => import-tree
# skips it. See ianepreston/nixos#310 and #910.
#
# NixOS wraps this with `set -e` when it becomes a service `script`.
# Every generation's fstab mounts subvol=@root, so the one outcome that
# must never happen is "no @root" (#910). The new root is therefore
# snapshotted beside the live one first, and the live root is only
# archived once its replacement exists:
#   - no @root-blank: the disk was never installed for rollback (the
#     wrong host's config switched in place, or impermanence added by
#     `task deploy` instead of a reinstall). Touch nothing.
#   - snapshot fails (e.g. a full filesystem): @root was never moved.
#   - the final rename fails: move the archived root back.
# Each of these exits non-zero so the unit shows as failed. Nothing in
# the initrd Requires= it, so sysroot.mount proceeds on @root: the worst
# case is "not rolled back", never "no root". The prune that follows
# is isolated so its failure can never propagate (#310).
{
  partlabel,
  keepDays ? 30,
}:
''
  mkdir -p /btrfs_tmp
  mount -t btrfs -o subvol=/ /dev/disk/by-partlabel/${partlabel} /btrfs_tmp
  trap 'umount /btrfs_tmp 2>/dev/null || true' EXIT

  fail() {
    echo "rollback-root: $*" >&2
    exit 1
  }

  # 0. Pre-flight: touch nothing on a layout this script doesn't own.
  #    Never create @root-blank here instead: that would wipe a
  #    non-impermanent host's root on the next boot.
  [ -e /btrfs_tmp/@root-blank ] ||
    fail "@root-blank missing; leaving @root untouched (disk not installed for rollback?)"

  # 1. Build the pristine root beside the live one, so a failure here
  #    leaves @root where it was. A leftover from an interrupted boot
  #    is cleared first.
  new=/btrfs_tmp/@root-new
  if [ -e "$new" ]; then
    btrfs subvolume delete --recursive "$new" ||
      fail "cannot clear stale @root-new; leaving @root untouched"
  fi
  btrfs subvolume snapshot /btrfs_tmp/@root-blank "$new" ||
    fail "snapshot of @root-blank failed; leaving @root untouched"

  # 2. Archive the live root (if any) for post-mortem, then move the
  #    new one into place. Pick a non-colliding archive name so a
  #    same-second or retried boot can't fail the move.
  dest=
  if [ -e /btrfs_tmp/@root ]; then
    mkdir -p /btrfs_tmp/@old_roots
    timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@root)" "+%Y-%m-%d_%H:%M:%S")
    dest="/btrfs_tmp/@old_roots/$timestamp"
    n=0
    while [ -e "$dest" ]; do
      n=$((n + 1))
      dest="/btrfs_tmp/@old_roots/''${timestamp}_$n"
    done
    mv /btrfs_tmp/@root "$dest" ||
      fail "cannot archive @root; leaving it in place"
  fi
  if ! mv "$new" /btrfs_tmp/@root; then
    if [ -n "$dest" ] && mv "$dest" /btrfs_tmp/@root; then
      fail "cannot move @root-new into place; previous root restored"
    fi
    fail "cannot move @root-new into place; previous root is at ''${dest:-<none>}"
  fi

  # 3. Best-effort prune of archived roots older than keepDays.
  #    `btrfs subvolume delete --recursive` removes nested
  #    subvolumes itself, so no awk (absent from the initrd) is
  #    needed. Wrapped so it can never abort the service under
  #    `set -e`. `-mindepth 1` keeps the @old_roots dir itself out.
  prune_old_roots() {
    local rc=0 old
    for old in $(find /btrfs_tmp/@old_roots/ -mindepth 1 -maxdepth 1 -mtime +${toString keepDays} 2>/dev/null); do
      btrfs subvolume delete --recursive "$old" || rc=1
    done
    return $rc
  }

  # Record prune health in @persist so the running system can
  # alert on it (journald is not persisted across the rollback).
  marker=/btrfs_tmp/@persist/var/lib/rollback-root
  if prune_old_roots; then
    rm -f "$marker/prune-failed" 2>/dev/null || true
  else
    mkdir -p "$marker" 2>/dev/null || true
    date -u "+%Y-%m-%dT%H:%M:%SZ" > "$marker/prune-failed" 2>/dev/null || true
  fi
''
