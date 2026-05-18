# btrfs disk layout for the tests-server VM (single virtio disk, no
# LUKS), with impermanence: @root is rolled back to @root-blank on
# every boot; @persist holds anything declared via the preservation
# module (which on this host comes from the `server` profile's
# preservation-server.nix).
#
# Functionally identical to _testvm-disks.nix; kept as a separate file
# so the testvm pattern (minimal, bootstrap-shakedown) stays decoupled
# from the tests-server pattern (server-shaped, restore-drill target).
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

  fileSystems."/persist".neededForBoot = true;

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
