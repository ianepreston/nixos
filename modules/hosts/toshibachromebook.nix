# Toshiba Chromebook - test/spare machine
{
  inputs,
  hostSpecs,
  customLib,
  ...
}:
{
  flake.nixosConfigurations.toshibachromebook = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs customLib;
      hostSpec = hostSpecs.toshibachromebook;
    };
    modules = [
      (customLib.relativeToRoot "hosts/nixos/toshibachromebook/hardware-configuration.nix")
      inputs.hardware.nixosModules.common-cpu-intel
      inputs.disko.nixosModules.disko
      (customLib.relativeToRoot "hosts/common/disks/toshibachromebook.nix")
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
      flatpak
      obsidian
      printing
      zsa-keeb
    ])
    ++ [
      (
        { pkgs, ... }:
        {
          boot = {
            loader.grub.extraConfig = "cros_legacy";
            kernelPackages = pkgs.linuxPackages_latest;
          };

          networking = {
            hostName = "toshibachromebook";
            networkmanager.enable = true;
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
