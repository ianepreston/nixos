# amos1 disk layout, with impermanence:
# @root on /dev/nvme0n1 is rolled back to @root-blank on every boot;
# @persist holds anything declared via the preservation-server module.
# @nix and the secondary SSD's @data subvolume are unchanged.
_: {
  disko.devices = {
    disk = {
      primary = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              name = "ESP";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" ];
              };
            };
            swap = {
              size = "32G";
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ]; # Override existing partition
                # Subvolumes must set a mountpoint in order to be mounted,
                # unless their parent is mounted
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
                  # Nothing else references it, so it stays pristine.
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
                };
              };
            };
          };

        };

      };
    };
  };
  # Preservation's bind mounts run before sysinit; /persist must be
  # available before they fire.
  fileSystems."/persist".neededForBoot = true;

  # Roll back @root to the empty snapshot on every boot. Runs in the
  # systemd initrd after the root device appears but before sysroot
  # is mounted from it. The previous @root is moved aside into
  # @old_roots/<timestamp> for post-mortem; entries older than 30d
  # are pruned next time the service runs.
  boot.initrd.systemd.services.rollback-root = {
    description = "Roll back @root to blank snapshot";
    wantedBy = [ "initrd.target" ];
    requires = [ "dev-disk-by\\x2dpartlabel-disk\\x2dprimary\\x2droot.device" ];
    after = [ "dev-disk-by\\x2dpartlabel-disk\\x2dprimary\\x2droot.device" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs_tmp
      mount -t btrfs -o subvol=/ /dev/disk/by-partlabel/disk-primary-root /btrfs_tmp

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
