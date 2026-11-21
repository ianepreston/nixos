# Regression test for the initrd @root rollback service
# (../hosts/_rollback-root.nix), guarding ianepreston/nixos#310.
#
# It runs the *real* rollback script (built from the same config-free
# helper the initrd service uses, so there is no divergent copy) against
# a scratch btrfs exposed under the by-partlabel path the script mounts,
# and asserts the two properties that matter:
#   1. happy path  - a >keepDays old root WITH nested subvolumes is
#      pruned (proving `btrfs subvolume delete --recursive`, the awk-free
#      replacement, works), a stale @root-new is cleared, and @root is
#      recreated.
#   2. failure path - even when `btrfs subvolume delete` fails, @root is
#      still recreated (the host stays bootable) and a prune-failed
#      marker is written.
#   3. no @root-blank (#910) - the script fails without archiving, and
#      @root is left in place with its contents.
#   4. snapshot failure (#910) - the script fails and @root is never
#      moved.
#
# The script body runs under `set -e`, matching how NixOS executes it as
# an initrd service, so the prune's best-effort isolation is exercised.
_: {
  perSystem =
    { pkgs, lib, ... }:
    let
      # The exact script the initrd would run, under `set -e`, built
      # from the same helper the service uses.
      rollback = pkgs.writeShellScript "rollback-under-test" (
        "set -e\n" + import ../hosts/_rollback-root-script.nix { partlabel = "rollbacktest"; }
      );
      # A `btrfs` shim that fails every `subvolume <sub>` but otherwise
      # behaves normally, to inject a failure into one step.
      failingBtrfs =
        sub:
        pkgs.writeShellScript "fake-btrfs-${sub}" ''
          if [ "$1" = "subvolume" ] && [ "$2" = "${sub}" ]; then
            exit 1
          fi
          exec ${pkgs.btrfs-progs}/bin/btrfs "$@"
        '';
    in
    {
      # NixOS VM tests are Linux-only; keep the `checks` attribute itself
      # unconditional (conditioning the attr name on `pkgs` makes
      # flake-parts recurse) and gate just its contents.
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        rollback-root-resilience = pkgs.testers.runNixOSTest {
          name = "rollback-root-resilience";

          nodes.machine = {
            boot.supportedFilesystems = [ "btrfs" ];
            boot.kernelModules = [ "loop" ];
            environment.systemPackages = [ pkgs.btrfs-progs ];
          };

          testScript = ''
            machine.wait_for_unit("multi-user.target")

            # Scratch btrfs on a loop device, exposed under the
            # by-partlabel path the rollback script mounts.
            machine.succeed("truncate -s 1G /scratch.img")
            loop = machine.succeed("losetup -f --show /scratch.img").strip()
            machine.succeed(f"mkfs.btrfs -f {loop}")
            machine.succeed("mkdir -p /dev/disk/by-partlabel /mnt")
            machine.succeed(f"ln -sf {loop} /dev/disk/by-partlabel/rollbacktest")

            def build_layout():
                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("btrfs subvolume create /mnt/@root-blank")
                machine.succeed("btrfs subvolume create /mnt/@root")
                machine.succeed("btrfs subvolume create /mnt/@root/srv")
                machine.succeed("mkdir -p /mnt/@old_roots /mnt/@persist/var/lib")
                # An old root WITH nested subvolumes - the shape that
                # bricked the host when awk was missing.
                machine.succeed("btrfs subvolume create /mnt/@old_roots/oldroot")
                machine.succeed("btrfs subvolume create /mnt/@old_roots/oldroot/srv")
                machine.succeed("mkdir -p /mnt/@old_roots/oldroot/var/lib")
                machine.succeed("btrfs subvolume create /mnt/@old_roots/oldroot/var/lib/machines")
                machine.succeed("btrfs subvolume create /mnt/@old_roots/recentroot")
                machine.succeed("touch -d '45 days ago' /mnt/@old_roots/oldroot")
                machine.succeed("touch -d '5 days ago'  /mnt/@old_roots/recentroot")
                # A half-built root left by an interrupted boot.
                machine.succeed("btrfs subvolume create /mnt/@root-new")
                machine.succeed("btrfs subvolume create /mnt/@root-new/nested")
                machine.succeed("touch /mnt/@root-new/stale")
                machine.succeed("umount /mnt")

            def old_roots_count():
                return machine.succeed("ls -1 /mnt/@old_roots | wc -l").strip()

            def run_failing(prefix, expected):
                status, out = machine.execute(f"{prefix}${rollback} 2>&1")
                assert status != 0, f"rollback unexpectedly succeeded: {out}"
                assert expected in out, f"expected {expected!r} in: {out}"
                # the EXIT trap unmounted on the way out
                machine.fail("mountpoint -q /btrfs_tmp")

            def seed_live_root():
                machine.succeed("touch /mnt/@root/live-marker")
                machine.succeed("btrfs subvolume create /mnt/@root/nested")

            def assert_live_root_kept(before):
                machine.succeed("test -e /mnt/@root/live-marker")
                machine.succeed("test -d /mnt/@root/nested")
                machine.fail("test -e /mnt/@root-new")
                assert old_roots_count() == before, "@old_roots gained an entry"

            build_layout()

            with subtest("happy path prunes nested old root and recreates @root"):
                machine.succeed("${rollback}")
                machine.fail("mountpoint -q /btrfs_tmp")
                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("test -e /mnt/@root")
                machine.fail("test -e /mnt/@root/srv")
                machine.fail("test -e /mnt/@root/stale")
                machine.fail("test -e /mnt/@root-new")
                machine.fail("test -e /mnt/@old_roots/oldroot")
                machine.succeed("test -e /mnt/@old_roots/recentroot")
                machine.fail("test -e /mnt/@persist/var/lib/rollback-root/prune-failed")
                machine.succeed("umount /mnt")

            with subtest("prune failure still recreates @root and records a marker"):
                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("btrfs subvolume create /mnt/@old_roots/oldroot2")
                machine.succeed("btrfs subvolume create /mnt/@old_roots/oldroot2/srv")
                machine.succeed("touch -d '45 days ago' /mnt/@old_roots/oldroot2")
                machine.succeed("umount /mnt")

                machine.succeed("mkdir -p /run/fakebin-delete")
                machine.succeed("ln -sf ${failingBtrfs "delete"} /run/fakebin-delete/btrfs")
                machine.succeed("PATH=/run/fakebin-delete:$PATH ${rollback}")

                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("test -e /mnt/@root")
                machine.succeed("test -e /mnt/@persist/var/lib/rollback-root/prune-failed")
                # delete was forced to fail, so the old root is still there
                machine.succeed("test -e /mnt/@old_roots/oldroot2")
                machine.succeed("umount /mnt")

            with subtest("missing @root-blank leaves @root untouched"):
                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("btrfs subvolume delete /mnt/@root-blank")
                seed_live_root()
                before = old_roots_count()
                machine.succeed("umount /mnt")

                run_failing("", "@root-blank missing")

                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                assert_live_root_kept(before)
                machine.fail("test -e /mnt/@root-blank")
                # restore the layout for the next subtest
                machine.succeed("btrfs subvolume create /mnt/@root-blank")
                machine.succeed("rm /mnt/@root/live-marker")
                machine.succeed("btrfs subvolume delete /mnt/@root/nested")
                machine.succeed("umount /mnt")

            with subtest("snapshot failure never moves @root"):
                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                seed_live_root()
                before = old_roots_count()
                machine.succeed("umount /mnt")

                machine.succeed("mkdir -p /run/fakebin-snapshot")
                machine.succeed("ln -sf ${failingBtrfs "snapshot"} /run/fakebin-snapshot/btrfs")
                run_failing("PATH=/run/fakebin-snapshot:$PATH ", "snapshot of @root-blank failed")

                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                assert_live_root_kept(before)
                machine.succeed("umount /mnt")
          '';
        };
      };
    };
}
