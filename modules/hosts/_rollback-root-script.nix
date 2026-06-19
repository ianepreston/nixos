# Pure builder for the initrd @root rollback script. Kept free of any
# NixOS `config` dependency so it can be imported both by the initrd
# service (./_rollback-root.nix) and by its regression test
# (../flake/checks-rollback-root.nix), which runs this exact text
# against a scratch btrfs. Leading-underscore filename => import-tree
# skips it. See ianepreston/nixos#310.
#
# NixOS wraps this with `set -e` when it becomes a service `script`;
# everything on the critical path (archive the old root, recreate the
# blank root) must succeed, and the prune that follows is deliberately
# isolated so its failure can never propagate.
{
  partlabel,
  keepDays ? 30,
}:
''
  mkdir -p /btrfs_tmp
  mount -t btrfs -o subvol=/ /dev/disk/by-partlabel/${partlabel} /btrfs_tmp

  # 1. Archive the live root (if any) for post-mortem. Pick a
  #    non-colliding name so a same-second or retried boot can't
  #    fail the move (which would abort before the recreate).
  if [ -e /btrfs_tmp/@root ]; then
    mkdir -p /btrfs_tmp/@old_roots
    timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@root)" "+%Y-%m-%d_%H:%M:%S")
    dest="/btrfs_tmp/@old_roots/$timestamp"
    n=0
    while [ -e "$dest" ]; do
      n=$((n + 1))
      dest="/btrfs_tmp/@old_roots/''${timestamp}_$n"
    done
    mv /btrfs_tmp/@root "$dest"
  fi

  # 2. CRITICAL: recreate a pristine root from the blank snapshot
  #    *before* any maintenance, so a later failure can never
  #    leave the host unbootable.
  btrfs subvolume snapshot /btrfs_tmp/@root-blank /btrfs_tmp/@root

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

  umount /btrfs_tmp
''
