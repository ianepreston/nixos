# btrfs disk layout for any quickemu-driven VM target (single virtio
# disk, no LUKS), with impermanence: @root is rolled back to @root-blank
# on every boot; @persist holds anything declared via the preservation
# module.
#
# Imported by both tests-server.nix and tests-desktop.nix. Lives in a
# shared file because every VM target uses the same shape — disk size
# is set on the qcow2 by `task vm:up`, not in this layout.
_: {
  disko.devices = {
    disk = {
      disk0 = {
        type = "disk";
        device = "/dev/vda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              priority = 1;
              type = "EF00";
              name = "boot";
              size = "514M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "@root" = {
                    mountpoint = "/";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  # Empty subvolume created at install time; the initrd
                  # rollback service snapshots from this on every boot.
                  "@root-blank" = { };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "@swap" = {
                    mountpoint = "/.swapvol";
                    swap.swapfile.size = "4G";
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  # Preservation's bind mounts run before sysinit; /persist must be
  # available before they fire, so mark it as needed in stage 1.
  fileSystems."/persist".neededForBoot = true;

  # Roll back @root to the empty snapshot on every boot. Runs in the
  # systemd initrd after the root device appears but before sysroot
  # is mounted from it. The previous @root is moved aside into
  # @old_roots/<timestamp> for post-mortem from a recovery shell;
  # entries older than 30 days are pruned next time the service runs.
  boot.initrd.systemd.services.rollback-root = {
    description = "Roll back @root to blank snapshot";
    wantedBy = [ "initrd.target" ];
    requires = [ "dev-disk-by\\x2dpartlabel-disk\\x2ddisk0\\x2droot.device" ];
    after = [ "dev-disk-by\\x2dpartlabel-disk\\x2ddisk0\\x2droot.device" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs_tmp
      mount -t btrfs -o subvol=/ /dev/disk/by-partlabel/disk-disk0-root /btrfs_tmp

      if [ -e /btrfs_tmp/@root ]; then
        mkdir -p /btrfs_tmp/@old_roots
        timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@root)" "+%Y-%m-%d_%H:%M:%S")
        mv /btrfs_tmp/@root "/btrfs_tmp/@old_roots/$timestamp"
      fi

      # Recursively delete subvolumes under @old_roots older than 30d,
      # depth-first so nested subvols go before their parent.
      delete_subvolume_recursively() {
        local subvol="$1"
        for child in $(btrfs subvolume list -o "$subvol" 2>/dev/null | awk '{print $NF}'); do
          delete_subvolume_recursively "/btrfs_tmp/$child"
        done
        btrfs subvolume delete "$subvol"
      }
      for old in $(find /btrfs_tmp/@old_roots/ -maxdepth 1 -mtime +30 2>/dev/null); do
        delete_subvolume_recursively "$old"
      done

      btrfs subvolume snapshot /btrfs_tmp/@root-blank /btrfs_tmp/@root
      umount /btrfs_tmp
    '';
  };
}
