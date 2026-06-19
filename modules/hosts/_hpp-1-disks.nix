# hpp-1 disk layout, with impermanence:
# @root on /dev/nvme0n1 is rolled back to @root-blank on every boot;
# @persist holds anything declared via the preservation-server module.
# @nix and the secondary SSD's @data subvolume are unchanged.
_: {
  imports = [ ./_rollback-root.nix ];

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
              size = "16G";
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
      ssd = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "@data" = {
                    mountpoint = "/mnt/data";
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
  systemd.tmpfiles.rules = [
    "d /mnt/data 0755 ipreston users -"
  ];

  # Preservation's bind mounts run before sysinit; /persist must be
  # available before they fire.
  fileSystems."/persist".neededForBoot = true;

  # Roll back @root to the blank snapshot on every boot (see
  # ./_rollback-root.nix and ianepreston/nixos#310).
  rollbackRoot.partlabel = "disk-primary-root";
}
