# Regression test for the initrd @root rollback service
# (../hosts/_rollback-root.nix), guarding ianepreston/nixos#310.
#
# It runs the *real* rollback script (built from the same config-free
# helper the initrd service uses, so there is no divergent copy) against
# a scratch btrfs exposed under the by-partlabel path the script mounts,
# and asserts the two properties that matter:
#   1. happy path  - a >keepDays old root WITH nested subvolumes is
#      pruned (proving `btrfs subvolume delete --recursive`, the awk-free
#      replacement, works) and @root is recreated.
#   2. failure path - even when `btrfs subvolume delete` fails, @root is
#      still recreated (the host stays bootable) and a prune-failed
#      marker is written.
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
      # A `btrfs` shim that fails every `subvolume delete` but otherwise
      # behaves normally, to simulate a prune failure.
      fakeBtrfs = pkgs.writeShellScript "fake-btrfs" ''
        if [ "$1" = "subvolume" ] && [ "$2" = "delete" ]; then
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
                machine.succeed("umount /mnt")

            build_layout()

            with subtest("happy path prunes nested old root and recreates @root"):
                machine.succeed("${rollback}")
                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("test -e /mnt/@root")
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

                machine.succeed("mkdir -p /run/fakebin")
                machine.succeed("ln -sf ${fakeBtrfs} /run/fakebin/btrfs")
                machine.succeed("PATH=/run/fakebin:$PATH ${rollback}")

                machine.succeed("mount /dev/disk/by-partlabel/rollbacktest /mnt")
                machine.succeed("test -e /mnt/@root")
                machine.succeed("test -e /mnt/@persist/var/lib/rollback-root/prune-failed")
                # delete was forced to fail, so the old root is still there
                machine.succeed("test -e /mnt/@old_roots/oldroot2")
                machine.succeed("umount /mnt")
          '';
        };
      };
    };
}
