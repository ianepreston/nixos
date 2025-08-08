# NOTE: ... is needed because dikso passes diskoFile
{
  ...
}:
{
  disko.devices = {
    disk = {
      disk0 = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            bios = {
              priority = 1;
              name = "BIOS";
              size = "2M";
              # end = "2MiB";
              type = "EF02";
              # content = {
              #   type = "filesystem";
              #   format = "vfat";
              #   mountpoint = "/boot";
              #   mountOptions = [ "defaults" ];
              # };
            };
            boot = {
              priority = 2;
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
                  "@nix" = {
                    mountpoint = "/nix";
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
}
