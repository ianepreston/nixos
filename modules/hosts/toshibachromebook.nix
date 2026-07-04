# Toshiba Chromebook - test/spare machine
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.toshibachromebook = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.toshibachromebook;
    extraModules = [
      ./_toshibachromebook-hardware.nix
      inputs.hardware.nixosModules.common-cpu-intel
      inputs.disko.nixosModules.disko
      ./_toshibachromebook-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
      flatpak
      ipad
      printing
      tailscale
      zsa-keeb
      parents-user
    ])
    ++ [
      (
        { pkgs, ... }:
        {
          home-manager.sharedModules = with inputs.self.modules.homeManager; [
            vibes
            moonlight
            browser
            obsidian
          ];
          boot = {
            loader.grub.extraConfig = "cros_legacy";
            kernelPackages = pkgs.linuxPackages_latest;
          };

          networking = {
            networkmanager.enable = true;
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
