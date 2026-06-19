# btrfs disk layout for any quickemu-driven VM target (single virtio
# disk, no LUKS), with impermanence: @root is rolled back to @root-blank
# on every boot; @persist holds anything declared via the preservation
# module.
#
# Imported by both tests-server.nix and tests-desktop.nix. Lives in a
# shared file because every VM target uses the same shape — disk size
# is set on the qcow2 by `task vm:up`, not in this layout.
_: {
  imports = [ ./_rollback-root.nix ];

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

  # Roll back @root to the blank snapshot on every boot (see
  # ./_rollback-root.nix and ianepreston/nixos#310).
  rollbackRoot.partlabel = "disk-disk0-root";
}
