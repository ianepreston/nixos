# Toshiba Chromebook - test/spare machine
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.toshibachromebook = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.toshibachromebook;
    };
    modules = [
      ./_toshibachromebook-hardware.nix
      inputs.hardware.nixosModules.common-cpu-intel
      inputs.disko.nixosModules.disko
      ./_toshibachromebook-disks.nix
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
          home-manager.sharedModules = with inputs.self.modules.homeManager; [
            vibes
            moonlight
            browser
          ];
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
